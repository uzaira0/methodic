#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ANDROID_DIR="$ROOT_DIR/chronicle"
APP_DIR="$ANDROID_DIR/app"
REPORT_DIR="${1:-$ROOT_DIR/tests/security/reports}"
REQUIRE_SIGNING_SECRET="${CHRONICLE_REQUIRE_MOBILE_SIGNING_SECRET:-0}"

mkdir -p "$REPORT_DIR"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "PASS: $*"
}

require_file_contains() {
  local file="$1"
  local pattern="$2"
  local description="$3"
  if ! grep -Eq -- "$pattern" "$file"; then
    fail "$description"
  fi
  pass "$description"
}

echo "=== Chronicle mobile upload guardrails ==="

REMOTE_ENROLLMENT_HELPER="$ROOT_DIR/scripts/android-remote-tablet-enrollment.sh"
require_file_contains "$REMOTE_ENROLLMENT_HELPER" \
  'enrollment_uri="\$\{SERVER_URL\}/chronicle/enroll\?.*#accessCode=' \
  "Remote-tablet helper uses the HTTPS fragment invitation contract"
if grep -Fq 'chronicle://enroll' "$REMOTE_ENROLLMENT_HELPER"; then
  fail "Remote-tablet helper must not construct obsolete custom-scheme invitations"
fi
require_file_contains "$REMOTE_ENROLLMENT_HELPER" \
  'access-code file must not grant group or other permissions' \
  "Remote-tablet helper protects one-time invitation input"
require_file_contains "$REMOTE_ENROLLMENT_HELPER" \
  "printf '%s\\\\n' \"\\\$enrollment_uri\".*\\|" \
  "Remote-tablet helper delivers the capability to adb over stdin"
if grep -Eq -- '-d "\$enrollment_uri"' "$REMOTE_ENROLLMENT_HELPER"; then
  fail "Remote-tablet helper must not expose the one-time capability in host process arguments"
fi

enrollment_helper_tmp="$(mktemp -d)"
trap 'rm -rf -- "$enrollment_helper_tmp"' EXIT
enrollment_code_file="$enrollment_helper_tmp/access-code"
python3 - "$enrollment_code_file" <<'PY'
import sys
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    handle.write("A" * 40 + "\n")
PY
chmod 600 "$enrollment_code_file"
enrollment_helper_output="$($REMOTE_ENROLLMENT_HELPER \
  --server-url https://study.example.org \
  --study-id 11111111-2222-4333-8444-555555555555 \
  --participant-id security-regression \
  --access-code-file "$enrollment_code_file" \
  --skip-server-checks)"
if grep -Eq 'A{32}|#accessCode=|chronicle://enroll' <<<"$enrollment_helper_output"; then
  fail "Remote-tablet helper must not print the one-time credential or complete invitation"
fi
pass "Remote-tablet helper keeps the one-time invitation out of command output"

fake_adb="$enrollment_helper_tmp/adb"
adb_contract_marker="$enrollment_helper_tmp/adb-contract-ok"
python3 - "$fake_adb" <<'PY'
import os
import sys

path = sys.argv[1]
script = r'''#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *" shell appops set "* ]]; then
  exit 0
fi
[[ "${1:-}" == shell && "${2:-}" == *"read -r invitation"* ]] || exit 10
[[ "$*" != *"#accessCode="* ]] || exit 13
IFS= read -r invitation
[[ "$invitation" == https://study.example.org/chronicle/enroll\?studyId=11111111-2222-4333-8444-555555555555\&participantId=security-regression#accessCode=* ]] || exit 11
: > "${ADB_CONTRACT_MARKER:?}"
'''
with open(path, "w", encoding="utf-8") as handle:
    handle.write(script)
os.chmod(path, 0o700)
PY
adb_helper_output="$(ADB="$fake_adb" ADB_CONTRACT_MARKER="$adb_contract_marker" \
  "$REMOTE_ENROLLMENT_HELPER" \
  --server-url https://study.example.org \
  --study-id 11111111-2222-4333-8444-555555555555 \
  --participant-id security-regression \
  --access-code-file "$enrollment_code_file" \
  --skip-server-checks \
  --run-adb)"
[[ -f "$adb_contract_marker" ]] || fail "Remote-tablet helper did not open the expected HTTPS invitation"
if grep -Eq 'A{32}|#accessCode=' <<<"$adb_helper_output"; then
  fail "Remote-tablet adb execution printed the one-time invitation credential"
fi
pass "Remote-tablet adb execution opens the arbitrary HTTPS origin without argv/output credential exposure"

if "$REMOTE_ENROLLMENT_HELPER" \
  --server-url https://study.example.org/chronicle \
  --study-id 11111111-2222-4333-8444-555555555555 \
  --participant-id security-regression \
  --access-code-file "$enrollment_code_file" \
  --skip-server-checks >/dev/null 2>&1; then
  fail "Remote-tablet helper must reject a non-root public URL"
fi
chmod 644 "$enrollment_code_file"
if "$REMOTE_ENROLLMENT_HELPER" \
  --server-url https://study.example.org \
  --study-id 11111111-2222-4333-8444-555555555555 \
  --participant-id security-regression \
  --access-code-file "$enrollment_code_file" \
  --skip-server-checks >/dev/null 2>&1; then
  fail "Remote-tablet helper must reject an access-code file visible to other users"
fi
pass "Remote-tablet helper rejects non-root origins and overexposed code files"

