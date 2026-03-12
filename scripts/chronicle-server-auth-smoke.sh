#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_NAME="com.openlattice.chronicle.controllers.AuthTokenControllerTest"

if ! command -v java >/dev/null 2>&1; then
  echo "chronicle-server auth smoke requires java and JAVA_HOME"
  exit 1
fi

cd "$ROOT_DIR"
./gradlew :chronicle-server:test --tests "$TEST_NAME" --no-daemon
