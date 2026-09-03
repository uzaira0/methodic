#!/usr/bin/env bash
# Store the NVD API key in an approved local secret source without printing it.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'EOF'
Usage:
  scripts/chronicle-store-nvd-api-key.sh [--keychain]
  scripts/chronicle-store-nvd-api-key.sh --file PATH
  scripts/chronicle-store-nvd-api-key.sh --help

Reads the key from stdin, or from a hidden interactive prompt when stdin is a
terminal. The key is never printed.

Targets:
  --keychain   Store in macOS Keychain using service chronicle-nvd-api-key.
               This is the default.
  --file PATH  Store in a private 0600 file for operator-managed RHEL hosts. The path
               must be outside the Git checkout.

Environment:
  CHRONICLE_NVD_KEYCHAIN_SERVICE   Keychain service override.
  CHRONICLE_NVD_KEYCHAIN_ACCOUNT   Keychain account override.
EOF
}

target="keychain"
file_path=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keychain)
      target="keychain"
      shift
      ;;
    --file)
      if [[ $# -lt 2 || -z "$2" ]]; then
        printf 'missing value for --file\n' >&2
        exit 2
      fi
      target="file"
      file_path="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      printf 'unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

read_key() {
  local value=""
  if [[ -t 0 ]]; then
    printf 'NVD API key: ' >&2
    IFS= read -r -s value
    printf '\n' >&2
  else
    IFS= read -r value || true
  fi
  value="${value%$'\r'}"
  printf '%s' "$value"
}

validate_key() {
  local value="$1"
  if [[ -z "$value" ]]; then
    printf 'NVD API key was empty.\n' >&2
    exit 2
  fi
  if [[ "${#value}" -lt 20 ]]; then
    printf 'NVD API key was too short to be valid.\n' >&2
    exit 2
  fi
  if [[ "$value" =~ [[:space:][:cntrl:]] ]]; then
    printf 'NVD API key must be a single line with no whitespace.\n' >&2
    exit 2
  fi
}

store_keychain() {
  local value="$1"
  if ! command -v security >/dev/null 2>&1; then
    printf 'macOS security CLI is not available; use --file PATH on this host.\n' >&2
    exit 127
  fi

  local user="${USER:-}"
  if [[ -z "$user" ]] && command -v id >/dev/null 2>&1; then
    user="$(id -un 2>/dev/null || true)"
  fi
  local service="${CHRONICLE_NVD_KEYCHAIN_SERVICE:-chronicle-nvd-api-key}"
  local account="${CHRONICLE_NVD_KEYCHAIN_ACCOUNT:-$user}"
  if [[ -z "$account" ]]; then
    printf 'could not determine Keychain account; set CHRONICLE_NVD_KEYCHAIN_ACCOUNT.\n' >&2
    exit 2
  fi

  security add-generic-password \
    -a "$account" \
    -s "$service" \
    -w "$value" \
    -U >/dev/null

  printf 'Stored NVD API key in macOS Keychain service %s for account %s.\n' "$service" "$account"
}

store_file() {
  local value="$1"
  local path="$file_path"
  if [[ -z "$path" ]]; then
    printf '--file PATH is required for file storage.\n' >&2
    exit 2
  fi
  if [[ "$path" != /* ]]; then
    path="$PWD/$path"
  fi

  local repo_root
  repo_root="$(cd "$ROOT_DIR" && git rev-parse --show-toplevel 2>/dev/null || printf '%s' "$ROOT_DIR")"
  case "$path" in
    "$repo_root"|"$repo_root"/*)
      printf 'refusing to write NVD API key inside Git checkout: %s\n' "$path" >&2
      exit 2
      ;;
  esac

  if [[ -L "$path" ]]; then
    printf 'refusing to write NVD API key through symlink: %s\n' "$path" >&2
    exit 2
  fi

  local dir base tmp
  dir="$(dirname "$path")"
  base="$(basename "$path")"
  mkdir -p "$dir"
  tmp="$dir/.$base.tmp.$$"
  trap 'rm -f -- "$tmp"' RETURN
  umask 077
  printf '%s\n' "$value" > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$path"
  trap - RETURN
  chmod 600 "$path"
  file_path="$path"

  printf 'Stored NVD API key in private file %s.\n' "$path"
  printf 'Use: export CHRONICLE_NVD_API_KEY_FILE=%q\n' "$path"
}

key="$(read_key)"
validate_key "$key"

case "$target" in
  keychain)
    store_keychain "$key"
    ;;
  file)
    store_file "$key"
    ;;
  *)
    printf 'unknown target: %s\n' "$target" >&2
    exit 2
    ;;
esac

unset key

if [[ "$target" == "file" ]]; then
  CHRONICLE_NVD_API_KEY_FILE="$file_path" "$ROOT_DIR/scripts/chronicle-load-nvd-api-key.sh"
else
  "$ROOT_DIR/scripts/chronicle-load-nvd-api-key.sh"
fi