MAESTRO_RUNNER="$ROOT_DIR/tests/maestro/maestro-run-emulator.sh"
MAESTRO_CONFIG="$ROOT_DIR/.maestro/config.yaml"
MAESTRO_SMOKE_FLOW="$ROOT_DIR/.maestro/smoke.yaml"
MAESTRO_SETUP="$ROOT_DIR/.maestro/setup-test-data.sh"
MAESTRO_ENROLLMENT_FLOW="$ROOT_DIR/.maestro/flows/01_enrollment.yaml"
MAESTRO_ARTIFACT_ENROLLMENT_FLOW="$ROOT_DIR/.maestro/artifact/01_enrollment_after_external_link.yaml"
MAESTRO_MINIMAL_CORE_ARTIFACT_FLOW="$ROOT_DIR/.maestro/artifact/05_minimal_core_enrollment_after_external_link.yaml"
MAESTRO_UNLOCK_ARTIFACT_FLOW="$ROOT_DIR/.maestro/artifact/06_enable_unlock_identification.yaml"
MAESTRO_UNLOCK_PROMPT_ARTIFACT_FLOW="$ROOT_DIR/.maestro/artifact/07_unlock_identification_prompt.yaml"
MAESTRO_OFFLINE_ARTIFACT_FLOW="$ROOT_DIR/.maestro/artifact/08_offline_queue.yaml"
MAESTRO_RETRY_ARTIFACT_FLOW="$ROOT_DIR/.maestro/artifact/09_retry_drain.yaml"
MAESTRO_NOTIFICATION_DENIAL_FLOW="$ROOT_DIR/.maestro/artifact/10_unlock_notification_denial.yaml"
MAESTRO_NOTIFICATION_RECOVERY_FLOW="$ROOT_DIR/.maestro/artifact/11_unlock_notification_recovery.yaml"
MAESTRO_SECOND_INVITATION_FLOW="$ROOT_DIR/.maestro/flows/03_second_invitation_rejected.yaml"
MAESTRO_SETTINGS_FLOW="$ROOT_DIR/.maestro/flows/02_settings.yaml"
MAESTRO_SINGLE_SERVER_FLOW="$ROOT_DIR/.maestro/flows/04_single_server.yaml"

require_file_contains "$MAESTRO_SETUP" \
  'candidate: \{id: "00000000-0000-0000-0000-000000000000"\}' \
  "Maestro participant setup uses the current id-only Candidate contract"
for minimal_module in usage_events device_lifecycle user_identification battery_telemetry upload_telemetry; do
  require_file_contains "$MAESTRO_SETUP" \
    "\"${minimal_module}\"" \
    "Maestro minimal-core profile includes ${minimal_module}"
done
require_file_contains "$MAESTRO_SETUP" \
  'TEST_MODULE_PROFILE:-battery_only' \
  "Maestro keeps its short CI profile as the default"
if grep -Eq 'candidate: \{[^}]*firstName|candidate: \{[^}]*lastName' "$MAESTRO_SETUP"; then
  fail "Maestro participant setup must not send retired Candidate profile fields"
fi

if [[ -e "$ROOT_DIR/.maestro/flows/03_reenrollment.yaml" ||
      -e "$ROOT_DIR/.maestro/flows/04_multi_server.yaml" ]] ||
   grep -Rqi 'multi-server' "$ROOT_DIR/.maestro"; then
  fail "Maestro must enforce the one-active-study/server product contract"
fi
[[ -f "$ROOT_DIR/.maestro/flows/04_single_server.yaml" ]] ||
  fail "Maestro single-server settings flow is missing"
[[ -f "$MAESTRO_SECOND_INVITATION_FLOW" ]] ||
  fail "Maestro second-invitation rejection flow is missing"
if grep -Eq '10\.0\.2\.2|SERVER_URL="?http:|usesCleartextTraffic.*sed|google-services\.json' \
  "$ROOT_DIR/.maestro/config.yaml"; then
  fail "Maestro must not weaken the production HTTPS/origin contract"
fi
require_file_contains "$MAESTRO_RUNNER" \
  'adb reverse tcp:8443 tcp:8443' \
  "Maestro reverses the exact HTTPS port into the emulator"
require_file_contains "$MAESTRO_RUNNER" \
  '/data/misc/user/0/cacerts-added' \
  "Maestro installs its ephemeral CA in the debug-only user trust store before Android 14"
require_file_contains "$ROOT_DIR/chronicle/app/src/debug/res/xml/debug_network_security_config.xml" \
  '<debug-overrides>' \
  "Android debug builds explicitly scope user-CA trust to debuggable artifacts"
require_file_contains "$MAESTRO_RUNNER" \
  '/apex/com\.android\.conscrypt/cacerts' \
  "Maestro installs its ephemeral CA in the Android 14+ Conscrypt store"
require_file_contains "$MAESTRO_RUNNER" \
  'nsenter --mount="/proc/\$\{process_pid\}/ns/mnt"' \
  "Maestro installs the Android 14+ CA in the app-inherited zygote namespace"
require_file_contains "$MAESTRO_RUNNER" \
  'wait_for_android_services 10' \
  "Maestro waits for a sustained API 23 system-server stability window"
require_file_contains "$MAESTRO_RUNNER" \
  'service check package' \
  "Maestro verifies the legacy package manager before starting its driver"
require_file_contains "$MAESTRO_RUNNER" \
  'adb shell ps' \
  "Maestro reads the API 23-compatible process table"
require_file_contains "$MAESTRO_RUNNER" \
  "awk '\\\$NF == \"system_server\" \{ print \\\$2 \}'" \
  "Maestro finds system_server without relying on unavailable API 23 pidof"
require_file_contains "$MAESTRO_RUNNER" \
  'run_minimum_sdk_startup_smoke' \
  "API 23 uses a transport-independent minimum-SDK startup proof"
require_file_contains "$MAESTRO_RUNNER" \
  'monkey -p "\$APP_PACKAGE" -c android\.intent\.category\.LAUNCHER 1' \
  "API 23 launches the installed package through its declared launcher"
require_file_contains "$MAESTRO_RUNNER" \
  'package="\$APP_PACKAGE".*\$NF == package' \
  "API 23 requires the Chronicle process to remain alive"
require_file_contains "$MAESTRO_RUNNER" \
  'package=\\"\$\{APP_PACKAGE\}\\"' \
  "API 23 binds the visible UI hierarchy to Chronicle"
require_file_contains "$MAESTRO_RUNNER" \
  'Unable to launch app \$\{APP_PACKAGE\}: am force-stop \$\{APP_PACKAGE\}' \
  "Maestro recognizes only the exact pre-flow app-launch transport failure"
require_file_contains "$MAESTRO_RUNNER" \
  'tests="1" failures="1"' \
  "Maestro constrains app-launch retry to a one-test pre-flow result"
require_file_contains "$MAESTRO_RUNNER" \
  '<failure>Unknown error</failure>' \
  "Maestro recognizes the opaque pre-flow driver transport failure"
