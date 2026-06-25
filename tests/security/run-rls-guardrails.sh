#!/usr/bin/env bash
# Focused guardrails for Chronicle RLS request/connection context regressions.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
REPORT_DIR="${1:-$ROOT_DIR/tests/security/reports}"

mkdir -p "$REPORT_DIR"

echo "=== RLS guardrails: Semgrep ==="
semgrep scan \
  --config "$ROOT_DIR/tests/security/rules/rls-context.yaml" \
  --error \
  --no-git-ignore \
  --sarif -o "$REPORT_DIR/rls-context.semgrep.sarif" \
  "$ROOT_DIR/chronicle-server/src/main/kotlin" \
  "$ROOT_DIR/docker/docker-compose.traefik.yml"

echo "=== RLS guardrails: ast-grep ==="
ast-grep scan \
  --rule "$ROOT_DIR/tests/security/ast-grep/no-rls-context-manager-call.yml" \
  "$ROOT_DIR/chronicle-server/src/main/kotlin" \
  --format sarif > "$REPORT_DIR/rls-no-context-manager-call.ast-grep.sarif"

ast-grep scan \
  --rule "$ROOT_DIR/tests/security/ast-grep/no-direct-admin-rls-bypass.yml" \
  "$ROOT_DIR/chronicle-server/src/main/kotlin" \
  --format sarif > "$REPORT_DIR/rls-no-direct-admin-bypass.ast-grep.sarif"

ast-grep scan \
  --rule "$ROOT_DIR/tests/security/ast-grep/no-rls-filter-storage-resolver.yml" \
  "$ROOT_DIR/chronicle-server/src/main/kotlin" \
  --format sarif > "$REPORT_DIR/rls-no-filter-storage-resolver.ast-grep.sarif"

echo "RLS guardrails passed"
