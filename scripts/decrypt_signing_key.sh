#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

function cleanup {
    echo "🧹 Cleanup..."
    rm -f $HOME/secrets/chronicle-keys.gpg-key
}

trap 'cleanup' ERR

# Decrypt the file
mkdir -p secrets
# --batch to prevent interactive command
# --yes to assume "yes" for questions
gpg --quiet --batch --yes --passphrase="$SIGNING_KEY_PASSPHRASE" --output ./secrets/chronicle-keys.gpg-key --decrypt chronicle-keys.gpg-key.gpg
gpg --fast-import --no-tty --batch --yes ./secrets/chronicle-keys.gpg-key