require_file_contains "$MAESTRO_RUNNER" \
  'dumpsys window windows.*grep -Fq "\$APP_PACKAGE"' \
  "Maestro retries an opaque failure only when Chronicle never acquired a window"
if [[ "$(grep -Fc 'configure_reverse_proxy' "$MAESTRO_RUNNER")" -lt 3 ]]; then
  fail "Maestro must define, initially apply, and restore its HTTPS reverse port around a safe retry"
fi
pass "Maestro restores its verified HTTPS reverse port before retrying a pre-flow driver loss"
require_file_contains "$MAESTRO_RUNNER" \
  'timeout --foreground --signal=TERM --kill-after=30s 12m' \
  "Maestro bounds each flow attempt while preserving in-script failure evidence"
require_file_contains "$MAESTRO_RUNNER" \
  'current_uid="\$\(timeout 10s adb shell id -u' \
  "Maestro avoids restarting adbd when the disposable emulator is already rooted"
require_file_contains "$MAESTRO_RUNNER" \
  'root_result="\$\(timeout 30s adb root' \
  "Maestro bounds the adbd root transition"
require_file_contains "$MAESTRO_RUNNER" \
  'wait_for_adb_device "adb root restart"' \
  "Maestro bounds and identifies an adbd root reconnect failure"
require_file_contains "$MAESTRO_RUNNER" \
  'timeout 10s adb reconnect offline' \
  "Maestro attempts bounded recovery from an offline emulator transport"
require_file_contains "$MAESTRO_RUNNER" \
  'MAESTRO_CLI_NO_ANALYTICS=1' \
  "Maestro disables unrelated CLI analytics during the isolated egress test"
require_file_contains "$MAESTRO_RUNNER" \
  'cannot install the ephemeral CA noninteractively' \
  "Maestro fails explicitly when a disposable emulator cannot install the CA"
require_file_contains "$MAESTRO_RUNNER" \
  '--env APP_PACKAGE="\$APP_PACKAGE"' \
  "Maestro binds resource identifiers to the exact installed package"
require_file_contains "$MAESTRO_RUNNER" \
  '--env API_LEVEL="\$API_LEVEL"' \
  "Maestro exposes the tested API level to lifecycle decisions"
require_file_contains "$MAESTRO_RUNNER" \
  '^[[:space:]]+\.maestro/ 2>&1 \| tee "\$log_file"$' \
  "Maestro runs the configured workspace instead of bypassing it"
require_file_contains "$MAESTRO_CONFIG" \
  '^[[:space:]]+- "smoke\.yaml"$' \
  "Maestro workspace discovers only the continuous smoke journey"
expected_maestro_flow_order=$'flows/01_enrollment.yaml\nflows/02_settings.yaml\nflows/03_second_invitation_rejected.yaml\nflows/04_single_server.yaml'
actual_maestro_flow_order="$(
  sed -n 's/^[[:space:]]*-[[:space:]]*runFlow:[[:space:]]*//p' "$MAESTRO_SMOKE_FLOW"
)"
[[ "$actual_maestro_flow_order" == "$expected_maestro_flow_order" ]] ||
  fail "Maestro smoke journey must preserve the enrollment-dependent nested-flow order"
pass "Maestro preserves one continuous enrollment-dependent smoke journey"
for main_tab_flow in "$MAESTRO_SETTINGS_FLOW" "$MAESTRO_SINGLE_SERVER_FLOW"; do
  require_file_contains "$main_tab_flow" \
    ':id/nav_overview"' \
    "Maestro returns from the main tab shell through Overview"
done
require_file_contains "$MAESTRO_SINGLE_SERVER_FLOW" \
  ':id/settingsServerSummary"' \
  "Maestro verifies the read-only active server summary"
require_file_contains "$MAESTRO_SINGLE_SERVER_FLOW" \
  'text: "\(\?s\)\.\*\$\{SERVER_URL\}\.\*"' \
  "Maestro binds the visible server identity to the exact enrollment origin"
for forbidden_server_control in settingsServerList openServerSettingsButton addServerSettingsButton; do
  require_file_contains "$MAESTRO_SINGLE_SERVER_FLOW" \
    "assertNotVisible:" \
    "Maestro asserts that Play server mutation controls are absent"
  require_file_contains "$MAESTRO_SINGLE_SERVER_FLOW" \
    ":id/${forbidden_server_control}\"" \
    "Maestro covers hidden Play server control ${forbidden_server_control}"
done
pass "Maestro proves the Play server identity is read-only"
if grep -Fq '⚙ Edit configuration' "$MAESTRO_SINGLE_SERVER_FLOW"; then
  fail "Maestro single-server flow references retired settings copy"
fi
pass "Maestro single-server flow avoids retired settings copy"
if grep -Eq '^[[:space:]]*-[[:space:]]*pressKey:[[:space:]]*back' "$MAESTRO_SETTINGS_FLOW"; then
  fail "Maestro settings flow must not use Android Back to leave the main tab shell"
fi
pass "Maestro settings flow respects the main-shell Back-to-Home contract"
require_file_contains "$MAESTRO_RUNNER" \
  'uiautomator dump /data/local/tmp/chronicle-maestro-ui\.xml' \
  "Maestro captures the live failure UI before the emulator is destroyed"
require_file_contains "$MAESTRO_RUNNER" \
  'logcat -d > "failure-screenshots/logcat-api\$\{API_LEVEL\}\.txt"' \
  "Maestro captures live failure logs before the emulator is destroyed"
if rg -q 'com\.bcm\.chronicle\.debug' "$ROOT_DIR/.maestro"; then
  fail "Maestro flows must not be hardcoded to the debug package"
fi
require_file_contains "$MAESTRO_ENROLLMENT_FLOW" \
  '^appId: \$\{APP_PACKAGE\}$' \
  "Maestro enrollment can exercise the exact release package"
require_file_contains "$MAESTRO_ENROLLMENT_FLOW" \
  'visible: "Battery Optimization"' \
  "Maestro waits for the asynchronous first-run battery dialog"
if sed -n '/text: "CANCEL"/,+1p' "$MAESTRO_ENROLLMENT_FLOW" | grep -q 'optional: true'; then
  fail "Maestro must not race the required first-run battery dialog with an optional tap"
