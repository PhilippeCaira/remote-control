# Changes vs. upstream RustDesk

This document tracks the modifications applied to the upstream
[rustdesk/rustdesk](https://github.com/rustdesk/rustdesk) source tree (imported
under `client/upstream/`) as required by AGPL-3.0 §5.

The canonical list of patches applied on top of `client/upstream/` lives in
`client/patches/`; this file is a human-readable summary.

## Categories of modification

1. **Hardcoded rendezvous server, relay, API server, and server public key**
   - Source of truth: GitHub Actions secrets (`RENDEZVOUS_SERVER`,
     `RELAY_SERVER`, `API_SERVER`, `RS_PUB_KEY`) consumed by
     `client/scripts/apply-branding.sh` at build-prep time.
   - Mechanism: `sed` substitution directly in the upstream source.
     RustDesk's upstream exposes these as plain `const` values — verified
     against the pinned tag recorded in `client/upstream/.upstream-ref`:
       - `libs/hbb_common/src/config.rs`: `RENDEZVOUS_SERVERS`, `RS_PUB_KEY`
       - `src/common.rs`: `get_api_server_()` fallback literal
         `"https://admin.rustdesk.com"`.
   - Rationale for sed-over-env-var: upstream does not read these via
     `option_env!()` or a build.rs; the signed-blob mechanism
     (`read_custom_client`) requires RustDesk's private signing key.
     Substitution at the source level is the minimal, auditable change.

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
