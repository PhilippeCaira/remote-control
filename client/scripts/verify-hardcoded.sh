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
#   EXPECT_RENDEZVOUS   e.g. rdv.example.com
#   EXPECT_RELAY        e.g. rdv.example.com:21117  (hostname only checked)
#   EXPECT_API          e.g. https://api.example.com
#   EXPECT_RS_PUB_KEY   base64 ed25519 public key (tr -d '\n' before set)
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
EXPECT_RELAY_HOST="${EXPECT_RELAY%%:*}"   # strip port

command -v strings >/dev/null || fail "\`strings\` not found — install binutils"

for bin in "$@"; do
    [[ -f "$bin" ]] || fail "not a file: $bin"
    log "scanning $bin ($(du -h "$bin" | cut -f1))"

    # Extract once, grep N times.
    tmp=$(mktemp)
    trap 'rm -f "$tmp"' EXIT
    strings -n 6 "$bin" > "$tmp"

    missing=()
    grep -qF -- "$EXPECT_RENDEZVOUS"   "$tmp" || missing+=("RENDEZVOUS:$EXPECT_RENDEZVOUS")
    grep -qF -- "$EXPECT_RELAY_HOST"   "$tmp" || missing+=("RELAY:$EXPECT_RELAY_HOST")
    grep -qF -- "$EXPECT_API"          "$tmp" || missing+=("API:$EXPECT_API")
    grep -qF -- "$EXPECT_RS_PUB_KEY"   "$tmp" || missing+=("RS_PUB_KEY")

    if (( ${#missing[@]} > 0 )); then
        fail "missing in $bin: ${missing[*]}"
    fi

    # Anti-regression: upstream RustDesk default pubkey must NOT leak.
    # (A release binary with this key present would fall back to public infra.)
    if grep -qF -- "OeVuKk5nlHiXp+APNn0Y3pC1Iwpwn44JGqrQCsWqmBw=" "$tmp"; then
        fail "upstream default RS_PUB_KEY detected in $bin — config override failed"
    fi

    log "OK  $bin has all expected hardcoded values"
    rm -f "$tmp"
    trap - EXIT
done

log "all binaries verified"
