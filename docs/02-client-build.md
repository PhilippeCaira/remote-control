# Client build

End-to-end instructions for producing branded RustDesk binaries. Most
users will let GitHub Actions drive this (see `.github/workflows/`), but
the same steps run locally for debugging.

## The contract

Every build — CI or local — consumes a fixed set of environment
variables. `client/scripts/apply-branding.sh` refuses to start if any is
missing. The full list with explanations is in
[`client/.env.example`](../client/.env.example); the summary table:

| Variable                | Source                                   | Example                               |
|-------------------------|------------------------------------------|---------------------------------------|
| `RENDEZVOUS_SERVER`     | GitHub Secret (set from `init-keys.sh`) | `rdv.example.com`                     |
| `RS_PUB_KEY`            | GitHub Secret                            | `OeVu…=` (base64, single line)        |
| `API_SERVER`            | GitHub Secret                            | `https://api.example.com`             |
| `BRAND_APP_NAME`        | GitHub Variable (not secret)             | `RemoteControl`                       |
| `BRAND_ORG`             | GitHub Variable                          | `com.example`                         |
| `BRAND_ANDROID_APP_ID`  | GitHub Variable                          | `com.example.remotecontrol`           |
| `BRAND_MACOS_BUNDLE_ID` | GitHub Variable                          | `com.example.remotecontrol`           |
| `BRAND_COPYRIGHT`       | GitHub Variable                          | `Copyright (c) 2026 Example SA`       |

> **Secrets vs. Variables.** Only the three server endpoints are
> secrets: leaking them does not give attacker access but needlessly
> reveals your infrastructure. The five `BRAND_*` values are harmless
> and can live in GitHub **Variables** (visible in logs), which makes
> them easier to track across revisions.

## How the substitution works

`apply-branding.sh` rewrites the upstream source tree in place. Each
substitution targets a single well-known string from the pinned
upstream (see `client/upstream/.upstream-ref`):

| File (inside `client/upstream/`)                       | Upstream default            | Replaced with                |
|--------------------------------------------------------|-----------------------------|------------------------------|
| `libs/hbb_common/src/config.rs` `RENDEZVOUS_SERVERS`   | `rs-ny.rustdesk.com`        | `$RENDEZVOUS_SERVER`         |
| `libs/hbb_common/src/config.rs` `RS_PUB_KEY`           | `OeVu…=`                    | `$RS_PUB_KEY`                |
| `libs/hbb_common/src/config.rs` `APP_NAME`             | `RustDesk`                  | `$BRAND_APP_NAME`            |
| `libs/hbb_common/src/config.rs` `ORG`                  | `com.carriez`               | `$BRAND_ORG`                 |
| `src/common.rs` `get_api_server_()` fallback           | `https://admin.rustdesk.com`| `$API_SERVER`                |
| `flutter/android/app/build.gradle` `applicationId`     | `com.carriez.flutter_hbb`   | `$BRAND_ANDROID_APP_ID`      |
| `flutter/android/app/.../AndroidManifest.xml` `package`| same                         | same                         |
| `AndroidManifest.xml` `android:label`                  | `RustDesk`                  | `$BRAND_APP_NAME`            |
| `AndroidManifest.xml` input-service label              | `RustDesk Input`            | `$BRAND_APP_NAME Input`      |
| `macos/Runner/Configs/AppInfo.xcconfig` `PRODUCT_NAME` | `RustDesk`                  | `$BRAND_APP_NAME`            |
| `AppInfo.xcconfig` `PRODUCT_BUNDLE_IDENTIFIER`         | `com.carriez.flutterHbb`    | `$BRAND_MACOS_BUNDLE_ID`     |
| `AppInfo.xcconfig` `PRODUCT_COPYRIGHT`                 | `Copyright © 2025 …`        | `$BRAND_COPYRIGHT`           |

All substitutions are idempotent: running the script twice is a no-op.
After every substitution the script verifies the target string landed —
a missing hit is a fatal error (protects against upstream drift).

## Local dev build (Linux AppImage)

Quick path to hold a branded binary in your hand on a Debian/Ubuntu
developer box.

```bash
cd /path/to/remote-control

# 1. Prepare the env
cp client/.env.example client/.env
$EDITOR client/.env              # fill all 8 values

# 2. Apply branding to the upstream tree
set -a; source client/.env; set +a
client/scripts/apply-branding.sh

# 3. Toolchain prerequisites (first time only)
sudo apt install -y \
    clang libasound2-dev libxdo-dev libxfixes-dev libgtk-3-dev \
    libpam0g-dev libpulse-dev libvdpau-dev libva-dev libdrm-dev \
    libudev-dev libx11-dev libxrandr-dev libxext-dev libxinerama-dev \
    libxcb1-dev libxcb-shape0-dev libxcb-xfixes0-dev libxcb-randr0-dev \
    libxcb-shm0-dev libpango1.0-dev cmake pkg-config git curl
rustup default stable
# Flutter: install via https://docs.flutter.dev/get-started/install/linux
# and ensure the version pinned in client/upstream/flutter/pubspec.yaml
# (channel stable, Flutter 3.x).

# vcpkg is needed for libvpx / libyuv / opus / aom
git clone https://github.com/microsoft/vcpkg ~/vcpkg
~/vcpkg/bootstrap-vcpkg.sh
export VCPKG_ROOT=~/vcpkg
$VCPKG_ROOT/vcpkg install libvpx libyuv opus aom

# 4. Build
cd client/upstream
python3 build.py --flutter --release
```

The resulting AppImage lands under `client/upstream/dist/` (or under
`release/` depending on the upstream packaging script).

Run it and verify:
- The window title contains your `BRAND_APP_NAME`.
- "Settings → Network" shows `RENDEZVOUS_SERVER` and `API_SERVER` as
  non-editable defaults.
- The binary connects to the server without any manual configuration.

## Post-build verification

`client/scripts/verify-hardcoded.sh` is run both in CI and manually to
guarantee each produced artifact carries the expected hardcoded values:

```bash
EXPECT_RENDEZVOUS=$RENDEZVOUS_SERVER \
EXPECT_RELAY=$RENDEZVOUS_SERVER:21117 \
EXPECT_API=$API_SERVER \
EXPECT_RS_PUB_KEY=$RS_PUB_KEY \
client/scripts/verify-hardcoded.sh client/upstream/dist/*.AppImage
```

A missing match fails fast. A leak of the upstream default `RS_PUB_KEY`
(which would route clients to the public RustDesk infrastructure) is
also detected and fails.

## Reset / re-run

The script mutates the upstream tree. To undo before trying a new set
of values:

```bash
git restore client/upstream/
```

This is cheap thanks to the subtree import — no re-fetch required.

## Upstream upgrades

When a new RustDesk tag is released:

```bash
PATH="$HOME/.local/bin:$PATH" git subtree pull --prefix=client/upstream \
    https://github.com/rustdesk/rustdesk.git <new-tag> --squash
echo "<new-tag>" > client/upstream/.upstream-ref
```

Re-run `apply-branding.sh` locally. If any substitution fails,
the upstream has renamed a target: update the `sed` pattern in
`client/scripts/apply-branding.sh` to match the new string, commit,
and re-run. This is the maintenance cost.
