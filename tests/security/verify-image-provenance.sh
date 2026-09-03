#!/usr/bin/env bash
# Verify Chronicle container image provenance and optional image scan evidence.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPORT_DIR="${CHRONICLE_IMAGE_PROVENANCE_REPORT_DIR:-$SCRIPT_DIR/reports/image-provenance}"

MODE="verify"
IMAGE_TAG="${IMAGE_TAG:-}"
BACKEND_IMAGE="${BACKEND_IMAGE:-ghcr.io/uzaira0/chronicle/chronicle-backend}"
FRONTEND_IMAGE="${FRONTEND_IMAGE:-ghcr.io/uzaira0/chronicle/chronicle-frontend}"
REPOSITORY="${GITHUB_REPOSITORY:-uzaira0/chronicle}"
SIGNER_WORKFLOW="${SIGNER_WORKFLOW:-}"
SOURCE_REF="${SOURCE_REF:-}"
VERIFY_ATTESTATION=true
RUN_SBOM=true
RUN_VULN=true
RUN_LICENSE=true
ATTESTATION_RETRIES="${CHRONICLE_ATTESTATION_RETRIES:-4}"
ATTESTATION_RETRY_SLEEP_SECONDS="${CHRONICLE_ATTESTATION_RETRY_SLEEP_SECONDS:-10}"
IMAGE_REFS=()

PASS=0
FAIL=0
SKIP=0

log_pass() { PASS=$((PASS + 1)); printf '[PASS] %s\n' "$*"; }
log_fail() { FAIL=$((FAIL + 1)); printf '[FAIL] %s\n' "$*" >&2; }
log_skip() { SKIP=$((SKIP + 1)); printf '[SKIP] %s\n' "$*"; }
log_info() { printf '[INFO] %s\n' "$*"; }

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Verifies Chronicle container image attestations. Provide either --tag, or one
or more full --image refs.

Options:
  --tag TAG              Immutable tag for BACKEND_IMAGE and FRONTEND_IMAGE.
  --image REF            Full image ref to verify. Can be repeated.
  --backend-image REF    Backend image registry path without tag.
  --frontend-image REF   Frontend image registry path without tag.
  --repo OWNER/REPO      GitHub repository that produced the attestation.
  --signer-workflow REF  Expected signer workflow. Default:
                         github.com/OWNER/REPO/.github/workflows/cd.yml
  --source-ref REF       Optional expected source ref, e.g. refs/tags/v1.2.0.
  --report-dir DIR       Directory for JSON/SBOM/scan reports.
  --skip-attestation     Skip gh attestation verification. Dev-only.
  --skip-sbom            Skip Syft SBOM generation.
  --skip-vuln            Skip Grype vulnerability scan.
  --skip-license         Skip Syft license scan.
  --verify               Verify mode. Default.
  --sign                 Refuse local signing. Images are attested in GitHub CD.
  --help                 Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) IMAGE_TAG="${2:?Missing tag value}"; shift 2 ;;
    --image) IMAGE_REFS+=("${2:?Missing image ref}"); shift 2 ;;
    --backend-image) BACKEND_IMAGE="${2:?Missing backend image}"; shift 2 ;;
    --frontend-image) FRONTEND_IMAGE="${2:?Missing frontend image}"; shift 2 ;;
    --repo) REPOSITORY="${2:?Missing repository}"; shift 2 ;;
    --signer-workflow) SIGNER_WORKFLOW="${2:?Missing signer workflow}"; shift 2 ;;
    --source-ref) SOURCE_REF="${2:?Missing source ref}"; shift 2 ;;
    --report-dir) REPORT_DIR="${2:?Missing report dir}"; shift 2 ;;
    --skip-attestation) VERIFY_ATTESTATION=false; shift ;;
    --skip-sbom) RUN_SBOM=false; shift ;;
    --skip-vuln) RUN_VULN=false; shift ;;
    --skip-license) RUN_LICENSE=false; shift ;;
    --verify) MODE="verify"; shift ;;
    --sign) MODE="sign"; shift ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$SIGNER_WORKFLOW" ]]; then
  SIGNER_WORKFLOW="github.com/${REPOSITORY}/.github/workflows/cd.yml"
