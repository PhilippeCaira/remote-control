#!/usr/bin/env bash
# ============================================================================
# run-two-peers.sh — launch two local instances of the branded RustDesk
# client with isolated $HOME directories, so they register as separate
# peers ("A" and "B") against the local hbbs.
#
# Assumes:
#   - The Linux client has been built (see docs/02-client-build.md or
#     docs/04-e2e-local.md).
#   - The server stack is running via the local profile.
#
# Usage:
#   scripts/run-two-peers.sh [path/to/bundle/executable]
# Default path: client/upstream/flutter/build/linux/x64/release/bundle/rustdesk
# ============================================================================
set -euo pipefail

BIN=${1:-client/upstream/flutter/build/linux/x64/release/bundle/rustdesk}
[[ -x "$BIN" ]] || { echo "ERROR: not executable: $BIN" >&2; exit 1; }

run_peer() {
    local name=$1
    local home="/tmp/rdc-peer-${name}"
    mkdir -p "$home/xdg"
    chmod 700 "$home/xdg"
    echo "[peer $name] starting with HOME=$home"
    env -i \
        HOME="$home" \
        XDG_RUNTIME_DIR="$home/xdg" \
        DISPLAY="${DISPLAY:-:0}" \
        WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-}" \
        XDG_SESSION_TYPE="${XDG_SESSION_TYPE:-x11}" \
        DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-}" \
        PATH="/usr/local/bin:/usr/bin:/bin" \
        "$BIN" \
        >"$home/peer-${name}.log" 2>&1 &
    echo "[peer $name] pid $! — logs: $home/peer-${name}.log"
}

if command -v tmux >/dev/null && [[ -n "${TMUX:-}" ]]; then
    tmux split-window -h "tail -F /tmp/rdc-peer-a/peer-a.log" || true
    tmux split-window -v "tail -F /tmp/rdc-peer-b/peer-b.log" || true
fi

run_peer a
sleep 2
run_peer b

cat <<EOF

Two peers running. In the app UI of each, read the 9-digit ID.
From peer A, paste peer B's ID + the accept password displayed on B.

Kill both:
    pkill -f "$BIN"

Watch server traffic:
    docker compose -f server/docker-compose.yml logs -f rustdesk | \\
      grep -iE "register|session|relay"
EOF
