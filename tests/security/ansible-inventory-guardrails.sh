#!/usr/bin/env bash
# Static guardrails for Chronicle Ansible inventory separation.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
REPORT_DIR="${1:-/tmp/chronicle-ansible-inventory-guardrails}"
REPORT_FILE="$REPORT_DIR/ansible-inventory-guardrails.txt"

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

check_shared_defaults_are_neutral() {
  local shared="$ROOT_DIR/deploy/ansible/inventory/group_vars/all.yml"
  local leakage="$REPORT_DIR/shared-default-private-deployment-leakage.txt"
  local retired_rehearsal_label='test''prod'

  : > "$leakage"
  if grep -En "${retired_rehearsal_label}|nip\\.io|[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+\\.nip\\.io" "$shared" > "$leakage"; then
    fail "shared Ansible defaults contain private deployment values; see $leakage"
  else
    pass "shared Ansible defaults are private-deployment-neutral"
  fi

  if ruby -e 'require "yaml"; data = YAML.load_file(ARGV[0]); exit(data["chronicle_k8s_overlays"] == [] ? 0 : 1)' "$shared"; then
    pass "shared Ansible defaults do not imply a Kubernetes overlay"
  else
    fail "shared Ansible defaults must set chronicle_k8s_overlays to []"
  fi
}

check_deployment_examples_are_neutral() {
  local leakage="$REPORT_DIR/deployment-example-private-leakage.txt"
  local retired_rehearsal_label='test''prod'
  : > "$leakage"

  if grep -En "${retired_rehearsal_label}|nip\\.io|research\\.[A-Za-z0-9.-]+" \
      "$ROOT_DIR/deploy/ansible/inventory/operator.example.ini" \
      "$ROOT_DIR/deploy/ansible/inventory/host_vars/operator-production.example.yml" \
      "$ROOT_DIR/deploy/ansible/inventory/host_vars/operator-fallback.example.yml" > "$leakage"; then
    fail "deployment example inventory contains private test deployment values; see $leakage"
  else
    pass "deployment example inventory is private-deployment-neutral"
  fi

  if grep -q 'rejects tracked, symlinked, or group/world-accessible' "$ROOT_DIR/deploy/ansible/README.md" &&
    grep -q 'mode `0600`' "$ROOT_DIR/deploy/ansible/README.md" &&
    grep -q 'CHRONICLE_ANSIBLE_INVENTORY' "$ROOT_DIR/deploy/ansible/README.md"; then
    pass "Ansible README documents strict inventory tracked/symlink/mode rejection"
  else
    fail "Ansible README must document that strict portable evidence rejects tracked, symlinked, or group/world-accessible inventories"
  fi
}

record "Chronicle Ansible inventory guardrails"
require_file "deploy/ansible/inventory/operator.example.ini"
require_file "deploy/ansible/inventory/host_vars/operator-production.example.yml"
require_file "deploy/ansible/inventory/host_vars/operator-fallback.example.yml"
check_shared_defaults_are_neutral
check_deployment_examples_are_neutral

if [ "$failures" -gt 0 ]; then
  record "Ansible inventory guardrails failed with $failures finding(s)"
  exit 1
fi

record "Ansible inventory guardrails passed"