fi
pass "Maestro requires the first-run battery dialog dismissal"
require_file_contains "$MAESTRO_ENROLLMENT_FLOW" \
  'true: \$\{parseInt\(API_LEVEL\) >= 30\}' \
  "Maestro gates the Android 11 app-hibernation decision by API level"
require_file_contains "$MAESTRO_ENROLLMENT_FLOW" \
  'visible: "Keep Chronicle Active"' \
  "Maestro waits for the asynchronous app-hibernation dialog"
require_file_contains "$MAESTRO_ARTIFACT_ENROLLMENT_FLOW" \
  '^appId: \$\{APP_PACKAGE\}$' \
  "Maestro has an exact-package post-dispatch artifact enrollment flow"
require_file_contains "$MAESTRO_MINIMAL_CORE_ARTIFACT_FLOW" \
  '^appId: \$\{APP_PACKAGE\}$' \
  "Maestro has an exact-package minimal-core enrollment flow"
if grep -Eq 'openLink|accessCode|TEST_ENROLLMENT_ACCESS_CODE' \
  "$MAESTRO_ARTIFACT_ENROLLMENT_FLOW" "$MAESTRO_MINIMAL_CORE_ARTIFACT_FLOW"; then
  fail "Artifact enrollment must receive its invitation from the guarded adb stdin helper"
fi
minimal_core_consent_actions="$(rg -c ':id/orientationAccept"' "$MAESTRO_MINIMAL_CORE_ARTIFACT_FLOW")"
if [[ "$minimal_core_consent_actions" != "8" ]]; then
  fail "Minimal-core artifact enrollment must wait for and accept all four required consent steps"
fi
pass "Minimal-core artifact enrollment explicitly accepts all four required consent steps"
require_file_contains "$MAESTRO_UNLOCK_ARTIFACT_FLOW" \
  ':id/identifyUserSwitch"' \
  "Exact-artifact coverage enables unlock identification through the participant control"
require_file_contains "$MAESTRO_UNLOCK_ARTIFACT_FLOW" \
  'Active: Chronicle will show the device-user prompt after unlock\.' \
  "Exact-artifact coverage verifies unlock identification is visibly active"
require_file_contains "$MAESTRO_UNLOCK_PROMPT_ARTIFACT_FLOW" \
  'Please select current user:' \
  "Exact-artifact coverage handles the choice screen opened from the private notification"
require_file_contains "$MAESTRO_UNLOCK_PROMPT_ARTIFACT_FLOW" \
  ':id/child_user_btn"' \
  "Exact-artifact coverage records a synthetic target-user choice"
bash -n "$ROOT_DIR/.maestro/artifact/open-unlock-notification.sh"
require_file_contains "$ROOT_DIR/.maestro/artifact/open-unlock-notification.sh" \
  'KEYCODE_POWER' \
  "Exact-artifact unlock coverage exercises a real screen-off/screen-on cycle"
require_file_contains "$ROOT_DIR/.maestro/artifact/open-unlock-notification.sh" \
  'com\.openlattice\.chronicle\.private\.identify-user' \
  "Exact-artifact unlock coverage requires the private identification notification"
if grep -Eq 'am[[:space:]]+start.*UserIdentificationActivity' \
  "$ROOT_DIR/.maestro/artifact/open-unlock-notification.sh"; then
  fail "Unlock artifact coverage must open the posted notification, not start its activity directly"
fi
pass "Exact-artifact unlock coverage opens the posted notification without bypassing it"
require_file_contains "$MAESTRO_OFFLINE_ARTIFACT_FLOW" \
  '\[1-9\]\[0-9\]\*\\\\nremaining to upload' \
  "Exact-artifact coverage requires a durable nonempty queue while the server is offline"
require_file_contains "$MAESTRO_RETRY_ARTIFACT_FLOW" \
  '0\\\\nremaining to upload' \
  "Exact-artifact coverage requires the queue to drain after server recovery"
require_file_contains "$MAESTRO_RETRY_ARTIFACT_FLOW" \
  'Failed attempts: usage/lifecycle \[1-9\]\[0-9\]\*' \
  "Exact-artifact coverage requires a recovered upload failure to remain visible"
require_file_contains "$MAESTRO_NOTIFICATION_DENIAL_FLOW" \
  'Paused: notifications are disabled' \
  "Exact-artifact coverage verifies unlock identification visibly pauses after denial"
require_file_contains "$MAESTRO_NOTIFICATION_DENIAL_FLOW" \
  'Allow Chronicle notifications' \
  "Exact-artifact coverage verifies notification recovery guidance after denial"
require_file_contains "$MAESTRO_NOTIFICATION_RECOVERY_FLOW" \
  'Active: Chronicle will show the device-user prompt after unlock\.' \
  "Exact-artifact coverage verifies unlock identification resumes after permission recovery"
for current_dashboard_id in overviewStudyId overviewParticipantId overviewLastUpload; do
  printf -v current_dashboard_pattern 'id: "\$\{APP_PACKAGE\}:id/%s"' "$current_dashboard_id"
  require_file_contains "$MAESTRO_ARTIFACT_ENROLLMENT_FLOW" \
    "$current_dashboard_pattern" \
    "Artifact enrollment asserts current dashboard id ${current_dashboard_id}"
done
if rg -q ':id/(studyId|participantId|lastUploadHeader|action_settings)"' "$ROOT_DIR/.maestro"; then
  fail "Maestro flows reference retired dashboard resource IDs"
fi
require_file_contains "$MAESTRO_ENROLLMENT_FLOW" \
  'chronicle://enroll\?.*#accessCode=\$\{TEST_ENROLLMENT_ACCESS_CODE\}' \
  "Maestro enrolls with a fragment-only one-time capability"
require_file_contains "$MAESTRO_SECOND_INVITATION_FLOW" \
  '#accessCode=\$\{TEST_ENROLLMENT_ACCESS_CODE_2\}' \
  "Maestro opens a distinct second one-time invitation"
require_file_contains "$MAESTRO_SECOND_INVITATION_FLOW" \
  'This device already has an active Chronicle study\. Withdraw from it before opening another study invitation\.' \
  "Maestro asserts the one-active-study rejection"
require_file_contains "$MAESTRO_SECOND_INVITATION_FLOW" \
  ':id/overviewParticipantId"' \
  "Maestro binds retained-participant evidence to the participant card"
