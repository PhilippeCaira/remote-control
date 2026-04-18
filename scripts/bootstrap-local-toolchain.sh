#!/usr/bin/env bash
# ============================================================================
# bootstrap-local-toolchain.sh — install every build dependency for a local
# Linux + Android build of the branded RustDesk client on Fedora 41+.
#
# Idempotent. Re-running only re-does what is missing.
# Writes sourceable PATH helpers to ~/.config/remote-control/env.
#
# You will be prompted for sudo ONCE (dnf install). All subsequent steps
# are user-scope.
# ============================================================================
set -euo pipefail

log() { printf '[bootstrap] %s\n' "$*"; }

mkdir -p "$HOME/.config/remote-control"
ENV_FILE="$HOME/.config/remote-control/env"
: > "$ENV_FILE"

# ---------------------------------------------------------------------------
# B.1 — System packages (Fedora)
# ---------------------------------------------------------------------------
log "Step 1/5: installing system packages via dnf (sudo required)..."
sudo dnf install -y \
    clang llvm cmake ninja-build pkgconf-pkg-config \
    gtk3-devel pango-devel glib2-devel cairo-devel \
    alsa-lib-devel pulseaudio-libs-devel pipewire-devel \
    libxdo-devel libXfixes-devel libXrandr-devel libXext-devel \
    libXinerama-devel libxcb-devel xcb-util-devel libxkbcommon-devel \
    libX11-devel pam-devel systemd-devel libdrm-devel libva-devel \
    libvdpau-devel libayatana-appindicator-gtk3-devel \
    gstreamer1-devel gstreamer1-plugins-base-devel \
    ffmpeg-free-devel \
    openssl-devel \
    nasm binutils \
    python3.11 \
    unzip wget curl git tar \
    perl-FindBin perl-File-Compare perl-File-Copy perl-IPC-Cmd \
    perl-Time-Piece perl-File-Path perl-File-Temp \
    perl-Digest-SHA perl-Text-Template

# ---------------------------------------------------------------------------
# B.2 — Rust 1.75 via rustup
# ---------------------------------------------------------------------------
log "Step 2/5: Rust 1.75 toolchain..."
if ! command -v rustup >/dev/null; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
        sh -s -- -y --default-toolchain 1.75.0 --profile minimal
fi
# shellcheck disable=SC1091
source "$HOME/.cargo/env"
rustup toolchain install 1.75.0 --profile minimal
rustup default 1.75.0
rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
if ! command -v cargo-ndk >/dev/null; then
    cargo install cargo-ndk --version 3.1.2 --locked
fi
echo 'source "$HOME/.cargo/env"' >> "$ENV_FILE"

# ---------------------------------------------------------------------------
# B.3 — vcpkg + host libs (libvpx, libyuv, opus, aom)
# ---------------------------------------------------------------------------
log "Step 3/5: vcpkg host libs (long — up to ~40 min on first run)..."
if [[ ! -d "$HOME/vcpkg" ]]; then
    git clone https://github.com/microsoft/vcpkg "$HOME/vcpkg"
fi
(
    cd "$HOME/vcpkg"
    git fetch origin
    git checkout 120deac3062162151622ca4860575a33844ba10b
    [[ -x ./vcpkg ]] || ./bootstrap-vcpkg.sh -disableMetrics
    # ffmpeg required by rustdesk/hwcodec (even when hwcodec is built against
    # vcpkg on Linux — system ffmpeg headers are in /usr/include/ffmpeg but
    # hwcodec build.rs looks inside $VCPKG_ROOT/installed/x64-linux/include).
    # ffmpeg build is the long pole — ~30-60 min on first run.
    ./vcpkg install libvpx libyuv opus aom ffmpeg
)
echo "export VCPKG_ROOT=$HOME/vcpkg" >> "$ENV_FILE"
echo 'export PATH="$VCPKG_ROOT:$PATH"' >> "$ENV_FILE"

# ---------------------------------------------------------------------------
# B.4 — Flutter 3.24.5
# ---------------------------------------------------------------------------
log "Step 4/5: Flutter 3.24.5..."
if [[ ! -x "$HOME/flutter/bin/flutter" ]]; then
    curl -L -o /tmp/flutter.tar.xz \
        https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.24.5-stable.tar.xz
    tar -xJf /tmp/flutter.tar.xz -C "$HOME/"
    rm -f /tmp/flutter.tar.xz
fi

# Apply the same patch the CI applies on stock 3.24.5.
PATCH_FILE="$(pwd)/client/upstream/.github/patches/flutter_3.24.4_dropdown_menu_enableFilter.diff"
if [[ -f "$PATCH_FILE" ]]; then
    cp "$PATCH_FILE" "$HOME/flutter/"
    (
        cd "$HOME/flutter"
        if git apply --reverse --check "$(basename "$PATCH_FILE")" 2>/dev/null; then
            log "flutter patch already applied"
        elif git apply --check "$(basename "$PATCH_FILE")" 2>/dev/null; then
            git apply "$(basename "$PATCH_FILE")"
            log "flutter patch applied"
        else
            log "WARN: flutter patch neither applies nor reverses cleanly — investigate manually"
        fi
    )
fi
echo "export PATH=\"$HOME/flutter/bin:\$PATH\"" >> "$ENV_FILE"

# ---------------------------------------------------------------------------
# B.5 — Android SDK + NDK r27c + AVD image
# ---------------------------------------------------------------------------
log "Step 5/5: Android SDK + NDK r27c..."
ANDROID_HOME="$HOME/Android/Sdk"
mkdir -p "$ANDROID_HOME/cmdline-tools"
if [[ ! -d "$ANDROID_HOME/cmdline-tools/latest" ]]; then
    curl -L -o /tmp/cmdline-tools.zip \
        https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip
    unzip -q /tmp/cmdline-tools.zip -d "$ANDROID_HOME/cmdline-tools"
    mv "$ANDROID_HOME/cmdline-tools/cmdline-tools" "$ANDROID_HOME/cmdline-tools/latest"
    rm -f /tmp/cmdline-tools.zip
fi
export ANDROID_HOME
export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH"
yes | sdkmanager --licenses >/dev/null
sdkmanager "platform-tools" "ndk;27.2.12479018" "platforms;android-34" \
           "build-tools;34.0.0" "emulator" \
           "system-images;android-34;google_apis;x86_64"

{
    echo "export ANDROID_HOME=$ANDROID_HOME"
    echo 'export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/27.2.12479018"'
    echo 'export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"'
} >> "$ENV_FILE"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
cat <<EOF

================================================================================
 Toolchain ready. Source this file in every new shell to pick up the paths:

   source ~/.config/remote-control/env

 Then the full sequence is:

   # start the server locally
   cd server
   cp .env.example .env                # edit domains to *.rdc.local
   cp docker-compose.override.yml.example docker-compose.override.yml
   ./scripts/init-keys.sh              # prints RS_PUB_KEY
   ./scripts/install-local-ca.sh       # sudo trust anchor + /etc/hosts
   docker compose up -d

   # build the Linux client
   cd ../client
   cp .env.example .env                # paste RS_PUB_KEY, set hostnames + brand
   set -a; source .env; set +a
   ./scripts/apply-branding.sh
   cd upstream
   cargo build --lib --features flutter,hwcodec,unix-file-copy-paste --release
   python3 build.py --flutter --skip-cargo --hwcodec --unix-file-copy-paste

 If python3 (3.14) chokes, fall back to 3.11:
   python3.11 build.py --flutter --skip-cargo --hwcodec --unix-file-copy-paste
================================================================================
EOF
