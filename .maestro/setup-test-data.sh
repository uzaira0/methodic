#!/usr/bin/env bash
# Creates a current, consent-capable study plus two synthetic invitations for Maestro.
# Source this file from CI so the exported synthetic invitation values remain available to later
# steps. The administrator token is transported separately in a private one-use file and never
# survives this function call.
set -euo pipefail

chronicle_setup_test_data() {
local SCRIPT_DIR ROOT_DIR AUTH_TOKEN_FILE_VALUE AUTH_TOKEN_DIR AUTH_TOKEN_VALUE token_mode
export -n AUTH_TOKEN AUTH_TOKEN_VALUE 2>/dev/null || true
unset AUTH_TOKEN
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
: "${SERVER_URL:?SERVER_URL is required}"
: "${AUTH_TOKEN_FILE:?AUTH_TOKEN_FILE is required; generate a short-lived token file at runtime}"
AUTH_TOKEN_FILE_VALUE="$AUTH_TOKEN_FILE"
export -n AUTH_TOKEN_FILE 2>/dev/null || true
unset AUTH_TOKEN_FILE
AUTH_TOKEN_DIR="$(dirname "$AUTH_TOKEN_FILE_VALUE")"
[[ -f "$AUTH_TOKEN_FILE_VALUE" && ! -L "$AUTH_TOKEN_FILE_VALUE" && -O "$AUTH_TOKEN_FILE_VALUE" ]] || {
  printf 'ERROR: AUTH_TOKEN_FILE must be a current-owner regular non-symlink file\n' >&2
  return 1
}
if token_mode="$(stat -c '%a' "$AUTH_TOKEN_FILE_VALUE" 2>/dev/null)"; then
  :
else
  token_mode="$(stat -f '%Lp' "$AUTH_TOKEN_FILE_VALUE")"
fi
[[ "$token_mode" == "600" ]] || {
  printf 'ERROR: AUTH_TOKEN_FILE must have mode 0600\n' >&2
  return 1
}
IFS= read -r AUTH_TOKEN_VALUE <"$AUTH_TOKEN_FILE_VALUE"
[[ "$AUTH_TOKEN_VALUE" =~ ^[^[:space:]]+\.[^[:space:]]+\.[^[:space:]]+$ ]] || {
  printf 'ERROR: AUTH_TOKEN_FILE does not contain one JWT\n' >&2
  return 1
}
# Delete the one-use transport before spawning any network or data-generation helper. The token
# remains function-local, unexported, and reaches curl only over configuration stdin.
rm -f -- "$AUTH_TOKEN_FILE_VALUE"
rmdir -- "$AUTH_TOKEN_DIR" 2>/dev/null || true
abort_setup() {
  printf 'ERROR: %s\n' "$*" >&2
  return 1
}
mask_ci_secret() {
  if [[ "${GITHUB_ACTIONS:-false}" == "true" ]]; then
    printf '::add-mask::%s\n' "$1"
  fi
}
command -v jq >/dev/null 2>&1 || {
  abort_setup "jq is required to seed Maestro enrollment data"
}

# Exercise the same root-origin rule as the public app. The local Caddy listener terminates
# TLS and forwards these direct API routes to the ephemeral backend.
if ! python3 - "$SERVER_URL" <<'PY'
import sys
from urllib.parse import urlsplit

try:
    value = sys.argv[1]
    parsed = urlsplit(value)
    valid_port = parsed.port is None or 1 <= parsed.port <= 65535
except ValueError:
    raise SystemExit(1)
if not (
    parsed.scheme == "https"
    and parsed.hostname
    and parsed.username is None
    and parsed.password is None
    and parsed.path == ""
    and parsed.query == ""
    and parsed.fragment == ""
    and valid_port
):
    raise SystemExit(1)
PY
then
  abort_setup "SERVER_URL must be an exact HTTPS root origin"
fi
API_BASE="${SERVER_URL}/chronicle"

request() {
  local method="$1" url="$2" body="${3:-}"
  local -a args=(--silent --show-error --connect-timeout 5 --max-time 30
    -w $'\n%{http_code}' -X "$method" "$url")
  if [[ -n "$body" ]]; then
    args+=(-H "Content-Type: application/json" --data "$body")
  fi
  authorized_curl "${args[@]}"
}

authorized_curl() {
  printf 'header = "Authorization: Bearer %s"\n' "$AUTH_TOKEN_VALUE" \
    | curl --config - "$@"
}

response_body() { sed '$d' <<<"$1"; }
response_code() { tail -n 1 <<<"$1"; }
require_success() {
  local description="$1" response="$2" code
  code="$(response_code "$response")"
  if [[ ! "$code" =~ ^2[0-9][0-9]$ ]]; then
    printf 'ERROR: %s failed with HTTP %s\n' "$description" "$code" >&2
    return 1
  fi
}

echo "Waiting for Chronicle API to be ready..."
last_readiness_status="000"
for attempt in $(seq 1 60); do
  last_readiness_status="$(authorized_curl --silent --show-error \
    --connect-timeout 5 --max-time 10 --output /dev/null --write-out '%{http_code}' \
    "${API_BASE}/v3/study" 2>/dev/null || true)"
  if [[ "$last_readiness_status" =~ ^2[0-9][0-9]$ ]]; then
    echo "API is ready."
    break
  fi
  if [[ "$attempt" -eq 60 ]]; then
    abort_setup "API did not become ready in 120 seconds (last HTTP status: ${last_readiness_status})"
  fi
  sleep 2
done

# Explicitly disable every generated collection module except one simple required module.
# That keeps the CI consent path deterministic when the module catalog grows: the participant
# reviews the study disclosure and one module choice instead of silently inheriting new defaults.
STUDY_PAYLOAD="$(python3 - "$ROOT_DIR/generated/domain-contracts/chronicle-domain-contracts.json" \
  "${TEST_MODULE_PROFILE:-battery_only}" <<'PY'
from datetime import datetime, timezone
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    active_modules = json.load(handle)["contracts"]["activeCollectionModuleIds"]
profile = sys.argv[2]
enabled_by_profile = {
    "battery_only": {"battery_telemetry", "upload_telemetry"},
    "minimal_core": {
        "usage_events",
        "device_lifecycle",
        "user_identification",
        "battery_telemetry",
        "upload_telemetry",
    },
}
if profile not in enabled_by_profile:
    raise SystemExit(f"unsupported TEST_MODULE_PROFILE: {profile}")
enabled_modules = enabled_by_profile[profile]
missing = enabled_modules.difference(active_modules)
if missing:
    raise SystemExit(f"active collection contract is missing profile modules: {sorted(missing)}")
modules = {module_id: {"enabled": False} for module_id in active_modules}
for module_id in enabled_modules:
    modules[module_id] = {"enabled": True, "required": True}
payload = {
    "title": "Maestro CI Test Study" if profile == "battery_only" else "Chronicle Minimal Core Test",
    "description": "Synthetic automated enrollment test",
    "contact": "ci-test@example.org",
    "modules": {"CHRONICLE_DATA_COLLECTION": {}},
    "settings": {
        "DataCollection": {
            "@class": "com.openlattice.chronicle.collection.AndroidDataCollectionSetting",
            "modules": modules,
            "settingsVersion": 1,
            "version": 2,
        },
        "ParticipantPolicy": {
            "@class": "com.openlattice.chronicle.study.StudyParticipantPolicy",
            "responsibleInstitution": "Example Research Organization",
            "serverOperator": "Example Research Organization",
            "researchContact": "ci-test@example.org",
            "purpose": "Verify Chronicle enrollment in continuous integration",
            "expectedDuration": "One automated test run",
            "procedures": (
                "Review the disclosure and enable synthetic battery and upload telemetry"
                if profile == "battery_only"
                else "Review and enable synthetic app usage, lifecycle, unlock identification, and battery telemetry"
            ),
            "foreseeableRisks": "No real participant or research data is used",
            "expectedBenefits": "Automated compatibility verification",
            "dataUseAndSharing": "Synthetic test data remains in the ephemeral CI service",
            "retentionAndDeletion": "The CI service is destroyed after the job",
            "privacyPolicyUrl": "https://example.org/privacy",
            "withdrawalUrl": "https://example.org/withdrawal",
            "consentDocumentUrl": None,
            "version": "maestro-ci-v1",
            "effectiveAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        },
    },
}
print(json.dumps(payload, separators=(",", ":")))
PY
)"

echo "Creating synthetic study..."
study_response="$(request POST "${API_BASE}/v3/study" "$STUDY_PAYLOAD")"
require_success "create study" "$study_response"
TEST_STUDY_ID="$(response_body "$study_response" | jq -er \
  'select(type == "string" and test("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"))')"

register_participant() {
  local participant_id="$1" response participant_payload
  participant_payload="$(jq -cn \
    --arg participantId "$participant_id" \
    '{participantId: $participantId, candidate: {id: "00000000-0000-0000-0000-000000000000"}, participationStatus: "ENROLLED"}')"
  response="$(request POST "${API_BASE}/v3/study/${TEST_STUDY_ID}/participant" "$participant_payload")"
  require_success "register synthetic participant" "$response"
}

issue_enrollment_code() {
  local participant_id="$1" response code
  response="$(request POST \
    "${API_BASE}/v3/study/${TEST_STUDY_ID}/participant/${participant_id}/form-access-codes" \
    '{"formKind":"ENROLLMENT"}')"
  require_success "issue enrollment invitation" "$response"
  code="$(response_body "$response" | jq -er \
    '.accessCode | select(type == "string" and test("^[A-Za-z0-9_-]{32,256}$"))')"
  printf '%s\n' "$code"
}

TEST_PARTICIPANT_ID="maestro-test-001"
TEST_PARTICIPANT_ID_2="maestro-test-002"
register_participant "$TEST_PARTICIPANT_ID"
register_participant "$TEST_PARTICIPANT_ID_2"
TEST_ENROLLMENT_ACCESS_CODE="$(issue_enrollment_code "$TEST_PARTICIPANT_ID")"
mask_ci_secret "$TEST_ENROLLMENT_ACCESS_CODE"
TEST_ENROLLMENT_ACCESS_CODE_2="$(issue_enrollment_code "$TEST_PARTICIPANT_ID_2")"

# Mask before exporting. The values are short-lived synthetic capabilities and must never
# appear in workflow logs or uploaded Maestro diagnostics.
mask_ci_secret "$TEST_ENROLLMENT_ACCESS_CODE_2"
export TEST_STUDY_ID TEST_PARTICIPANT_ID TEST_PARTICIPANT_ID_2
export TEST_ENROLLMENT_ACCESS_CODE TEST_ENROLLMENT_ACCESS_CODE_2

if [[ -n "${GITHUB_ENV:-}" ]]; then
  {
    printf 'TEST_STUDY_ID=%s\n' "$TEST_STUDY_ID"
    printf 'TEST_PARTICIPANT_ID=%s\n' "$TEST_PARTICIPANT_ID"
    printf 'TEST_PARTICIPANT_ID_2=%s\n' "$TEST_PARTICIPANT_ID_2"
    printf 'TEST_ENROLLMENT_ACCESS_CODE=%s\n' "$TEST_ENROLLMENT_ACCESS_CODE"
    printf 'TEST_ENROLLMENT_ACCESS_CODE_2=%s\n' "$TEST_ENROLLMENT_ACCESS_CODE_2"
  } >>"$GITHUB_ENV"
fi

echo "Synthetic study, participants, and masked one-time invitations are ready."
}

chronicle_setup_test_data
unset -f chronicle_setup_test_data request authorized_curl response_body response_code \
  require_success register_participant issue_enrollment_code mask_ci_secret abort_setup
