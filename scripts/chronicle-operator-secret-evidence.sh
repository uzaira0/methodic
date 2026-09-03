#!/usr/bin/env bash
# Collect redacted operator workstation and local secret-custody preflight evidence.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPORT_DIR="${CHRONICLE_OPERATOR_SECRET_REPORT_DIR:-/tmp/chronicle-operator-secret-evidence}"

usage() {
  cat <<'EOF'
Usage: scripts/chronicle-operator-secret-evidence.sh [options]

Collects redacted operator-access and local secret-custody preflight evidence:
  - canonical checkout proof
  - scoped git status
  - operator tool versions
  - local secret-bearing path custody checks without reading secret values
  - operator access and secret custody coverage matrices
  - artifact SHA-256 manifest
Options:
  --report-dir DIR          Evidence output directory.
  -h, --help                Show this help.

The script never prints secret values. It checks file existence, git tracking
state, git ignore state, and permission bits only.

By default it checks these local secret-bearing paths when present:
  docker/.env.production.local
  chronicle-ios/chronicle/Config/Chronicle.local.xcconfig
  chronicle-ios/secrets/age-key.txt
  $HOME/.config/chronicle/age-key.txt
  $HOME/.ssh/id_*
  $HOME/.ssh/*.pem
  $HOME/.ssh/*.key
  $HOME/.kube/config
  $HOME/.aws/credentials

Override the list with CHRONICLE_LOCAL_SECRET_PATHS as a colon-separated list.
Globs are expanded without reading file contents. Public SSH keys and known-host
metadata are excluded from the secret-bearing path check.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --report-dir)
      REPORT_DIR="${2:?--report-dir requires a value}"
      shift 2
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

file_mode() {
  local path="$1"
  if stat -f '%Lp' "$path" >/dev/null 2>&1; then
    stat -f '%Lp' "$path"
  else
    stat -c '%a' "$path"
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

is_under_path() {
  local path="$1"
  local base="$2"
  case "$path" in
    "$base"/*|"$base") return 0 ;;
    *) return 1 ;;
  esac
}

repo_relative_path() {
  local path="$1"
  local base="$2"
  if [[ "$path" == "$base" ]]; then
    printf '.\n'
  else
    printf '%s\n' "${path#$base/}"
  fi
}

validate_secret_path() {
  local raw_path="$1"
  local path="$raw_path"
  if [[ "$path" == \~/* ]]; then
    path="$HOME/${path#\~/}"
  elif [[ "$path" != /* ]]; then
    path="$ROOT_DIR/$path"
  fi

  if [[ ! -e "$path" ]]; then
    printf 'absent\t%s\n' "$raw_path"
    return 0
  fi

  if [[ -L "$path" ]]; then
    printf 'fail\t%s\tsymlinked-secret-path\n' "$raw_path"
    return 1
  fi

  local mode
  mode="$(file_mode "$path")"
  local mode_tail="${mode: -2}"
  if [[ "$mode_tail" != "00" ]]; then
    printf 'fail\t%s\tmode=%s group-or-other-readable\n' "$raw_path" "$mode"
    return 1
  fi

  local git_root=""
  git_root="$(git -C "$(dirname "$path")" rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -n "$git_root" ]] && is_under_path "$path" "$git_root"; then
    local rel
    rel="$(repo_relative_path "$path" "$git_root")"
    if git -C "$git_root" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1; then
      printf 'fail\t%s\tmode=%s tracked-by-git\n' "$raw_path" "$mode"
      return 1
    fi
    if ! git -C "$git_root" check-ignore -q -- "$rel"; then
      printf 'fail\t%s\tmode=%s not-gitignored\n' "$raw_path" "$mode"
      return 1
    fi
    printf 'ok\t%s\tmode=%s ignored-untracked\n' "$raw_path" "$mode"
    return 0
  fi

  printf 'ok\t%s\tmode=%s outside-repo\n' "$raw_path" "$mode"
}

expand_secret_path_spec() {
  local raw_path="$1"
  local path="$raw_path"
  if [[ "$path" == \~/* ]]; then
    path="$HOME/${path#\~/}"
  elif [[ "$path" != /* ]]; then
    path="$ROOT_DIR/$path"
  fi

  if [[ "$path" == *"*"* || "$path" == *"?"* || "$path" == *"["* ]]; then
    local matches=()
    while IFS= read -r match; do
      matches+=("$match")
    done < <(compgen -G "$path" || true)
    if [[ "${#matches[@]}" -eq 0 ]]; then
      printf '%s\n' "$raw_path"
      return 0
    fi
    printf '%s\n' "${matches[@]}"
    return 0
  fi

  printf '%s\n' "$raw_path"
}

should_check_secret_candidate() {
  local raw_path="$1"
  case "$raw_path" in
    *.pub|*/known_hosts|*/known_hosts.old|*/authorized_keys)
      return 1
      ;;
    *)
      return 0
      ;;
  esac
}

