#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
critical_missing=0
warnings=0

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

check_required_cmd() {
  local name="$1"
  local hint="${2:-}"
  if have_cmd "$name"; then
    printf '[ok] %s: %s\n' "$name" "$(command -v "$name")"
  else
    if [[ -n "$hint" ]]; then
      printf '[missing] %s (%s)\n' "$name" "$hint"
    else
      printf '[missing] %s\n' "$name"
    fi
    critical_missing=$((critical_missing + 1))
  fi
}

check_optional_cmd() {
  local name="$1"
  if have_cmd "$name"; then
    printf '[ok] %s: %s\n' "$name" "$(command -v "$name")"
  else
    printf '[warn] %s not found\n' "$name"
    warnings=$((warnings + 1))
  fi
}

printf 'Chronicle preflight\n'
printf 'root: %s\n\n' "$ROOT_DIR"

printf 'Toolchain\n'
check_required_cmd git
check_required_cmd node
check_required_cmd bun
check_required_cmd java "required for ./gradlew projects and :chronicle-api:test"
check_optional_cmd docker

if [[ -n "${JAVA_HOME:-}" ]]; then
  printf '[ok] JAVA_HOME: %s\n' "$JAVA_HOME"
else
  printf '[warn] JAVA_HOME is not set'
  if have_cmd java; then
    java_bin="$(readlink -f "$(command -v java)" 2>/dev/null || command -v java)"
    java_home_guess="$(cd "$(dirname "$java_bin")/.." && pwd 2>/dev/null || true)"
    if [[ -n "$java_home_guess" ]]; then
      printf ' (try: export JAVA_HOME=%s)\n' "$java_home_guess"
    else
      printf '\n'
    fi
  else
    printf ' (install a JDK and export JAVA_HOME to enable JVM validation)\n'
  fi
  warnings=$((warnings + 1))
fi

printf '\nWorkspace\n'
if git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  printf '[ok] git worktree detected\n'
else
  printf '[missing] not a git worktree\n'
  critical_missing=$((critical_missing + 1))
fi

if [[ -f "$ROOT_DIR/docker/.env" ]]; then
  printf '[ok] docker/.env present\n'
else
  printf '[warn] docker/.env missing\n'
  warnings=$((warnings + 1))
fi

submodule_output="$(git -C "$ROOT_DIR" submodule status --recursive 2>/dev/null || true)"
if [[ -n "$submodule_output" ]]; then
  if grep -q '^-' <<<"$submodule_output"; then
    printf '[warn] some submodules are not initialized\n'
    warnings=$((warnings + 1))
  else
    printf '[ok] submodules initialized\n'
  fi
else
  printf '[warn] no submodule status available\n'
  warnings=$((warnings + 1))
fi

if git -C "$ROOT_DIR" diff --quiet --ignore-submodules=dirty && git -C "$ROOT_DIR" diff --cached --quiet --ignore-submodules=dirty; then
  printf '[ok] top-level worktree clean\n'
else
  printf '[warn] top-level worktree has changes\n'
  warnings=$((warnings + 1))
fi

printf '\nSummary\n'
printf 'critical_missing=%d warnings=%d\n' "$critical_missing" "$warnings"

if (( critical_missing > 0 )); then
  if ! have_cmd java; then
    printf 'blocked: gradle validation cannot run until a JDK is installed and JAVA_HOME is configured\n'
  fi
  exit 1
fi
