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
#      (rename app, disable updater, …).
#   3. Substitute the endpoint/key triplet into the upstream source using
#      sed — the upstream exposes these as plain `const` values, not
#      env-var-driven macros (verified against rustdesk 1.4.6). Driven by
#      the following environment variables:
#          RENDEZVOUS_SERVER  — bare host, e.g. rdv.example.com
#          RS_PUB_KEY         — base64 ed25519 public key (single line)
#          API_SERVER         — full URL, e.g. https://api.example.com
#   4. Copy branded assets (icons, splash) from client/branding/ into
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
sed -i -E \
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
sed -i -E \
    -e "s|\"https://admin\.rustdesk\.com\"\.to_owned\(\)|\"${API_SERVER_ESC}\".to_owned()|" \
    "$COMMON_RS"

grep -qF "\"${API_SERVER}\".to_owned()" "$COMMON_RS" \
    || fail "API_SERVER substitution failed in $COMMON_RS"

# ---------------------------------------------------------------------------
# 4. Copy branded assets (non-fatal if missing; CI's release workflow has
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
