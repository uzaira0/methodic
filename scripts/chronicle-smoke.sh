#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failures=0
skips=0

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

run_step() {
  local label="$1"
  shift
  printf '\n== %s ==\n' "$label"
  if "$@"; then
    printf '[ok] %s\n' "$label"
  else
    printf '[fail] %s\n' "$label"
    failures=$((failures + 1))
  fi
}

skip_step() {
  local label="$1"
  printf '\n== %s ==\n' "$label"
  printf '[skip] %s\n' "$label"
  skips=$((skips + 1))
}

printf 'Chronicle smoke validation\n'
printf 'root: %s\n' "$ROOT_DIR"

if have_cmd java; then
  run_step "gradle-projects" bash -lc "cd '$ROOT_DIR' && ./gradlew projects"
  run_step "chronicle-api-tests" bash -lc "cd '$ROOT_DIR' && ./gradlew :chronicle-api:test"
else
  skip_step "gradle-projects (java missing)"
  skip_step "chronicle-api-tests (java missing)"
fi

if have_cmd node && have_cmd npm; then
  run_step "chronicle-web-check" bash -lc "cd '$ROOT_DIR/chronicle-web' && npm run check"
  run_step "chronicle-web-tests" bash -lc "cd '$ROOT_DIR/chronicle-web' && npm test -- --runInBand --watch=false"
else
  skip_step "chronicle-web-check (node/npm missing)"
  skip_step "chronicle-web-tests (node/npm missing)"
fi

if have_cmd docker && [[ -f "$ROOT_DIR/docker/.env" ]]; then
  run_step "traefik-compose-config" bash -lc "cd '$ROOT_DIR' && docker compose -f docker/docker-compose.traefik.yml config -q"
else
  skip_step "traefik-compose-config (docker or docker/.env missing)"
fi

printf '\nSummary\n'
printf 'failures=%d skips=%d\n' "$failures" "$skips"

if (( failures > 0 )); then
  exit 1
fi
