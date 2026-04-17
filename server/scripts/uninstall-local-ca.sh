#!/usr/bin/env bash
# ============================================================================
# uninstall-local-ca.sh — reverse install-local-ca.sh.
# ============================================================================
set -euo pipefail

HOSTS_BEGIN="# BEGIN remote-control-local"
HOSTS_END="# END remote-control-local"
CA_ANCHOR_NAME="remote-control-local.pem"

log() { printf '[uninstall-local-ca] %s\n' "$*"; }

# 1. Remove trust anchor.
if [[ -f "/etc/pki/ca-trust/source/anchors/${CA_ANCHOR_NAME}" ]]; then
    sudo rm -f "/etc/pki/ca-trust/source/anchors/${CA_ANCHOR_NAME}"
    sudo update-ca-trust extract
    log "removed p11-kit anchor"
elif [[ -f "/usr/local/share/ca-certificates/${CA_ANCHOR_NAME%.pem}.crt" ]]; then
    sudo rm -f "/usr/local/share/ca-certificates/${CA_ANCHOR_NAME%.pem}.crt"
    sudo update-ca-certificates
    log "removed debian anchor"
else
    log "no trust anchor installed by us"
fi

# 2. Remove /etc/hosts block.
if grep -qF "$HOSTS_BEGIN" /etc/hosts; then
    sudo sed -i "/^${HOSTS_BEGIN}\$/,/^${HOSTS_END}\$/d" /etc/hosts
    # Also drop the blank line we inserted before the block if it is still there.
    sudo sed -i -e ':a' -e '/^\n*$/{$d;N;ba' -e '}' /etc/hosts
    log "removed hosts block"
else
    log "no hosts block to remove"
fi

log "done"
