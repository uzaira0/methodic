#!/usr/bin/env bash
# setup-test-data.sh
# Creates a test study and participant via the Chronicle web API.
# Called by CI before running Maestro flows.
#
# Outputs TEST_STUDY_ID and TEST_PARTICIPANT_ID for use by Maestro.
#
# Usage: source setup-test-data.sh

set -euo pipefail

# When running behind Traefik: SERVER_URL=http://host → /chronicle/api/web/chronicle/...
# When running directly: SERVER_URL=http://host:40320 → /chronicle/...
# Detect by checking if SERVER_URL contains a port
if echo "${SERVER_URL:-}" | grep -qE ':[0-9]+$'; then
  API_BASE="${SERVER_URL}/chronicle"
else
  API_BASE="${SERVER_URL:-http://localhost}/chronicle/api/web/chronicle"
fi
AUTH_TOKEN="${AUTH_TOKEN:-eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJodHRwczovL2xvY2FsaG9zdC8iLCJhdWQiOiJkdW1teS1jbGllbnQtaWQiLCJzdWIiOiJsb2NhbC1hZG1pbiIsImlhdCI6MTc3MDQyOTkxNSwiZXhwIjo0OTI0MDI5OTE1fQ.5d9ecGq0oAaoTujkV9i1SpZAMHpSl6IJMjJSWvvoBoo}"

echo "Waiting for Chronicle API to be ready..."
for i in $(seq 1 60); do
  if curl -sf "${API_BASE}/v3/study/" \
    -H "Authorization: Bearer ${AUTH_TOKEN}" > /dev/null 2>&1; then
    echo "API is ready."
    break
  fi
  if [ "$i" -eq 60 ]; then
    echo "ERROR: API did not become ready in 60 seconds"
    exit 1
  fi
  sleep 2
done

# Create a test study with Android data collection enabled
echo "Creating test study..."
STUDY_RESPONSE=$(curl -s -w '\n%{http_code}' -X POST "${API_BASE}/v3/study/" \
  -H "Authorization: Bearer ${AUTH_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "title": "Maestro CI Test Study",
    "description": "Automated test study created by CI",
    "contact": "ci-test@example.com",
    "modules": {
      "CHRONICLE_DATA_COLLECTION": {}
    }
  }')

STUDY_HTTP_CODE=$(echo "${STUDY_RESPONSE}" | tail -1)
STUDY_BODY=$(echo "${STUDY_RESPONSE}" | head -n -1)
if [ "${STUDY_HTTP_CODE}" -ge 400 ]; then
  echo "ERROR: Failed to create study (HTTP ${STUDY_HTTP_CODE}): ${STUDY_BODY}"
  exit 1
fi

TEST_STUDY_ID=$(echo "${STUDY_BODY}" | tr -d '"')
echo "Created study: ${TEST_STUDY_ID}"

# Register a test participant
echo "Registering test participant..."
PARTICIPANT_RESPONSE=$(curl -s -w '\n%{http_code}' -X POST "${API_BASE}/v3/study/${TEST_STUDY_ID}/participant" \
  -H "Authorization: Bearer ${AUTH_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "participantId": "maestro-test-001",
    "candidate": {
      "firstName": "Maestro",
      "lastName": "CI"
    },
    "participationStatus": "ENROLLED"
  }')

PARTICIPANT_HTTP_CODE=$(echo "${PARTICIPANT_RESPONSE}" | tail -1)
PARTICIPANT_BODY=$(echo "${PARTICIPANT_RESPONSE}" | head -n -1)
if [ "${PARTICIPANT_HTTP_CODE}" -ge 400 ]; then
  echo "ERROR: Failed to register participant (HTTP ${PARTICIPANT_HTTP_CODE}): ${PARTICIPANT_BODY}"
  exit 1
fi

TEST_PARTICIPANT_ID="maestro-test-001"
echo "Registered participant: ${TEST_PARTICIPANT_ID}"

# Export for Maestro
export TEST_STUDY_ID
export TEST_PARTICIPANT_ID

echo "TEST_STUDY_ID=${TEST_STUDY_ID}" >> "${GITHUB_ENV:-/dev/null}"
echo "TEST_PARTICIPANT_ID=${TEST_PARTICIPANT_ID}" >> "${GITHUB_ENV:-/dev/null}"

echo "Test data setup complete."
echo "  Study ID:       ${TEST_STUDY_ID}"
echo "  Participant ID: ${TEST_PARTICIPANT_ID}"
