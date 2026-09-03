#!/usr/bin/env bash
# Rollback-focused smoke checks. Runs post-deploy smoke and validates expected rollback evidence.
set -euo pipefail

EXPECTED_BACKEND_IMAGE="${CHRONICLE_EXPECTED_BACKEND_IMAGE:-}"
EXPECTED_FRONTEND_IMAGE="${CHRONICLE_EXPECTED_FRONTEND_IMAGE:-}"
REQUIRE_IMAGES="${CHRONICLE_ROLLBACK_REQUIRE_IMAGES:-0}"
KUBE_NAMESPACE="${CHRONICLE_KUBE_NAMESPACE:-chronicle}"
KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pass_count=0
fail_count=0
skip_count=0

usage() {
  cat <<'EOF'
Usage: CHRONICLE_BASE_URL=https://host scripts/chronicle-rollback-smoke.sh

Optional expected image checks:
  CHRONICLE_EXPECTED_BACKEND_IMAGE=registry/image:tag
  CHRONICLE_EXPECTED_FRONTEND_IMAGE=registry/image:tag
  CHRONICLE_ROLLBACK_REQUIRE_IMAGES=1
  CHRONICLE_KUBE_NAMESPACE=chronicle

All arguments are passed through to scripts/chronicle-post-deploy-smoke.sh.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

pass() {
  pass_count=$((pass_count + 1))
  printf 'PASS %-36s %s\n' "$1" "$2"
}

fail() {
  fail_count=$((fail_count + 1))
  printf 'FAIL %-36s %s\n' "$1" "$2"
}

skip() {
  skip_count=$((skip_count + 1))
  printf 'SKIP %-36s %s\n' "$1" "$2"
}

image_ref_is_acceptable() {
  local ref="$1"
  local last_component tag

  if [[ "$ref" =~ @sha256:[0-9A-Fa-f]{64}$ ]]; then
    return 0
  fi

  last_component="${ref##*/}"
  if [[ "$last_component" != *:* ]]; then
    return 1
  fi

  tag="${last_component##*:}"
  if [[ "$tag" =~ ^sha-[0-9A-Fa-f]{7,64}$ ]]; then
    return 0
  fi
  if [[ "$tag" =~ ^v[0-9]+([.][0-9]+){0,3}([-+][0-9A-Za-z.-]+)?$ ]]; then
    return 0
  fi

  return 1
}

validate_expected_image_ref() {
  local name="$1"
  local ref="$2"

  if [[ -z "$ref" ]]; then
    if [[ "$REQUIRE_IMAGES" == "1" ]]; then
      fail "$name expected image" "required but not set"
      return 1
    fi
    return 0
  fi

  if image_ref_is_acceptable "$ref"; then
    pass "$name expected image ref" "$ref"
  else
    fail "$name expected image ref" "mutable, placeholder, untagged, or non-release ref is not acceptable: $ref"
    return 1
  fi
}

deployment_image() {
  local deployment="$1"
  local container_name="$2"
  local actual

  actual="$("$KUBECTL_BIN" -n "$KUBE_NAMESPACE" get "deploy/${deployment}" -o "jsonpath={.spec.template.spec.containers[?(@.name==\"${container_name}\")].image}" 2>/dev/null || true)"
  if [[ -n "$actual" ]]; then
    printf '%s\n' "$actual"
    return 0
  fi

  "$KUBECTL_BIN" -n "$KUBE_NAMESPACE" get "deploy/${deployment}" -o 'jsonpath={.spec.template.spec.containers[0].image}' 2>/dev/null || true
}

printf 'Chronicle rollback smoke\n'

"$ROOT_DIR/scripts/chronicle-post-deploy-smoke.sh" "$@"

validate_expected_image_ref "backend" "$EXPECTED_BACKEND_IMAGE" || true
validate_expected_image_ref "frontend" "$EXPECTED_FRONTEND_IMAGE" || true

if ! command -v "$KUBECTL_BIN" >/dev/null 2>&1; then
  if [[ "$REQUIRE_IMAGES" == "1" ]]; then
    fail "image verification" "$KUBECTL_BIN not found"
  else
    skip "image verification" "$KUBECTL_BIN not found"
  fi
else
  if [[ -n "$EXPECTED_BACKEND_IMAGE" ]]; then
    actual="$(deployment_image chronicle-backend backend)"
    if [[ "$actual" == "$EXPECTED_BACKEND_IMAGE" ]]; then
      pass "backend rollback image" "$actual"
    else
      fail "backend rollback image" "actual=${actual:-missing}; expected=$EXPECTED_BACKEND_IMAGE"
    fi
  else
    if [[ "$REQUIRE_IMAGES" == "1" ]]; then
      fail "backend rollback image" "CHRONICLE_EXPECTED_BACKEND_IMAGE not set"
    else
      skip "backend rollback image" "CHRONICLE_EXPECTED_BACKEND_IMAGE not set"
    fi
  fi

  if [[ -n "$EXPECTED_FRONTEND_IMAGE" ]]; then
    actual="$(deployment_image chronicle-frontend frontend)"
    if [[ "$actual" == "$EXPECTED_FRONTEND_IMAGE" ]]; then
      pass "frontend rollback image" "$actual"
    else
      fail "frontend rollback image" "actual=${actual:-missing}; expected=$EXPECTED_FRONTEND_IMAGE"
    fi
  else
    if [[ "$REQUIRE_IMAGES" == "1" ]]; then
      fail "frontend rollback image" "CHRONICLE_EXPECTED_FRONTEND_IMAGE not set"
    else
      skip "frontend rollback image" "CHRONICLE_EXPECTED_FRONTEND_IMAGE not set"
    fi
  fi
fi

printf 'Rollback evidence checks: %s pass, %s fail, %s skip\n' "$pass_count" "$fail_count" "$skip_count"
if [[ "$fail_count" -gt 0 ]]; then
  exit 1
fi