require_file_contains "$MAESTRO_SECOND_INVITATION_FLOW" \
  'text: "\(\?s\)\.\*\$\{TEST_PARTICIPANT_ID\}\.\*"' \
  "Maestro matches the retained participant inside its multiline accessibility node"
require_file_contains "$MAESTRO_SETUP" \
  'AUTH_TOKEN_FILE:\?AUTH_TOKEN_FILE is required' \
  "Maestro seeding requires a private one-use authentication token file"
require_file_contains "$MAESTRO_SETUP" \
  'export -n AUTH_TOKEN_FILE' \
  "Maestro seeding removes the token-file path from child-process environments"
require_file_contains "$MAESTRO_SETUP" \
  'curl --config -' \
  "Maestro seeding sends the administrator header over curl configuration stdin"
require_file_contains "$MAESTRO_SETUP" \
  'rm -f --.*AUTH_TOKEN_FILE_VALUE' \
  "Maestro seeding deletes the private token transport before API helpers run"
require_file_contains "$MAESTRO_SETUP" \
  'GITHUB_ACTIONS:-false.*==.*true' \
  "Maestro seeding prints add-mask commands only inside GitHub Actions"
if grep -Eq -- '-H[[:space:]]+"Authorization: Bearer.*AUTH_TOKEN' "$MAESTRO_SETUP"; then
  fail "Maestro seeding must not expose the administrator token in curl argv"
fi
if grep -Eq 'eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}' "$MAESTRO_SETUP"; then
  fail "Maestro seeding must not retain a JWT in source"
fi
plain_http_auth_dir="$enrollment_helper_tmp/plain-http-auth"
mkdir -m 700 "$plain_http_auth_dir"
plain_http_auth_file="$plain_http_auth_dir/admin.jwt"
(umask 077; printf '%s\n' 'header.payload.signature' >"$plain_http_auth_file")
chmod 600 "$plain_http_auth_file"
if SERVER_URL=http://127.0.0.1:40320 AUTH_TOKEN_FILE="$plain_http_auth_file" \
  bash -c 'source "$1"' _ "$MAESTRO_SETUP" >/dev/null 2>&1; then
  fail "Maestro seeding must reject a plain-HTTP server origin"
fi
[[ ! -e "$plain_http_auth_file" ]] ||
  fail "Maestro plain-HTTP rejection fixture did not consume its one-use token file"
pass "Maestro seeding rejects plain HTTP after consuming a valid private token fixture"

if find "$APP_DIR/libs" -type f -name '*.jar' 2>/dev/null | grep -q .; then
  find "$APP_DIR/libs" -type f -name '*.jar' >&2
  fail "Android app/libs must not contain local jars; they can shadow local chronicle-models changes"
fi
pass "No Android app/libs jar shadowing"

if grep -Eq "implementation[[:space:]]+fileTree\\([^)]*libs" "$APP_DIR/build.gradle"; then
  fail "Android build must not use implementation fileTree(dir: 'libs')"
fi
pass "Android build does not depend on app/libs fileTree"

require_file_contains "$APP_DIR/build.gradle" "readDockerEnvValue\\('MOBILE_SIGNING_SECRET'\\)" \
  "Debug builds can read MOBILE_SIGNING_SECRET from Docker env files"
require_file_contains "$APP_DIR/build.gradle" "com\\.openlattice:chronicle-models:0\\.1\\.0-SNAPSHOT" \
  "Android app uses local chronicle-models snapshot"

IOS_CONFIG_GENERATOR="$ROOT_DIR/chronicle-ios/scripts/generate-ios-config.sh"
require_file_contains "$IOS_CONFIG_GENERATOR" '^umask 077$' \
  "iOS secret config generator uses a private umask"
require_file_contains "$IOS_CONFIG_GENERATOR" 'chmod 600 "\$tmp_file"' \
  "iOS secret config generator enforces mode 0600"
require_file_contains "$IOS_CONFIG_GENERATOR" 'mv -f -- "\$tmp_file" "\$out_file"' \
  "iOS secret config generator installs config atomically"
ios_local_config="$ROOT_DIR/chronicle-ios/chronicle/Config/Chronicle.local.xcconfig"
if [[ -f "$ios_local_config" ]]; then
  ios_config_mode="$(stat -c '%a' "$ios_local_config" 2>/dev/null || stat -f '%Lp' "$ios_local_config")"
  [[ "$ios_config_mode" == "600" ]] || fail "Generated iOS secret config must have mode 0600"
fi
pass "Generated iOS secret config, when present, has mode 0600"

if [[ "${CHRONICLE_SKIP_ANDROID_BUILD:-0}" == "1" && "$REQUIRE_SIGNING_SECRET" == "1" ]]; then
  fail "Android build verification cannot be skipped when the mobile signing secret is required"
fi

if [[ "${CHRONICLE_SKIP_ANDROID_BUILD:-0}" != "1" ]]; then
  (
    cd "$ANDROID_DIR"
    gradle_tasks=(:app:generateResearchDebugBuildConfig)
    if [[ "$REQUIRE_SIGNING_SECRET" == "1" ]]; then
      gradle_tasks=(:app:verifyMobileSigningSecret "${gradle_tasks[@]}")
    fi
    ./gradlew "${gradle_tasks[@]}" --quiet
  )

  build_config="$APP_DIR/build/generated/source/buildConfig/research/debug/com/openlattice/chronicle/BuildConfig.java"
  [[ -n "$build_config" ]] || fail "Generated BuildConfig was not found"
  [[ -f "$build_config" ]] || fail "Generated research debug BuildConfig was not found"

  if [[ "$REQUIRE_SIGNING_SECRET" == "1" ]]; then
    if grep -Eq 'MOBILE_SIGNING_SECRET = ""' "$build_config"; then
      fail "Generated BuildConfig has an empty MOBILE_SIGNING_SECRET"
    fi
    if grep -Eiq 'MOBILE_SIGNING_SECRET = ".*(change_me|changeme|placeholder|replace_me|example).*"' "$build_config"; then
      fail "Generated BuildConfig has a placeholder MOBILE_SIGNING_SECRET"
    fi
    pass "Generated BuildConfig has a production-strength non-placeholder MOBILE_SIGNING_SECRET"
  fi
