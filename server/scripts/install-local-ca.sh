#!/usr/bin/env bash
# ============================================================================
# install-local-ca.sh — trust the Caddy `tls internal` root CA on this host
# and add hostname entries to /etc/hosts, so the locally-built client can
# reach https://api.rdc.local and the rendezvous hostname rdv.rdc.local.
#
# Meant ONLY for the local testing profile (docker-compose.override.yml).
# Fully reversible via uninstall-local-ca.sh.
#
# Requirements:
#   - sudo
#   - Fedora/RHEL: `trust` (ca-certificates), `update-ca-trust` (both
#     present by default).
# ============================================================================
set -euo pipefail

SERVER_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SERVER_DIR"

HOSTS_BEGIN="# BEGIN remote-control-local"
HOSTS_END="# END remote-control-local"
CA_SRC="volumes/caddy/data/caddy/pki/authorities/local/root.crt"
CA_ANCHOR_NAME="remote-control-local.pem"

log() { printf '[install-local-ca] %s\n' "$*"; }
fail() { printf '[install-local-ca] ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Ensure docker-compose.override.yml is active (the CA only exists after
#    Caddy has started at least once under `tls internal`).
# ---------------------------------------------------------------------------
[[ -f docker-compose.override.yml ]] \
    || fail "docker-compose.override.yml missing. Copy the .example first."

# ---------------------------------------------------------------------------
# 2. Wait for Caddy to produce its root CA (up to 60 s after compose up).
# ---------------------------------------------------------------------------
log "waiting for $CA_SRC to appear..."
for _ in $(seq 1 60); do
    [[ -f "$CA_SRC" ]] && break
    sleep 1
done
[[ -f "$CA_SRC" ]] || fail "Caddy root CA not produced yet. Did you run 'docker compose up -d'?"

# ---------------------------------------------------------------------------
# 3. Install the CA in the system trust store.
# ---------------------------------------------------------------------------
if command -v trust >/dev/null; then
    log "installing trust anchor via p11-kit 'trust'"
    sudo cp "$CA_SRC" "/etc/pki/ca-trust/source/anchors/${CA_ANCHOR_NAME}"
    sudo update-ca-trust extract
elif [[ -d /usr/local/share/ca-certificates ]]; then
    log "installing trust anchor via update-ca-certificates (Debian-style)"
    sudo cp "$CA_SRC" "/usr/local/share/ca-certificates/${CA_ANCHOR_NAME%.pem}.crt"
    sudo update-ca-certificates
else
    fail "neither p11-kit 'trust' nor /usr/local/share/ca-certificates available"
fi

# ---------------------------------------------------------------------------
# 4. Idempotently append hostnames to /etc/hosts.
# ---------------------------------------------------------------------------
if grep -qF "$HOSTS_BEGIN" /etc/hosts; then
    log "/etc/hosts already contains our block — skipping"
else
    log "adding hostname entries to /etc/hosts"
    sudo tee -a /etc/hosts >/dev/null <<EOF

$HOSTS_BEGIN
127.0.0.1 rdv.rdc.local
127.0.0.1 api.rdc.local
127.0.0.1 dl.rdc.local
$HOSTS_END
EOF
fi

# ---------------------------------------------------------------------------
# 5. Verify from the host. Caddy may be running on a non-standard port when
#    80/443 are already taken — read it from the override file.
# ---------------------------------------------------------------------------
HTTPS_PORT=$(awk '/^[[:space:]]*-[[:space:]]*"127\.0\.0\.1:[0-9]+:443/ {
    match($0, /:[0-9]+:443/);
    s=substr($0, RSTART+1, RLENGTH-5); print s; exit
}' docker-compose.override.yml 2>/dev/null || true)
HTTPS_PORT=${HTTPS_PORT:-443}
API_URL="https://api.rdc.local:${HTTPS_PORT}"

if curl -sSf --max-time 5 "${API_URL}/api/version" >/dev/null; then
    log "verified: ${API_URL}/api/version is reachable and trusted"
else
    log "WARN: ${API_URL}/api/version did not respond (yet?)"
    log "      - confirm: docker compose ps  -> caddy+rustdesk healthy"
    log "      - confirm: curl -vk ${API_URL}/api/version"
fi

cat <<EOF

================================================================================
 Next steps
--------------------------------------------------------------------------------
 1. Web admin:  ${API_URL}/_admin/
 2. Record the pubkey printed by server/scripts/init-keys.sh — you will
    paste it into client/.env under RS_PUB_KEY.
 3. For the client build, use:
       RENDEZVOUS_SERVER=rdv.rdc.local
       API_SERVER=${API_URL}
       RS_PUB_KEY=<the pubkey>
 4. To roll everything back:  server/scripts/uninstall-local-ca.sh
================================================================================
EOF
