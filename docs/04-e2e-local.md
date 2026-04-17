# Local end-to-end test

Walkthrough for running the full stack — server + branded client —
on a single Fedora 41+ box, without a public domain or any external
signing material. Produces a working demonstration of the "plug &
play" flow that production end users will experience.

## 0. Prerequisites

- Fedora 41 or later, KVM available for Android emulation (optional).
- Docker Engine + compose v2.
- sudo access (one-shot for `trust anchor` and `dnf install`).

Clone this repo and `cd` into it:

```bash
git clone <this repo> remote-control
cd remote-control
```

## 1. Install toolchain

```bash
bash scripts/bootstrap-local-toolchain.sh
```

Runs: dnf packages, Rust 1.75 + Android targets, vcpkg + host libs (the
long pole — 20-40 minutes on first run because of aom), Flutter 3.24.5
+ upstream patch, Android SDK + NDK r27c + x86_64 AVD image.

Idempotent. After it completes, source the env once per shell:

```bash
source ~/.config/remote-control/env
```

## 2. Start the server (local profile)

```bash
cd server
cp .env.example .env
# Edit .env:
#   DOMAIN_RDV=rdv.rdc.local
#   DOMAIN_API=api.rdc.local
#   DOMAIN_DL=dl.rdc.local
#   ACME_EMAIL=anything@example.com   (unused by tls internal, still required)
#   RUSTDESK_API_JWT_KEY=$(openssl rand -hex 32)
#   MUST_LOGIN=N                      (simpler for a 2-peer demo)

cp docker-compose.override.yml.example docker-compose.override.yml

./scripts/init-keys.sh            # prints RS_PUB_KEY on stdout — COPY IT
docker compose up -d
./scripts/install-local-ca.sh      # sudo trust anchor + /etc/hosts
docker compose ps                  # rustdesk + caddy must be healthy
curl -sI https://api.rdc.local/_admin/ | head -3    # HTTP/2 200
```

Open `https://api.rdc.local/_admin/` in a browser. Default admin
credentials are printed at `docker compose logs rustdesk | grep -i admin`
the first time.

## 3. Build the Linux client

```bash
cd ../client
cp .env.example .env
# Edit .env — paste the RS_PUB_KEY from step 2, set hostnames and brand:
#   RENDEZVOUS_SERVER=rdv.rdc.local
#   RS_PUB_KEY=<pasted from init-keys output>
#   API_SERVER=https://api.rdc.local
#   BRAND_APP_NAME=RemoteControl
#   BRAND_ORG=com.localtest
#   BRAND_ANDROID_APP_ID=com.localtest.remotecontrol
#   BRAND_MACOS_BUNDLE_ID=com.localtest.remotecontrol
#   BRAND_COPYRIGHT="Copyright (c) 2026 Local Test"

set -a; source .env; set +a
./scripts/apply-branding.sh

cd upstream
cargo build --lib --features flutter,hwcodec,unix-file-copy-paste --release
python3 build.py --flutter --skip-cargo --hwcodec --unix-file-copy-paste

# Fallback for Python 3.14 incompatibilities:
#   python3.11 build.py --flutter --skip-cargo --hwcodec --unix-file-copy-paste

../scripts/verify-hardcoded.sh \
    flutter/build/linux/x64/release/bundle/lib/librustdesk.so
```

Expected artefact:
`client/upstream/flutter/build/linux/x64/release/bundle/` with an
executable named `rustdesk` (Rust crate name — internal) whose UI
strings and API endpoints are our local ones.

## 4. Sanity-check with the official client

Before wiring up 2 branded peers, prove the server itself works with
the upstream-signed RustDesk binary:

- Download `rustdesk` from https://rustdesk.com/ on this machine (or a
  VM peer).
- Settings → Network → ID Server: `rdv.rdc.local`; Relay Server:
  `rdv.rdc.local:21117`; API Server: `https://api.rdc.local`; Key:
  paste the `RS_PUB_KEY` from step 2.
- Close Settings → a 9-digit ID should appear and the status should go
  green.

`docker compose logs rustdesk` should show a `register` event.

