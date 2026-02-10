#!/usr/bin/env bash
# setup-test-data.sh
# Creates a test study and participant via the Chronicle web API.
# Called by CI before running Maestro flows.
#
# Outputs TEST_STUDY_ID and TEST_PARTICIPANT_ID for use by Maestro.
#
# Usage: source setup-test-data.sh

set -euo pipefail

API_BASE="${SERVER_URL:-http://localhost}/chronicle/api/web/chronicle"
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
STUDY_RESPONSE=$(curl -sf -X POST "${API_BASE}/v3/study/" \
  -H "Authorization: Bearer ${AUTH_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "title": "Maestro CI Test Study",
    "description": "Automated test study created by CI",
    "modules": {
      "CHRONICLE_DATA_COLLECTION": {}
    }
  }')

TEST_STUDY_ID=$(echo "${STUDY_RESPONSE}" | tr -d '"')
echo "Created study: ${TEST_STUDY_ID}"

# Register a test participant
echo "Registering test participant..."
PARTICIPANT_RESPONSE=$(curl -sf -X POST "${API_BASE}/v3/study/${TEST_STUDY_ID}/participant" \
  -H "Authorization: Bearer ${AUTH_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "participantId": "maestro-test-001"
  }')

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
