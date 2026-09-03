#!/usr/bin/env bash
# Collect redacted release identity, image, and Kubernetes manifest evidence.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPORT_DIR="${CHRONICLE_RELEASE_EVIDENCE_DIR:-/tmp/chronicle-release-evidence}"
OVERLAY="${CHRONICLE_RELEASE_OVERLAY:-k8s/overlays/rhel9-small}"
ALLOW_PLACEHOLDERS=0

usage() {
  cat <<'EOF'
Usage: scripts/chronicle-release-evidence.sh [options]

Collects release evidence for operator deployments without printing secrets:
  - canonical git commit and scoped status
  - recursive submodule SHAs
  - rendered Kubernetes manifest and checksum
  - Chronicle workload image refs from the rendered manifest
  - third-party workload image refs from the rendered manifest
  - rejection of plaintext Secret resources and stringData
  - rejection of mutable, placeholder, untagged, or non-release Chronicle images
  - rejection of third-party images that are not digest-pinned
  - release/deploy/rollback coverage matrix

Options:
  --report-dir DIR       Evidence output directory.
  --overlay PATH         Kustomize overlay to render, default k8s/overlays/rhel9-small.
  --allow-placeholders   Allow placeholder Chronicle image refs for non-cutover static evidence.
  -h, --help             Show this help.

Production evidence must not use --allow-placeholders.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --report-dir)
      REPORT_DIR="${2:?--report-dir requires a value}"
      shift 2
      ;;
    --overlay)
      OVERLAY="${2:?--overlay requires a value}"
      shift 2
      ;;
    --allow-placeholders)
      ALLOW_PLACEHOLDERS=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

mkdir -p "$REPORT_DIR"
SUMMARY="$REPORT_DIR/summary.tsv"
: > "$SUMMARY"

timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

record() {
  printf '%s\t%s\t%s\n' "$(timestamp)" "$1" "$2" | tee -a "$SUMMARY"
}

run_step() {
  local name="$1"
  shift
  local logfile="$REPORT_DIR/${name//[^A-Za-z0-9_.-]/_}.log"
  record "$name" "start"
  if "$@" >"$logfile" 2>&1; then
    record "$name" "pass"
  else
    local status=$?
    record "$name" "fail status=$status log=$logfile"
    cat "$logfile" >&2
    exit "$status"
  fi
}

sha256_file() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  else
    shasum -a 256 "$path" | awk '{print $1}'
  fi
}

render_kustomize() {
  local output="$REPORT_DIR/rendered-manifest.yaml"
  if [[ ! -f "$ROOT_DIR/$OVERLAY/kustomization.yaml" ]]; then
    echo "Kustomize overlay is not readable: $OVERLAY" >&2
    return 1
  fi
  if command -v kubectl >/dev/null 2>&1; then
    kubectl kustomize "$ROOT_DIR/$OVERLAY" > "$output"
  elif command -v kustomize >/dev/null 2>&1; then
    kustomize build "$ROOT_DIR/$OVERLAY" > "$output"
  else
    echo "kubectl or kustomize is required to render release manifests" >&2
    return 127
  fi
}

write_git_identity() {
  git -C "$ROOT_DIR" rev-parse HEAD > "$REPORT_DIR/git-commit.txt"
  git -C "$ROOT_DIR" status --short --branch > "$REPORT_DIR/git-status.txt"
  git -C "$ROOT_DIR" submodule status --recursive > "$REPORT_DIR/submodules.tsv"
}

