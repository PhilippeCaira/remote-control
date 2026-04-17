#!/usr/bin/env bash
# ============================================================================
# rotate-key.sh — supervised rotation of the hbbs signing key.
#
# WARNING:
#   Rotating the server key invalidates EVERY deployed client binary. Every
#   installed client must be uninstalled and replaced with a new build that
#   embeds the new public key. Reserve this procedure for:
#     * confirmed private-key compromise;
#     * a deliberate mass re-enrolment.
#
# This script:
#   1. Backs up the current keypair to volumes/rustdesk/server/attic/.
#   2. Removes the live key so the container regenerates one at next start.
#   3. Does NOT touch GitHub Secrets — the operator must manually copy the
#      new pubkey printed at the end into RS_PUB_KEY before the next build.
#
# Usage:   ./rotate-key.sh --yes-i-understand
# ============================================================================
set -euo pipefail

if [[ "${1:-}" != "--yes-i-understand" ]]; then
    cat >&2 <<'EOF'
Refusing to run without explicit acknowledgement. Pass --yes-i-understand
after reading the warning at the top of this file.

Every deployed client will stop connecting until it is replaced by a new
build compiled against the new public key.
EOF
    exit 2
fi

SERVER_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SERVER_DIR"

COMPOSE="docker compose"
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
ATTIC="volumes/rustdesk/server/attic/${STAMP}"

mkdir -p "$ATTIC"
if [[ -f volumes/rustdesk/server/id_ed25519 ]]; then
    mv volumes/rustdesk/server/id_ed25519     "$ATTIC/"
    mv volumes/rustdesk/server/id_ed25519.pub "$ATTIC/"
    chmod 600 "$ATTIC/id_ed25519"
    echo "[rotate-key] Previous key moved to $ATTIC"
else
    echo "[rotate-key] No existing key found; proceeding as first-time init."
fi

echo "[rotate-key] Restarting rustdesk to regenerate..."
$COMPOSE up -d --force-recreate rustdesk

for i in {1..60}; do
    if [[ -f volumes/rustdesk/server/id_ed25519.pub ]]; then break; fi
    sleep 1
done

if [[ ! -f volumes/rustdesk/server/id_ed25519.pub ]]; then
    echo "ERROR: new key did not appear. Restore the previous one from $ATTIC." >&2
    exit 1
fi

NEW_PUB=$(tr -d '\n' < volumes/rustdesk/server/id_ed25519.pub)
echo
echo "[rotate-key] NEW public key:"
echo "  $NEW_PUB"
echo
echo "Now:"
echo "  1. Update GitHub Secret RS_PUB_KEY to the string above."
echo "  2. Bump the client version (tag v<next>) and trigger a release."
echo "  3. Notify every client to reinstall with the new binaries."
echo "  4. After a grace window, remove the old private key from $ATTIC."
