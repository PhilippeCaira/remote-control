#!/usr/bin/env bash
# ============================================================================
# apply-branding.sh — prepare client/upstream/ for a branded build.
#
# Called by CI (and by humans for local test builds) before invoking the
# upstream build system. Mutates the upstream tree in place.
#
# Order of operations:
#   1. Preflight: upstream tree present and at the expected pinned tag.
#   2. Apply every static `.patch` under client/patches/ in lexical order
#      (disable updater, …).
#   3. Substitute the endpoint/key triplet into the upstream source using
#      sed — the upstream exposes these as plain `const` values, not
#      env-var-driven macros (verified against rustdesk 1.4.6). Driven by
#      the following environment variables:
#          RENDEZVOUS_SERVER  — bare host, e.g. rdv.example.com
#          RS_PUB_KEY         — base64 ed25519 public key (single line)
#          API_SERVER         — full URL, e.g. https://api.example.com
#   4. Inject the product identity (user-visible name, organisation
#      reverse-DNS, Android applicationId, macOS bundle id, copyright):
#          BRAND_APP_NAME        — e.g. RemoteControl (no spaces, A-Za-z0-9)
#          BRAND_ORG             — e.g. com.example
#          BRAND_ANDROID_APP_ID  — e.g. com.example.remotecontrol
#          BRAND_MACOS_BUNDLE_ID — e.g. com.example.remotecontrol
#          BRAND_COPYRIGHT       — e.g. "Copyright (c) 2026 Example SA"
#      The crate name and the Flutter package name (`rustdesk`,
#      `flutter_hbb`) are intentionally NOT changed: they are referenced
#      by `use` statements throughout the codebase; only the *user-visible*
#      strings are rewritten.
#   5. Copy branded assets (icons, splash) from client/branding/ into
#      the well-known locations inside upstream/.
#
# Idempotency: each patch is probed with `git apply --check --reverse`
# first; the sed substitutions are idempotent by construction
# (placeholder is the upstream default string, which disappears after
# the first pass — a second pass is a no-op).
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLIENT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
UPSTREAM="$CLIENT_DIR/upstream"
BRANDING="$CLIENT_DIR/branding"
PATCHES="$CLIENT_DIR/patches"

