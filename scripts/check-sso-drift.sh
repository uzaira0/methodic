#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
strict=0

if [[ "${1:-}" == "--strict" ]]; then
  strict=1
fi

run_group() {
  local label="$1"
  local pattern="$2"
  shift 2
  local output

  output="$(rg -n "$pattern" "$@" 2>/dev/null || true)"

  printf '\n== %s ==\n' "$label"
  if [[ -z "$output" ]]; then
    printf '[ok] no matches\n'
    return 0
  fi

  printf '%s\n' "$output"
  return 1
}

printf 'Chronicle SSO drift audit\n'
printf 'root: %s\n' "$ROOT_DIR"

if ! run_group \
  "server_auth0_wiring" \
  "Auth0Pod|Auth0Configuration|LocalUserListingService|LocalUserDirectoryService" \
  "$ROOT_DIR/chronicle-server/src/main/kotlin/com/openlattice/chronicle"; then
  :
fi

defaults_failed=0
if ! run_group \
  "server_auth0_defaults" \
  "methodic\\.us\\.auth0\\.com|cdn\\.auth0\\.com|allowed-domains: methodic|Auth0 domains" \
  "$ROOT_DIR/chronicle-server/src/main/kotlin/com/openlattice/chronicle" \
  "$ROOT_DIR/chronicle-server/src/main/resources/ssrf.yaml" \
  "$ROOT_DIR/docs/SECURITY-HARDENING.md"; then
  defaults_failed=1
fi

if ! run_group \
  "web_bootstrap_paths" \
  "/chronicle/config\\.json|fetchBootstrapToken|exchangeBootstrapToken" \
  "$ROOT_DIR/chronicle-web/src"; then
  :
fi

if ! run_group \
  "web_legacy_user_storage" \
  "AUTH0_USER_INFO|AUTH0_ID_TOKEN|USER_INFO_STORAGE_KEY|AUTH0_NONCE_STATE|Auth0NonceState" \
  "$ROOT_DIR/chronicle-web/src"; then
  :
fi

if ! run_group \
  "web_stale_auth0_runtime" \
  "Auth0AdminRoute|core/auth/Auth0|copy auth0 token" \
  "$ROOT_DIR/chronicle-web/src"; then
  :
fi

if (( strict == 1 && defaults_failed == 1 )); then
  printf '\n[fail] strict mode: Auth0-specific runtime/config defaults were reintroduced\n'
  exit 1
fi
