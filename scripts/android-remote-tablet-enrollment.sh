#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SERVER_URL="${CHRONICLE_REMOTE_SERVER_URL:-}"
STUDY_ID="${CHRONICLE_STUDY_ID:-}"
PARTICIPANT_ID="${CHRONICLE_PARTICIPANT_ID:-tablet-$(date -u +%Y%m%dT%H%M%SZ)}"
PACKAGE="${CHRONICLE_ANDROID_PACKAGE:-com.openlattice.chronicle.bcmtest.debug}"
SERIAL="${ANDROID_SERIAL:-}"
APK_PATH="${CHRONICLE_ANDROID_APK:-}"
HOST_HEADER="${CHRONICLE_REMOTE_HOST_HEADER:-}"
RUN_ADB=0
RUN_HMAC_SMOKE=0
SKIP_SERVER_CHECKS=0
EMIT_ENV_FILE=""

usage() {
  cat <<'EOF'
Usage: scripts/android-remote-tablet-enrollment.sh --server-url HTTPS_URL --study-id UUID [options]

Preflights a public HTTPS Chronicle server URL and prints the adb commands needed
to enroll a physical Android tablet that is on another network.

This script is for local BCM dogfooding/testing. It refuses HTTP because the
Android app rejects insecure enrollment URLs.

Required:
  --server-url URL       Public HTTPS base URL, e.g. https://chronicle.example.edu
  --study-id UUID        Chronicle study UUID

Options:
  --participant-id ID    Participant ID to embed in the enrollment link
                         (default: tablet-<utc timestamp>)
  --package PACKAGE      Android app id (default: com.openlattice.chronicle.bcmtest.debug)
  --serial SERIAL        adb serial for --run-adb
  --apk PATH             APK to install for --run-adb, or command to print
  --host-header HOST     Curl-only Host header for edge diagnostics
  --hmac-smoke           Run tests/security/test-hmac-enforcement.sh against URL
  --skip-server-checks   Do not curl health/study endpoints
  --emit-env FILE        Write CHRONICLE_* values for follow-up scripts
  --run-adb              Execute adb install/grant/enrollment commands now
  -h, --help             Show this help

Before scanning/running the generated link, register the participant ID in the
Chronicle web UI for the target study.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --server-url) SERVER_URL="${2:?missing --server-url value}"; shift 2 ;;
    --study-id) STUDY_ID="${2:?missing --study-id value}"; shift 2 ;;
    --participant-id) PARTICIPANT_ID="${2:?missing --participant-id value}"; shift 2 ;;
    --package) PACKAGE="${2:?missing --package value}"; shift 2 ;;
    --serial) SERIAL="${2:?missing --serial value}"; shift 2 ;;
    --apk) APK_PATH="${2:?missing --apk value}"; shift 2 ;;
    --host-header) HOST_HEADER="${2:?missing --host-header value}"; shift 2 ;;
    --hmac-smoke) RUN_HMAC_SMOKE=1; shift ;;
    --skip-server-checks) SKIP_SERVER_CHECKS=1; shift ;;
    --emit-env) EMIT_ENV_FILE="${2:?missing --emit-env value}"; shift 2 ;;
    --run-adb) RUN_ADB=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$SERVER_URL" && -f "$ROOT_DIR/docker/.env" ]]; then
  domain="$(awk -F= '/^DOMAIN=/{print substr($0,index($0,"=")+1)}' "$ROOT_DIR/docker/.env" | tail -1)"
  if [[ -n "$domain" ]]; then
    SERVER_URL="https://${domain}"
  fi
fi

SERVER_URL="${SERVER_URL%/}"

if [[ -z "$SERVER_URL" || -z "$STUDY_ID" ]]; then
  usage >&2
  exit 2
fi

if [[ ! "$SERVER_URL" =~ ^https://[^[:space:]/]+(:[0-9]+)?(/.*)?$ ]]; then
  echo "server URL must be an HTTPS URL with a host: $SERVER_URL" >&2
  exit 2
fi

if [[ ! "$STUDY_ID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
  echo "study ID must be a UUID: $STUDY_ID" >&2
  exit 2
fi

if [[ ! "$PARTICIPANT_ID" =~ ^[A-Za-z0-9._:@-]+$ ]]; then
  echo "participant ID may only contain letters, numbers, dot, underscore, colon, at-sign, or hyphen: $PARTICIPANT_ID" >&2
  exit 2
fi

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "$1 is required" >&2
    exit 1
  }
}

urlencode() {
  need_cmd node
  node -e 'process.stdout.write(encodeURIComponent(process.argv[1]))' "$1"
}

shell_escape() {
  printf '%q' "$1"
}

curl_args=()
if [[ -n "$HOST_HEADER" ]]; then
  curl_args=(-H "Host: ${HOST_HEADER}")
fi

curl_code() {
  local url="$1"
  curl -sS -o /dev/null -w '%{http_code}' --proto '=https' --tlsv1.2 "${curl_args[@]}" "$url" 2>/dev/null || echo "000"
}

if [[ "$SKIP_SERVER_CHECKS" == "0" ]]; then
  health_code="$(curl_code "${SERVER_URL}/chronicle/v3/healthz")"
  case "$health_code" in
    200) health_note="health endpoint reachable" ;;
    401|403) health_note="server reachable; health endpoint requires auth at this edge" ;;
    *)
      echo "health check failed: ${SERVER_URL}/chronicle/v3/healthz returned HTTP ${health_code}" >&2
      echo "The tablet must be able to reach this exact HTTPS URL from its home network." >&2
      exit 1
      ;;
  esac

  study_code="$(curl_code "${SERVER_URL}/chronicle/v3/study/${STUDY_ID}")"
  case "$study_code" in
    200) study_note="study endpoint reachable" ;;
    401|403) study_note="study endpoint reachable but requires researcher auth" ;;
    404) study_note="study endpoint returned 404; confirm the study exists before enrolling" ;;
    000) study_note="study endpoint could not be reached" ;;
    *) study_note="study endpoint returned HTTP ${study_code}" ;;
  esac
