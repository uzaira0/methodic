#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_NAME="com.openlattice.chronicle.controllers.AuthTokenControllerTest"
PROJECT_CACHE_DIR="${CHRONICLE_GRADLE_PROJECT_CACHE_DIR:-}"

if ! command -v java >/dev/null 2>&1; then
  echo "chronicle-server auth smoke requires java and JAVA_HOME"
  exit 1
fi

cd "$ROOT_DIR"
GRADLE_ARGS=( :chronicle-server:test --tests "$TEST_NAME" --no-daemon --no-watch-fs )

if [[ -n "$PROJECT_CACHE_DIR" ]]; then
  mkdir -p "$PROJECT_CACHE_DIR"
  GRADLE_ARGS=( --project-cache-dir "$PROJECT_CACHE_DIR" "${GRADLE_ARGS[@]}" )
fi

./gradlew "${GRADLE_ARGS[@]}"
