#!/usr/bin/env bash
# Security layer runner for CI.
# Usage: run-all-security.sh <layer> <report-dir>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=tests/security/security-runner-lib.sh
source "$SCRIPT_DIR/security-runner-lib.sh"

prepare_checkov_runtime() {
  if checkov --version >/dev/null 2>&1; then
    return 0
  fi

  local expat_lib="/opt/homebrew/opt/expat/lib"
  if [ -d "$expat_lib" ] &&
    DYLD_LIBRARY_PATH="$expat_lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" checkov --version >/dev/null 2>&1; then
    export DYLD_LIBRARY_PATH="$expat_lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
    echo "Using Homebrew expat for local Checkov Python runtime"
    return 0
  fi

  echo "Checkov is installed but failed to start. Run 'checkov --version' for the local toolchain error." >&2
  return 1
}

validate_sarif() {
  local report="$1"
  [ -s "$report" ] || return 1
  python3 - "$report" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    document = json.load(handle)
if document.get("version") != "2.1.0" or not isinstance(document.get("runs"), list):
    raise SystemExit("invalid SARIF document")
PY
}

run_checkov_scan() {
  local output_dir="$REPORT_DIR/checkov-output"
  local report="$output_dir/results_sarif.sarif"
  local status=0
  command -v checkov >/dev/null 2>&1 || return 127
  prepare_checkov_runtime || return 2
  mkdir -p "$output_dir"
  checkov -d "$ROOT_DIR/docker" \
    --framework dockerfile \
    --output sarif --output-file-path "$output_dir" || status=$?
  validate_sarif "$report" || return 2
  return "$status"
}

run_hadolint_scan() {
  local dockerfile="$1"
  local report="$2"
  local status=0
  command -v hadolint >/dev/null 2>&1 || return 127
  hadolint --format sarif "$dockerfile" >"$report" || status=$?
  validate_sarif "$report" || return 2
  return "$status"
}

discover_dockerfiles() {
  python3 - "$ROOT_DIR/docker" <<'PY'
import os
import sys

root = os.path.abspath(sys.argv[1])
matches = []
for directory, _, files in os.walk(root):
    for name in files:
        if name == "Dockerfile" or name.startswith("Dockerfile.") or name.endswith(".Dockerfile"):
            matches.append(os.path.join(directory, name))
for path in sorted(matches):
    sys.stdout.buffer.write(path.encode("utf-8") + b"\0")
PY
}

dockerfile_report_name() {
  python3 - "$ROOT_DIR" "$1" <<'PY'
import os
import re
import sys

relative = os.path.relpath(os.path.abspath(sys.argv[2]), os.path.abspath(sys.argv[1]))
print("hadolint-" + re.sub(r"[^A-Za-z0-9._-]+", "__", relative) + ".sarif")
PY
}

run_auth_semgrep() {
  local report="$REPORT_DIR/auth-patterns.sarif"
  local status=0
  command -v semgrep >/dev/null 2>&1 || return 127
  semgrep scan --error --config "p/jwt" --config "p/secrets" \
    --sarif -o "$report" \
    "$ROOT_DIR/chronicle-server/src" "$ROOT_DIR/chronicle-web/src" || status=$?
  validate_sarif "$report" || return 2
  return "$status"
}

run_injection_semgrep() {
  local report="$REPORT_DIR/injection.sarif"
  local status=0
  command -v semgrep >/dev/null 2>&1 || return 127
  semgrep scan --error --config "p/sql-injection" --config "p/xss" \
    --sarif -o "$report" \
    "$ROOT_DIR/chronicle-server/src" "$ROOT_DIR/chronicle-web/src" || status=$?
  validate_sarif "$report" || return 2
  return "$status"
}

run_crypto_semgrep() {
  local report="$REPORT_DIR/crypto.sarif"
  local status=0
  command -v semgrep >/dev/null 2>&1 || return 127
  semgrep scan --error --config "p/insecure-transport" \
    --sarif -o "$report" "$ROOT_DIR/chronicle-server/src" || status=$?
  validate_sarif "$report" || return 2
  return "$status"
}

run_sast_semgrep() {
  local report="$REPORT_DIR/semgrep.sarif"
  local count_report="$REPORT_DIR/semgrep-actionable-count.txt"
  local status=0
  command -v semgrep >/dev/null 2>&1 || return 127
  semgrep scan --quiet --config "$ROOT_DIR/tests/security/rules/" \
    --sarif -o "$report" \
    "$ROOT_DIR/chronicle-server/src" "$ROOT_DIR/chronicle-api/src" \
    "$ROOT_DIR/chronicle-web/src" || status=$?
  validate_sarif "$report" || return 2
  python3 - "$report" "$count_report" <<'PY'
import json
import sys

path, count_path = sys.argv[1:]
with open(path, "r", encoding="utf-8") as handle:
    sarif = json.load(handle)

unsuppressed_count = 0
for run in sarif.get("runs", []):
    kept = [
        result
        for result in run.get("results", [])
        if not result.get("suppressions")
    ]
    run["results"] = kept
    unsuppressed_count += len(kept)

with open(path, "w", encoding="utf-8") as handle:
    json.dump(sarif, handle)
with open(count_path, "w", encoding="utf-8") as handle:
    handle.write(str(unsuppressed_count))
print(f"Semgrep actionable findings: {unsuppressed_count}")
PY
  [ "$status" -le 1 ] || return 2
  [ "$(cat "$count_report")" -eq 0 ] || return 1
  return 0
}