If this fails, the bug is in the server stack — not in our branding
pipeline. Fix server-side before proceeding.

## 5. Two branded peers on this PC

```bash
cd ../..                           # back to repo root
scripts/run-two-peers.sh
```

Each peer lives under `/tmp/rdc-peer-a` and `/tmp/rdc-peer-b`. The
helper sets `HOME` + `XDG_RUNTIME_DIR` cleanly so the two instances
don't share configuration.

### What to validate

- Window title: `RemoteControl`, not `RustDesk`.
- Each UI shows its own 9-digit ID and a green status.
- `https://api.rdc.local/_admin/` → Device list contains both peers.
- In peer A, type peer B's ID, hit Connect, enter the ad-hoc session
  password displayed on B. A video feed of B's desktop should appear
  in A's window, with keyboard and mouse flowing through.
- `docker compose logs rustdesk | grep -iE "register|session|relay"`
  shows real-time events.

### Optional: verify the hardcoded pubkey is what we baked in

```bash
strings client/upstream/flutter/build/linux/x64/release/bundle/lib/librustdesk.so \
   | grep -F "$(cat server/volumes/rustdesk/server/id_ed25519.pub)"
```

The grep must hit at least once. If it does not, branding did not land
and the client falls back to the upstream public key — which would
try to route clients to RustDesk's public infrastructure.

## 6. Android emulator scenario (bonus)

Requires B.5 from the bootstrap (Android SDK + NDK + x86_64 image).

```bash
source ~/.config/remote-control/env

# Build the APK
cd client/upstream
cargo ndk --platform 21 --target x86_64-linux-android build \
    --release --features flutter,hwcodec
mkdir -p flutter/android/app/src/main/jniLibs/x86_64
cp target/x86_64-linux-android/release/liblibrustdesk.so \
   flutter/android/app/src/main/jniLibs/x86_64/librustdesk.so
cp "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/x86_64-linux-android/libc++_shared.so" \
   flutter/android/app/src/main/jniLibs/x86_64/
cd flutter
flutter build apk --release --target-platform android-x64 --split-per-abi
cd ..
../scripts/verify-hardcoded.sh \
    flutter/android/app/src/main/jniLibs/x86_64/librustdesk.so

# Boot the AVD (if not already running)
cd ../..
avdmanager create avd -n rdc-test \
    -k "system-images;android-34;google_apis;x86_64" \
    --device "pixel_6" 2>/dev/null || true
emulator -avd rdc-test -no-snapshot -no-audio &

# Wait for adb to see it, then install
adb wait-for-device
adb install -r \
  client/upstream/flutter/build/app/outputs/flutter-apk/app-x86_64-release.apk
adb shell am start -n com.localtest.remotecontrol/.MainActivity
```

Inside the emulator: the app launches branded, fetches an ID, and can
take control of one of the Linux peers from step 5.

Networking note: the AVD uses its own network namespace but can reach
the host via `10.0.2.2`. Our client hardcodes `rdv.rdc.local` which
resolves to `127.0.0.1` on the host — this will not work from the
emulator. Either:

- Point `RENDEZVOUS_SERVER` at the host's LAN IP before rebuilding the
  APK (`192.168.x.x`), or
- Add `10.0.2.2 rdv.rdc.local api.rdc.local` to the emulator's hosts
  file (`adb root && adb shell "echo '10.0.2.2 rdv.rdc.local' >> /etc/hosts"`).

The second approach keeps the binary unchanged.

## 7. Tearing down

```bash
# Stop peers + emulator
pkill -f flutter/build/linux/x64/release/bundle/rustdesk
adb emu kill || true

# Stop the server stack
cd server && docker compose down

# Revert sudo changes
./scripts/uninstall-local-ca.sh
```

The only persistent artefacts on the host afterwards are the installed
toolchain (`~/flutter`, `~/vcpkg`, `~/.cargo`, `~/Android/Sdk`) and the
dnf packages. Run `dnf remove <packages>` + `rm -rf ~/flutter ~/vcpkg
~/Android/Sdk` if a full cleanup is wanted.
