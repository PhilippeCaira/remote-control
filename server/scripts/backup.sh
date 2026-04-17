#!/usr/bin/env bash
# ============================================================================
# backup.sh — tar the Docker volumes to a timestamped archive.
#
# Critical content:
#   - volumes/rustdesk/server/id_ed25519 (losing this = reinstall every client)
#   - volumes/rustdesk/api/*             (SQLite with users, devices, addr book)
#   - volumes/caddy/*                    (TLS certificates, easy to reissue)
#
# Designed to be invoked by cron daily:
#   5 3 * * *  /opt/remote-control/server/scripts/backup.sh >/var/log/rdc-backup.log 2>&1
# ============================================================================
set -euo pipefail

SERVER_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SERVER_DIR"

DEST_DIR="${BACKUP_DIR:-/var/backups/remote-control}"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-14}"

mkdir -p "$DEST_DIR"
chmod 700 "$DEST_DIR"

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
ARCHIVE="${DEST_DIR}/remote-control-${STAMP}.tar.gz"

echo "[backup] Creating ${ARCHIVE}"
tar --preserve-permissions \
    --one-file-system \
    -C "$SERVER_DIR" \
    -czf "$ARCHIVE" \
    volumes/rustdesk volumes/caddy 2>&1 \
  | grep -v 'socket ignored' || true

chmod 600 "$ARCHIVE"

# Rotate: remove local archives older than RETENTION_DAYS.
find "$DEST_DIR" -maxdepth 1 -name 'remote-control-*.tar.gz' \
    -type f -mtime +"$RETENTION_DAYS" -delete

echo "[backup] Done. $(du -h "$ARCHIVE" | cut -f1) written."

# Offsite sync (opt-in). Set RCLONE_REMOTE=b2:bucket/path in the environment
# (or a wrapper cron) to enable.
if [[ -n "${RCLONE_REMOTE:-}" ]] && command -v rclone >/dev/null; then
    echo "[backup] Syncing to ${RCLONE_REMOTE}"
    rclone copy --retries 3 --low-level-retries 5 "$ARCHIVE" "$RCLONE_REMOTE"
fi