fi

if [[ "$MODE" == "sign" ]]; then
  log_fail "Local image signing is disabled; Chronicle images must be attested by GitHub CD via OIDC."
  exit 1
fi

mkdir -p "$REPORT_DIR"

sanitize_name() {
  printf '%s' "$1" | tr '/:@' '---' | tr -cd 'A-Za-z0-9._-'
}

reject_mutable_ref() {
  local ref="$1"
  case "$ref" in
    *:latest|*:main|*:master|*:develop|*:dev|*:staging|*:production)
      log_fail "Mutable image ref is not allowed: $ref"
      return 1
      ;;
  esac
  return 0
}

validate_image_ref() {
  local ref="$1"
  reject_mutable_ref "$ref" || return 1

  if [[ "$ref" == *@sha256:* ]]; then
    return 0
  fi

  if [[ "$ref" =~ ^[^[:space:]]+:(sha-[0-9A-Za-z._-]+|v[0-9][0-9A-Za-z._-]*)$ ]]; then
    return 0
  fi

  log_fail "Image ref must use a digest, sha-* tag, or v* release tag: $ref"
  return 1
}

if [[ "${#IMAGE_REFS[@]}" -eq 0 ]]; then
  if [[ -z "$IMAGE_TAG" ]]; then
    log_fail "Provide --tag or at least one --image ref"
    exit 1
  fi

  case "$IMAGE_TAG" in
    latest|main|master|develop|dev|staging|production|CHANGE_ME*|change_me*|change-me*)
      log_fail "Mutable or placeholder IMAGE_TAG is not allowed: $IMAGE_TAG"
      exit 1
      ;;
  esac

  IMAGE_REFS=("${BACKEND_IMAGE}:${IMAGE_TAG}" "${FRONTEND_IMAGE}:${IMAGE_TAG}")
fi

log_info "Chronicle image provenance verification"
log_info "Repository: $REPOSITORY"
log_info "Signer workflow: $SIGNER_WORKFLOW"
log_info "Report directory: $REPORT_DIR"

for image in "${IMAGE_REFS[@]}"; do
  validate_image_ref "$image" || true
done

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi

if [[ "$VERIFY_ATTESTATION" == true ]]; then
  if ! command -v gh >/dev/null 2>&1; then
    log_fail "gh CLI is required for attestation verification"
  fi
else
  log_skip "Attestation verification skipped by operator request"
fi

if [[ "$RUN_SBOM" == true || "$RUN_LICENSE" == true ]]; then
  if ! command -v syft >/dev/null 2>&1; then
    log_skip "syft not installed; SBOM/license scans skipped"
    RUN_SBOM=false
    RUN_LICENSE=false
  fi
fi

if [[ "$RUN_VULN" == true ]]; then
  if ! command -v grype >/dev/null 2>&1; then
    log_skip "grype not installed; vulnerability scan skipped"
    RUN_VULN=false
  fi
fi