reject_plaintext_secrets() {
  local manifest="$REPORT_DIR/rendered-manifest.yaml"
  if grep -REn 'kind:[[:space:]]*Secret|^[[:space:]]*stringData:' "$manifest" > "$REPORT_DIR/plaintext-secret-findings.txt"; then
    echo "Rendered release manifest contains Secret resources or stringData; see $REPORT_DIR/plaintext-secret-findings.txt" >&2
    return 1
  fi
  : > "$REPORT_DIR/plaintext-secret-findings.txt"
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

image_ref_is_digest_pinned() {
  local ref="$1"
  [[ "$ref" =~ @sha256:[0-9A-Fa-f]{64}$ ]]
}

extract_and_validate_images() {
  local manifest="$REPORT_DIR/rendered-manifest.yaml"
  local images="$REPORT_DIR/rendered-images.tsv"
  local chronicle_images="$REPORT_DIR/chronicle-release-images.tsv"
  local third_party_images="$REPORT_DIR/third-party-release-images.tsv"
  local blockers="$REPORT_DIR/image-ref-blockers.txt"
  : > "$images"
  : > "$chronicle_images"
  : > "$third_party_images"
  : > "$blockers"

  awk '/^[[:space:]]*-?[[:space:]]*image:[[:space:]]*/ { sub(/^[[:space:]]*-?[[:space:]]*image:[[:space:]]*/, ""); gsub(/"/, ""); print }' "$manifest" |
    sort -u > "$images"

  grep -E '^ghcr\.io/uzaira0/chronicle/chronicle-(backend|frontend|keycloak):|^ghcr\.io/uzaira0/chronicle/chronicle-(backend|frontend|keycloak)@sha256:' "$images" \
    > "$chronicle_images" || true
  grep -Ev '^ghcr\.io/uzaira0/chronicle/chronicle-(backend|frontend|keycloak)(:|@sha256:)' "$images" \
    > "$third_party_images" || true

  for component in backend frontend keycloak; do
    if ! grep -Eq "chronicle-${component}(:|@sha256:)" "$chronicle_images"; then
      printf 'missing Chronicle image for component: %s\n' "$component" >> "$blockers"
    fi
  done

  local ref
  while IFS= read -r ref; do
    if [[ "$ALLOW_PLACEHOLDERS" == "1" ]] &&
      [[ "$ref" =~ :sha-000000000000$ || "$ref" =~ :sha-REPLACE_WITH_RELEASE_SHA$ ]]; then
      continue
    fi
    if ! image_ref_is_acceptable "$ref"; then
      printf 'unacceptable Chronicle image ref: %s\n' "$ref" >> "$blockers"
    fi
  done < "$chronicle_images"

  while IFS= read -r ref; do
    [[ -z "$ref" ]] && continue
    if ! image_ref_is_digest_pinned "$ref"; then
      printf 'third-party image ref is not digest-pinned: %s\n' "$ref" >> "$blockers"
    fi
  done < "$third_party_images"

  if [[ -s "$blockers" ]]; then
    cat "$blockers" >&2
    return 1
  fi
}

write_release_deploy_rollback_matrix() {
  cat > "$REPORT_DIR/release-deploy-rollback-matrix.tsv" <<EOF
control	evidence_source	coverage_status	cutover_requirement
git-commit	git-commit.txt	covered-by-release-evidence	exact superproject commit recorded for release/change record
git-status	git-status.txt	covered-by-release-evidence	dirty state reviewed and scoped before deploy
submodule-shas	submodules.tsv	covered-by-release-evidence	recursive submodule SHAs recorded for reproducible release identity
kubernetes-render	rendered-manifest.yaml	covered-by-release-evidence	rendered overlay retained with checksum for target environment
manifest-integrity	release-evidence-manifest.txt	covered-by-release-evidence	rendered_manifest_sha256 and artifact checksums retained
plaintext-secret-rejection	plaintext-secret-findings.txt	covered-by-release-evidence	must remain empty; rendered Secret/stringData resources block release
chronicle-image-refs	chronicle-release-images.tsv	covered-by-release-evidence	backend/frontend/keycloak refs are immutable or release-shaped
third-party-image-refs	third-party-release-images.tsv	covered-by-release-evidence	third-party refs are digest-pinned
image-ref-blockers	image-ref-blockers.txt	covered-by-release-evidence	must remain empty; mutable, placeholder, untagged, or non-release refs block cutover
post-deploy-smoke	scripts/chronicle-post-deploy-smoke.sh	required-live-evidence	CHRONICLE_BASE_URL smoke output attached for target host
rollback-image-proof	scripts/chronicle-rollback-smoke.sh	required-live-evidence	CHRONICLE_ROLLBACK_REQUIRE_IMAGES=1 with expected backend/frontend refs
kubernetes-rollout	CHRONICLE_ANSIBLE_INVENTORY|required-live-kube	required-live-evidence	live RHEL/RKE2 validators or kube smoke prove workloads ready
EOF
}

write_manifest() {
  local rendered="$REPORT_DIR/rendered-manifest.yaml"
  local manifest="$REPORT_DIR/release-evidence-manifest.txt"
  {
    printf 'date_utc=%s\n' "$(timestamp)"
    printf 'repo=%s\n' "$ROOT_DIR"
    printf 'overlay=%s\n' "$OVERLAY"
    printf 'allow_placeholders=%s\n' "$ALLOW_PLACEHOLDERS"
    printf 'git_commit=%s\n' "$(cat "$REPORT_DIR/git-commit.txt")"
    printf 'rendered_manifest_sha256=%s\n' "$(sha256_file "$rendered")"
    printf 'artifact\tsha256\n'
    for artifact in \
      git-commit.txt \
      git-status.txt \
      submodules.tsv \
      rendered-manifest.yaml \
      rendered-images.tsv \
      chronicle-release-images.tsv \
      third-party-release-images.tsv \
      plaintext-secret-findings.txt \
      image-ref-blockers.txt \
      release-deploy-rollback-matrix.tsv; do
      printf '%s\t%s\n' "$artifact" "$(sha256_file "$REPORT_DIR/$artifact")"
    done
  } > "$manifest"
}

run_step "canonical-preflight-explain" "${REPO_CANONICAL_PREFLIGHT:-repo-canonical-preflight}" --explain
run_step "canonical-preflight" "${REPO_CANONICAL_PREFLIGHT:-repo-canonical-preflight}"
run_step "git-release-identity" write_git_identity
run_step "render-kustomize-overlay" render_kustomize
run_step "reject-plaintext-secret-manifests" reject_plaintext_secrets
run_step "validate-chronicle-image-refs" extract_and_validate_images
run_step "release-deploy-rollback-matrix" write_release_deploy_rollback_matrix
run_step "write-release-evidence-manifest" write_manifest

record "evidence" "complete report_dir=$REPORT_DIR"
printf 'Chronicle release evidence complete: %s\n' "$REPORT_DIR"