write_tool_versions() {
  local output="$REPORT_DIR/operator-tool-versions.txt"
  : > "$output"
  for tool in git gh ssh kubectl helm ansible-playbook age sops gitleaks; do
    if command -v "$tool" >/dev/null 2>&1; then
      printf '## %s\n' "$tool" >> "$output"
      case "$tool" in
        ssh)
          ssh -V >> "$output" 2>&1 || true
          ;;
        ansible-playbook)
          ansible-playbook --version | sed -n '1,3p' >> "$output" 2>&1 || true
          ;;
        *)
          "$tool" --version | sed -n '1,3p' >> "$output" 2>&1 || true
          ;;
      esac
    else
      printf '## %s\nmissing\n' "$tool" >> "$output"
    fi
    printf '\n' >> "$output"
  done
}

validate_local_secret_paths() {
  local output="$REPORT_DIR/local-secret-path-custody.tsv"
  : > "$output"
  printf 'status\tpath\tdetail\n' >> "$output"

  local path_list="${CHRONICLE_LOCAL_SECRET_PATHS:-docker/.env.production.local:chronicle-ios/chronicle/Config/Chronicle.local.xcconfig:chronicle-ios/secrets/age-key.txt:$HOME/.config/chronicle/age-key.txt:$HOME/.ssh/id_*:$HOME/.ssh/*.pem:$HOME/.ssh/*.key:$HOME/.kube/config:$HOME/.aws/credentials}"
  if [[ ${CHRONICLE_LOCAL_SECRET_PATHS+x} == x ]]; then
    if [[ -z "${CHRONICLE_LOCAL_SECRET_PATHS//[[:space:]:]/}" ]]; then
      printf 'fail\tCHRONICLE_LOCAL_SECRET_PATHS\tempty-secret-path-inventory\n' >> "$output"
      echo "CHRONICLE_LOCAL_SECRET_PATHS override must include at least one explicit secret-bearing path" >&2
      return 1
    fi
  fi

  local failures=0
  local path
  IFS=':' read -r -a paths <<< "$path_list"
  for path in "${paths[@]}"; do
    if [[ -z "${path//[[:space:]]/}" ]]; then
      printf 'fail\tCHRONICLE_LOCAL_SECRET_PATHS\tempty-secret-path-entry\n' >> "$output"
      failures=$((failures + 1))
      continue
    fi
    local expanded
    while IFS= read -r expanded; do
      if ! should_check_secret_candidate "$expanded"; then
        continue
      fi
      if ! validate_secret_path "$expanded" >> "$output"; then
        failures=$((failures + 1))
      fi
    done < <(expand_secret_path_spec "$path")
  done

  if [[ "$failures" -gt 0 ]]; then
    echo "local secret-bearing path custody failed; see $output" >&2
    return 1
  fi
}

