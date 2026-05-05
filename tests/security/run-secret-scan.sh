#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Chronicle Secret Detection ==="
echo "Scanning for leaked secrets with gitleaks..."

gitleaks detect \
  --source "$SCRIPT_DIR/../.." \
  --config "$SCRIPT_DIR/gitleaks.toml" \
  --verbose \
  --no-git

echo "No secrets detected"