log()  { printf '[apply-branding] %s\n' "$*"; }
fail() { printf '[apply-branding] ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Preflight
# ---------------------------------------------------------------------------
[[ -d "$UPSTREAM" ]] || fail "upstream tree missing: $UPSTREAM"
[[ -f "$UPSTREAM/Cargo.toml" ]] || fail "$UPSTREAM does not look like a RustDesk tree"
[[ -f "$UPSTREAM/libs/hbb_common/src/config.rs" ]] \
    || fail "hbb_common subtree missing under $UPSTREAM/libs/hbb_common"

if [[ -f "$UPSTREAM/.upstream-ref" ]]; then
    log "upstream pinned at: $(cat "$UPSTREAM/.upstream-ref")"
fi

: "${RENDEZVOUS_SERVER:?set RENDEZVOUS_SERVER (e.g. rdv.example.com)}"
: "${RS_PUB_KEY:?set RS_PUB_KEY (base64 ed25519 public key)}"
: "${API_SERVER:?set API_SERVER (e.g. https://api.example.com)}"
: "${BRAND_APP_NAME:?set BRAND_APP_NAME (e.g. RemoteControl)}"
: "${BRAND_ORG:?set BRAND_ORG (e.g. com.example)}"
: "${BRAND_ANDROID_APP_ID:?set BRAND_ANDROID_APP_ID (e.g. com.example.remotecontrol)}"
: "${BRAND_MACOS_BUNDLE_ID:?set BRAND_MACOS_BUNDLE_ID (e.g. com.example.remotecontrol)}"
: "${BRAND_COPYRIGHT:?set BRAND_COPYRIGHT (e.g. \"Copyright (c) 2026 Example SA\")}"
: "${UPDATE_CHECK_URL:?set UPDATE_CHECK_URL (e.g. https://owner.github.io/repo/version/latest.json)}"

# Cheap sanity checks. Hard to catch every invalid input via regex alone,
# but these rule out the most common mistakes.
[[ "$BRAND_APP_NAME"       =~ ^[A-Za-z][A-Za-z0-9]*$ ]] \
    || fail "BRAND_APP_NAME must be alphanumeric, start with a letter (got: $BRAND_APP_NAME)"
[[ "$BRAND_ORG"            =~ ^[a-z][a-z0-9]*(\.[a-z][a-z0-9]*)+$ ]] \
    || fail "BRAND_ORG must be reverse-DNS lowercase (got: $BRAND_ORG)"
[[ "$BRAND_ANDROID_APP_ID" =~ ^[a-z][a-z0-9]*(\.[a-z][a-z0-9]*)+$ ]] \
    || fail "BRAND_ANDROID_APP_ID must be reverse-DNS lowercase"
[[ "$BRAND_MACOS_BUNDLE_ID" =~ ^[A-Za-z][A-Za-z0-9-]*(\.[A-Za-z][A-Za-z0-9-]*)+$ ]] \
    || fail "BRAND_MACOS_BUNDLE_ID must be reverse-DNS"

# Guard against accidental leak of the upstream default key.
if [[ "$RS_PUB_KEY" == "OeVuKk5nlHiXp+APNn0Y3pC1Iwpwn44JGqrQCsWqmBw=" ]]; then
    fail "RS_PUB_KEY equals the upstream RustDesk default — refusing to build"
fi

# ---------------------------------------------------------------------------
# 2. Apply static patches in lexical order
# ---------------------------------------------------------------------------
shopt -s nullglob
PATCH_FILES=("$PATCHES"/*.patch)
shopt -u nullglob

if (( ${#PATCH_FILES[@]} == 0 )); then
    log "no patches in $PATCHES — nothing to apply"
else
    pushd "$UPSTREAM" >/dev/null
    for patch in "${PATCH_FILES[@]}"; do
        name=$(basename "$patch")
        if git apply --check --reverse "$patch" 2>/dev/null; then
            log "already applied: $name (skipping)"
            continue
        fi
        if ! git apply --check "$patch" 2>/dev/null; then
            fail "patch does not apply cleanly: $name — rebase against upstream"
        fi
        log "applying $name"
        git apply "$patch"
    done
    popd >/dev/null
fi

# ---------------------------------------------------------------------------
# 3. Inject hardcoded endpoints and pubkey.
#
# Target 1: libs/hbb_common/src/config.rs
#     pub const RENDEZVOUS_SERVERS: &[&str] = &["rs-ny.rustdesk.com"];
#     pub const RS_PUB_KEY: &str = "OeVuKk5nlHiXp+APNn0Y3pC1Iwpwn44JGqrQCsWqmBw=";
#
# Target 2: src/common.rs, fn get_api_server_()
#     fallback literal "https://admin.rustdesk.com" becomes API_SERVER.
# ---------------------------------------------------------------------------
CONFIG_RS="$UPSTREAM/libs/hbb_common/src/config.rs"
COMMON_RS="$UPSTREAM/src/common.rs"

# Escape user-supplied values for sed: & \ / and delimiter characters.
sed_escape() { printf '%s' "$1" | sed -e 's/[\/&|]/\\&/g'; }

RENDEZVOUS_ESC=$(sed_escape "$RENDEZVOUS_SERVER")
RS_PUB_KEY_ESC=$(sed_escape "$RS_PUB_KEY")
API_SERVER_ESC=$(sed_escape "$API_SERVER")

log "patching $CONFIG_RS"
sed -i.sedbak -E \
    -e "s|&\[\"rs-ny\.rustdesk\.com\"\]|\&[\"${RENDEZVOUS_ESC}\"]|" \
    -e "s|\"OeVuKk5nlHiXp\+APNn0Y3pC1Iwpwn44JGqrQCsWqmBw=\"|\"${RS_PUB_KEY_ESC}\"|" \
    "$CONFIG_RS"

# Verify that the substitution actually happened.
grep -qF "\"${RENDEZVOUS_SERVER}\"" "$CONFIG_RS" \
    || fail "RENDEZVOUS substitution failed in $CONFIG_RS"
grep -qF "\"${RS_PUB_KEY}\""        "$CONFIG_RS" \
    || fail "RS_PUB_KEY substitution failed in $CONFIG_RS"
if grep -qF "rs-ny.rustdesk.com" "$CONFIG_RS" \
     || grep -qF "OeVuKk5nlHiXp+APNn0Y3pC1Iwpwn44JGqrQCsWqmBw=" "$CONFIG_RS"; then
    fail "upstream default still present in $CONFIG_RS after sed"
fi

log "patching $COMMON_RS"
sed -i.sedbak -E \
    -e "s|\"https://admin\.rustdesk\.com\"\.to_owned\(\)|\"${API_SERVER_ESC}\".to_owned()|" \
    "$COMMON_RS"

grep -qF "\"${API_SERVER}\".to_owned()" "$COMMON_RS" \
    || fail "API_SERVER substitution failed in $COMMON_RS"

# ---------------------------------------------------------------------------
# 4. Inject product identity (user-visible branding).
# ---------------------------------------------------------------------------
APP_NAME_ESC=$(sed_escape "$BRAND_APP_NAME")
ORG_ESC=$(sed_escape "$BRAND_ORG")
ANDROID_APP_ID_ESC=$(sed_escape "$BRAND_ANDROID_APP_ID")
MACOS_BUNDLE_ID_ESC=$(sed_escape "$BRAND_MACOS_BUNDLE_ID")
COPYRIGHT_ESC=$(sed_escape "$BRAND_COPYRIGHT")

# 4.1 Rust: APP_NAME + ORG defaults in config.rs (RwLock initial values).
log "patching APP_NAME/ORG in $CONFIG_RS"
sed -i.sedbak -E \
    -e "s|RwLock::new\(\"RustDesk\"\.to_owned\(\)\)|RwLock::new(\"${APP_NAME_ESC}\".to_owned())|" \
    -e "s|RwLock::new\(\"com\.carriez\"\.to_owned\(\)\)|RwLock::new(\"${ORG_ESC}\".to_owned())|" \
    "$CONFIG_RS"
grep -qF "RwLock::new(\"${BRAND_APP_NAME}\".to_owned())" "$CONFIG_RS" \
    || fail "APP_NAME substitution failed in $CONFIG_RS"
grep -qF "RwLock::new(\"${BRAND_ORG}\".to_owned())" "$CONFIG_RS" \
    || fail "ORG substitution failed in $CONFIG_RS"

# 4.2 Android: applicationId, package, android:label.
ANDROID_GRADLE="$UPSTREAM/flutter/android/app/build.gradle"
ANDROID_MANIFEST="$UPSTREAM/flutter/android/app/src/main/AndroidManifest.xml"

log "patching $ANDROID_GRADLE"
sed -i.sedbak -E \
    -e "s|applicationId \"com\.carriez\.flutter_hbb\"|applicationId \"${ANDROID_APP_ID_ESC}\"|" \
    "$ANDROID_GRADLE"
grep -qF "applicationId \"${BRAND_ANDROID_APP_ID}\"" "$ANDROID_GRADLE" \
    || fail "applicationId substitution failed in $ANDROID_GRADLE"

log "patching $ANDROID_MANIFEST"
# IMPORTANT: do NOT change the `package="com.carriez.flutter_hbb"` attribute.
# That value is the *namespace* used to generate the R class at
# `com.carriez.flutter_hbb.R`. Every Kotlin file in
# flutter/android/app/src/main/kotlin/com/carriez/flutter_hbb/ imports R
# via that path. The user-visible identity comes from applicationId in
# build.gradle (which we do change). This matches Android's current
# namespace-vs-applicationId convention.
sed -i.sedbak -E \
    -e "s|android:label=\"RustDesk Input\"|android:label=\"${APP_NAME_ESC} Input\"|" \
    -e "s|android:label=\"RustDesk\"|android:label=\"${APP_NAME_ESC}\"|" \
    "$ANDROID_MANIFEST"
grep -qF "android:label=\"${BRAND_APP_NAME}\""  "$ANDROID_MANIFEST" \
    || fail "android:label substitution failed in $ANDROID_MANIFEST"

# 4.3 macOS: PRODUCT_NAME, PRODUCT_BUNDLE_IDENTIFIER, PRODUCT_COPYRIGHT.
MACOS_XCCONFIG="$UPSTREAM/flutter/macos/Runner/Configs/AppInfo.xcconfig"
log "patching $MACOS_XCCONFIG"
sed -i.sedbak -E \
    -e "s|^PRODUCT_NAME *= *RustDesk\$|PRODUCT_NAME = ${APP_NAME_ESC}|" \
    -e "s|^PRODUCT_BUNDLE_IDENTIFIER *= *com\.carriez\.flutterHbb\$|PRODUCT_BUNDLE_IDENTIFIER = ${MACOS_BUNDLE_ID_ESC}|" \
    -e "s|^PRODUCT_COPYRIGHT *=.*\$|PRODUCT_COPYRIGHT = ${COPYRIGHT_ESC}|" \
    "$MACOS_XCCONFIG"
grep -qE "^PRODUCT_NAME *= *${BRAND_APP_NAME}\$"            "$MACOS_XCCONFIG" \
    || fail "PRODUCT_NAME substitution failed in $MACOS_XCCONFIG"
grep -qE "^PRODUCT_BUNDLE_IDENTIFIER *= *${BRAND_MACOS_BUNDLE_ID}\$" "$MACOS_XCCONFIG" \
    || fail "PRODUCT_BUNDLE_IDENTIFIER substitution failed in $MACOS_XCCONFIG"

# 4.4 Auto-update endpoint and Windows MSI filename pattern.
#
# Upstream checks https://api.rustdesk.com/version/latest and expects MSIs
# named rustdesk-<v>-x86_64.msi. Both are rewritten here so a branded build
# consumes our release feed on github.io and downloads our branded MSI.
HBB_LIB_RS="$UPSTREAM/libs/hbb_common/src/lib.rs"
UPDATER_RS="$UPSTREAM/src/updater.rs"
UPDATE_CHECK_URL_ESC=$(sed_escape "$UPDATE_CHECK_URL")

log "patching update-check URL in $HBB_LIB_RS"
sed -i.sedbak -E \
    -e "s|\"https://api\.rustdesk\.com/version/latest\"|\"${UPDATE_CHECK_URL_ESC}\"|" \
    "$HBB_LIB_RS"
grep -qF "\"${UPDATE_CHECK_URL}\"" "$HBB_LIB_RS" \
    || fail "UPDATE_CHECK_URL substitution failed in $HBB_LIB_RS"

log "patching MSI filename pattern in $UPDATER_RS"
# The string appears twice in a #[cfg(target_os="windows")] block; replace
# both at once. The flutter branch uses rustdesk-<v>-x86_64.<ext>; the
# sciter branch rustdesk-<v>-x86-sciter.exe. We brand both.
sed -i.sedbak -E \
    -e "s|\"\{\}/rustdesk-\{\}-x86_64\.\{\}\"|\"\{\}/${APP_NAME_ESC}-\{\}-x86_64.\{\}\"|" \
    -e "s|\"\{\}/rustdesk-\{\}-x86-sciter\.exe\"|\"\{\}/${APP_NAME_ESC}-\{\}-x86-sciter.exe\"|" \
    "$UPDATER_RS"
grep -qF "${BRAND_APP_NAME}-{}-x86_64" "$UPDATER_RS" \
    || fail "MSI filename-pattern substitution failed in $UPDATER_RS"

# 4.5 Anchor the four hardcoded values in a `#[used] static` so LTO cannot
# eliminate them. macOS x86_64 aggressive DCE otherwise strips the API
# fallback literal from both the dylib and the wrapper, breaking
# verify-hardcoded. Linux / Windows / macOS arm64 don't need this but the
# anchor is harmless there.
if ! grep -q "_RDC_BUILD_INFO_ANCHOR" "$CONFIG_RS"; then
    # Use Rust raw strings `r"..."` so URLs and base64 pubkeys don't need
    # escaping, and use the UNESCAPED user-supplied values (sed escapes
    # `/` as `\/` which is an invalid Rust string escape).
    cat >> "$CONFIG_RS" <<EOF

// ── Branded build anchor (added by client/scripts/apply-branding.sh) ─────
// Keeps the four hardcoded endpoints resident through LTO so post-build
// verification (client/scripts/verify-hardcoded.sh) can locate them.
#[used]
static _RDC_BUILD_INFO_ANCHOR: [&str; 4] = [
    r"${RENDEZVOUS_SERVER}",
    r"${RS_PUB_KEY}",
    r"${API_SERVER}",
    r"${BRAND_APP_NAME}",
];
EOF
    log "appended _RDC_BUILD_INFO_ANCHOR to $CONFIG_RS"
fi

# 4.6 Global regression check: no upstream brand strings should remain.
LEAK_FILES=(
    "$CONFIG_RS"
    "$ANDROID_GRADLE"
    "$ANDROID_MANIFEST"
    "$MACOS_XCCONFIG"
)
for f in "${LEAK_FILES[@]}"; do
    if grep -qF "com.carriez" "$f" || grep -qF "flutter_hbb" "$f"; then
        log "WARN: upstream brand token still present in $f — review the site list"
    fi
done

# 4.7 Remove sed in-place backups (portable pattern: `-i.sedbak -E` works
# on GNU sed AND BSD sed. Without the attached extension, BSD treats the
# next flag as an extension and the command misparses).
find "$UPSTREAM" -name '*.sedbak' -delete

# ---------------------------------------------------------------------------
# 5. Copy branded assets (non-fatal if missing; CI's release workflow has
#    a separate strict-mode guard).
# ---------------------------------------------------------------------------
copy() {  # copy <src> <dst>
    local src=$1 dst=$2
    if [[ -f "$src" ]]; then
        mkdir -p "$(dirname "$dst")"
        install -m 0644 "$src" "$dst"
        log "copied $(realpath --relative-to="$CLIENT_DIR" "$src") -> $(realpath --relative-to="$UPSTREAM" "$dst")"
    else
        log "missing asset (skipped): $src"
    fi
}

copy "$BRANDING/assets/icon.ico"           "$UPSTREAM/res/icon.ico"
copy "$BRANDING/assets/icon.icns"          "$UPSTREAM/res/icon.icns"
copy "$BRANDING/assets/icon-128.png"       "$UPSTREAM/res/128x128.png"
copy "$BRANDING/assets/icon-32.png"        "$UPSTREAM/res/32x32.png"
copy "$BRANDING/assets/icon-mac.png"       "$UPSTREAM/res/mac-icon.png"
copy "$BRANDING/assets/tray-icon.ico"      "$UPSTREAM/res/tray-icon.ico"
copy "$BRANDING/assets/logo.png"           "$UPSTREAM/flutter/assets/logo.png"

for density in mdpi hdpi xhdpi xxhdpi xxxhdpi; do
    copy "$BRANDING/assets/android/ic_launcher_${density}.png" \
         "$UPSTREAM/flutter/android/app/src/main/res/mipmap-${density}/ic_launcher.png"
    copy "$BRANDING/assets/android/ic_launcher_round_${density}.png" \
         "$UPSTREAM/flutter/android/app/src/main/res/mipmap-${density}/ic_launcher_round.png"
done

copy "$BRANDING/splash/splash.png"         "$UPSTREAM/flutter/assets/splash.png"
copy "$BRANDING/splash/splash-dark.png"    "$UPSTREAM/flutter/assets/splash-dark.png"

log "branding applied to $UPSTREAM"
log "next: run upstream build (python3 build.py --flutter / cargo build --release)"
