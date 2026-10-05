#!/usr/bin/env bash
# Render the production Kustomize overlay only after operators supply reviewed immutable
# image digests. The source overlay carries nondeployable sentinels so plain `kubectl apply`
# cannot silently fall back to a mutable tag.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)

require_digest() {
  local name=$1 value
  value=${!name:-}
  [[ "$value" =~ ^[0-9a-f]{64}$ ]] || {
    printf 'error: %s must be a 64-character owner-approved lowercase SHA-256 digest\n' "$name" >&2
    exit 2
  }
}

require_digest CHRONICLE_BACKEND_IMAGE_DIGEST
require_digest CHRONICLE_FRONTEND_IMAGE_DIGEST
require_digest CHRONICLE_KEYCLOAK_IMAGE_DIGEST
command -v kustomize >/dev/null 2>&1 || {
  echo 'error: kustomize is required to render the production overlay' >&2
  exit 127
}

kustomize build "$root/k8s/overlays/production" |
  sed \
    -e "s/__CHRONICLE_BACKEND_IMAGE_DIGEST__/${CHRONICLE_BACKEND_IMAGE_DIGEST}/g" \
    -e "s/__CHRONICLE_FRONTEND_IMAGE_DIGEST__/${CHRONICLE_FRONTEND_IMAGE_DIGEST}/g" \
    -e "s/__CHRONICLE_KEYCLOAK_IMAGE_DIGEST__/${CHRONICLE_KEYCLOAK_IMAGE_DIGEST}/g"
