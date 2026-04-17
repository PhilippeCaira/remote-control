# Server installation

End-to-end install of the `remote-control` server stack on a fresh Linux VPS.
Target state after this document:

- `rdv.<your-domain>` exposes hbbs/hbbr on ports 21115-21119 (TCP) + 21116/UDP;
- `api.<your-domain>` exposes the rustdesk-api admin UI and web client
  behind Let's Encrypt TLS;
- `dl.<your-domain>` serves signed installer binaries.

## 1. Prerequisites

- A Linux VPS (Debian 12 or Ubuntu 22.04+ LTS recommended). 2 vCPU / 2 GB RAM
  is enough for dozens of concurrent sessions; scale up only if relay
  throughput becomes a bottleneck.
- A domain where you control DNS.
- Root or sudo access on the VPS.
- Opened inbound ports on the hosting provider's network firewall
  (Hetzner, OVH, Scaleway, DigitalOcean, …):

  | Port  | Proto | Purpose                       |
  |-------|-------|-------------------------------|
  | 22    | TCP   | SSH (ideally restricted by IP)|
  | 80    | TCP   | ACME HTTP-01 challenge        |
  | 443   | TCP   | Caddy (api + dl)              |
  | 21115 | TCP   | hbbs                          |
  | 21116 | TCP   | hbbs                          |
  | 21116 | UDP   | hbbs (NAT hole punching)      |
  | 21117 | TCP   | hbbr (relay)                  |
  | 21118 | TCP   | hbbs web client WebSocket     |
  | 21119 | TCP   | hbbr WebSocket                |

## 2. DNS

Create three A (and AAAA, if IPv6) records pointing to the VPS public IP:

```
rdv.<your-domain>   A   203.0.113.42
api.<your-domain>   A   203.0.113.42
dl.<your-domain>    A   203.0.113.42
```

Verify with `dig +short rdv.<your-domain>` before moving on. Caddy will fail
to obtain a certificate if the A record is not resolvable yet.

## 3. Install Docker

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker "$USER"  # optional; log out/in to take effect
```

Confirm:

```bash
docker --version
docker compose version
```

## 4. OS firewall

Even behind a cloud firewall, add a host-level guard. On Debian/Ubuntu:

```bash
sudo apt install -y ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp
sudo ufw allow 80,443/tcp
sudo ufw allow 21115:21117/tcp
sudo ufw allow 21118:21119/tcp
sudo ufw allow 21116/udp
sudo ufw enable
```

## 5. Deploy the repository

```bash
sudo mkdir -p /opt/remote-control
sudo chown "$USER": /opt/remote-control
git clone https://github.com/<your-org>/remote-control.git /opt/remote-control
cd /opt/remote-control/server

cp .env.example .env
chmod 600 .env
editor .env     # fill DOMAIN_*, ACME_EMAIL, RUSTDESK_API_JWT_KEY
```

Generate a strong JWT secret:

```bash
openssl rand -hex 32
```

## 6. Generate the server signing key

```bash
./scripts/init-keys.sh
```

On first run, this starts the `rustdesk` container, waits for
`volumes/rustdesk/server/id_ed25519{,.pub}` to appear, and prints the public
key on stdout. Copy it.

## 7. Register GitHub Secrets (before any client build)

At `https://github.com/<your-org>/remote-control/settings/secrets/actions`,
add the four required secrets:

| Secret name         | Value                                |
|---------------------|--------------------------------------|
| `RS_PUB_KEY`        | the ed25519 pubkey printed in §6     |
| `RENDEZVOUS_SERVER` | `rdv.<your-domain>`                  |
| `RELAY_SERVER`      | `rdv.<your-domain>:21117`            |
| `API_SERVER`        | `https://api.<your-domain>`          |

> **Ordering matters.** Client builds embed these values at compile time;
> they cannot be changed in a shipped binary without a new release.

## 8. Bring up the full stack

```bash
docker compose up -d
docker compose ps
```

All services should report `running (healthy)` within a minute. Then:

```bash
curl -sI https://api.<your-domain>/_admin/
# HTTP/2 200
```

Open `https://api.<your-domain>/_admin/` in a browser. Default credentials
appear in `docker compose logs rustdesk | grep -i password` the very first
time the container starts — change them immediately.

## 9. Smoke test with the official client

Before investing effort in the custom client build, verify the server works
with the upstream RustDesk binary:

1. On a test machine, install `rustdesk` from https://rustdesk.com/.
2. Settings → Network → set:
   - ID server: `rdv.<your-domain>`
   - Relay server: `rdv.<your-domain>:21117`
   - API server: `https://api.<your-domain>`
   - Key: paste the `RS_PUB_KEY` value.
3. Repeat on a second machine and initiate a connection. `docker compose logs
   rustdesk` should show the registration and relay traffic.

If this works, you can proceed to the client-build milestone with
confidence. If it does not, the problem is on the server side — fix it
here, not in the client.

## 10. Schedule backups

```bash
sudo crontab -e
# add:
5 3 * * * /opt/remote-control/server/scripts/backup.sh >>/var/log/rdc-backup.log 2>&1
```

Optional offsite: install `rclone`, configure a remote named e.g. `b2`, and
append `RCLONE_REMOTE=b2:my-bucket/rdc` to the cron environment.

## 11. Hardening checklist

- [ ] `.env` is `chmod 600` and owned by a non-root deploy user.
- [ ] `volumes/rustdesk/server/id_ed25519` is `chmod 600`.
- [ ] `MUST_LOGIN=Y` in `.env` — enforce admin-managed accounts.
- [ ] Admin default password changed.
- [ ] SSH restricted by key + fail2ban, or VPN-only.
- [ ] Backups verified by restoring into `/tmp/restore-test` at least once.
- [ ] Monitoring: external blackbox probe on `https://api.<your-domain>/`.

## Troubleshooting

- **Caddy fails TLS**: confirm DNS A records point at this VPS; check
  `docker compose logs caddy` for the ACME error text.
- **UDP 21116 blocked**: some VPS providers filter UDP by default. Use
  `iperf3 -u -s` on the VPS + client to confirm traversal; switch provider
  if the packets never arrive.
- **Clients stuck on "Trying to connect"**: nearly always a mismatched
  `RS_PUB_KEY`. Compare the server pubkey with the one embedded in the
  binary (`strings <binary> | grep -A1 -B1 <first-8-chars-of-pubkey>`).