fi

# Phase 10 split the usage collector into the :collection-usage Gradle module.
require_file_contains "$ANDROID_DIR/collection-usage/src/main/java/com/openlattice/chronicle/sensors/UsageEventsChronicleSensor.kt" \
  "activityClass[[:space:]]*=[[:space:]]*it\\.className" \
  "UsageEvents collector preserves Android activity class"
require_file_contains "$APP_DIR/src/main/java/com/openlattice/chronicle/services/upload/UploadExecutor.kt" \
  "datum\\.activityClass" \
  "Upload mapper forwards activity class to ChronicleUsageEvent"
require_file_contains "$ROOT_DIR/chronicle-models/src/main/kotlin/com/openlattice/chronicle/android/ChronicleUsageEvent.kt" \
  "activityClass" \
  "Shared ChronicleUsageEvent DTO contains activityClass"
require_file_contains "$ROOT_DIR/chronicle-server/src/main/resources/db/migration/V22__add_usage_event_activity_class.sql" \
  "activity_class" \
  "Postgres migration adds activity_class"

if find "$ANDROID_DIR" -type f \( \
    -name 'google-services.json' -o \
    -name 'GoogleService-Info.plist' -o \
    -iname '*firebase*' \
  \) 2>/dev/null | grep -q .; then
  find "$ANDROID_DIR" -type f \( \
    -name 'google-services.json' -o \
    -name 'GoogleService-Info.plist' -o \
    -iname '*firebase*' \
  \) >&2
  fail "Android app must not include Firebase config files or Firebase-named source files"
fi
pass "Android app has no Firebase config/source files"

if rg -n \
  'com\.google\.gms\.google-services|com\.google\.firebase|firebase-(analytics|crashlytics|messaging)|Firebase[A-Za-z]+|FirebaseMessagingService' \
  "$ANDROID_DIR" \
  --glob '!**/build/**' \
  --glob '!**/.gradle/**' \
  --glob '!**/schemas/**' >/dev/null; then
  rg -n \
    'com\.google\.gms\.google-services|com\.google\.firebase|firebase-(analytics|crashlytics|messaging)|Firebase[A-Za-z]+|FirebaseMessagingService' \
    "$ANDROID_DIR" \
    --glob '!**/build/**' \
    --glob '!**/.gradle/**' \
    --glob '!**/schemas/**' >&2
  fail "Android app must not compile Firebase SDKs or call Firebase APIs"
fi
pass "Android app has no Firebase SDK dependencies or API calls"

require_file_contains "$APP_DIR/src/debug/AndroidManifest.xml" \
  'android:name="\.debug\.DebugSyncConfigReceiver"' \
  "Android debug automation receiver is explicitly declared"
require_file_contains "$APP_DIR/src/debug/AndroidManifest.xml" \
  'android:permission="android\.permission\.DUMP"' \
  "Android debug automation receiver is restricted to ADB/system callers"
require_file_contains "$APP_DIR/src/main/java/com/openlattice/chronicle/api/ChronicleStudyApi.kt" \
  '@POST\(V4_BASE \+ STUDY_ID_PATH \+ PARTICIPANT_PATH \+ PARTICIPANT_ID_PATH \+ "/reminders"\)' \
  "Android treats reminder reconciliation as a state-changing request"
require_file_contains "$ROOT_DIR/chronicle-server/src/main/kotlin/com/openlattice/chronicle/controllers/MobileReminderController.kt" \
  '@PostMapping\(' \
  "Server reminder reconciliation is a POST handler"
require_file_contains "$ROOT_DIR/chronicle-server/src/main/kotlin/com/openlattice/chronicle/controllers/MobileReminderController.kt" \
  '"/chronicle/v4/study/\{studyId\}/participant/\{participantId\}/reminders"' \
  "Server reminder reconciliation uses POST while rotating access codes"
if grep -Eq '@GET\(.*PARTICIPANT_ID_PATH.*"/reminders"' \
  "$APP_DIR/src/main/java/com/openlattice/chronicle/api/ChronicleStudyApi.kt"; then
  fail "Android reminder reconciliation must not use cacheable GET semantics"
fi
pass "Android reminder reconciliation has no GET mapping"
if ! awk '
  /android:name="\.receivers\.lifecycle\.SurveyNotificationsReceiver"/ { receiver = 1 }
  receiver && /android:exported="false"/ { protected = 1 }
  receiver && /\/>/ { exit(protected ? 0 : 1) }
  END { if (!protected) exit 1 }
' "$APP_DIR/src/main/AndroidManifest.xml"; then
  fail "Android participant reminder receiver must be explicitly non-exported"
fi
pass "Android participant reminder receiver is explicitly non-exported"
require_file_contains "$ROOT_DIR/chronicle-ios/chronicle/ChronicleApp.swift" \
  'DebugEnrollmentAutomationGate\.allowsHeadlessEnrollment\(\)' \
  "iOS debug auto-enrollment requires a trusted process launch gate"
legacy_rehearsal_label='test''prod'
require_file_contains "$ROOT_DIR/chronicle-ios/chronicle/Utilities/ChronicleURLSession.swift" \
  "actualFingerprint == ChronicleServerTrustPolicy\\.${legacy_rehearsal_label}CertificateSHA256" \
  "iOS rehearsal TLS exception requires the configured leaf certificate fingerprint"

require_file_contains "$ROOT_DIR/chronicle-server/src/main/kotlin/com/openlattice/chronicle/services/enrollment/EnrollmentService.kt" \
  'private const val DISABLED_PUSH_DEVICE_TOKEN = ""' \
  "Server enrollment intentionally blanks legacy push device tokens"
if grep -Eq 'sourceDevice\.(fcmRegistrationToken|apnDeviceToken)' \
  "$ROOT_DIR/chronicle-server/src/main/kotlin/com/openlattice/chronicle/services/enrollment/EnrollmentService.kt"; then
  fail "Server enrollment must not persist client-supplied FCM/APN tokens"
fi
pass "Server enrollment does not read client-supplied FCM/APN tokens for storage"

