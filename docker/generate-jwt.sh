#!/usr/bin/env bash
# generate-jwt.sh — Generate a short-lived JWT for manual Chronicle diagnostics.
#
# The signing secret is accepted from a mode-0600 file or stdin. JWTs are never
# printed; an explicit output path is required and is atomically created 0600.
# JWT_SECRET remains a compatibility input for existing test harnesses, but is
# copied directly to the signer over a private descriptor rather than placed in argv.
#
# Usage:
#   ./generate-jwt.sh --secret-file /secure/jwt-secret --output ./diagnostic.jwt
#   ./generate-jwt.sh --secret-stdin --output ./diagnostic.jwt < /secure/jwt-secret
#   JWT_SECRET_FILE=/secure/jwt-secret JWT_OUTPUT_FILE=./diagnostic.jwt ./generate-jwt.sh
#
# Requirements: bash, python3

set -euo pipefail

# Capture the compatibility input in unexported shell state before even path discovery runs.
# The value is later moved onto fd 3 and cleared before Python starts, so no helper inherits
# JWT_SECRET (or a renamed environment copy) accidentally.
AMBIENT_JWT_SECRET="${JWT_SECRET-}"
export -n JWT_SECRET 2>/dev/null || true
unset JWT_SECRET

umask 077

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_FILE="${JWT_OUTPUT_FILE:-}"
SECRET_FILE="${JWT_SECRET_FILE:-}"
SECRET_STDIN=false

err() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null
}

require_private_file() {
  local path="$1" description="$2" mode
  [[ -f "$path" && ! -L "$path" ]] || err "$description must be a regular, non-symlink file: $path"
  mode="$(file_mode "$path")" || err "could not inspect permissions for $description: $path"
  [[ "$mode" == "600" ]] || err "$description must have mode 0600 (found $mode): $path"
  [[ -O "$path" ]] || err "$description must be owned by the current user: $path"
}

usage() {
  sed -n '2,/^$/{ s/^# //; s/^#$//; p }' "$0"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --secret-file)
      [[ $# -ge 2 ]] || err "--secret-file requires a path"
      SECRET_FILE="$2"
      shift 2
      ;;
    --secret-stdin)
      SECRET_STDIN=true
      shift
      ;;
    --output)
      [[ $# -ge 2 ]] || err "--output requires a path"
      OUTPUT_FILE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *) err "unknown option: $1" ;;
  esac
done

[[ -n "$OUTPUT_FILE" ]] || err "--output (or JWT_OUTPUT_FILE) is required; JWTs are never printed"
if $SECRET_STDIN && [[ -n "$SECRET_FILE" ]]; then
  err "choose exactly one of --secret-file/JWT_SECRET_FILE or --secret-stdin"
fi

SECRET_KIND="raw"
if [[ -n "$SECRET_FILE" ]]; then
  require_private_file "$SECRET_FILE" "JWT signing secret file"
elif $SECRET_STDIN; then
  : # The original stdin is duplicated to fd 3 below.
elif [[ -n "$AMBIENT_JWT_SECRET" ]]; then
  : # Compatibility input is connected directly to fd 3 below.
elif [[ -f "$SCRIPT_DIR/.env" ]]; then
  SECRET_FILE="$SCRIPT_DIR/.env"
  SECRET_KIND="env"
  require_private_file "$SECRET_FILE" "JWT environment file"
else
  err "no JWT signing secret supplied; use --secret-file or --secret-stdin"
fi

JWT_TTL_SECONDS="${JWT_TTL_SECONDS:-900}"
JWT_MAX_TTL_SECONDS="${JWT_MAX_TTL_SECONDS:-3600}"

[[ "$JWT_TTL_SECONDS" =~ ^[0-9]+$ ]] && (( JWT_TTL_SECONDS > 0 )) || \
  err "JWT_TTL_SECONDS must be a positive integer number of seconds"
[[ "$JWT_MAX_TTL_SECONDS" =~ ^[0-9]+$ ]] && (( JWT_MAX_TTL_SECONDS > 0 )) || \
  err "JWT_MAX_TTL_SECONDS must be a positive integer number of seconds"
(( JWT_TTL_SECONDS <= JWT_MAX_TTL_SECONDS )) || \
  err "JWT_TTL_SECONDS ($JWT_TTL_SECONDS) exceeds JWT_MAX_TTL_SECONDS ($JWT_MAX_TTL_SECONDS)"

OUTPUT_PARENT="$(dirname "$OUTPUT_FILE")"
[[ -d "$OUTPUT_PARENT" ]] || err "JWT output directory does not exist: $OUTPUT_PARENT"
[[ ! -e "$OUTPUT_FILE" && ! -L "$OUTPUT_FILE" ]] || \
  err "refusing to overwrite existing JWT output: $OUTPUT_FILE"
OUTPUT_PARENT="$(cd "$OUTPUT_PARENT" && pwd -P)"
OUTPUT_FILE="$OUTPUT_PARENT/$(basename "$OUTPUT_FILE")"

TMP_FILE="$(mktemp "$OUTPUT_FILE.tmp.XXXXXX")"
chmod 600 "$TMP_FILE"
cleanup() {
  [[ -n "${TMP_FILE:-}" && -f "$TMP_FILE" ]] && rm -f -- "$TMP_FILE"
  return 0
}
trap cleanup EXIT

generate_jwt() {
  python3 - "$TMP_FILE" "$JWT_TTL_SECONDS" "$SECRET_KIND" <<'PY'
import base64
import hashlib
import hmac
import json
import os
import secrets
import sys
import time

output_path, ttl_text, secret_kind = sys.argv[1:]
source = os.fdopen(3, "rb", closefd=False).read()
if secret_kind == "env":
    secret = b""
    for raw_line in source.splitlines():
        if raw_line.startswith(b"JWT_SECRET="):
            secret = raw_line.split(b"=", 1)[1]
            break
else:
    secret = source.rstrip(b"\r\n")
if not secret:
    raise SystemExit("ERROR: JWT signing secret is empty")

def b64url(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")

now = int(time.time())
payload = {
    "iss": "https://localhost/",
    "aud": "dummy-client-id",
    "sub": "local-admin",
    "iat": now,
    "exp": now + int(ttl_text),
    "jti": secrets.token_hex(16),
}
header_segment = b64url(json.dumps({"alg": "HS256", "typ": "JWT"}, separators=(",", ":")).encode())
payload_segment = b64url(json.dumps(payload, separators=(",", ":")).encode())
signing_input = f"{header_segment}.{payload_segment}".encode("ascii")
signature = b64url(hmac.new(secret, signing_input, hashlib.sha256).digest())
token = f"{header_segment}.{payload_segment}.{signature}\n"
with open(output_path, "w", encoding="ascii", newline="") as output:
    output.write(token)
os.chmod(output_path, 0o600)
PY
}

if [[ -n "$SECRET_FILE" ]]; then
  generate_jwt 3< "$SECRET_FILE"
elif $SECRET_STDIN; then
  generate_jwt 3<&0
else
  # A here-string is prepared by this shell without a credential-bearing argv or exported
  # variable. Clear the shell copy before the signer process is launched.
  exec 3<<<"$AMBIENT_JWT_SECRET"
  unset AMBIENT_JWT_SECRET
  generate_jwt
  exec 3<&-
fi

[[ "$(file_mode "$TMP_FILE")" == "600" ]] || err "temporary JWT output did not retain mode 0600"
mv -- "$TMP_FILE" "$OUTPUT_FILE"
TMP_FILE=""
trap - EXIT
printf 'Wrote protected diagnostic JWT: %s\n' "$OUTPUT_FILE" >&2
