#!/usr/bin/env bash
# ============================================================================
# verify-hardcoded.sh — post-build assertion that every required secret is
# actually embedded in the produced binary.
#
# Runs after each platform build in CI; fail-fast if a regression (env var
# not honored, stripped by link, replaced by upstream default) would ship
# a binary that silently falls back to RustDesk's public infrastructure.
#
# Usage:   verify-hardcoded.sh <path/to/binary>[ <more binaries>...]
#
# Required environment:
#   EXPECT_RENDEZVOUS            e.g. rdv.example.com
#   EXPECT_RELAY                 e.g. rdv.example.com:21117  (hostname only checked)
#   EXPECT_API                   e.g. https://api.example.com
#   EXPECT_RS_PUB_KEY            base64 ed25519 public key (tr -d '\n' before set)
#   EXPECT_ADMIN_PW_URL          e.g. https://api.example.com/admin-pw
#   EXPECT_ADMIN_PW_HMAC_KEY_PREFIX
#                                first 16 chars of the base64 HMAC key
#                                (full key is ~44 chars; a prefix check avoids
#                                printing the full secret in CI logs if this
#                                assertion ever fails)
#
# Each binary is scanned with `strings`; every expected value must appear
# at least once. Any miss fails the script.
# ============================================================================
set -euo pipefail

fail() { printf '[verify-hardcoded] FAIL: %s\n' "$*" >&2; exit 1; }
log()  { printf '[verify-hardcoded] %s\n' "$*"; }

(( $# >= 1 )) || fail "usage: $0 <binary> [binary...]"

: "${EXPECT_RENDEZVOUS:?set EXPECT_RENDEZVOUS}"
: "${EXPECT_API:?set EXPECT_API}"
: "${EXPECT_RS_PUB_KEY:?set EXPECT_RS_PUB_KEY}"
: "${EXPECT_ADMIN_PW_URL:?set EXPECT_ADMIN_PW_URL}"
: "${EXPECT_ADMIN_PW_HMAC_KEY_PREFIX:?set EXPECT_ADMIN_PW_HMAC_KEY_PREFIX}"
EXPECT_RELAY_HOST="${EXPECT_RELAY%%:*}"   # strip port

command -v strings >/dev/null || fail "\`strings\` not found — install binutils"

# Each expected value must be found in AT LEAST ONE of the scanned binaries.
# This is looser than "every binary has every value" because compiler
# optimizations (notably LTO on macOS x86_64) can dedup or inline strings
# across the dylib / main exe boundary — e.g. API_SERVER fallback string
# sometimes ends up in the Flutter wrapper binary, not in librustdesk.dylib.
# The anti-regression check (upstream default pubkey) still runs per-file:
# if that string shows up ANYWHERE, we ship a broken binary.

found_rendezvous=0; found_relay=0; found_api=0; found_pubkey=0
found_admin_pw_url=0; found_admin_pw_key=0
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

for bin in "$@"; do
    [[ -f "$bin" ]] || fail "not a file: $bin"
    log "scanning $bin ($(du -h "$bin" | cut -f1))"
    strings -n 6 "$bin" > "$tmp"

    grep -qF -- "$EXPECT_RENDEZVOUS"                "$tmp" && found_rendezvous=1
    grep -qF -- "$EXPECT_RELAY_HOST"                "$tmp" && found_relay=1
    grep -qF -- "$EXPECT_API"                       "$tmp" && found_api=1
    grep -qF -- "$EXPECT_RS_PUB_KEY"                "$tmp" && found_pubkey=1
    grep -qF -- "$EXPECT_ADMIN_PW_URL"              "$tmp" && found_admin_pw_url=1
    grep -qF -- "$EXPECT_ADMIN_PW_HMAC_KEY_PREFIX"  "$tmp" && found_admin_pw_key=1

    # Anti-regression: upstream RustDesk default pubkey must NOT appear
    # anywhere, otherwise the binary is still targeting public infra.
    if grep -qF -- "OeVuKk5nlHiXp+APNn0Y3pC1Iwpwn44JGqrQCsWqmBw=" "$tmp"; then
        fail "upstream default RS_PUB_KEY detected in $bin — config override failed"
    fi
done

missing=()
(( found_rendezvous ))    || missing+=("RENDEZVOUS:$EXPECT_RENDEZVOUS")
(( found_relay ))         || missing+=("RELAY:$EXPECT_RELAY_HOST")
(( found_api ))           || missing+=("API:$EXPECT_API")
(( found_pubkey ))        || missing+=("RS_PUB_KEY")
(( found_admin_pw_url ))  || missing+=("ADMIN_PW_URL:$EXPECT_ADMIN_PW_URL")
(( found_admin_pw_key ))  || missing+=("ADMIN_PW_HMAC_KEY (prefix)")
if (( ${#missing[@]} > 0 )); then
    fail "missing across all scanned binaries: ${missing[*]}"
fi

log "all expected hardcoded values found across $# binary/binaries"
