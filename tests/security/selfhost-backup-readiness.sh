#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
ENTRYPOINT="${ROOT_DIR}/selfhost/backup-entrypoint.sh"
RUN_PARENT="${SELFHOST_BACKUP_TEST_ROOT:-${ROOT_DIR}/build/operator-test-runs/selfhost-backup-readiness}"

fail() {
  echo "self-host backup readiness test failed: $*" >&2
  exit 1
}

[[ "$RUN_PARENT" == /* ]] || fail "test run parent must be absolute"
case "$RUN_PARENT" in
  /tmp|/tmp/*|/private/tmp|/private/tmp/*|/var/folders|/var/folders/*)
    fail "test run parent must not use a system temporary directory"
    ;;
esac
[[ -x "$ENTRYPOINT" ]] || fail "backup entrypoint is missing or not executable"

umask 077
/bin/mkdir -p "$RUN_PARENT"
RUN_DIR="$(/usr/bin/mktemp -d "${RUN_PARENT}/run.XXXXXX")"
trap '/bin/rm -rf -- "$RUN_DIR"' EXIT
COMMAND_DIR="${RUN_DIR}/commands"
/bin/mkdir -p "$COMMAND_DIR"

cat >"${COMMAND_DIR}/pg_isready" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
counter="${BACKUP_TEST_STATE:?}/pg.count"
count=0
[[ ! -f "$counter" ]] || count="$(cat "$counter")"
count=$((count + 1))
printf '%s\n' "$count" >"$counter"
(( count >= BACKUP_TEST_DB_READY_AFTER ))
EOF

cat >"${COMMAND_DIR}/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
counter="${BACKUP_TEST_STATE:?}/curl.count"
count=0
[[ ! -f "$counter" ]] || count="$(cat "$counter")"
count=$((count + 1))
printf '%s\n' "$count" >"$counter"
if (( count >= BACKUP_TEST_BACKEND_READY_AFTER )); then
  # The real unauthenticated study route returns 401; the wrapper must accept that as a
  # serving Spring request path, exactly as the backend container healthcheck does.
  printf '401'
else
  printf '503'
fi
EOF

cat >"${COMMAND_DIR}/image-init" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'started\n' >"${BACKUP_TEST_INIT_MARKER:?}"
EOF
/bin/chmod 0755 "${COMMAND_DIR}/pg_isready" "${COMMAND_DIR}/curl" "${COMMAND_DIR}/image-init"

run_entrypoint() {
  local state_dir="$1"
  local timeout="$2"
  local db_ready_after="$3"
  local backend_ready_after="$4"
  local marker="$5"
  local output="$6"
  /bin/mkdir -p "$state_dir"
  PATH="${COMMAND_DIR}:/usr/bin:/bin" \
    BACKUP_TEST_STATE="$state_dir" \
    BACKUP_TEST_DB_READY_AFTER="$db_ready_after" \
    BACKUP_TEST_BACKEND_READY_AFTER="$backend_ready_after" \
    BACKUP_TEST_INIT_MARKER="$marker" \
    BACKUP_STARTUP_TIMEOUT_SECONDS="$timeout" \
    BACKUP_STARTUP_INTERVAL_SECONDS=1 \
    POSTGRES_HOST=postgres \
    POSTGRES_PORT=5432 \
    POSTGRES_DB=chronicle \
    POSTGRES_USER=chronicle \
    /bin/bash "$ENTRYPOINT" "${COMMAND_DIR}/image-init" >"$output" 2>&1
}

success_state="${RUN_DIR}/success-state"
success_marker="${RUN_DIR}/success.init"
success_output="${RUN_DIR}/success.log"
run_entrypoint "$success_state" 6 2 2 "$success_marker" "$success_output" \
  || fail "entrypoint did not recover when dependencies became ready"
[[ -f "$success_marker" ]] || fail "image init was not launched after readiness"
[[ "$(cat "${success_state}/pg.count")" -ge 3 ]] || fail "database readiness was not retried"
[[ "$(cat "${success_state}/curl.count")" -ge 2 ]] || fail "backend readiness was not retried"
grep -Fq 'Backup dependencies are ready' "$success_output" \
  || fail "successful readiness was not reported"

failure_state="${RUN_DIR}/failure-state"
failure_marker="${RUN_DIR}/failure.init"
failure_output="${RUN_DIR}/failure.log"
set +e
run_entrypoint "$failure_state" 1 1 99 "$failure_marker" "$failure_output"
failure_status=$?
set -e
[[ "$failure_status" -ne 0 ]] || fail "entrypoint started after a permanent backend failure"
[[ ! -e "$failure_marker" ]] || fail "image init ran before the backend was ready"
grep -Fq 'backup startup timed out after 1s' "$failure_output" \
  || fail "readiness timeout was not comprehensible"

invalid_output="${RUN_DIR}/invalid.log"
set +e
BACKUP_STARTUP_TIMEOUT_SECONDS=0 /bin/bash "$ENTRYPOINT" "${COMMAND_DIR}/image-init" \
  >"$invalid_output" 2>&1
invalid_status=$?
set -e
[[ "$invalid_status" -ne 0 ]] || fail "entrypoint accepted a zero startup timeout"
grep -Fq 'BACKUP_STARTUP_TIMEOUT_SECONDS must be a positive integer' "$invalid_output" \
  || fail "invalid timeout rejection was not comprehensible"

set +e
BACKUP_STARTUP_TIMEOUT_SECONDS=3601 /bin/bash "$ENTRYPOINT" "${COMMAND_DIR}/image-init" \
  >"${RUN_DIR}/oversized-timeout.log" 2>&1
oversized_status=$?
set -e
[[ "$oversized_status" -ne 0 ]] || fail "entrypoint accepted an effectively unbounded startup timeout"
grep -Fq 'BACKUP_STARTUP_TIMEOUT_SECONDS must not exceed 3600' \
  "${RUN_DIR}/oversized-timeout.log" ||
  fail "oversized timeout rejection was not comprehensible"

set +e
BACKUP_STARTUP_TIMEOUT_SECONDS=10 BACKUP_STARTUP_INTERVAL_SECONDS=61 \
  /bin/bash "$ENTRYPOINT" "${COMMAND_DIR}/image-init" \
  >"${RUN_DIR}/oversized-interval.log" 2>&1
oversized_status=$?
set -e
[[ "$oversized_status" -ne 0 ]] || fail "entrypoint accepted an excessive readiness interval"
grep -Fq 'BACKUP_STARTUP_INTERVAL_SECONDS must not exceed 60' \
  "${RUN_DIR}/oversized-interval.log" ||
  fail "oversized readiness-interval rejection was not comprehensible"

echo "self-host backup readiness test passed"
