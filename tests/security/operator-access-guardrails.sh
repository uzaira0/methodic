#!/usr/bin/env bash
# Static guardrails for reusable operator access and secret-custody tooling.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
REPORT_DIR="${1:-/tmp/chronicle-operator-access-guardrails}"
REPORT_FILE="$REPORT_DIR/operator-access-guardrails.txt"

mkdir -p "$REPORT_DIR"
: > "$REPORT_FILE"
failures=0

record() {
  printf '%s\n' "$*" | tee -a "$REPORT_FILE"
}

fail() {
  failures=$((failures + 1))
  record "[fail] $*"
}

pass() {
  record "[ok] $*"
}

require_file() {
  local path="$1"
  if [ -f "$ROOT_DIR/$path" ]; then
    pass "found $path"
  else
    fail "missing $path"
  fi
}

require_pattern() {
  local path="$1"
  local pattern="$2"
  local description="$3"
  if grep -Eq -- "$pattern" "$ROOT_DIR/$path"; then
    pass "$description"
  else
    fail "$description"
  fi
}

reject_pattern() {
  local path="$1"
  local pattern="$2"
  local description="$3"
  if grep -Eq -- "$pattern" "$ROOT_DIR/$path"; then
    fail "$description"
  else
    pass "$description"
  fi
}

record "Chronicle operator access and secret-custody guardrails"

require_file "scripts/chronicle-operator-secret-evidence.sh"
require_file "deploy/ansible/inventory/operator.example.ini"
require_file "deploy/ansible/inventory/host_vars/operator-production.example.yml"
require_file "deploy/ansible/inventory/host_vars/operator-fallback.example.yml"

require_pattern "scripts/chronicle-operator-secret-evidence.sh"   'CHRONICLE_LOCAL_SECRET_PATHS'   "operator tooling allows an explicit local secret path inventory"
require_pattern "scripts/chronicle-operator-secret-evidence.sh"   'empty-secret-path-(inventory|entry)'   "operator tooling rejects empty secret path inventory values"
require_pattern "scripts/chronicle-operator-secret-evidence.sh"   'expand_secret_path_spec'   "operator tooling expands configured globs without reading secret values"
require_pattern "scripts/chronicle-operator-secret-evidence.sh"   'should_check_secret_candidate'   "operator tooling excludes public SSH metadata"
require_pattern "scripts/chronicle-operator-secret-evidence.sh"   'check-ignore'   "operator tooling proves repository-local secret files are ignored"
require_pattern "scripts/chronicle-operator-secret-evidence.sh"   'ls-files --error-unmatch'   "operator tooling rejects tracked local secret files"
require_pattern "scripts/chronicle-operator-secret-evidence.sh"   'group-or-other-readable'   "operator tooling rejects group/world-readable secret files"
require_pattern "scripts/chronicle-operator-secret-evidence.sh"   'symlinked-secret-path'   "operator tooling rejects symlinked secret paths"
require_pattern "scripts/chronicle-operator-secret-evidence.sh"   'operator-access-control-matrix\.tsv'   "operator tooling writes an access-control matrix"
require_pattern "scripts/chronicle-operator-secret-evidence.sh"   'secret-custody-matrix\.tsv'   "operator tooling writes a secret-custody matrix"
require_pattern "scripts/chronicle-operator-secret-evidence.sh"   'operator-secret-evidence-manifest\.txt'   "operator tooling writes an artifact checksum manifest"
require_pattern "scripts/chronicle-operator-secret-evidence.sh"   'never prints secret values|without reading secret values'   "operator tooling documents value-free custody checks"

require_pattern "deploy/ansible/inventory/operator.example.ini"   'ansible_user=CHANGEME_OPERATOR_USER'   "example inventory requires a named operator"
require_pattern "deploy/ansible/inventory/operator.example.ini"   'ansible_become=true'   "example inventory uses audited privilege escalation"

reject_pattern "scripts/chronicle-operator-secret-evidence.sh"   'private[-_]deployment[-_]evidence|rehearsal[-_]credentials'   "operator tooling must not depend on private tenant or test deployment artifacts"
reject_pattern "deploy/ansible/inventory/operator.example.ini"   'nip\.io|/Users/|/home/[^<[:space:]]+|ansible_host=[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'   "example inventory must not contain live topology or local account paths"

if [ "$failures" -gt 0 ]; then
  record "Operator access guardrails failed with $failures finding(s)"
  exit 1
fi

record "Operator access guardrails passed"
