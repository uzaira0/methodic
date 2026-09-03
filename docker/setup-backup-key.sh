#!/bin/bash
# setup-backup-key.sh — Initialize backup encryption key in secure location
#
# Moves the backup encryption key from the legacy location (alongside backups)
# to /etc/chronicle/backup-encryption-key (separate from backup data).
#
# HIPAA §164.312(a)(2)(iv) — Encryption key management

set -euo pipefail

KEY_DIR="/etc/chronicle"
KEY_FILE="${KEY_DIR}/backup-encryption-key"
LEGACY_KEY="/opt/chronicle/backups/.backup-encryption-key"

if [ -f "$KEY_FILE" ]; then
    echo "Backup encryption key already exists at ${KEY_FILE}"
    echo "Permissions: $(stat -c '%a %U:%G' "$KEY_FILE")"
    exit 0
fi

sudo mkdir -p "$KEY_DIR"

if [ -f "$LEGACY_KEY" ]; then
    echo "Moving key from legacy location..."
    sudo mv "$LEGACY_KEY" "$KEY_FILE"
else
    echo "Generating new backup encryption key..."
    openssl rand -base64 64 | sudo tee "$KEY_FILE" > /dev/null
fi

sudo chmod 600 "$KEY_FILE"
sudo chown root:root "$KEY_FILE"
echo "Backup encryption key ready at ${KEY_FILE}"
echo "Permissions: $(stat -c '%a %U:%G' "$KEY_FILE")"
