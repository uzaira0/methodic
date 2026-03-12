#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WEB_DIR="$ROOT_DIR/chronicle-web"

run_step() {
  local label="$1"
  shift
  echo
  echo "==> $label"
  "$@"
}

cd "$ROOT_DIR"

run_step "Traefik compose syntax" docker compose -f docker/docker-compose.traefik.yml config -q
run_step "SSO drift audit" ./scripts/check-sso-drift.sh
run_step "Web check" bash -lc "cd '$WEB_DIR' && bun run check"
run_step "Web Bun tests" bash -lc "cd '$WEB_DIR' && bun run test"
run_step "Web legacy compatibility tests" bash -lc "cd '$WEB_DIR' && bun run test:legacy -- --runInBand --watch=false"
run_step "Web route-cutover smoke" ./scripts/chronicle-web-route-cutover-smoke.sh
run_step "Web browser smoke" bash -lc "cd '$WEB_DIR' && bun run e2e"

if command -v java >/dev/null 2>&1 || [[ -n "${JAVA_HOME:-}" ]] || [[ -x "${HOME}/.local/jdks/temurin-21/bin/java" ]]; then
  export CHRONICLE_GRADLE_PROJECT_CACHE_DIR="${CHRONICLE_GRADLE_PROJECT_CACHE_DIR:-/tmp/chronicle-gradle-project-cache}"
  export GRADLE_USER_HOME="${GRADLE_USER_HOME:-/tmp/chronicle-gradle-user-home}"
  run_step "Server auth smoke" ./scripts/chronicle-server-auth-smoke.sh
else
  echo
  echo "==> Server auth smoke"
  echo "Skipping JVM validation because java is not available on PATH."
fi

echo
echo "Production-like validation completed."