run_bun_frozen_install() {
  command -v bun >/dev/null 2>&1 || return 127
  [ -f "$ROOT_DIR/chronicle-web/package.json" ] || return 2
  (cd "$ROOT_DIR/chronicle-web" && bun install --frozen-lockfile)
}

run_bun_audit() {
  local report="$REPORT_DIR/bun-audit.json"
  local status=0
  command -v bun >/dev/null 2>&1 || return 127
  [ -f "$ROOT_DIR/chronicle-web/package.json" ] || return 2
  (cd "$ROOT_DIR/chronicle-web" && bun audit --audit-level=high --json) >"$report" || status=$?
  python3 - "$report" <<'PY' || return 2
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as handle:
    json.load(handle)
PY
  return "$status"
}

run_gitleaks_scan() {
  local report="$REPORT_DIR/gitleaks.sarif"
  local status=0
  command -v gitleaks >/dev/null 2>&1 || return 127
  gitleaks detect --source "$ROOT_DIR" \
    --config "$ROOT_DIR/tests/security/gitleaks.toml" \
    --report-format sarif --report-path "$report" \
    --no-banner || status=$?
  validate_sarif "$report" || return 2
  return "$status"
}

run_license_report() {
  (cd "$ROOT_DIR" && ./gradlew :chronicle-server:generateLicenseReport --no-daemon) || return $?
  printf '%s\n' '{"passed":true,"note":"Gradle license report generated successfully"}' \
    >"$REPORT_DIR/license.json"
}

run_compliance_scan() {
  local report="$REPORT_DIR/compliance.json"
  local status=0
  command -v conftest >/dev/null 2>&1 || return 127
  [ -d "$ROOT_DIR/tests/security/policies" ] || return 2
  conftest test "$ROOT_DIR/docker/docker-compose.traefik.yml" \
    --policy "$ROOT_DIR/tests/security/policies/" \
    --output json >"$report" 2>&1 || status=$?
  python3 - "$report" <<'PY' || return 2
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as handle:
    json.load(handle)
PY
  return "$status"
}

sarif_actionable_count() {
  python3 - "$1" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    sarif = json.load(handle)
print(
    sum(
        1
        for run in sarif.get("runs", [])
        for result in run.get("results", [])
        if not result.get("suppressions")
    )
)
PY
}

run_collection_semgrep_modularization() {
  local report="$REPORT_DIR/collection-semgrep-modularization.sarif"
  local status=0
  local count
  command -v semgrep >/dev/null 2>&1 || return 127
  semgrep scan --quiet \
    --config "$ROOT_DIR/tests/security/collection-rules/collection-modularization.yaml" \
    --sarif -o "$report" \
    "$ROOT_DIR"/chronicle/{app,collection-core,collection-upload,collection-sensors,collection-usage,collection-lifecycle}/src/main/java/com/openlattice/chronicle/collection \
    || status=$?
  validate_sarif "$report" || return 2
  [ "$status" -le 1 ] || return 2
  count="$(sarif_actionable_count "$report")" || return 2
  echo "Collection modularization findings: $count"
  [ "$count" -eq 0 ] || return 1
}

run_collection_semgrep_dto() {
  local report="$REPORT_DIR/collection-semgrep-dto.sarif"
  local status=0
  local count
  command -v semgrep >/dev/null 2>&1 || return 127
  semgrep scan --quiet \
    --config "$ROOT_DIR/tests/security/collection-rules/collection-dto.yaml" \
    --sarif -o "$report" \
    "$ROOT_DIR/chronicle-models/src/main/kotlin/com/openlattice/chronicle/collection" \
    || status=$?
  validate_sarif "$report" || return 2
  [ "$status" -le 1 ] || return 2
  count="$(sarif_actionable_count "$report")" || return 2
  echo "Collection DTO findings: $count"
  [ "$count" -eq 0 ] || return 1
}

run_collection_ast_grep() {
  local rule="$1"
  local report="$REPORT_DIR/collection-${rule}.sarif"
  local stderr_report="$REPORT_DIR/collection-${rule}.stderr"
  local status=0
  local count
  command -v ast-grep >/dev/null 2>&1 || return 127
  ast-grep scan --rule "$ROOT_DIR/tests/security/ast-grep/${rule}.yml" \
    "$ROOT_DIR/chronicle" "$ROOT_DIR/chronicle-models" "$ROOT_DIR/chronicle-server" \
    --format sarif >"$report" 2>"$stderr_report" || status=$?
  cat "$stderr_report"
  validate_sarif "$report" || return 2
  [ "$status" -le 1 ] || return 2
  count="$(sarif_actionable_count "$report")" || return 2
  echo "$rule: $count finding(s)"
  [ "$count" -eq 0 ] || return 1
}