write_evidence_templates() {
  cat > "$REPORT_DIR/operator-access-evidence-template.md" <<'EOF'
# Operator Access Evidence

Date:
Environment:
Operator ticket or approval:
Primary operator:
Backup operator:
No shared routine account/kubeconfig proof:
SSH path: VPN | bastion | other approved path
SSH public-key inventory or fingerprint evidence:
SSH key revocation/offboarding path:
Password SSH disabled evidence:
Direct root login disabled evidence:
Sudo group and audit evidence:
Kubeconfig or identity issuance path:
Kubeconfig revocation path:
RBAC scope and cluster-admin exception, if any:
Operator access control matrix:
Break-glass owner:
Break-glass approval path:
Break-glass start/end time or expiry:
Evidence storage location:
Review date:
Stop conditions:
EOF

  cat > "$REPORT_DIR/secret-custody-evidence-template.md" <<'EOF'
# Secret Custody Evidence

Date:
Environment:
Operator ticket or approval:
Secret store: operator vault | OpenBao | age/SOPS | other approved path
Mobile signing key custody:
Database credential custody:
TDE/keyring custody:
Backup encryption key custody:
Backup/TDE key custody separate from backup media:
OIDC/client secret custody:
Registry token custody:
Grafana/observability secret custody:
External Secrets backend proof:
Secret sync proof without values:
Secret custody matrix:
Rotation owner:
Rotation cadence or next review:
Emergency rotation path:
Last redaction review:
Review date:
Stop conditions:
EOF
}

write_operator_secret_matrices() {
  cat > "$REPORT_DIR/operator-access-control-matrix.tsv" <<'EOF'
control	evidence_source	coverage_status	cutover_requirement
primary-operator	CHRONICLE_OPERATOR_ACCESS_EVIDENCE	required-strict-evidence	named primary operator with approval and review date
backup-operator	CHRONICLE_OPERATOR_ACCESS_EVIDENCE	required-strict-evidence	named backup operator with approval and review date
no-shared-routine-access	CHRONICLE_OPERATOR_ACCESS_EVIDENCE	required-strict-evidence	no shared daily-use operator account, shared admin credential, or shared kubeconfig for routine access
ssh-access-path	CHRONICLE_OPERATOR_ACCESS_EVIDENCE	required-strict-evidence	operator-approved VPN, bastion, or equivalent approved path
ssh-key-inventory	CHRONICLE_OPERATOR_ACCESS_EVIDENCE	required-strict-evidence	fingerprint-only inventory and revocation/offboarding proof
password-ssh-disabled	CHRONICLE_OPERATOR_ACCESS_EVIDENCE	required-strict-evidence	PasswordAuthentication no or equivalent managed-control proof
direct-root-login-posture	CHRONICLE_OPERATOR_ACCESS_EVIDENCE	required-strict-evidence	PermitRootLogin no or approved break-glass-only posture
sudo-audit	CHRONICLE_OPERATOR_ACCESS_EVIDENCE	required-strict-evidence	sudo membership, command logging, auditd/journal evidence
kubernetes-identity	CHRONICLE_OPERATOR_ACCESS_EVIDENCE	required-strict-evidence	issuer/subject/RBAC scope and revocation path without kubeconfig YAML
cluster-admin-exception	CHRONICLE_OPERATOR_ACCESS_EVIDENCE	required-if-present	purpose, owner, approval, expiry/review, and stop condition
break-glass	CHRONICLE_OPERATOR_ACCESS_EVIDENCE	required-strict-evidence	owner, approval path, start/end or expiry, validation after use
local-tooling	operator-tool-versions.txt	covered-by-local-preflight	version inventory for release/operator workstation context
local-secret-paths	local-secret-path-custody.tsv	covered-by-local-preflight	local secret files absent or mode 600, untracked, and gitignored
ssh-private-keys	local-secret-path-custody.tsv	covered-by-local-preflight	SSH private keys absent or mode 600, outside repo or untracked and gitignored
EOF

  cat > "$REPORT_DIR/secret-custody-matrix.tsv" <<'EOF'
secret_class	evidence_source	coverage_status	cutover_requirement
mobile-signing-key	CHRONICLE_SECRET_CUSTODY_EVIDENCE	required-strict-evidence	approved store/custody, rotation owner, no-disclosure proof
jwt-session-signing	CHRONICLE_SECRET_CUSTODY_EVIDENCE	required-strict-evidence	approved store/custody, rotation owner, old-token rejection proof where applicable
oidc-client-secret	CHRONICLE_SECRET_CUSTODY_EVIDENCE	required-strict-evidence	upstream IdP or approved store, login smoke, no values in evidence
database-credentials	CHRONICLE_SECRET_CUSTODY_EVIDENCE	required-strict-evidence	approved store, app reconnect/readiness proof, revocation path
postgres-tls-key-cert	CHRONICLE_SECRET_CUSTODY_EVIDENCE	required-strict-evidence	approved custody, expiry/chain proof, key not in evidence
tde-keyring	CHRONICLE_SECRET_CUSTODY_EVIDENCE	required-strict-evidence	custody separate from backup media, encryption and restore proof
backup-encryption-key	CHRONICLE_SECRET_CUSTODY_EVIDENCE	required-strict-evidence	custody separate from backup media, decrypt/restore proof
registry-token	CHRONICLE_SECRET_CUSTODY_EVIDENCE	required-strict-evidence	scoped token custody, image pull proof, revocation path
external-secrets-backend	CHRONICLE_SECRET_CUSTODY_EVIDENCE	required-strict-evidence	ExternalSecret Ready/Synced or key-name proof without values
grafana-observability-secret	CHRONICLE_SECRET_CUSTODY_EVIDENCE	required-strict-evidence	ExternalSecret or approved store proof, no public exposure
waf-bouncer-key	CHRONICLE_SECRET_CUSTODY_EVIDENCE	required-if-self-hosted	self-hosted fallback only; placeholder templates are not custody proof
local-secret-paths	local-secret-path-custody.tsv	covered-by-local-preflight	local secret files absent or mode 600, untracked, and gitignored
ssh-private-keys	local-secret-path-custody.tsv	covered-by-local-preflight	SSH private keys absent or mode 600, outside repo or untracked and gitignored
EOF
}

