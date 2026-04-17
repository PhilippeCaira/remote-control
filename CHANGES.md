# Changes vs. upstream RustDesk

This document tracks the modifications applied to the upstream
[rustdesk/rustdesk](https://github.com/rustdesk/rustdesk) source tree (imported
under `client/upstream/`) as required by AGPL-3.0 §5.

The canonical list of patches applied on top of `client/upstream/` lives in
`client/patches/`; this file is a human-readable summary.

## Categories of modification

1. **Hardcoded rendezvous and relay endpoints**
   - Source of truth: GitHub Actions secrets (`RENDEZVOUS_SERVER`, `RELAY_SERVER`,
     `API_SERVER`, `RS_PUB_KEY`) injected at build time.
   - Mechanism: environment variables honored by the upstream build
     (`libs/hbb_common/src/config.rs`) per the official "hardcode settings"
     documentation. No source file is modified for these values.

2. **Branding (name, icons, logo, bundle identifiers)**
   - Assets live in `client/branding/` and are copied into the upstream tree
     by `client/scripts/apply-branding.sh`.
   - Text patches (pubspec.yaml, AndroidManifest.xml, Info.plist,
     AppInfo.xcconfig, build.gradle, Cargo.toml) live in `client/patches/`.

3. **Auto-update disabled**
   - The upstream updater points to RustDesk's official servers. It is
     disabled in this fork so that clients only receive updates distributed
     from our own download portal.
   - Patch: `client/patches/0XX-disable-auto-update.patch`.

4. **"About" screen attribution**
   - A line is added to the About dialog crediting RustDesk upstream and
     linking to this public repository, as required by AGPL-3.0.

## Upstream tracking

- Upstream pinned tag: _recorded in `client/upstream/.upstream-ref` at each
  `git subtree pull`._
- Rebase cadence: monthly, or upon a critical upstream security release.

## How to regenerate this summary

Each time a patch is added, amended, or removed in `client/patches/`, update
the matching section above. Patches are the authoritative source; this file
is a convenience.
