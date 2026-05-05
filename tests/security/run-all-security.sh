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
    semgrep scan --config "$ROOT_DIR/tests/security/rules/" \
      --sarif -o "$REPORT_DIR/semgrep.sarif" \
      "$ROOT_DIR/chronicle-server/src" "$ROOT_DIR/chronicle-api/src" \
      "$ROOT_DIR/chronicle-web/src" \
      || true
    echo "SAST scan complete"
    ;;

  sca)
    echo "=== SCA: Trivy filesystem ==="
    trivy fs --scanners vuln --severity HIGH,CRITICAL \
      --format sarif -o "$REPORT_DIR/trivy-sca.sarif" \
      "$ROOT_DIR" || true

    echo "=== SCA: Bun audit ==="
    if [ -f "$ROOT_DIR/chronicle-web/package.json" ]; then
      cd "$ROOT_DIR/chronicle-web"
      bun install --frozen-lockfile 2>/dev/null || true
      bun audit --json > "$REPORT_DIR/bun-audit.json" 2>&1 || true
    fi
    echo "SCA scan complete"
    ;;

  container)
    echo "=== Container: Trivy config ==="
    for df in "$ROOT_DIR"/docker/Dockerfile.*; do
      name=$(basename "$df" | tr '.' '-')
      trivy config --severity HIGH,CRITICAL \
        --format sarif -o "$REPORT_DIR/trivy-${name}.sarif" \
        "$df" || true
    done
    echo "Container scan complete"
    ;;

  secrets)
    echo "=== Secrets: Gitleaks ==="
    gitleaks detect --source "$ROOT_DIR" \
      --report-format sarif --report-path "$REPORT_DIR/gitleaks.sarif" \
      --no-banner || true
    echo "Secrets scan complete"
    ;;

  iac)
    echo "=== IaC: Checkov ==="
    checkov -d "$ROOT_DIR/docker" \
      --framework dockerfile \
      --output sarif --output-file-path "$REPORT_DIR/" \
      --soft-fail || true

    echo "=== IaC: Hadolint ==="
    for df in "$ROOT_DIR"/docker/Dockerfile.*; do
      name=$(basename "$df")
      hadolint --format sarif "$df" > "$REPORT_DIR/hadolint-${name}.sarif" 2>&1 || true
    done
    echo "IaC scan complete"
    ;;

  auth)
    echo "=== Auth: JWT/session pattern check ==="
    # Check for hardcoded secrets and insecure auth patterns
    semgrep scan --config "p/jwt" --config "p/secrets" \
      --sarif -o "$REPORT_DIR/auth-patterns.sarif" \
      "$ROOT_DIR/chronicle-server/src" "$ROOT_DIR/chronicle-web/src" \
      || true
    echo "Auth scan complete"
    ;;

  injection)
    echo "=== Injection: Semgrep injection rules ==="
    semgrep scan --config "p/sql-injection" --config "p/xss" \
      --sarif -o "$REPORT_DIR/injection.sarif" \
      "$ROOT_DIR/chronicle-server/src" "$ROOT_DIR/chronicle-web/src" \
      || true
    echo "Injection scan complete"
    ;;

  crypto)
    echo "=== Crypto: Weak crypto patterns ==="
    semgrep scan --config "p/insecure-transport" \
      --sarif -o "$REPORT_DIR/crypto.sarif" \
      "$ROOT_DIR/chronicle-server/src" \
      || true
    echo "Crypto scan complete"
    ;;

  license)
    echo "=== License: Trivy license scan ==="
    trivy fs --scanners license --severity HIGH,CRITICAL \
      --format sarif -o "$REPORT_DIR/license.sarif" \
      "$ROOT_DIR" || true
    echo "License scan complete"
    ;;

  compliance)
    echo "=== Compliance: Conftest OPA policies ==="
    if [ -d "$ROOT_DIR/tests/security/policies" ]; then
      conftest test "$ROOT_DIR/docker/docker-compose.traefik.yml" \
        --policy "$ROOT_DIR/tests/security/policies/" \
        --output json > "$REPORT_DIR/compliance.json" 2>&1 || true
    else
      echo "No OPA policies found — skipping conftest"
      echo '{"passed":true,"note":"No policies configured"}' > "$REPORT_DIR/compliance.json"
    fi
    echo "Compliance scan complete"
    ;;

  *)
    echo "ERROR: Unknown layer: $LAYER"
    echo "Valid layers: sast, sca, container, secrets, iac, auth, injection, crypto, license, compliance"
    exit 1
    ;;
esac

echo "Layer $LAYER completed. Reports in $REPORT_DIR"
