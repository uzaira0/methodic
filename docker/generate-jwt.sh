#!/usr/bin/env bash
# generate-jwt.sh — Generate a signed JWT for self-hosted Chronicle deployments
#
# Reads JWT_SECRET from .env (or environment) and produces an HS256-signed JWT
# with sub=local-admin, 30-day expiry. Outputs the token to stdout and
# optionally writes docker/chronicle-config.json for the frontend.
#
# Usage:
#   ./generate-jwt.sh              # print token to stdout
#   ./generate-jwt.sh --write-config  # also write chronicle-config.json
#
# Requirements: openssl, base64 (GNU coreutils or macOS)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load JWT_SECRET from .env if not already in environment
if [ -z "${JWT_SECRET:-}" ]; then
  ENV_FILE="${SCRIPT_DIR}/.env"
  if [ -f "$ENV_FILE" ]; then
    JWT_SECRET="$(grep -E '^JWT_SECRET=' "$ENV_FILE" | head -1 | cut -d= -f2-)"
  fi
fi

if [ -z "${JWT_SECRET:-}" ]; then
  echo "ERROR: JWT_SECRET not found in environment or .env file" >&2
  echo "Generate one with: openssl rand -base64 64" >&2
  exit 1
fi

# --- helpers ---

# Base64url encode (no padding)
b64url() {
  openssl base64 -e -A | tr '+/' '-_' | tr -d '='
}

# --- build JWT ---

NOW=$(date +%s)
EXP=$((NOW + 30 * 86400))  # 30 days

HEADER='{"alg":"HS256","typ":"JWT"}'
PAYLOAD="{\"iss\":\"https://localhost/\",\"aud\":\"dummy-client-id\",\"sub\":\"local-admin\",\"iat\":${NOW},\"exp\":${EXP}}"

H=$(printf '%s' "$HEADER" | b64url)
P=$(printf '%s' "$PAYLOAD" | b64url)

SIGNATURE=$(printf '%s.%s' "$H" "$P" | openssl dgst -sha256 -hmac "$JWT_SECRET" -binary | b64url)

TOKEN="${H}.${P}.${SIGNATURE}"

echo "$TOKEN"

# Optionally write config.json for the frontend
if [ "${1:-}" = "--write-config" ]; then
  CONFIG_FILE="${SCRIPT_DIR}/chronicle-config.json"
  printf '{"token":"%s"}\n' "$TOKEN" > "$CONFIG_FILE"
  echo "Wrote ${CONFIG_FILE}" >&2
fi