for image in "${IMAGE_REFS[@]}"; do
  report_name="$(sanitize_name "$image")"

  if [[ "$VERIFY_ATTESTATION" == true && "$FAIL" -eq 0 ]]; then
    gh_args=(
      attestation verify "oci://${image}"
      --repo "$REPOSITORY"
      --signer-workflow "$SIGNER_WORKFLOW"
      --deny-self-hosted-runners
      --format json
    )
    if [[ -n "$SOURCE_REF" ]]; then
      gh_args+=(--source-ref "$SOURCE_REF")
    fi

    log_info "Verifying GitHub provenance attestation for $image"
    verified=false
    for attempt in $(seq 1 "$ATTESTATION_RETRIES"); do
      if gh "${gh_args[@]}" > "$REPORT_DIR/attestation-${report_name}.json" 2> "$REPORT_DIR/attestation-${report_name}.log"; then
        verified=true
        break
      fi
      if [[ "$attempt" -lt "$ATTESTATION_RETRIES" ]]; then
        log_info "Attestation not verified yet for $image; retrying in ${ATTESTATION_RETRY_SLEEP_SECONDS}s (${attempt}/${ATTESTATION_RETRIES})"
        sleep "$ATTESTATION_RETRY_SLEEP_SECONDS"
      fi
    done

    if [[ "$verified" == true ]]; then
      log_pass "GitHub provenance attestation verified for $image"
    else
      log_fail "GitHub provenance attestation verification failed for $image; see $REPORT_DIR/attestation-${report_name}.log"
    fi
  fi

  if [[ "$RUN_SBOM" == true ]]; then
    log_info "Generating SPDX SBOM for $image"
    if syft "$image" -o spdx-json="$REPORT_DIR/sbom-${report_name}.spdx.json" 2> "$REPORT_DIR/sbom-${report_name}.log"; then
      log_pass "SBOM generated for $image"
    else
      log_fail "SBOM generation failed for $image; see $REPORT_DIR/sbom-${report_name}.log"
    fi
  fi

  if [[ "$RUN_VULN" == true ]]; then
    log_info "Scanning $image for HIGH/CRITICAL vulnerabilities"
    vuln_file="$REPORT_DIR/vulns-${report_name}.json"
    if grype "$image" -o json --file "$vuln_file" 2> "$REPORT_DIR/vulns-${report_name}.log"; then
      if command -v jq >/dev/null 2>&1; then
        critical_count="$(jq '[.matches[]? | select(.vulnerability.severity == "Critical")] | length' "$vuln_file" 2>/dev/null || echo 0)"
        high_count="$(jq '[.matches[]? | select(.vulnerability.severity == "High")] | length' "$vuln_file" 2>/dev/null || echo 0)"
      else
        critical_count="$(grep -c '"Critical"' "$vuln_file" 2>/dev/null || echo 0)"
        high_count="$(grep -c '"High"' "$vuln_file" 2>/dev/null || echo 0)"
      fi

      if [[ "$critical_count" -gt 0 || "$high_count" -gt 0 ]]; then
        log_fail "$image has $critical_count CRITICAL and $high_count HIGH vulnerabilities"
      else
        log_pass "$image has no HIGH/CRITICAL vulnerabilities"
      fi
    else
      log_fail "Vulnerability scan failed for $image; see $REPORT_DIR/vulns-${report_name}.log"
    fi
  fi

  if [[ "$RUN_LICENSE" == true ]]; then
    license_file="$REPORT_DIR/licenses-${report_name}.json"
    log_info "Scanning $image for license evidence"
    if syft "$image" -o json --file "$license_file" 2> "$REPORT_DIR/licenses-${report_name}.log"; then
      if command -v jq >/dev/null 2>&1; then
        strong_copyleft="$(jq -r '[.artifacts[]?.licenses[]? | select(.value | test("^(GPL-|AGPL-|SSPL|CC-BY-SA|OSL)"; "i")) | .value] | unique | join("\n")' "$license_file" 2>/dev/null || true)"
      else
        strong_copyleft="$(grep -Eio 'GPL-[^", ]+|AGPL-[^", ]+|SSPL[^", ]*|CC-BY-SA[^", ]*|OSL[^", ]*' "$license_file" 2>/dev/null | sort -u || true)"
      fi

      if [[ -n "$strong_copyleft" ]]; then
        log_fail "$image has strong copyleft licenses: $(printf '%s' "$strong_copyleft" | paste -sd ',' -)"
      else
        log_pass "No strong copyleft licenses found for $image"
      fi
    else
      log_fail "License scan failed for $image; see $REPORT_DIR/licenses-${report_name}.log"
    fi
  fi
done

printf '\nSummary: %s passed, %s failed, %s skipped. Reports: %s\n' "$PASS" "$FAIL" "$SKIP" "$REPORT_DIR"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
