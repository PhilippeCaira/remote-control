# remote-control

Self-hosted TeamViewer alternative built on the RustDesk stack.

- **Server**: `lejianwen/rustdesk-server` (hbbs + hbbr) and
  `lejianwen/rustdesk-api` deployed via Docker Compose behind Caddy.
- **Client**: rebranded fork of [`rustdesk/rustdesk`](https://github.com/rustdesk/rustdesk)
  with the rendezvous server, relay server, API server, and server public key
  hardcoded at build time. Matrix-built for Windows, macOS, Linux, and Android
  via GitHub Actions.
- **Distribution**: signed installers served from `dl.<your-domain>`; end users
  download and run — no configuration required on their side.

## Repository layout

```
.
├── server/           # Docker Compose stack: hbbs, hbbr, rustdesk-api, Caddy
├── client/
│   ├── upstream/     # git subtree of rustdesk/rustdesk (pinned tag)
│   ├── branding/     # logo, icons, splash, app name
│   ├── patches/      # modifications vs. upstream (AGPL §5 disclosure)
│   └── scripts/      # apply-branding.sh, verify-hardcoded.sh
├── .github/workflows # CI: build-client-{windows,macos,linux,android}, release
├── docs/             # install, runbook, key rotation, AGPL compliance
└── scripts/          # bootstrap.sh (one-shot dev setup)
```

## Status

Bootstrapping. See `docs/99-runbook.md` for the full implementation plan.
Milestones tracked in the approved implementation plan.

## License

AGPL-3.0. See [`LICENSE`](LICENSE) for the full text and [`NOTICE`](NOTICE) for
attribution of upstream components. Modifications vs. upstream RustDesk are
documented in [`CHANGES.md`](CHANGES.md).

Because this software is intended to be operated as a network service for
end users, AGPL-3.0 §13 applies: the Corresponding Source of any deployed
version must be made available to its users. This repository is that
Corresponding Source.
