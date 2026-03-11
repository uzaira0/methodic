#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CI_FILE="$ROOT_DIR/.github/workflows/ci.yml"
SECURITY_FILE="$ROOT_DIR/.github/workflows/security-scan.yml"

require_pattern() {
  local file="$1"
  local pattern="$2"
  if ! rg -Fq "$pattern" "$file"; then
    printf '[fail] %s missing pattern: %s\n' "$file" "$pattern" >&2
    exit 1
  fi
}

reject_pattern() {
  local file="$1"
  local pattern="$2"
  if rg -Fq "$pattern" "$file"; then
    printf '[fail] %s contains forbidden pattern: %s\n' "$file" "$pattern" >&2
    exit 1
  fi
}

printf 'Chronicle Bun workflow audit\n'

require_pattern "$CI_FILE" 'oven-sh/setup-bun@v2'
require_pattern "$CI_FILE" 'actions/setup-node@v4'
require_pattern "$CI_FILE" 'bun install --frozen-lockfile'
require_pattern "$CI_FILE" 'bun run check'
require_pattern "$CI_FILE" 'bun run test -- --runInBand --watch=false'

require_pattern "$SECURITY_FILE" 'bun-security-scan:'
require_pattern "$SECURITY_FILE" 'bun audit --json'
require_pattern "$SECURITY_FILE" 'bun audit --audit-level=high'
require_pattern "$SECURITY_FILE" 'actions/setup-node@v4'

reject_pattern "$CI_FILE" 'package-lock.json'
reject_pattern "$CI_FILE" 'npm ci'
reject_pattern "$CI_FILE" 'npm run check'
reject_pattern "$CI_FILE" 'npm run test'
reject_pattern "$SECURITY_FILE" 'package-lock.json'
reject_pattern "$SECURITY_FILE" 'npm audit'
reject_pattern "$SECURITY_FILE" 'npm ci'

printf '[ok] Bun workflow audit passed\n'
