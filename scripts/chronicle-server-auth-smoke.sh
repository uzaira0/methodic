#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_NAME="com.openlattice.chronicle.controllers.AuthTokenControllerTest"
PROJECT_CACHE_DIR="${CHRONICLE_GRADLE_PROJECT_CACHE_DIR:-}"
JAVA_BIN="${JAVA_BIN:-}"
SMOKE_WORKDIR="${CHRONICLE_SERVER_SMOKE_WORKDIR:-}"
KEEP_WORKDIR="${CHRONICLE_SERVER_SMOKE_KEEP_WORKDIR:-0}"

if [[ -z "$JAVA_BIN" && -n "${JAVA_HOME:-}" && -x "${JAVA_HOME}/bin/java" ]]; then
  JAVA_BIN="${JAVA_HOME}/bin/java"
fi

if [[ -z "$JAVA_BIN" && -x "${HOME}/.local/jdks/temurin-21/bin/java" ]]; then
  JAVA_BIN="${HOME}/.local/jdks/temurin-21/bin/java"
fi

if [[ -z "$JAVA_BIN" ]] && ! command -v java >/dev/null 2>&1; then
  echo "chronicle-server auth smoke requires java and JAVA_HOME"
  exit 1
fi

if [[ -n "$JAVA_BIN" ]]; then
  export JAVA_HOME="$(cd "$(dirname "$JAVA_BIN")/.." && pwd)"
  export PATH="${JAVA_HOME}/bin:${PATH}"
fi

cd "$ROOT_DIR"

if ! command -v rsync >/dev/null 2>&1; then
  echo "chronicle-server auth smoke requires rsync"
  exit 1
fi

if [[ -z "$SMOKE_WORKDIR" ]]; then
  SMOKE_WORKDIR="$(mktemp -d /tmp/chronicle-server-auth-smoke.XXXXXX)"
else
  mkdir -p "$SMOKE_WORKDIR"
fi

cleanup() {
  if [[ "$KEEP_WORKDIR" != "1" ]]; then
    rm -rf "$SMOKE_WORKDIR"
  fi
}

trap cleanup EXIT

rsync -a \
  --delete \
  --exclude '.gradle/' \
  --exclude 'build/' \
  --exclude 'chronicle-api/build/' \
  --exclude 'chronicle-server/build/' \
  --exclude 'rhizome/build/' \
  --exclude 'rhizome-client/build/' \
  --exclude 'chronicle-web/' \
  --exclude 'chronicle/' \
  --exclude 'docker/' \
  --exclude 'node_modules/' \
  "$ROOT_DIR/" \
  "$SMOKE_WORKDIR/"

cd "$SMOKE_WORKDIR"
GRADLE_ARGS=( :chronicle-server:test --tests "$TEST_NAME" --no-daemon --no-watch-fs )

if [[ -n "$PROJECT_CACHE_DIR" ]]; then
  mkdir -p "$PROJECT_CACHE_DIR"
  GRADLE_ARGS=( --project-cache-dir "$PROJECT_CACHE_DIR" "${GRADLE_ARGS[@]}" )
fi

./gradlew "${GRADLE_ARGS[@]}"