write_artifact_manifest() {
  local manifest="$REPORT_DIR/operator-secret-evidence-manifest.txt"
  {
    printf 'date_utc=%s\n' "$(timestamp)"
    printf 'repo=%s\n' "$ROOT_DIR"
    printf 'secret_policy=%s\n' "do-not-record-secret-values-private-keys-tokens-kubeconfigs-recovery-shares-or-raw-phi"
    printf 'artifact\tsha256\n'
    for artifact in \
      summary.tsv \
      operator-tool-versions.txt \
      local-secret-path-custody.tsv \
      operator-access-control-matrix.tsv \
      secret-custody-matrix.tsv \
      operator-access-evidence-template.md \
      secret-custody-evidence-template.md; do
      if [[ -f "$REPORT_DIR/$artifact" ]]; then
        printf '%s\t%s\n' "$artifact" "$(sha256_file "$REPORT_DIR/$artifact")"
      fi
    done
  } > "$manifest"
}

run_step "canonical-preflight-explain" "${REPO_CANONICAL_PREFLIGHT:-repo-canonical-preflight}" --explain
run_step "canonical-preflight" "${REPO_CANONICAL_PREFLIGHT:-repo-canonical-preflight}"
run_step "git-status-scoped" git -C "$ROOT_DIR" status --short --branch -- \
  scripts/chronicle-operator-secret-evidence.sh \
  tests/security/operator-access-guardrails.sh
run_step "operator-tool-versions" write_tool_versions
run_step "local-secret-path-custody" validate_local_secret_paths
run_step "evidence-templates" write_evidence_templates
run_step "operator-secret-matrices" write_operator_secret_matrices
run_step "operator-secret-evidence-manifest" write_artifact_manifest

record "evidence" "complete report_dir=$REPORT_DIR"
printf 'Chronicle operator/secret preflight evidence complete: %s\n' "$REPORT_DIR"
