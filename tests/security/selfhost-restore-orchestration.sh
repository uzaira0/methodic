#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CHRONICLE_SCRIPT="${ROOT_DIR}/selfhost/chronicle"
RUN_PARENT="${SELFHOST_RESTORE_ORCHESTRATION_TEST_ROOT:-${ROOT_DIR}/build/operator-test-runs/selfhost-restore-orchestration}"

fail() {
  echo "self-host restore orchestration test failed: $*" >&2
  exit 1
}

[[ "$RUN_PARENT" == /* ]] || fail "test run parent must be absolute"
case "$RUN_PARENT" in
  /tmp|/tmp/*|/private/tmp|/private/tmp/*|/var/folders|/var/folders/*)
    fail "test run parent must not use a system temporary directory"
    ;;
esac
[[ ! -L "$RUN_PARENT" ]] || fail "test run parent must not be a symlink"
bash -n "$CHRONICLE_SCRIPT"

umask 077
/bin/mkdir -p "$RUN_PARENT"
RUN_DIR="$(/usr/bin/mktemp -d "${RUN_PARENT}/run.XXXXXX")"
/bin/chmod 0700 "$RUN_DIR"
trap '/bin/rm -rf -- "$RUN_DIR"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

setup_case() {
  local name="$1"
  CASE_DIR="${RUN_DIR}/${name}"
  SELFHOST_DIR="${CASE_DIR}/selfhost"
  COMMAND_DIR="${CASE_DIR}/commands"
  COMMAND_LOG="${CASE_DIR}/docker.log"
  STOPPED_MARKER="${CASE_DIR}/writers-stopped"
  OUTPUT="${CASE_DIR}/output.log"
  CASE_STOP_EXIT=0
  CASE_INCLUDE_CA_EXPORT=0
  /bin/mkdir -p "${SELFHOST_DIR}/backups/last" "$COMMAND_DIR"
  /bin/cp "$CHRONICLE_SCRIPT" "${SELFHOST_DIR}/chronicle"
  /bin/chmod 0755 "${SELFHOST_DIR}/chronicle"
  printf 'fixture restore payload\n' | gzip -c >"${SELFHOST_DIR}/backups/last/chronicle-latest.sql.gz"
  /bin/chmod 0600 "${SELFHOST_DIR}/backups/last/chronicle-latest.sql.gz"
  cat >"${SELFHOST_DIR}/.env" <<'EOF'
COMPOSE_PROJECT_NAME=chronicle-selfhost-restore-fixture
CHRONICLE_STATE_DIR=.
COMPOSE_FILE=docker-compose.yml:overlays/mode-behind-proxy-internal.yml:overlays/backups.yml
POSTGRES_PASSWORD=fixture-postgres-password
MOBILE_SIGNING_ENABLED=false
MOBILE_SIGNING_REQUIRED=false
MOBILE_SIGNING_SECRET=
MOBILE_SIGNING_SECRET_PREVIOUS=
JWT_SECRET=fixture-jwt-secret
METRICS_PASSWORD=fixture-metrics-secret
CHRONICLE_INTERNAL_WEB_SECRET=fixture-internal-secret
DASHBOARD_PASSWORD_HASH='fixture-dashboard-hash'
RESTORE_START_WAIT_TIMEOUT_SECONDS=17
EOF
  /bin/chmod 0600 "${SELFHOST_DIR}/.env"

  cat >"${COMMAND_DIR}/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

for secret_name in POSTGRES_PASSWORD MOBILE_SIGNING_SECRET JWT_SECRET METRICS_PASSWORD \
    CHRONICLE_INTERNAL_WEB_SECRET DASHBOARD_PASSWORD_HASH; do
  [[ -z "${!secret_name+x}" ]] || {
    echo "deployment secret reached docker environment: ${secret_name}" >&2
    exit 91
  }
done

log="${SELFHOST_RESTORE_ORCHESTRATION_LOG:?}"
stopped="${SELFHOST_RESTORE_ORCHESTRATION_STOPPED:?}"
[[ "${1:-}" == compose ]] || exit 92
shift
if [[ "${1:-}" == -p ]]; then
  [[ -n "${2:-}" ]] || exit 93
  shift 2
fi
profile=""
if [[ "${1:-}" == --profile ]]; then
  profile="${2:-}"
  [[ "$profile" == restore ]] || exit 101
  shift 2
fi

case "${1:-}" in
  config)
    [[ "${2:-}" == --services ]] || exit 94
    printf '%s\n' postgres backend web db-init db-backup
    [[ "${SELFHOST_RESTORE_INCLUDE_CA_EXPORT:-0}" != 1 || "$profile" == restore ]] || printf '%s\n' ca-export
    [[ "$profile" != restore ]] || printf '%s\n' restore
    ;;
  stop)
    shift
    printf 'stop:%s\n' "$*" >>"$log"
    : >"$stopped"
    exit "${SELFHOST_RESTORE_ORCHESTRATION_STOP_EXIT:-0}"
    ;;
  ps)
    [[ "$profile" == restore ]] || exit 102
    [[ "$*" == 'ps --status running --services' ]] || exit 95
    printf '%s\n' postgres
    if [[ ! -e "$stopped" ]]; then
      printf '%s\n' backend web db-backup
    fi
    ;;
  run)
    if [[ "$profile" == restore ]]; then
      printf 'run:%s\n' "$*" >>"$log"
      [[ -e "$stopped" ]] || {
        echo "restore ran before writers stopped" >&2
        exit 96
      }
      [[ " $* " == *' -e CHRONICLE_RESTORE_ORCHESTRATED=true '* ]] || exit 97
      [[ " $* " == *' -e RESTORE_FILE=/backups/'* ]] || exit 98
      exit "${SELFHOST_RESTORE_ORCHESTRATION_RUN_EXIT:-0}"
    fi
    [[ "$*" == 'run --rm --no-deps ca-export' ]] || exit 103
    printf 'ca-export\n' >>"$log"
    ;;
  up)
    [[ -z "$profile" ]] || exit 104
    printf 'up:%s\n' "$*" >>"$log"
    case "$*" in
      'up -d --wait --wait-timeout 17 --remove-orphans postgres backend web db-init db-backup') ;;
      'up -d --wait --wait-timeout 17 --no-deps backend web db-backup')
        /bin/rm -f -- "$stopped"
        ;;
      *) exit 99 ;;
    esac
    exit "${SELFHOST_RESTORE_ORCHESTRATION_UP_EXIT:-0}"
    ;;
  *) exit 100 ;;
esac
EOF
  /bin/chmod 0755 "${COMMAND_DIR}/docker"
}

run_restore() {
  local run_exit="${1:-0}" up_exit="${2:-0}"
  shift 2 || true
  set +e
  (
    cd "$SELFHOST_DIR"
    env \
      "PATH=${COMMAND_DIR}:${PATH}" \
      "SELFHOST_RESTORE_ORCHESTRATION_LOG=${COMMAND_LOG}" \
      "SELFHOST_RESTORE_ORCHESTRATION_STOPPED=${STOPPED_MARKER}" \
      "SELFHOST_RESTORE_ORCHESTRATION_STOP_EXIT=${CASE_STOP_EXIT}" \
      "SELFHOST_RESTORE_ORCHESTRATION_RUN_EXIT=${run_exit}" \
      "SELFHOST_RESTORE_ORCHESTRATION_UP_EXIT=${up_exit}" \
      "SELFHOST_RESTORE_INCLUDE_CA_EXPORT=${CASE_INCLUDE_CA_EXPORT}" \
      /bin/bash ./chronicle restore "$@"
  ) >"$OUTPUT" 2>&1
  RESTORE_STATUS=$?
  set -e
}

assert_ordered_success() {
  local stop_line run_line up_line
  stop_line="$(grep -n '^stop:' "$COMMAND_LOG" | head -1 | cut -d: -f1)"
  run_line="$(grep -n '^run:' "$COMMAND_LOG" | head -1 | cut -d: -f1)"
  up_line="$(grep -n '^up:' "$COMMAND_LOG" | head -1 | cut -d: -f1)"
  [[ -n "$stop_line" && -n "$run_line" && -n "$up_line" ]] ||
    fail "success case omitted stop, restore, or startup"
  (( stop_line < run_line && run_line < up_line )) ||
    fail "restore operations ran out of order"
}

setup_case success
CASE_INCLUDE_CA_EXPORT=1
run_restore 0 0 --yes
if [[ "$RESTORE_STATUS" -ne 0 ]]; then
  /bin/cat "$OUTPUT" >&2
  fail "guarded restore success case failed"
fi
assert_ordered_success
grep -Fq 'stop:backend web db-init db-backup' "$COMMAND_LOG" ||
  fail "guarded restore did not stop every configured application/backup service"
[[ ! -e "${SELFHOST_DIR}/.chronicle-restore.lock" ]] ||
  fail "successful restore left its ownership lock"
grep -Fq 'Restore complete.' "$OUTPUT" || fail "success was not reported"
grep -Fxq 'ca-export' "$COMMAND_LOG" || fail "local restore did not run CA export after healthy startup"
! grep -Fq 'CHRONICLE_RESTORE_LEAVE_STOPPED=true' "$COMMAND_LOG" ||
  fail "normal restore incorrectly selected prior-binary rollback verification"

setup_case no-start
run_restore 0 0 --yes --no-start
[[ "$RESTORE_STATUS" -eq 0 ]] || fail "--no-start restore failed"
grep -q '^run:' "$COMMAND_LOG" || fail "--no-start omitted the restore"
grep -Fq 'CHRONICLE_RESTORE_LEAVE_STOPPED=true' "$COMMAND_LOG" ||
  fail "--no-start omitted protected continuity comparison"
! grep -q '^up:' "$COMMAND_LOG" || fail "--no-start restarted the application"
[[ ! -e "${SELFHOST_DIR}/.chronicle-restore.lock" ]] ||
  fail "successful --no-start restore left its ownership lock"
grep -Fq 'application remains stopped' "$OUTPUT" ||
  fail "--no-start output did not describe the resulting state"

setup_case no-start-continuity-failure
run_restore 45 0 --yes --no-start
[[ "$RESTORE_STATUS" -ne 0 ]] || fail "rollback continuity rejection returned success"
grep -Fq 'CHRONICLE_RESTORE_LEAVE_STOPPED=true' "$COMMAND_LOG" ||
  fail "rollback continuity rejection did not exercise the protected comparison path"
! grep -q '^up:' "$COMMAND_LOG" || fail "rejected rollback restarted the application"
[[ "$(cat "${SELFHOST_DIR}/.chronicle-restore.lock/phase")" == restoring ]] ||
  fail "rejected rollback did not preserve its destructive phase"

setup_case stop-failure
CASE_STOP_EXIT=44
run_restore 0 0 --yes
[[ "$RESTORE_STATUS" -ne 0 ]] || fail "partial service-stop failure returned success"
grep -Fq 'stop:backend web db-init db-backup' "$COMMAND_LOG" ||
  fail "partial service-stop failure did not exercise the stop command"
! grep -q '^run:' "$COMMAND_LOG" || fail "restore ran after the service-stop command failed"
grep -Fq 'up -d --wait --wait-timeout 17 --no-deps backend web db-backup' "$COMMAND_LOG" ||
  fail "pre-restore failure did not restart the services that were previously running"
[[ ! -e "${SELFHOST_DIR}/.chronicle-restore.lock" ]] ||
  fail "pre-restore stop failure left a destructive-operation lock"
grep -Fq 'The pre-restore service state was restored.' "$OUTPUT" ||
  fail "pre-restore stop failure did not report service recovery"

setup_case restore-failure
run_restore 42 0 --yes
[[ "$RESTORE_STATUS" -ne 0 ]] || fail "failed restore returned success"
grep -q '^stop:' "$COMMAND_LOG" || fail "failed restore did not stop writers"
grep -q '^run:' "$COMMAND_LOG" || fail "restore failure fixture was not exercised"
! grep -q '^up:' "$COMMAND_LOG" || fail "failed restore restarted the application"
[[ "$(cat "${SELFHOST_DIR}/.chronicle-restore.lock/phase")" == restoring ]] ||
  fail "failed restore did not preserve its destructive phase"
grep -Fq 'do not start Chronicle application services' "$OUTPUT" ||
  fail "failed restore did not explain its fail-closed state"

# The lock is a durable containment boundary, not just an instruction in the failed
# process's stderr. The ordinary startup command must refuse before it reaches Compose,
# including after the original restore process has exited.
restore_log_lines="$(wc -l <"$COMMAND_LOG" | tr -d '[:space:]')"
set +e
(
  cd "$SELFHOST_DIR"
  env \
    "PATH=${COMMAND_DIR}:${PATH}" \
    "SELFHOST_RESTORE_ORCHESTRATION_LOG=${COMMAND_LOG}" \
    "SELFHOST_RESTORE_ORCHESTRATION_STOPPED=${STOPPED_MARKER}" \
    /bin/bash ./chronicle up
) >"${CASE_DIR}/blocked-up.log" 2>&1
blocked_up_status=$?
set -e
[[ "$blocked_up_status" -ne 0 ]] || fail "ordinary startup ignored an incomplete restore lock"
grep -Fq 'cannot start Chronicle while an incomplete restore operation is preserved' \
  "${CASE_DIR}/blocked-up.log" || fail "blocked startup did not explain the restore interlock"
[[ "$(wc -l <"$COMMAND_LOG" | tr -d '[:space:]')" == "$restore_log_lines" ]] ||
  fail "blocked startup reached Docker Compose despite the incomplete restore lock"

setup_case startup-failure
run_restore 0 43 --yes
[[ "$RESTORE_STATUS" -ne 0 ]] || fail "post-restore startup failure returned success"
[[ "$(grep -c '^stop:' "$COMMAND_LOG")" -eq 2 ]] ||
  fail "startup failure did not stop application services again"
[[ "$(cat "${SELFHOST_DIR}/.chronicle-restore.lock/phase")" == starting-services ]] ||
  fail "startup failure did not preserve its recovery phase"
grep -Fq 'did not return healthy' "$OUTPUT" ||
  fail "startup failure was not explained"

setup_case upgrade-interlock
/bin/mkdir "${SELFHOST_DIR}/.chronicle-upgrade.lock"
run_restore 0 0 --yes
[[ "$RESTORE_STATUS" -ne 0 ]] || fail "restore ignored an upgrade lock"
[[ ! -e "$COMMAND_LOG" ]] || ! grep -Eq '^(stop|run|up):' "$COMMAND_LOG" ||
  fail "restore changed services despite an upgrade lock"
grep -Fq 'an upgrade is active or incomplete' "$OUTPUT" ||
  fail "upgrade interlock was not explained"

setup_case rotation-interlock
/bin/mkdir "${SELFHOST_DIR}/.chronicle-secret-rotation"
run_restore 0 0 --yes
[[ "$RESTORE_STATUS" -ne 0 ]] || fail "restore ignored a secret-rotation lock"
[[ ! -e "$COMMAND_LOG" ]] || ! grep -Eq '^(stop|run|up):' "$COMMAND_LOG" ||
  fail "restore changed services despite a secret-rotation lock"
grep -Fq 'a secret rotation is active or incomplete' "$OUTPUT" ||
  fail "secret-rotation interlock was not explained"

setup_case dangling-lock-interlock
/bin/ln -s missing-operation-owner "${SELFHOST_DIR}/.chronicle-upgrade.lock"
run_restore 0 0 --yes
[[ "$RESTORE_STATUS" -ne 0 ]] || fail "restore ignored a dangling operation-lock symlink"
[[ ! -e "$COMMAND_LOG" ]] || ! grep -Eq '^(stop|run|up):' "$COMMAND_LOG" ||
  fail "restore changed services despite a dangling operation lock"

setup_case existing-restore-lock
/bin/mkdir "${SELFHOST_DIR}/.chronicle-restore.lock"
run_restore 0 0 --yes
[[ "$RESTORE_STATUS" -ne 0 ]] || fail "restore ignored an existing restore lock"
grep -Fq 'another restore is active or incomplete' "$OUTPUT" ||
  fail "existing restore lock was not explained"

setup_case escaped-path
printf 'outside restore payload\n' | gzip -c >"${SELFHOST_DIR}/outside.sql.gz"
/bin/ln -s ../../outside.sql.gz "${SELFHOST_DIR}/backups/last/escaped.sql.gz"
run_restore 0 0 --yes /backups/last/escaped.sql.gz
[[ "$RESTORE_STATUS" -ne 0 ]] || fail "restore accepted a dump resolving outside backups"
[[ ! -e "$COMMAND_LOG" ]] || fail "unsafe path reached Docker Compose"
grep -Fq 'restore dump is unavailable or unsafe' "$OUTPUT" ||
  fail "unsafe restore path was not explained"

# Ensure each state-changing script contains the post-acquisition recheck that closes the
# otherwise unavoidable check-then-mkdir race. The rotation behavior is also exercised by
# its dedicated fixture test.
grep -Fq 'started while the restore lock was being acquired' "$CHRONICLE_SCRIPT" ||
  fail "restore omits post-acquisition operation-lock rechecks"
grep -Fq 'started while the upgrade lock was being acquired' "${ROOT_DIR}/selfhost/upgrade.sh" ||
  fail "upgrade omits post-acquisition operation-lock rechecks"
grep -Fq 'started while the secret-rotation lock was being acquired' \
  "${ROOT_DIR}/selfhost/rotate-secret.sh" ||
  fail "secret rotation omits post-acquisition operation-lock rechecks"

echo "self-host restore orchestration test passed"
