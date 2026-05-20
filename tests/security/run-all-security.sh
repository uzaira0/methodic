#!/usr/bin/env bash
# Security layer runner for CI.
# Usage: run-all-security.sh <layer> <report-dir>
set -euo pipefail

LAYER="${1:?Usage: $0 <layer> <report-dir>}"
REPORT_DIR="${2:?Usage: $0 <layer> <report-dir>}"
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

mkdir -p "$REPORT_DIR"

case "$LAYER" in
  sast)
    echo "=== SAST: Semgrep ==="
    set +e
    semgrep scan --quiet --config "$ROOT_DIR/tests/security/rules/" \
      --sarif -o "$REPORT_DIR/semgrep.sarif" \
      "$ROOT_DIR/chronicle-server/src" "$ROOT_DIR/chronicle-api/src" \
      "$ROOT_DIR/chronicle-web/src"
    semgrep_status=$?
    set -e
    if [ ! -f "$REPORT_DIR/semgrep.sarif" ]; then
      echo "Semgrep did not produce a SARIF report"
      exit 1
    fi
    python3 - "$REPORT_DIR/semgrep.sarif" "$REPORT_DIR/semgrep-actionable-count.txt" <<'PY'
import json
import sys

path = sys.argv[1]
count_path = sys.argv[2]
with open(path, "r", encoding="utf-8") as f:
    sarif = json.load(f)

unsuppressed_count = 0
for run in sarif.get("runs", []):
    kept = []
    for result in run.get("results", []):
        if result.get("suppressions"):
            continue
        kept.append(result)
    run["results"] = kept
    unsuppressed_count += len(kept)

with open(path, "w", encoding="utf-8") as f:
    json.dump(sarif, f)

with open(count_path, "w", encoding="utf-8") as f:
    f.write(str(unsuppressed_count))

print(f"Semgrep actionable findings: {unsuppressed_count}")
PY
    semgrep_actionable_count="$(cat "$REPORT_DIR/semgrep-actionable-count.txt")"
    if [ "$semgrep_status" -gt 1 ]; then
      echo "Semgrep execution failed with status $semgrep_status"
      exit "$semgrep_status"
    fi
    if [ "$semgrep_actionable_count" -gt 0 ]; then
      echo "Semgrep found actionable repo-specific security findings"
      exit 1
    fi
    echo "=== SAST: focused RLS guardrails (blocking) ==="
    "$ROOT_DIR/tests/security/run-rls-guardrails.sh" "$REPORT_DIR"
    echo "SAST scan complete"
    ;;

  sca)
    echo "=== SCA: Bun audit ==="
    if [ -f "$ROOT_DIR/chronicle-web/package.json" ]; then
      cd "$ROOT_DIR/chronicle-web"
      bun install --frozen-lockfile
      bun audit --audit-level=high --json > "$REPORT_DIR/bun-audit.json"
    fi
    echo "SCA scan complete"
    ;;

  secrets)
    echo "=== Secrets: Gitleaks ==="
    gitleaks detect --source "$ROOT_DIR" \
      --config "$ROOT_DIR/tests/security/gitleaks.toml" \
      --report-format sarif --report-path "$REPORT_DIR/gitleaks.sarif" \
      --no-banner
    echo "Secrets scan complete"
    ;;

  iac)
    echo "=== IaC: Checkov ==="
    checkov -d "$ROOT_DIR/docker" \
      --framework dockerfile \
      --output sarif --output-file-path "$REPORT_DIR/"

    echo "=== IaC: Hadolint ==="
    for df in "$ROOT_DIR"/docker/Dockerfile.*; do
      name=$(basename "$df")
      hadolint --format sarif "$df" > "$REPORT_DIR/hadolint-${name}.sarif"
    done
    echo "IaC scan complete"
    ;;

  sso)
    echo "=== SSO: Keycloak broker hardening guardrails ==="
    python3 "$ROOT_DIR/tests/security/sso-hardening-tests.py" | tee "$REPORT_DIR/sso-hardening.txt"
    echo "SSO hardening scan complete"
    ;;

  mobile)
    echo "=== Mobile: upload signing/activityClass guardrails ==="
    "$ROOT_DIR/tests/security/mobile-upload-guardrails.sh" "$REPORT_DIR" | tee "$REPORT_DIR/mobile-upload-guardrails.txt"
    echo "=== Mobile: dogfood lifecycle tooling guardrails ==="
    "$ROOT_DIR/tests/security/dogfood-tooling-guardrails.sh" "$REPORT_DIR" | tee "$REPORT_DIR/dogfood-tooling-guardrails.txt"
    echo "Mobile upload guardrails complete"
    ;;

  auth)
    echo "=== Auth: JWT/session pattern check ==="
    # Check for hardcoded secrets and insecure auth patterns
    semgrep scan --error --config "p/jwt" --config "p/secrets" \
      --sarif -o "$REPORT_DIR/auth-patterns.sarif" \
      "$ROOT_DIR/chronicle-server/src" "$ROOT_DIR/chronicle-web/src"
    echo "Auth scan complete"
    ;;

  injection)
    echo "=== Injection: Semgrep injection rules ==="
    semgrep scan --error --config "p/sql-injection" --config "p/xss" \
      --sarif -o "$REPORT_DIR/injection.sarif" \
      "$ROOT_DIR/chronicle-server/src" "$ROOT_DIR/chronicle-web/src"
    echo "Injection scan complete"
    ;;

  crypto)
    echo "=== Crypto: Weak crypto patterns ==="
    semgrep scan --error --config "p/insecure-transport" \
      --sarif -o "$REPORT_DIR/crypto.sarif" \
      "$ROOT_DIR/chronicle-server/src"
    echo "Crypto scan complete"
    ;;

  license)
    echo "=== License: Gradle license report ==="
    (cd "$ROOT_DIR" && ./gradlew :chronicle-server:generateLicenseReport --no-daemon)
    echo '{"passed":true,"note":"Gradle license report generated successfully"}' > "$REPORT_DIR/license.json"
    echo "License scan complete"
    ;;

  compliance)
    echo "=== Compliance: Conftest OPA policies ==="
    if [ -d "$ROOT_DIR/tests/security/policies" ]; then
      conftest test "$ROOT_DIR/docker/docker-compose.traefik.yml" \
        --policy "$ROOT_DIR/tests/security/policies/" \
        --output json > "$REPORT_DIR/compliance.json" 2>&1
    else
      echo "No OPA policies found"
      exit 1
    fi
    echo "Compliance scan complete"
    ;;

  *)
    echo "ERROR: Unknown layer: $LAYER"
    echo "Valid layers: sast, sca, secrets, iac, sso, mobile, auth, injection, crypto, license, compliance"
    exit 1
    ;;
esac

echo "Layer $LAYER completed. Reports in $REPORT_DIR"