if grep -Eq 'requestMatchers\(HttpMethod\.POST, "/chronicle/v3/study/\*/participant/\*/ios/' \
  "$ROOT_DIR/chronicle-server/src/main/kotlin/com/openlattice/chronicle/pods/servlet/ChronicleServerSecurityPod.kt"; then
  fail "Legacy iOS write routes must not be permitAll"
fi
pass "Legacy iOS writes require per-device authentication"
require_file_contains "$ROOT_DIR/chronicle-ios/chronicle/Utilities/ApiClient.swift" \
  'request\.setValue\(apiKey, forHTTPHeaderField: "X-Api-Key"\)' \
  "iOS uploads attach the per-device API key"
require_file_contains "$ROOT_DIR/chronicle-ios/chronicle/Utilities/ApiClient.swift" \
  'request\.setValue\(deviceId, forHTTPHeaderField: "X-Chronicle-Device-Id"\)' \
  "iOS uploads attach the device-binding header"

require_file_contains "$ROOT_DIR/docker/docker-compose.traefik.yml" \
  'MOBILE_SIGNING_ENABLED: \$\{MOBILE_SIGNING_ENABLED:-false\}' \
  "Production compose defaults controlled legacy HMAC off"
require_file_contains "$ROOT_DIR/docker/docker-compose.traefik.yml" \
  'MOBILE_SIGNING_REQUIRED: \$\{MOBILE_SIGNING_REQUIRED:-false\}' \
  "Production compose defaults controlled legacy HMAC enforcement off"
require_file_contains "$ROOT_DIR/docker/docker-compose.traefik.yml" \
  'CHRONICLE_SECURITY_COOKIE_SECURE: \$\{CHRONICLE_SECURITY_COOKIE_SECURE:\?' \
  "Production compose requires CHRONICLE_SECURITY_COOKIE_SECURE to be explicit"
require_file_contains "$ROOT_DIR/docker/docker-compose.traefik.yml" \
  'CHRONICLE_SECURITY_REQUIRE_MFA: \$\{CHRONICLE_SECURITY_REQUIRE_MFA:\?' \
  "Production compose requires MFA enforcement to be explicit"
require_file_contains "$ROOT_DIR/docker/docker-compose.traefik.yml" \
  'MOBILE_SIGNING_ENABLED and MOBILE_SIGNING_REQUIRED must either both be true or both be false' \
  "Production backend validates the controlled-legacy flags atomically"
require_file_contains "$ROOT_DIR/docker/docker-compose.traefik.yml" \
  'MOBILE_SIGNING_SECRET must stay blank unless controlled legacy compatibility is enabled' \
  "Production backend rejects an unused deployment-wide mobile secret"
if grep -Eq 'production requires MOBILE_SIGNING_(ENABLED|REQUIRED)=true' \
  "$ROOT_DIR/docker/docker-compose.traefik.yml"; then
  fail "Production backend must not force controlled legacy HMAC on for public clients"
fi
pass "Production backend allows the false/false/blank public-client contract"
require_file_contains "$ROOT_DIR/docker/docker-compose.traefik.yml" \
  'production requires CHRONICLE_SECURITY_COOKIE_SECURE=true' \
  "Production backend entrypoint rejects CHRONICLE_SECURITY_COOKIE_SECURE=false"
require_file_contains "$ROOT_DIR/docker/docker-compose.traefik.yml" \
  'production requires CHRONICLE_SECURITY_REQUIRE_MFA=true' \
  "Production backend entrypoint rejects CHRONICLE_SECURITY_REQUIRE_MFA=false"
require_file_contains "$ROOT_DIR/docker/docker-compose.traefik.yml" \
  'OIDC_ENABLED=true but OIDC_CLIENT_SECRET is missing or still a placeholder' \
  "Production backend entrypoint rejects placeholder OIDC client secrets"
require_file_contains "$ROOT_DIR/docker/docker-compose.traefik.yml" \
  'replace Upstream OIDC client credentials before using KEYCLOAK_DEFAULT_IDP=upstream-oidc' \
  "Keycloak entrypoint rejects placeholder Upstream OIDC client credentials"
require_file_contains "$ROOT_DIR/docker/docker-compose.traefik.yml" \
  'contains unresolved template variables' \
  "Production backend entrypoint rejects unresolved rendered config variables"
require_file_contains "$ROOT_DIR/docker/docker-compose.traefik.yml" \
  'production CORS must not allow plain HTTP origins' \
  "Production backend entrypoint rejects plain HTTP CORS origins"
require_file_contains "$ROOT_DIR/docker/docker-compose.traefik.yml" \
  'production CORS must not allow wildcard origins' \
  "Production backend entrypoint rejects wildcard CORS origins"
require_file_contains "$ROOT_DIR/docker/docker-compose.traefik.yml" \
  'production CORS development-mode must be false' \
  "Production backend entrypoint rejects CORS development mode"
if grep -Eq '^[[:space:]]*-[[:space:]]*"http://' "$ROOT_DIR/docker/cors.yaml.template"; then
  fail "Production CORS template must not allow plain HTTP origins"
fi
pass "Production CORS template does not allow plain HTTP origins"
if grep -Eq '^[[:space:]]*-[[:space:]]*"\*"' "$ROOT_DIR/docker/cors.yaml.template"; then
  fail "Production CORS template must not allow wildcard origins"
fi
pass "Production CORS template does not allow wildcard origins"
if grep -Eq 'IMAGE_TAG:-latest|\$\{(BACKEND_IMAGE|FRONTEND_IMAGE):-' "$ROOT_DIR/docker/docker-compose.production.yml"; then
  fail "Production image override must not default to mutable image tags or registry paths"
fi
pass "Production image override requires explicit image references"
if grep -Eq '^IMAGE_TAG=(latest|main|master|develop|dev|staging|production)$' "$ROOT_DIR/docker/.env.production"; then
  fail "Production env template must not set IMAGE_TAG to a mutable tag"
fi
pass "Production env template does not use a mutable IMAGE_TAG"
require_file_contains "$ROOT_DIR/scripts/deploy.sh" \
  'Refusing mutable or placeholder image tag' \
  "Deploy script rejects mutable or placeholder image tags"
if grep -Eq '^[[:space:]]{2}(prometheus|loki):[[:space:]]*$' "$ROOT_DIR/docker/docker-compose.production.yml"; then
  fail "Production override must target active VictoriaMetrics/VictoriaLogs services, not stale Prometheus/Loki names"
