#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CI_FILE="$ROOT_DIR/.github/workflows/ci.yml"
SECURITY_FILE="$ROOT_DIR/.github/workflows/security-scan.yml"
LOCAL_CI_FILE="$ROOT_DIR/scripts/local-ci.sh"
SUPPLY_CHAIN_REPORT_DIR="${TMPDIR:-/tmp}/chronicle-bun-workflow-audit"

require_pattern() {
  local file="$1"
  local pattern="$2"
  if ! grep -Fq "$pattern" "$file"; then
    printf '[fail] %s missing pattern: %s\n' "$file" "$pattern" >&2
    exit 1
  fi
}

reject_pattern() {
  local file="$1"
  local pattern="$2"
  if [ -d "$file" ]; then
    if grep -RFq "$pattern" "$file"; then
      printf '[fail] %s contains forbidden pattern: %s\n' "$file" "$pattern" >&2
      exit 1
    fi
    return
  fi
  if grep -Fq "$pattern" "$file"; then
    printf '[fail] %s contains forbidden pattern: %s\n' "$file" "$pattern" >&2
    exit 1
  fi
}

printf 'Chronicle Bun workflow audit\n'

python3 "$ROOT_DIR/scripts/check-bun-script-references.py"

"$ROOT_DIR/tests/security/supply-chain-guardrails.sh" "$SUPPLY_CHAIN_REPORT_DIR"

require_pattern "$ROOT_DIR/.github/actions/setup-web/action.yml" 'uses: oven-sh/setup-bun@0c5077e51419868618aeaa5fe8019c62421857d6'
require_pattern "$ROOT_DIR/.github/actions/setup-web/action.yml" 'bun-version: 1.3.12'
require_pattern "$CI_FILE" 'uses: ./.github/actions/setup-web'
require_pattern "$CI_FILE" 'scripts/local-ci.sh web'
require_pattern "$CI_FILE" 'scripts/local-ci.sh dead-code'
require_pattern "$LOCAL_CI_FILE" 'bun audit --audit-level=high'
require_pattern "$LOCAL_CI_FILE" 'bun run check'
require_pattern "$LOCAL_CI_FILE" 'bun test'

require_pattern "$SECURITY_FILE" 'bun-security-scan:'
require_pattern "$SECURITY_FILE" 'scripts/local-ci.sh bun-audit'
require_pattern "$LOCAL_CI_FILE" 'bun audit --json'
require_pattern "$LOCAL_CI_FILE" 'bun audit --audit-level=high'
require_pattern "$SECURITY_FILE" 'bun-version: 1.3.12'
reject_pattern "$CI_FILE" 'package-lock.json'
reject_pattern "$CI_FILE" 'npm ci'
reject_pattern "$CI_FILE" 'npm run check'
reject_pattern "$CI_FILE" 'npm run test'
reject_pattern "$SECURITY_FILE" 'package-lock.json'
reject_pattern "$SECURITY_FILE" 'npm audit'
reject_pattern "$SECURITY_FILE" 'npm ci'
reject_pattern "$ROOT_DIR/.github" 'bun-version: latest'
# Bun is the sole JS runtime — Node must not reappear in any workflow or action.
reject_pattern "$ROOT_DIR/.github" 'actions/setup-node'
reject_pattern "$ROOT_DIR/.github" 'node-version:'
# npm/npx invocations must not creep back into any root workflow (bunx replaces
# npx; bun install replaces npm ci/install). registry.npmjs.org egress entries
# and dependabot's "npm" package-ecosystem label are fine and don't match these.
reject_pattern "$ROOT_DIR/.github" 'npx '
reject_pattern "$ROOT_DIR/.github" 'npm ci'
reject_pattern "$ROOT_DIR/.github" 'npm install'
reject_pattern "$ROOT_DIR/.github" 'npm run'
reject_pattern "$ROOT_DIR/.github" 'npm exec'
reject_pattern "$ROOT_DIR/.github" 'package-lock.json'

printf '[ok] Bun workflow audit passed\n'
