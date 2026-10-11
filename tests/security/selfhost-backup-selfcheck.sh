#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
IMAGE_DIR="${ROOT_DIR}/selfhost/backup-image"
RUN_PARENT="${SELFHOST_BACKUP_TEST_ROOT:-${ROOT_DIR}/build/operator-test-runs/selfhost-backup-selfcheck}"

fail() {
  echo "self-host backup self-check test failed: $*" >&2
  exit 1
}

[[ "$RUN_PARENT" == /* ]] || fail "test run parent must be absolute"
case "$RUN_PARENT" in
  /tmp|/tmp/*|/private/tmp|/private/tmp/*|/var/folders|/var/folders/*)
    fail "test run parent must not use a system temporary directory" ;;
esac
umask 077
mkdir -p "$RUN_PARENT"
RUN_DIR="$(mktemp -d "${RUN_PARENT}/run.XXXXXX")"
trap 'rm -rf -- "$RUN_DIR"' EXIT
COMMAND_DIR="${RUN_DIR}/commands"
mkdir -p "$COMMAND_DIR"

cat >"${COMMAND_DIR}/psql" <<'PY'
#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

state = Path(os.environ['SELFCHECK_TEST_STATE'])
mode = os.environ['SELFCHECK_TEST_MODE']
args = sys.argv[1:]
database = args[args.index('-d') + 1]
manifest = {'database_bytes': 1024, 'version': '112', 'tables': ['studies', 'study_participants', 'flyway_schema_history'],
            'study_participants': 3, 'studies': 2}
if '-c' in args:
    sql = args[args.index('-c') + 1]
else:
    first = sys.stdin.readline()
    if first.startswith('BEGIN ISOLATION LEVEL REPEATABLE READ'):
        buffer = ''
        for line in sys.stdin:
            if 'pg_export_snapshot()' in line:
                print('00000003-00000001-1', flush=True)
                continue
            buffer += line
            if 'SELECT json_build_object(' in buffer and line.strip().endswith(';'):
                print(json.dumps(manifest), flush=True)
                buffer = ''
        sys.exit(0)
    sql = first + sys.stdin.read()
with (state / 'sql.log').open('a') as log:
    log.write(database + ': ' + sql + '\n')
if 'DROP DATABASE' in sql:
    (state / 'scratch').unlink(missing_ok=True)
    with (state / 'drops').open('a') as log:
        log.write('drop\n')
elif 'CREATE DATABASE' in sql:
    (state / 'scratch').touch()
elif 'CREATE EXTENSION' in sql:
    assert 'pg_tde_set_key_using_database_key_provider' in sql
    assert "ALTER DATABASE \"chronicle_restore_selfcheck\" SET default_table_access_method = 'tde_heap'" in sql
    (state / 'tde').touch()
elif "current_setting('default_table_access_method')" in sql:
    assert (state / 'tde').exists()
    print('f' if mode == 'missing_tde' else 't')
elif 'COPY backup_selfcheck_disk FROM PROGRAM' in sql:
    if mode == 'unknown_space':
        sys.exit(3)
    print('Filesystem 1024-blocks Used Available Capacity Mounted on')
    print('volume 999999 1 ' + ('0' if mode == 'insufficient_space' else '999998') + ' 1% /data/db')
elif 'SELECT json_build_object' in sql:
    if database == 'chronicle_restore_selfcheck':
        if mode == 'row_mismatch':
            manifest['study_participants'] = 4
        elif mode == 'studies_mismatch':
            manifest['studies'] = 3
        elif mode == 'version_mismatch':
            manifest['version'] = '111'
        elif mode == 'missing_table':
            manifest['tables'].remove('studies')
    elif (state / 'source_changed').exists():
        manifest['studies'] = 9
    print(json.dumps(manifest))
elif "a.amname <>" in sql:
    print('0')
elif database == 'chronicle_restore_selfcheck' and '-- PostgreSQL database dump' in sql:
    assert os.environ.get('ENABLE_ENCRYPTION', 'true') == 'false' or (state / 'tde').exists(), 'restored before TDE setup'
    (state / 'restore').touch()
    if mode == 'restore_failure':
        sys.exit(3)
else:
    raise AssertionError('unexpected psql invocation: ' + sql)
PY

cat >"${COMMAND_DIR}/pg_dump" <<'PY'
#!/usr/bin/env python3
import gzip
import os
from pathlib import Path
import sys
state = Path(os.environ['SELFCHECK_TEST_STATE'])
args = sys.argv[1:]
if any(argument.startswith('--snapshot=') for argument in args):
    assert '--snapshot=00000003-00000001-1' in args
    assert args == ['-d', 'chronicle', '-Z1', '--snapshot=00000003-00000001-1'], args
    (state / 'snapshot').touch()
(state / 'source_changed').touch()
dump = '-- PostgreSQL database dump\n\\restrict fixture\nCREATE TABLE studies (study_id uuid);\n'
if os.environ['SELFCHECK_TEST_MODE'] != 'truncated_dump':
    dump += '-- PostgreSQL database dump complete\n--\n\\unrestrict fixture\n'
if '-f' in args:
    Path(args[args.index('-f') + 1]).write_bytes(gzip.compress(dump.encode()))
else:
    compressed = gzip.compress(dump.encode())
    sys.stdout.buffer.write(compressed[:-4] if os.environ['SELFCHECK_TEST_MODE'] == 'corrupt_gzip' else compressed)
PY

cat >"${COMMAND_DIR}/curl" <<'SH'
#!/usr/bin/env bash
[[ "${SELFCHECK_TEST_HTTP_FAIL:-false}" != true ]]
SH
chmod 0755 "${COMMAND_DIR}/psql" "${COMMAND_DIR}/pg_dump" "${COMMAND_DIR}/curl"
export PATH="${COMMAND_DIR}:$PATH"
export POSTGRES_DB=chronicle POSTGRES_HOST=postgres POSTGRES_PORT=5432 POSTGRES_USER=chronicle
export POSTGRES_PASSWORD=''
export POSTGRES_DB_FILE='**None**' POSTGRES_USER_FILE='**None**' POSTGRES_PASSWORD_FILE='**None**'
export POSTGRES_PASSFILE_STORE='**None**' POSTGRES_CLUSTER=FALSE POSTGRES_EXTRA_OPTS=-Z1
export BACKUP_SUFFIX=.sql.gz BACKUP_LATEST_TYPE=symlink
export BACKUP_KEEP_MINS=1440 BACKUP_KEEP_DAYS=7 BACKUP_KEEP_WEEKS=4 BACKUP_KEEP_MONTHS=6
export SCHEDULE=@daily HEALTHCHECK_PORT=8080
export BACKUP_SUCCESS_MARKER="${RUN_DIR}/published-backup-marker"

run_case() {
  local mode="$1" expected="$2" reason="$3"
  export SELFCHECK_TEST_MODE="$mode" SELFCHECK_TEST_STATE="${RUN_DIR}/${mode}/state"
  export BACKUP_DIR="${RUN_DIR}/${mode}/backups"
  mkdir -p "$BACKUP_DIR" "$SELFCHECK_TEST_STATE"
  rm -f "$BACKUP_SUCCESS_MARKER"
  python3 "${IMAGE_DIR}/selfcheck.py" health && fail "startup health passed before publication"
  local status=0
  bash "${IMAGE_DIR}/backup.sh" >"${RUN_DIR}/${mode}/output.log" 2>&1 || status=$?
  if [[ "$expected" == true ]]; then
    [[ "$status" -eq 0 ]] || fail "$mode did not succeed (see output.log)"
    python3 "${IMAGE_DIR}/selfcheck.py" health || fail "verified publication remains unhealthy"
  else
    [[ "$status" -ne 0 ]] || fail "$mode unexpectedly succeeded"
    ! python3 "${IMAGE_DIR}/selfcheck.py" health || fail "failed backup is healthy"
    [[ ! -e "${BACKUP_DIR}/daily/chronicle-latest.sql.gz" ]] || fail "$mode published a failed dump"
  fi
  grep -Fq "$reason" "${RUN_DIR}/${mode}/output.log" || fail "$mode omitted its result diagnostic"
  [[ -s "${SELFCHECK_TEST_STATE}/drops" ]] || fail "$mode did not drop scratch on exit"
  [[ ! -e "${SELFCHECK_TEST_STATE}/scratch" ]] || fail "$mode left scratch present"
}

run_case ok true 'restore verified'
[[ -e "${SELFCHECK_TEST_STATE}/snapshot" ]] || fail 'dump did not use the exported snapshot'
[[ -e "${SELFCHECK_TEST_STATE}/restore" ]] || fail 'successful backup was never restored'
[[ -e "${BACKUP_DIR}/daily/chronicle-latest.sql.gz" ]] || fail 'verified backup was not published'
gzip -t "${BACKUP_DIR}/daily/chronicle-latest.sql.gz"
# Preserve pg_dump's footer verbatim; the shared validator accepts it.
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="${ROOT_DIR}/selfhost" \
  python3 -m chronicle_ops.dump "${BACKUP_DIR}/daily/chronicle-latest.sql.gz"
ENABLE_ENCRYPTION=false run_case unencrypted true 'restore verified'
[[ ! -e "${SELFCHECK_TEST_STATE}/tde" ]] || fail 'unencrypted restore initialized TDE'
run_case restore_failure false 'restore failed'
[[ -e "${SELFCHECK_TEST_STATE}/restore" ]] || fail 'restore failure was not reached'
run_case missing_tde false 'lacks TDE'
[[ ! -e "${SELFCHECK_TEST_STATE}/restore" ]] || fail 'restore ran without tde_heap default'
run_case insufficient_space false 'insufficient space'
[[ ! -e "${SELFCHECK_TEST_STATE}/restore" ]] || fail 'restore ran without disk space'
run_case unknown_space false 'insufficient space'
run_case truncated_dump false 'lacks the final PostgreSQL database dump complete marker'
[[ ! -e "${SELFCHECK_TEST_STATE}/restore" ]] || fail 'truncated dump was restored'
run_case row_mismatch false 'study_participants row count mismatch'
run_case studies_mismatch false 'studies row count mismatch'
run_case version_mismatch false 'schema version mismatch'
run_case missing_table false 'missing public tables'

# A missing gzip trailer is rejected before any scratch restore, and cleanup still runs.
run_case corrupt_gzip false 'failed gzip integrity verification'
[[ ! -e "${SELFCHECK_TEST_STATE}/restore" ]] || fail 'corrupt gzip was restored'

# go-cron owns scheduling and job health, including failed restores above.
grep -Fq 'exec /usr/local/bin/go-cron -s "$SCHEDULE" -p "$HEALTHCHECK_PORT"' "${IMAGE_DIR}/init.sh" ||
  fail 'scheduler no longer owns the configured health endpoint'
grep -Fq 'CMD python3 /selfcheck.py health && curl -f "http://localhost:$HEALTHCHECK_PORT/" || exit 1' "${ROOT_DIR}/selfhost/Dockerfile.backup" ||
  fail 'healthcheck no longer probes go-cron'
grep -Fq 'timeout --signal=TERM --kill-after=30 "${BACKUP_VERIFY_TIMEOUT_SECONDS:-3600}"' "${IMAGE_DIR}/backup.sh" || fail 'restore self-check is not bounded'
echo 'self-host backup self-check test passed'