fi
pass "Production override does not reference stale Prometheus/Loki services"
require_file_contains "$ROOT_DIR/docker/docker-compose.production.yml" \
  '^[[:space:]]{2}victoria-metrics:[[:space:]]*$' \
  "Production override tunes active victoria-metrics service"
require_file_contains "$ROOT_DIR/docker/docker-compose.production.yml" \
  '^[[:space:]]{2}victoria-logs:[[:space:]]*$' \
  "Production override tunes active victoria-logs service"

bash -n "$ROOT_DIR/scripts/android-auto-upload-e2e.sh"
bash -n "$ANDROID_DIR/scripts/android-release-candidate-gate.sh"
bash -n "$ROOT_DIR/scripts/deploy.sh"
pass "Android auto-upload E2E script parses"
pass "Android release candidate gate script parses"
pass "Production deploy script parses"

require_file_contains "$ANDROID_DIR/scripts/android-release-candidate-gate.sh" \
  'refusing Android debug signing material for a release candidate' \
  "Android release candidate gate rejects debug signing material"
require_file_contains "$ANDROID_DIR/scripts/android-release-candidate-gate.sh" \
  'refusing stale release artifact' \
  "Android release candidate gate rejects stale APK artifacts"
require_file_contains "$ANDROID_DIR/scripts/android-release-candidate-gate.sh" \
  'verify-android-16kb-native-libs\.sh' \
  "Android release candidate gate runs 16 KB native-library verification"
require_file_contains "$ANDROID_DIR/scripts/android-release-candidate-gate.sh" \
  'apksigner.*verify' \
  "Android release candidate gate verifies APK signing metadata"
require_file_contains "$ANDROID_DIR/scripts/android-release-candidate-gate.sh" \
  'signing\.properties\.example' \
  "Android release candidate gate points operators to the signing properties template"
require_file_contains "$ANDROID_DIR/scripts/android-release-candidate-gate.sh" \
  '--enrollment-url-file <path>' \
  "Android release candidate gate accepts enrollment invitations only from a caller-owned file"
require_file_contains "$ANDROID_DIR/scripts/android-release-candidate-gate.sh" \
  '--enrollment-url-file requires --install' \
  "Android release candidate gate only opens enrollment links after installing the exact candidate"
require_file_contains "$ANDROID_DIR/scripts/android-release-candidate-gate.sh" \
  'must be a regular, non-symlink file owned by the current user' \
  "Android release candidate gate requires a regular current-owner invitation file"
require_file_contains "$ANDROID_DIR/scripts/android-release-candidate-gate.sh" \
  'must have mode 0600' \
  "Android release candidate gate requires exact mode 0600 for the invitation file"
require_file_contains "$ANDROID_DIR/scripts/android-release-candidate-gate.sh" \
  'printf '\''%s\\n'\'' "\$enrollment_url" \| adb .* shell' \
  "Android release candidate gate delivers the invitation to adb over stdin"
require_file_contains "$ANDROID_DIR/scripts/android-release-candidate-gate.sh" \
  'unset enrollment_url' \
  "Android release candidate gate clears the full invitation after dispatch"
require_file_contains "$ANDROID_DIR/scripts/android-release-candidate-gate.sh" \
  'enrollment_url_retained=false' \
  "Android release candidate evidence records that the full invitation was not retained"
require_file_contains "$ANDROID_DIR/scripts/android-release-candidate-gate.sh" \
  'enrollment_credential_retained=false' \
  "Android release candidate evidence records that the credential was not retained"
require_file_contains "$ANDROID_DIR/scripts/android-release-candidate-gate.sh" \
  'rg -aFq -- "\$enrollment_code" "\$output_dir"' \
  "Android release candidate gate scans all retained evidence for the actual credential"
require_file_contains "$ANDROID_DIR/scripts/android-release-candidate-gate.sh" \
  'window-focus-after-enrollment-url\.txt' \
  "Android release candidate gate retains only non-content enrollment focus evidence"

if grep -Eq -- '--enrollment-url <url>|^[[:space:]]*--enrollment-url\)' \
  "$ANDROID_DIR/scripts/android-release-candidate-gate.sh"; then
  fail "Android release candidate gate must not accept full enrollment URLs on the command line"
fi
if grep -Eq -- '-d "\$enrollment_url"|echo .*enrollment_url=.*\$enrollment_url' \
  "$ANDROID_DIR/scripts/android-release-candidate-gate.sh"; then
  fail "Android release candidate gate must not expose the invitation in argv or output"
fi
if grep -Eq -- 'uiautomator dump|enrollment-ui\.(xml|png)|logcat-after-enrollment-url' \
  "$ANDROID_DIR/scripts/android-release-candidate-gate.sh"; then
  fail "Android release candidate gate must not retain enrollment UI or logcat content"
fi
pass "Android release candidate gate uses private-file input, stdin dispatch, and credential-free evidence"

SIGNING_TEMPLATE="$APP_DIR/signing.properties.example"
[[ -f "$SIGNING_TEMPLATE" ]] || fail "Android release signing properties template must exist"
require_file_contains "$SIGNING_TEMPLATE" \
  '^storeFile=/absolute/path/to/chronicle-release-or-beta\.jks$' \
  "Android release signing template declares absolute storeFile placeholder"
require_file_contains "$SIGNING_TEMPLATE" \
  '^storePassword=<local secret>$' \
  "Android release signing template declares storePassword placeholder"
require_file_contains "$SIGNING_TEMPLATE" \
  '^keyAlias=<release key alias>$' \
  "Android release signing template declares keyAlias placeholder"
require_file_contains "$SIGNING_TEMPLATE" \
  '^keyPassword=<local secret>$' \
  "Android release signing template declares keyPassword placeholder"
if grep -Eq 'androiddebugkey|debug\.keystore|storePassword=android|keyPassword=android' "$SIGNING_TEMPLATE"; then
  fail "Android release signing template must not include Android debug signing material"
fi
pass "Android release signing template avoids debug signing material"

"$ROOT_DIR/tests/security/maestro-auth-transport-guardrails.sh"
pass "Maestro administrator token transport is functionally private and one-use"

echo "Mobile upload guardrails complete. Reports directory: $REPORT_DIR"
