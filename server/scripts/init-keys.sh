#!/usr/bin/env bash
# ============================================================================
# init-keys.sh — bootstrap hbbs signing keys.
#
# The server image generates an ed25519 keypair on first run under /data.
# This helper:
#   1. Starts the `rustdesk` service long enough for the key to appear.
#   2. Prints the public key so you can copy it into GitHub Secrets
#      (RS_PUB_KEY) — which is what every client build embeds.
#
# Idempotent: if the key already exists, it is just printed.
# ============================================================================
set -euo pipefail

cd "$(dirname "$0")/.."

COMPOSE="docker compose"
if ! $COMPOSE version >/dev/null 2>&1; then
    echo "ERROR: docker compose plugin not found. Install Docker Engine + compose-v2." >&2
    exit 1
fi

PUB_KEY_PATH="volumes/rustdesk/server/id_ed25519.pub"
PRIV_KEY_PATH="volumes/rustdesk/server/id_ed25519"

if [[ -f "$PUB_KEY_PATH" ]]; then
    echo "[init-keys] Existing key found."
else
    echo "[init-keys] No key present yet; starting the rustdesk service to generate one..."
    mkdir -p volumes/rustdesk/server volumes/rustdesk/api volumes/caddy/data volumes/caddy/config volumes/downloads
    $COMPOSE up -d rustdesk

    # Poll for up to 60 s.
    for i in {1..60}; do
        if [[ -f "$PUB_KEY_PATH" ]]; then break; fi
        sleep 1
    done

    if [[ ! -f "$PUB_KEY_PATH" ]]; then
        echo "ERROR: key file did not appear after 60 s." >&2
        echo "Inspect: docker compose logs rustdesk" >&2
        exit 1
    fi
fi

# Harden permissions on the private key.
chmod 600 "$PRIV_KEY_PATH" 2>/dev/null || true

PUB_KEY=$(tr -d '\n' < "$PUB_KEY_PATH")

cat <<EOF

================================================================================
 Server public key (RS_PUB_KEY)
--------------------------------------------------------------------------------
$PUB_KEY
================================================================================

Next steps:
  1. GitHub -> this repo -> Settings -> Secrets and variables -> Actions
       RS_PUB_KEY        = <the string above>
       RENDEZVOUS_SERVER = <your DOMAIN_RDV>
       RELAY_SERVER      = <your DOMAIN_RDV>:21117
       API_SERVER        = https://<your DOMAIN_API>

  2. NEVER commit volumes/rustdesk/server/id_ed25519 (the private key).
     It is already listed in .gitignore.

  3. Back up the private key NOW (see server/scripts/backup.sh).
     Losing it forces a rebuild + redeploy of EVERY client.

EOF