else
  health_code="skipped"
  health_note="server checks skipped"
  study_code="skipped"
  study_note="server checks skipped"
fi

encoded_study_id="$(urlencode "$STUDY_ID")"
encoded_participant_id="$(urlencode "$PARTICIPANT_ID")"
encoded_server_url="$(urlencode "$SERVER_URL")"
enrollment_uri="chronicle://enroll?studyId=${encoded_study_id}&participantId=${encoded_participant_id}&serverUrl=${encoded_server_url}"

if [[ "$RUN_HMAC_SMOKE" == "1" ]]; then
  BASE_URL="$SERVER_URL" \
    HOST_HEADER="$HOST_HEADER" \
    TEST_STUDY_ID="$STUDY_ID" \
    TEST_PARTICIPANT_ID="$PARTICIPANT_ID" \
    TEST_DEVICE_ID="remote-tablet-preflight" \
    "$ROOT_DIR/tests/security/test-hmac-enforcement.sh"
fi

if [[ -n "$EMIT_ENV_FILE" ]]; then
  umask 077
  {
    printf 'export CHRONICLE_REMOTE_SERVER_URL=%s\n' "$(shell_escape "$SERVER_URL")"
    printf 'export CHRONICLE_STUDY_ID=%s\n' "$(shell_escape "$STUDY_ID")"
    printf 'export CHRONICLE_PARTICIPANT_ID=%s\n' "$(shell_escape "$PARTICIPANT_ID")"
    printf 'export CHRONICLE_ANDROID_PACKAGE=%s\n' "$(shell_escape "$PACKAGE")"
  } > "$EMIT_ENV_FILE"
  if [[ -n "$SERIAL" ]]; then
    printf 'export ANDROID_SERIAL=%s\n' "$(shell_escape "$SERIAL")" >> "$EMIT_ENV_FILE"
  fi
fi

adb_prefix='adb'
if [[ -n "$SERIAL" ]]; then
  adb_prefix="adb -s ${SERIAL}"
fi

cat <<EOF
Remote Android tablet enrollment preflight
server_url=${SERVER_URL}
study_id=${STUDY_ID}
participant_id=${PARTICIPANT_ID}
package=${PACKAGE}
health=${health_code} (${health_note})
study=${study_code} (${study_note})

1. Register this participant in Chronicle web first:
   ${PARTICIPANT_ID}

2. On the home computer, verify adb sees the tablet:
   adb devices -l

3. Install the debug APK if needed:
   ${adb_prefix} install -r ${APK_PATH:-chronicle/app/build/outputs/apk/debug/app-debug.apk}

4. Grant usage-stats app-op when Android allows shell to do it:
   ${adb_prefix} shell appops set ${PACKAGE} GET_USAGE_STATS allow

5. Start enrollment on the tablet:
   ${adb_prefix} shell am start -W -a android.intent.action.VIEW -d '${enrollment_uri}' ${PACKAGE}

6. Optional: shorten debug sync cadence and run one sync immediately:
   ${adb_prefix} shell am broadcast -n ${PACKAGE}/com.openlattice.chronicle.debug.DebugSyncConfigReceiver \\
     -a com.openlattice.chronicle.debug.SET_SYNC_CONFIG \\
     --es strategy coordinated_collect_then_upload \\
     --el interval_minutes 15 \\
     --ez run_now true \\
     --ez reschedule true

7. Optional: collect a redacted debug bundle after testing:
   CHRONICLE_REMOTE_SERVER_URL='${SERVER_URL}' scripts/android-debug-bundle.sh \\
     --package ${PACKAGE} \\
     --study-id ${STUDY_ID} \\
     --participant-id ${PARTICIPANT_ID}
EOF

if [[ "$RUN_ADB" == "1" ]]; then
  ADB_BIN="${ADB:-adb}"
  adb_cmd=("$ADB_BIN")
  if [[ -n "$SERIAL" ]]; then
    adb_cmd+=("-s" "$SERIAL")
  fi
  if [[ -n "$APK_PATH" ]]; then
    "${adb_cmd[@]}" install -r "$APK_PATH"
  fi
  "${adb_cmd[@]}" shell appops set "$PACKAGE" GET_USAGE_STATS allow || true
  "${adb_cmd[@]}" shell am start -W \
    -a android.intent.action.VIEW \
    -d "$enrollment_uri" \
    "$PACKAGE"
fi
