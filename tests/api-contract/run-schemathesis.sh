#!/usr/bin/env bash
# Runs Schemathesis API contract testing against the Chronicle backend.
# Requires: schemathesis (pip install schemathesis), running Docker stack, generate-jwt.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DOCKER_DIR="$PROJECT_ROOT/docker"
REPORT_DIR="$PROJECT_ROOT/tests/api-contract/reports"

BASE_URL="${CHRONICLE_BASE_URL:-http://127.0.0.1:40320}"
SCHEMA_PATH="${CHRONICLE_SCHEMA_PATH:-$PROJECT_ROOT/chronicle-api/chronicle.yaml}"

mkdir -p "$REPORT_DIR"

# Generate a JWT for authentication
echo "Generating JWT token..."
if [ -f "$DOCKER_DIR/.env" ]; then
  # shellcheck source=/dev/null
  source "$DOCKER_DIR/.env"
fi

if [ -z "${JWT_SECRET:-}" ]; then
  echo "ERROR: JWT_SECRET not set. Source docker/.env or set JWT_SECRET env var."
  exit 1
fi

JWT_TOKEN=$("$DOCKER_DIR/generate-jwt.sh" 2>/dev/null || echo "")
if [ -z "$JWT_TOKEN" ]; then
  echo "ERROR: Failed to generate JWT token."
  exit 1
fi

echo "Running Schemathesis against $BASE_URL..."
echo "Schema: $SCHEMA_PATH"

schemathesis run "$SCHEMA_PATH" \
  --base-url "$BASE_URL" \
  --header "Authorization: Bearer $JWT_TOKEN" \
  --method GET \
  --max-examples 50 \
  --checks all \
  --junit-xml "$REPORT_DIR/schemathesis-report.xml" \
  --request-timeout 10000 \
  --validate-schema false \
  --hypothesis-seed 42 \
  || SCHEMATHESIS_EXIT=$?

echo ""
echo "Report written to: $REPORT_DIR/schemathesis-report.xml"

exit "${SCHEMATHESIS_EXIT:-0}"