security_runner_main() {
  if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <layer> <report-dir>" >&2
    return 2
  fi
  LAYER="$1"
  REPORT_DIR="$2"
  security_runner_init "$LAYER" "$REPORT_DIR"
  trap 'security_runner_exit_trap $?' EXIT

case "$LAYER" in
  sast)
    run_security_step "sast.semgrep" "SAST: Semgrep repository rules" "scanner" \
      "semgrep.log" "semgrep.sarif" -- run_sast_semgrep
    run_security_step "sast.rls" "SAST: focused RLS guardrails" "guardrail" \
      "rls-guardrails.txt" "" -- "$ROOT_DIR/tests/security/run-rls-guardrails.sh" "$REPORT_DIR"
    echo "SAST scan complete"
    ;;

  sca)
    run_security_step "sca.supply-chain" "SCA: supply-chain reproducibility guardrails" "guardrail" \
      "supply-chain-guardrails.txt" "supply-chain" -- \
      "$ROOT_DIR/tests/security/supply-chain-guardrails.sh" "$REPORT_DIR/supply-chain"
    run_security_step "sca.bun-install" "SCA: Bun frozen-lockfile install" "build" \
      "bun-install.log" "" -- run_bun_frozen_install
    run_security_step "sca.bun-audit" "SCA: Bun high-severity audit" "scanner" \
      "bun-audit.log" "bun-audit.json" -- run_bun_audit
    echo "SCA scan complete"
    ;;

  secrets)
    run_security_step "secrets.gitleaks" "Secrets: Gitleaks" "scanner" \
      "gitleaks.log" "gitleaks.sarif" -- run_gitleaks_scan
    echo "Secrets scan complete"
    ;;

  iac)
    run_security_step \
      "iac.checkov" "IaC: Checkov Dockerfile scan" "scanner" \
      "checkov.log" "checkov-output/results_sarif.sarif" -- run_checkov_scan

    dockerfile_list="$REPORT_DIR/dockerfiles.nul"
    discover_dockerfiles >"$dockerfile_list"
    dockerfile_count=0
    while IFS= read -r -d '' df; do
      dockerfile_count=$((dockerfile_count + 1))
      report_name="$(dockerfile_report_name "$df")"
      relative_df="${df#"$ROOT_DIR"/}"
      step_suffix="$(printf '%s' "$relative_df" | tr '/.' '--')"
      run_security_step \
        "iac.hadolint.${step_suffix}" "IaC: Hadolint $relative_df" "scanner" \
        "${report_name%.sarif}.log" "$report_name" -- \
        run_hadolint_scan "$df" "$REPORT_DIR/$report_name"
    done <"$dockerfile_list"
    if [ "$dockerfile_count" -eq 0 ]; then
      record_security_blocked \
        "iac.hadolint.discovery" "IaC: recursive Dockerfile discovery" \
        "No Dockerfiles were discovered under docker/"
    fi
    echo "IaC scan complete"
    ;;

  sso)
    run_security_step \
      "sso.hardening" "SSO: Keycloak broker hardening guardrails" "guardrail" \
      "sso-hardening.txt" "" -- \
      python3 "$ROOT_DIR/tests/security/sso-hardening-tests.py"
    echo "SSO hardening scan complete"
    ;;

  deploy)
    run_security_step "deploy.public-tree-privacy" "Deploy: public-tree privacy guardrails" "guardrail" \
      "public-tree-privacy-guardrails.txt" "" -- python3 "$ROOT_DIR/tests/security/public-tree-privacy-guardrails.py"
    run_security_step "deploy.runner-self-test" "Deploy: security runner capture-all self-test" "build" \
      "security-runner-self-test.txt" "" -- "$ROOT_DIR/tests/security/security-runner-self-test.sh"
    run_security_step "deploy.production" "Deploy: production deployment guardrails" "guardrail" \
      "deploy-guardrails.txt" "" -- "$ROOT_DIR/tests/security/deploy-guardrails.sh" "$REPORT_DIR"
    run_security_step "deploy.public-distribution-integration" "Deploy: public distribution integration contract" "guardrail" \
      "public-distribution-integration.txt" "" -- "$ROOT_DIR/tests/security/public-distribution-integration-guardrails.sh"
    run_security_step "deploy.db-secret-transport" "Deploy: database client secret-transport contract" "guardrail" \
      "db-secret-transport.txt" "" -- "$ROOT_DIR/tests/security/db-secret-transport-guardrails.sh"
    run_security_step "deploy.schema" "Deploy: schema/source-of-truth guardrails" "guardrail" \
      "schema-guardrails.txt" "" -- "$ROOT_DIR/tests/security/schema-guardrails.sh"
    run_security_step "deploy.kubernetes" "Deploy: Kubernetes production guardrails" "guardrail" \
      "kubernetes-guardrails.txt" "kubernetes" -- "$ROOT_DIR/tests/security/kubernetes-guardrails.sh" "$REPORT_DIR/kubernetes"
    run_security_step "deploy.cue-k8s" "Deploy: CUE/Kubernetes profile guardrails" "guardrail" \
      "cue-k8s-guardrails.txt" "cue-k8s" -- "$ROOT_DIR/tests/security/cue-k8s-guardrails.sh" "$REPORT_DIR/cue-k8s"
    run_security_step "deploy.backup-artifacts" "Deploy: backup/recovery artifact guardrails" "guardrail" \
      "backup-artifact-guardrails.txt" "backup-artifacts" -- "$ROOT_DIR/tests/security/backup-artifact-guardrails.sh" "$REPORT_DIR/backup-artifacts"
    run_security_step "deploy.selfhost-restore-failclosed" "Deploy: self-host restore fail-closed contract" "guardrail" \
      "selfhost-restore-failclosed.txt" "" -- "$ROOT_DIR/tests/security/selfhost-restore-failclosed.sh"
    run_security_step "deploy.selfhost-restore-continuity" "Deploy: self-host withdrawal continuity across restore" "guardrail" \
      "selfhost-restore-continuity.txt" "" -- "$ROOT_DIR/tests/security/selfhost-restore-continuity.sh"
    run_security_step "deploy.selfhost-restore-orchestration" "Deploy: self-host restore orchestration contract" "guardrail" \
      "selfhost-restore-orchestration.txt" "" -- "$ROOT_DIR/tests/security/selfhost-restore-orchestration.sh"
    run_security_step "deploy.selfhost-monitoring-timeout" "Deploy: self-host monitoring cannot block operator commands" "guardrail" \
      "selfhost-monitoring-timeout.txt" "" -- "$ROOT_DIR/tests/security/selfhost-monitoring-timeout.sh"
    run_security_step "deploy.selfhost-upgrade-failclosed" "Deploy: self-host upgrade quiescence and recovery contract" "guardrail" \
      "selfhost-upgrade-failclosed.txt" "" -- "$ROOT_DIR/tests/security/selfhost-upgrade-failclosed.sh"
    run_security_step "deploy.legacy-restore-failclosed" "Deploy: legacy production restore fail-closed contract" "guardrail" \
      "legacy-restore-failclosed.txt" "" -- "$ROOT_DIR/tests/security/legacy-restore-failclosed.sh"
    run_security_step "deploy.selfhost-backup-readiness" "Deploy: self-host backup restart readiness contract" "guardrail" \
      "selfhost-backup-readiness.txt" "" -- "$ROOT_DIR/tests/security/selfhost-backup-readiness.sh"
    run_security_step "deploy.selfhost-setup-secrets" "Deploy: self-host setup secret-custody contract" "guardrail" \
      "selfhost-setup-secrets.txt" "" -- "$ROOT_DIR/tests/security/selfhost-setup-secrets.sh"
    run_security_step "deploy.selfhost-mobile-signing-defaults" "Deploy: self-host public mobile-signing defaults" "guardrail" \
      "selfhost-mobile-signing-defaults.txt" "" -- "$ROOT_DIR/tests/security/selfhost-mobile-signing-defaults.sh"
    run_security_step "deploy.mobile-secret-flow" "Deploy: age-sealed mobile secret custody contract" "guardrail" \
      "mobile-secret-flow.txt" "" -- "$ROOT_DIR/tests/security/mobile-secret-flow.sh"
    run_security_step "deploy.selfhost-verify-secrets" "Deploy: self-host verify secret-custody contract" "guardrail" \
      "selfhost-verify-secrets.txt" "" -- "$ROOT_DIR/tests/security/selfhost-verify-secrets.sh"
    run_security_step "deploy.selfhost-secret-rotation" "Deploy: self-host secret rotation and rollback contract" "guardrail" \
      "selfhost-secret-rotation.txt" "" -- "$ROOT_DIR/tests/security/selfhost-secret-rotation.sh"
    run_security_step "deploy.selfhost-deletion-status" "Deploy: self-host deletion status secret-custody contract" "guardrail" \
      "selfhost-deletion-status.txt" "" -- "$ROOT_DIR/tests/security/selfhost-deletion-status.sh"
    run_security_step "deploy.selfhost-combination-matrix" "Deploy: declared self-host combination matrix" "guardrail" \
      "selfhost-combination-matrix.txt" "" -- "$ROOT_DIR/tests/security/selfhost-combination-matrix.sh"
    run_security_step "deploy.selfhost-release-bundle" "Deploy: source-free self-host release bundle contract" "guardrail" \
      "selfhost-release-bundle.txt" "" -- "$ROOT_DIR/tests/security/selfhost-release-bundle.sh"
    run_security_step "deploy.observability" "Deploy: observability fallback guardrails" "guardrail" \
      "observability-guardrails.txt" "observability" -- "$ROOT_DIR/tests/security/observability-guardrails.sh" "$REPORT_DIR/observability"
    run_security_step "deploy.operator-access" "Deploy: operator access and secret custody guardrails" "guardrail" \
      "operator-access-guardrails.txt" "operator-access" -- "$ROOT_DIR/tests/security/operator-access-guardrails.sh" "$REPORT_DIR/operator-access"
    run_security_step "deploy.vulnerability-evidence" "Deploy: vulnerability scan evidence guardrails" "guardrail" \
      "vulnerability-evidence-guardrails.txt" "vulnerability-evidence" -- "$ROOT_DIR/tests/security/vulnerability-evidence-guardrails.sh" "$REPORT_DIR/vulnerability-evidence"
    run_security_step "deploy.database-evidence" "Deploy: database evidence guardrails" "guardrail" \
      "database-evidence-guardrails.txt" "database-evidence" -- "$ROOT_DIR/tests/security/database-evidence-guardrails.sh" "$REPORT_DIR/database-evidence"
    run_security_step "deploy.vault-tde" "Deploy: Vault/TDE guardrails" "guardrail" \
      "vault-tde-guardrails.txt" "vault-tde" -- "$ROOT_DIR/tests/security/vault-tde-guardrails.sh" "$REPORT_DIR/vault-tde"
    echo "Deploy guardrails complete"
    ;;

  mobile)
    run_security_step "mobile.upload" "Mobile: upload signing/activityClass guardrails" "guardrail" \
      "mobile-upload-guardrails.txt" "" -- "$ROOT_DIR/tests/security/mobile-upload-guardrails.sh" "$REPORT_DIR"
    run_security_step "mobile.dogfood" "Mobile: dogfood lifecycle tooling guardrails" "guardrail" \
      "dogfood-tooling-guardrails.txt" "" -- "$ROOT_DIR/tests/security/dogfood-tooling-guardrails.sh" "$REPORT_DIR"
    echo "Mobile upload guardrails complete"
    ;;

  auth)
    # Passed by name to run_security_step.
    # shellcheck disable=SC2329
    auth_static_guardrails() {
      local auth_failures=0
      echo "=== Auth: JWT/session pattern check ==="
      echo "=== Auth: diagnostic JWT lifetime guardrails ==="
      rm -f "$REPORT_DIR/diagnostic.jwt" "$REPORT_DIR/oversized-diagnostic.jwt"
      if ! JWT_SECRET="auth-guardrail-secret-not-for-production" "$ROOT_DIR/docker/generate-jwt.sh" \
        --output "$REPORT_DIR/diagnostic.jwt"; then
        echo "generate-jwt.sh failed to produce a diagnostic token"
        auth_failures=$((auth_failures + 1))
      fi
      if ! python3 - "$REPORT_DIR/diagnostic.jwt" <<'PY'
import base64
import json
import sys

token_path = sys.argv[1]
token = open(token_path, "r", encoding="utf-8").read().strip()
payload_segment = token.split(".")[1]
payload_segment += "=" * (-len(payload_segment) % 4)
payload = json.loads(base64.urlsafe_b64decode(payload_segment.encode()))
ttl = int(payload["exp"]) - int(payload["iat"])
if ttl <= 0 or ttl > 3600:
    raise SystemExit(f"diagnostic JWT lifetime is unsafe: {ttl}s")
print(f"Diagnostic JWT lifetime: {ttl}s")
PY
      then
        echo "Diagnostic JWT could not be decoded or had an unsafe lifetime"
        auth_failures=$((auth_failures + 1))
      fi
    if JWT_SECRET="auth-guardrail-secret-not-for-production" JWT_TTL_SECONDS=7200 \
      "$ROOT_DIR/docker/generate-jwt.sh" --output "$REPORT_DIR/oversized-diagnostic.jwt" \
      >/dev/null 2>&1; then
      echo "generate-jwt.sh accepted an oversized diagnostic token TTL"
      auth_failures=$((auth_failures + 1))
    fi
    rm -f "$REPORT_DIR/diagnostic.jwt" "$REPORT_DIR/oversized-diagnostic.jwt"

    if grep -Eq '30[[:space:]]*\*[[:space:]]*86400|7[[:space:]]*\*[[:space:]]*86400|2592000|604800' \
      "$ROOT_DIR/docker/generate-jwt.sh"; then
      echo "generate-jwt.sh must not hard-code week/month-long diagnostic JWT lifetimes"
      auth_failures=$((auth_failures + 1))
    fi

    if grep -Eiq 'blocklist check failed.*allowing request|fail[s]? open' \
      "$ROOT_DIR/chronicle-server/src/main/kotlin/com/openlattice/chronicle/filters/JwtBlocklistFilter.kt"; then
      echo "JwtBlocklistFilter must fail closed when token revocation state cannot be checked"
      auth_failures=$((auth_failures + 1))
    fi

    if ! grep -Eq '@Valid[[:space:]]+@RequestBody[[:space:]]+request:[[:space:]]+ApiKeyCreateRequest' \
      "$ROOT_DIR/chronicle-server/src/main/kotlin/com/openlattice/chronicle/controllers/ApiKeyController.kt"; then
      echo "ApiKeyController must validate ApiKeyCreateRequest request bodies"
      auth_failures=$((auth_failures + 1))
    fi

    if ! grep -Eq 'MAX_ADMIN_KEY_TTL_DAYS[[:space:]]*=[[:space:]]*30' \
      "$ROOT_DIR/chronicle-server/src/main/kotlin/com/openlattice/chronicle/services/apikeys/ApiKeyService.kt"; then
      echo "Manual ADMIN API keys must be capped at 30 days"
      auth_failures=$((auth_failures + 1))
    fi
    if ! grep -Eq 'MAX_WRITE_KEY_TTL_DAYS[[:space:]]*=[[:space:]]*90' \
      "$ROOT_DIR/chronicle-server/src/main/kotlin/com/openlattice/chronicle/services/apikeys/ApiKeyService.kt"; then
      echo "Manual WRITE API keys must be capped at 90 days"
      auth_failures=$((auth_failures + 1))
    fi

    if grep -Eq 'Invalid API key from IP|study \{\}|participant \{\}|participantId" to participantId|deviceId" to deviceId' \
      "$ROOT_DIR/chronicle-server/src/main/kotlin/com/openlattice/chronicle/services/apikeys/ApiKeyService.kt" \
      "$ROOT_DIR/chronicle-server/src/main/kotlin/com/openlattice/chronicle/filters/ApiKeyAuthenticationFilter.kt"; then
      echo "API key logs/audit metadata must use stable refs instead of raw identifiers"
      auth_failures=$((auth_failures + 1))
    fi

    if ! grep -Eq 'allowedProtocols[[:space:]]*=[[:space:]]*setOf\("https"\)' \
      "$ROOT_DIR/chronicle-server/src/main/kotlin/com/openlattice/chronicle/services/webhooks/WebhookService.kt"; then
      echo "Webhook delivery URLs must be HTTPS-only"
      auth_failures=$((auth_failures + 1))
    fi
    if ! grep -Eq '\.header\("X-Chronicle-Signature",[[:space:]]*computeSignature\(claim\.payload,[[:space:]]*claim\.secretHash\)\)' \
      "$ROOT_DIR/chronicle-server/src/main/kotlin/com/openlattice/chronicle/services/webhooks/WebhookService.kt"; then
      echo "Webhook deliveries must include an authenticated signature header"
      auth_failures=$((auth_failures + 1))
    fi
    if ! grep -Eq 'A valid global HMAC must never be accepted as a replacement for that key' \
      "$ROOT_DIR/chronicle-server/src/main/kotlin/com/openlattice/chronicle/configuration/MobileApiSignatureFilter.kt" ||
       ! grep -Eq 'ApiKeyAuthenticationFilter binds it to study, participant, and device' \
      "$ROOT_DIR/chronicle-server/src/main/kotlin/com/openlattice/chronicle/pods/servlet/ChronicleServerSecurityPod.kt"; then
      echo "Mobile HMAC must remain documented as non-identity and post-enrollment access must stay device-key bound"
      auth_failures=$((auth_failures + 1))
    fi
    if grep -Eq '\.setAllowedOrigins[[:space:]]*\([[:space:]]*"\*"' \
      "$ROOT_DIR/rhizome/src/main/java/com/geekbeast/rhizome/configuration/websockets/WebSocketConfig.java"; then
      echo "Shared WebSocket configuration must not permit arbitrary origins"
      auth_failures=$((auth_failures + 1))
    fi
    if ! grep -Eq '@field:NotBlank\(message = "Webhook secret is required"\)' \
      "$ROOT_DIR/chronicle-api/src/main/kotlin/com/openlattice/chronicle/webhooks/WebhookCreateRequest.kt"; then
      echo "Webhook registrations must require a shared secret"
      auth_failures=$((auth_failures + 1))
    fi
    if grep -Eq 'Webhook \{\} created for study \{\}|Webhook \{\} deleted for study \{\}|delivery attempt \{\} to \{\}' \
      "$ROOT_DIR/chronicle-server/src/main/kotlin/com/openlattice/chronicle/services/webhooks/WebhookService.kt"; then
      echo "Webhook logs must not expose raw study IDs or callback URLs"
      auth_failures=$((auth_failures + 1))
    fi

    if grep -Eq 'SSRF violation detected.*URL:|req\.requestURL|request\.requestURL|sanitizeLogValue\(req\.remoteAddr\)|sanitizeLogValue\(request\.remoteAddr\)' \
      "$ROOT_DIR/chronicle-server/src/main/kotlin/com/openlattice/chronicle/controllers/ChronicleServerExceptionHandler.kt" \
      "$ROOT_DIR/chronicle-server/src/main/kotlin/com/openlattice/chronicle/controllers/GlobalExceptionHandler.kt"; then
      echo "Exception handlers must not log raw SSRF targets, full request URLs, or raw client IPs"
      auth_failures=$((auth_failures + 1))
    fi

    if grep -Eq 'Database error .*Message: \{\}".*e\.message|e\.message,[[:space:]]*e' \
      "$ROOT_DIR/chronicle-server/src/main/kotlin/com/openlattice/chronicle/controllers/ChronicleServerExceptionHandler.kt"; then
      echo "SQL exception logs must sanitize database error messages"
      auth_failures=$((auth_failures + 1))
    fi

    if grep -Eq 'response\.status[[:space:]]*===[[:space:]]*401[[:space:]]*\)[[:space:]]*\{[[:space:]]*return[[:space:]]*\{[^}]*testingLoginEnabled:[[:space:]]*true' \
      "$ROOT_DIR/chronicle-web/src/modern/lib/bootstrap-auth.ts"; then
      echo "The web bootstrap must not infer testing-login availability from an auth/session 401"
      auth_failures=$((auth_failures + 1))
    fi

    if grep -Eq 'URLSearchParams\(\{[[:space:]]*token[[:space:]]*\}\)|/download\?\$\{params\.toString\(\)\}|@RequestParam\("token"\)[[:space:]]+token:[[:space:]]+String|X-Chronicle-Download-Token|RequestHeader\(.*Download|SecureCompare\.equalsNullSafe' \
      "$ROOT_DIR/chronicle-web/src/modern/state/study-operations-api.ts" \
      "$ROOT_DIR/chronicle-server/src/main/kotlin/com/openlattice/chronicle/controllers/ExportController.kt"; then
      echo "Export downloads must not use bearer download tokens in URLs, headers, or controller comparisons"
      auth_failures=$((auth_failures + 1))
    fi

    if grep -Eq 'downloadToken[[:space:]]*=[[:space:]]*rs\.getString|downloadToken[[:space:]]*=[[:space:]]*token|Boolean\(job\.downloadToken\)|generateToken\(\)' \
      "$ROOT_DIR/chronicle-server/src/main/kotlin/com/openlattice/chronicle/services/export/ExportService.kt" \
      "$ROOT_DIR/chronicle-web/src/modern/routes/study-bulk-downloads-page.tsx"; then
      echo "Export jobs must not expose or require persisted bearer download tokens"
      auth_failures=$((auth_failures + 1))
    fi

    if [ ! -f "$ROOT_DIR/chronicle-server/src/main/resources/db/migration/V46__clear_export_download_tokens.sql" ]; then
      echo "Export download-token removal must include a migration that clears legacy plaintext tokens"
      auth_failures=$((auth_failures + 1))
    fi

    if grep -R -Eiq 'googletagmanager|google-analytics|gtag\(|G-WJ7BQMLPEK' \
      "$ROOT_DIR/chronicle-web/index.html" \
      "$ROOT_DIR/chronicle-web/src" \
      "$ROOT_DIR/chronicle-web/scripts" \
      "$ROOT_DIR/docker"; then
      echo "Browser-delivered Chronicle assets must not include third-party analytics beacons"
      auth_failures=$((auth_failures + 1))
    fi

    if grep -R -Eiq 'Referrer-Policy[[:space:]]+"strict-origin-when-cross-origin"|referrerPolicy[=:][[:space:]]*strict-origin-when-cross-origin|name="referrer"[[:space:]]+content="(origin|strict-origin|strict-origin-when-cross-origin)"' \
      "$ROOT_DIR/chronicle-web/index.html" \
      "$ROOT_DIR/chronicle-web/src/index.html" \
      "$ROOT_DIR/docker" \
      "$ROOT_DIR/chronicle-server/src/main/kotlin/com/openlattice/chronicle/configuration/SecurityHardeningConfig.kt"; then
      echo "Browser surfaces with participant identifiers must use no-referrer"
      auth_failures=$((auth_failures + 1))
    fi
    if ! grep -Eq 'name="referrer"|name='\''referrer'\''' "$ROOT_DIR/chronicle-web/index.html" ||
      ! grep -Eq 'content="no-referrer"|content='\''no-referrer'\''' "$ROOT_DIR/chronicle-web/index.html" ||
      ! grep -Eq 'name="referrer"|name='\''referrer'\''' "$ROOT_DIR/chronicle-web/src/index.html" ||
      ! grep -Eq 'content="no-referrer"|content='\''no-referrer'\''' "$ROOT_DIR/chronicle-web/src/index.html"; then
      echo "Chronicle HTML entrypoints must declare meta referrer=no-referrer"
      auth_failures=$((auth_failures + 1))
    fi

    if grep -Eq 'MDC\.put\("studyId",[[:space:]]*studyMatcher\.group\(1\)\)|MDC\.put\("participantId",[[:space:]]*LogSanitizer\.sanitize\(rawId|MDC\.put\("httpPath",[[:space:]]*LogSanitizer\.sanitizeUri\(path\)\)' \
      "$ROOT_DIR/chronicle-server/src/main/kotlin/com/openlattice/chronicle/configuration/ObservabilityFilter.kt"; then
      echo "ObservabilityFilter must log stable refs and route-shaped paths instead of raw request identifiers"
      auth_failures=$((auth_failures + 1))
    fi
    if ! grep -Eq 'sanitizeRequestPath\(path\)' \
      "$ROOT_DIR/chronicle-server/src/main/kotlin/com/openlattice/chronicle/configuration/ObservabilityFilter.kt"; then
      echo "ObservabilityFilter must route-shape httpPath via LogSanitizer.sanitizeRequestPath"
      auth_failures=$((auth_failures + 1))
    fi
    if grep -Eq 'UUID_PATTERN|/participant/\[\^/\]\+' \
      "$ROOT_DIR/chronicle-server/src/main/kotlin/com/openlattice/chronicle/observability/ApiMetricsFilter.kt"; then
      echo "ApiMetricsFilter must use shared request-path shaping instead of ad hoc identifier regexes"
      auth_failures=$((auth_failures + 1))
    fi
    if ! grep -Eq 'sanitizeRequestPath\(path\)' \
      "$ROOT_DIR/chronicle-server/src/main/kotlin/com/openlattice/chronicle/observability/ApiMetricsFilter.kt"; then
      echo "ApiMetricsFilter must emit route-shaped metric endpoint labels"
      auth_failures=$((auth_failures + 1))
    fi
    if grep -Eq 'sanitizeUri\(request\.requestURI\)' \
      "$ROOT_DIR/chronicle-server/src/main/kotlin/com/openlattice/chronicle/filters/ApiKeyAuthenticationFilter.kt"; then
      echo "ApiKeyAuthenticationFilter path-mismatch logs must route-shape request paths"
      auth_failures=$((auth_failures + 1))
    fi
    if grep -Eq 'enrollmentTotal\.labels\(studyId\.toString\(\)\)|labelNames\("study_id"\)' \
      "$ROOT_DIR/chronicle-server/src/main/kotlin/com/openlattice/chronicle/services/enrollment/EnrollmentService.kt" \
      "$ROOT_DIR/chronicle-server/src/main/kotlin/com/openlattice/chronicle/observability/ChronicleMetrics.kt"; then
      echo "Enrollment metrics must label stable study refs instead of raw study IDs"
      auth_failures=$((auth_failures + 1))
    fi
    # The single-quoted expression intentionally matches literal Kotlin
    # interpolation syntax.
    # shellcheck disable=SC2016
    if grep -Eq 'sanitizeUri\(requestPath\)|sanitizeUri\(path\)|sanitizeUri\(request\.requestURI\)|URI: \$\{request\.requestURI\}|IP: \$\{request\.remoteAddr\}|endpoint:\$\{request\.requestURI\}|\$studyId:\$participantId|UUID_PATTERN|PARTICIPANT_PATTERN' \
      "$ROOT_DIR/chronicle-server/src/main/kotlin/com/openlattice/chronicle/configuration/RateLimitFilter.kt" \
      "$ROOT_DIR/chronicle-server/src/main/kotlin/com/openlattice/chronicle/configuration/SecurityHardeningConfig.kt" \
      "$ROOT_DIR/chronicle-server/src/main/kotlin/com/openlattice/chronicle/configuration/ParameterPollutionFilter.kt"; then
      echo "Request validation/rate-limit logs and keys must use route-shaped paths and stable refs"
      auth_failures=$((auth_failures + 1))
    fi
    if grep -Eq 'path[[:space:]]*=[[:space:]]*req\.requestURI|val path[[:space:]]*=[[:space:]]*request\.requestURI|sanitizeLogValue\((req|request)\.requestURI\)' \
      "$ROOT_DIR/chronicle-server/src/main/kotlin/com/openlattice/chronicle/controllers/ChronicleServerExceptionHandler.kt" \
      "$ROOT_DIR/chronicle-server/src/main/kotlin/com/openlattice/chronicle/controllers/GlobalExceptionHandler.kt"; then
      echo "Exception handlers must not echo or log raw request paths"
      auth_failures=$((auth_failures + 1))
    fi
    if grep -Eq 'writeToLogFile\(entry\)|return getCurrentRequest\(\)\?\.requestURI[[:space:]]*$' \
      "$ROOT_DIR/chronicle-server/src/main/kotlin/com/openlattice/chronicle/audit/AuditService.kt" \
      "$ROOT_DIR/chronicle-server/src/main/kotlin/com/openlattice/chronicle/audit/AuditRequestContext.kt"; then
      echo "Audit events must be sanitized before log-file/DB persistence"
      auth_failures=$((auth_failures + 1))
    fi
    # eventQueue.offer(entry) is valid only in the failed-batch retry path: every
    # queued entry has already passed through sanitizedEntry below. Assert the
    # actual ingress boundary instead of rejecting that safe requeue operation.
    if ! grep -Eq 'val sanitizedEntry[[:space:]]*=[[:space:]]*sanitizeForPersistence\(entry\)' \
      "$ROOT_DIR/chronicle-server/src/main/kotlin/com/openlattice/chronicle/audit/AuditService.kt" ||
       ! grep -Eq 'writeToLogFile\(sanitizedEntry\)' \
      "$ROOT_DIR/chronicle-server/src/main/kotlin/com/openlattice/chronicle/audit/AuditService.kt" ||
       ! grep -Eq 'eventQueue\.offer\(sanitizedEntry\)' \
      "$ROOT_DIR/chronicle-server/src/main/kotlin/com/openlattice/chronicle/audit/AuditService.kt"; then
      echo "AuditService must sanitize audit entries before log-file and DB-queue persistence"
      auth_failures=$((auth_failures + 1))
    fi

      if [ "$auth_failures" -gt 0 ]; then
        echo "Auth static guardrails found $auth_failures violation(s)"
        return 1
      fi
      return 0
    }

    run_security_step "auth.static" "Auth: JWT/session static guardrails" "guardrail" \
      "auth-static-guardrails.txt" "" -- auth_static_guardrails
    # Semgrep is deliberately independent so a static guardrail finding cannot
    # suppress the scanner report.
    run_security_step "auth.semgrep" "Auth: hardcoded-secret and JWT patterns" "scanner" \
      "auth-semgrep.log" "auth-patterns.sarif" -- run_auth_semgrep
    echo "Auth scan complete"
    ;;

  injection)
    run_security_step "injection.semgrep" "Injection: Semgrep injection rules" "scanner" \
      "injection-semgrep.log" "injection.sarif" -- run_injection_semgrep
    echo "Injection scan complete"
    ;;

  crypto)
    run_security_step "crypto.semgrep" "Crypto: weak crypto patterns" "scanner" \
      "crypto-semgrep.log" "crypto.sarif" -- run_crypto_semgrep
    echo "Crypto scan complete"
    ;;

  license)
    run_security_step "license.gradle" "License: Gradle license report" "build" \
      "license.log" "license.json" -- run_license_report
    echo "License scan complete"
    ;;

  collection)
    run_security_step "collection.semgrep-modularization" \
      "Collection: Semgrep modularization rules" "scanner" \
      "collection-semgrep-modularization.log" "collection-semgrep-modularization.sarif" -- \
      run_collection_semgrep_modularization
    run_security_step "collection.semgrep-dto" \
      "Collection: Semgrep DTO secret-redaction rule" "scanner" \
      "collection-semgrep-dto.log" "collection-semgrep-dto.sarif" -- \
      run_collection_semgrep_dto

    for rule in collection-module-id-no-raw-string \
                collection-queue-insert-only-in-sink \
                collection-sensor-insert-only-in-sink \
                collection-hardware-service-only-via-manager \
                collection-lifecycle-record-only-via-module \
                collection-worker-no-direct-sensor-instantiation \
                collection-settings-service-no-rls-context-call \
                collection-settings-resolver-only-via-coordinator; do
      run_security_step "collection.ast-grep.${rule}" \
        "Collection: ast-grep $rule" "scanner" \
        "collection-${rule}.log" "collection-${rule}.sarif" -- \
        run_collection_ast_grep "$rule"
    done

    run_security_step "collection.upload-validation" \
      "Collection: upload batch-validation shell guardrail" "guardrail" \
      "collection-upload-validation.log" "" -- \
      "$ROOT_DIR/tests/security/collection-upload-validation-guardrail.sh" "$REPORT_DIR"
    run_security_step "collection.fixture-self-check" \
      "Collection: guardrail fixture self-check" "guardrail" \
      "collection-guardrail-fixtures.log" "" -- \
      "$ROOT_DIR/tests/security/collection-guardrail-fixtures.sh" "$REPORT_DIR"
    echo "Collection guardrails complete"
    ;;

  compliance)
    run_security_step "compliance.conftest" "Compliance: Conftest OPA policies" "scanner" \
      "compliance.log" "compliance.json" -- run_compliance_scan
    echo "Compliance scan complete"
    ;;

  *)
    echo "ERROR: Unknown layer: $LAYER"
    echo "Valid layers: sast, sca, secrets, iac, sso, deploy, mobile, auth, injection, crypto, license, compliance, collection"
    exit 1
    ;;
esac

echo "Layer $LAYER completed. Reports in $REPORT_DIR"
security_runner_finalize 0
trap - EXIT
return "$SECURITY_RUNNER_EXIT_CODE"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  runner_status=0
  security_runner_main "$@" || runner_status=$?
  exit "$runner_status"
fi
