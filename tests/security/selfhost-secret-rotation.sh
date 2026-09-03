#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
RUN_PARENT="${SELFHOST_ROTATION_TEST_ROOT:-${ROOT_DIR}/build/operator-test-runs/selfhost-secret-rotation}"
REAL_PYTHON="$(command -v python3)"

fail() {
  echo "self-host secret-rotation test failed: $*" >&2
  exit 1
}

! grep -Eq 'CREATE[[:space:]]+TABLE' "${ROOT_DIR}/selfhost/rotate-secret.sh" \
  || fail "rotate-secret.sh must not create schema outside Flyway"
TRACKING_SERVICE="${ROOT_DIR}/chronicle-server/src/main/kotlin/com/openlattice/chronicle/services/security/SecretRotationService.kt"
! grep -Eq 'CREATE[[:space:]]+TABLE' "$TRACKING_SERVICE" \
  || fail "SecretRotationService must not create schema outside Flyway"
TRACKING_MIGRATION="${ROOT_DIR}/chronicle-server/src/main/resources/db/migration/V83__own_secret_rotation_tracking.sql"
[[ -f "$TRACKING_MIGRATION" ]] || fail "secret-rotation tracking migration is missing"
grep -Fq 'CREATE TABLE IF NOT EXISTS secret_rotation_tracking' "$TRACKING_MIGRATION" \
  || fail "Flyway migration does not own secret-rotation tracking"

[[ "$RUN_PARENT" == /* ]] || fail "test run parent must be absolute"
case "$RUN_PARENT" in
  /tmp|/tmp/*|/private/tmp|/private/tmp/*|/var/folders|/var/folders/*)
    fail "test run parent must not use a system temporary directory"
    ;;
esac

umask 077
/bin/mkdir -p "$RUN_PARENT"
RUN_DIR="$(/usr/bin/mktemp -d "${RUN_PARENT}/run.XXXXXX")"
/bin/chmod 0700 "$RUN_DIR"
trap '/bin/rm -rf -- "$RUN_DIR"' EXIT

OLD_POSTGRES='fixture-old-postgres-password-0123456789'
OLD_MOBILE='fixture-old-mobile-signing-secret-0123456789'
OLD_JWT='fixture-old-jwt-signing-secret-0123456789'
OLD_METRICS='fixture-old-metrics-password-0123456789'
OLD_INTERNAL='fixture-old-internal-web-secret-0123456789'
OLD_GRAFANA='fixture-old-grafana-password-0123456789'
DASHBOARD_PASSWORD='fixture-"quoted\dashboard-password-0123456789'
GENERATED='abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789'
BCRYPT='$2a$14$fixturebcryptvalueabcdefghijklmnopqrstuv0123456789ABCDE'

write_secret_file() {
  local path="$1" value="$2"
  printf '%s' "$value" >"$path"
  /bin/chmod 0600 "$path"
}

setup_case() {
  local name="$1"
  CASE_DIR="${RUN_DIR}/${name}"
  SELFHOST_DIR="${CASE_DIR}/selfhost"
  COMMAND_DIR="${CASE_DIR}/commands"
  OUTPUT="${CASE_DIR}/output.txt"
  ARGS_LOG="${CASE_DIR}/argv.log"
  DB_PASSWORD_FILE="${CASE_DIR}/database-password"
  GRAFANA_PASSWORD_FILE="${CASE_DIR}/grafana-password"
  TDE_STATE_FILE="${CASE_DIR}/tde-state"
  GENERATED_FILE="${CASE_DIR}/generated-secret"
  DASHBOARD_FILE="${CASE_DIR}/dashboard-password"
  BCRYPT_FILE="${CASE_DIR}/bcrypt"
  FAIL_FIRST_UP_FILE="${CASE_DIR}/fail-first-up"
  KEYRING_BACKUP_FILE="${SELFHOST_DIR}/backups/keyring/chronicle-keyring.per"
  /bin/mkdir -p "$SELFHOST_DIR" "$COMMAND_DIR"
  /bin/cp "${ROOT_DIR}/selfhost/rotate-secret.sh" "$SELFHOST_DIR/"
  /bin/chmod 0755 "${SELFHOST_DIR}/rotate-secret.sh"
  write_secret_file "$DB_PASSWORD_FILE" "$OLD_POSTGRES"
  write_secret_file "$GRAFANA_PASSWORD_FILE" "$OLD_GRAFANA"
  write_secret_file "$TDE_STATE_FILE" 'chronicle_key|chronicle_keyring'
  write_secret_file "$GENERATED_FILE" "$GENERATED"
  write_secret_file "$DASHBOARD_FILE" "$DASHBOARD_PASSWORD"
  write_secret_file "$BCRYPT_FILE" "$BCRYPT"

  cat >"${SELFHOST_DIR}/.env" <<EOF
DOMAIN=chronicle.example.test
COMPOSE_PROJECT_NAME=chronicle-selfhost-rotation-fixture
CHRONICLE_STATE_DIR=.
COMPOSE_FILE=docker-compose.yml:overlays/mode-behind-proxy-internal.yml:overlays/backups.yml:overlays/monitoring.yml
ENABLE_ENCRYPTION=true
INTERNAL_BIND=127.0.0.1
INTERNAL_PORT=18081
DASHBOARD_USER=researcher
DASHBOARD_PASSWORD_HASH='$BCRYPT'
POSTGRES_USER=chronicle
POSTGRES_DB=chronicle
POSTGRES_PASSWORD='$OLD_POSTGRES'
MOBILE_SIGNING_ENABLED=true
MOBILE_SIGNING_REQUIRED=true
MOBILE_SIGNING_SECRET='$OLD_MOBILE'
MOBILE_SIGNING_SECRET_PREVIOUS=
JWT_SECRET='$OLD_JWT'
METRICS_PASSWORD='$OLD_METRICS'
CHRONICLE_INTERNAL_WEB_SECRET='$OLD_INTERNAL'
CHRONICLE_REVIEWER_ACCESS_ENABLED=false
CHRONICLE_REVIEWER_ACCESS_SECRET=
CHRONICLE_REVIEWER_STUDY_ID=00000000-0000-0000-0000-000000000001
CHRONICLE_REVIEWER_PARTICIPANT_ID=play-reviewer
GRAFANA_ADMIN_PASSWORD='$OLD_GRAFANA'
GRAFANA_BIND=127.0.0.1
GRAFANA_PORT=13000
CADDY_IMAGE=ghcr.io/example/caddy@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
RELEASE_VERSION=9.8.7-test.1
EOF
  /bin/chmod 0600 "${SELFHOST_DIR}/.env"

  cat >"${COMMAND_DIR}/openssl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == 'rand -hex 32' ]] || exit 81
cat "${SELFHOST_ROTATION_TEST_GENERATED_FILE}"
printf '\n'
EOF

  cat >"${COMMAND_DIR}/python3" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
for key in DASHBOARD_PASSWORD DASHBOARD_PASSWORD_HASH POSTGRES_PASSWORD MOBILE_SIGNING_SECRET \
  MOBILE_SIGNING_SECRET_PREVIOUS JWT_SECRET METRICS_PASSWORD CHRONICLE_INTERNAL_WEB_SECRET \
  CHRONICLE_REVIEWER_ACCESS_SECRET GRAFANA_ADMIN_PASSWORD SMTP_PASSWORD OIDC_CLIENT_SECRET; do
  [[ -z "${!key+x}" ]] || {
    echo "secret ${key} reached Python environment" >&2
    exit 82
  }
done
exec "${SELFHOST_ROTATION_TEST_REAL_PYTHON}" "$@"
EOF

  cat >"${COMMAND_DIR}/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

for key in DASHBOARD_PASSWORD DASHBOARD_PASSWORD_HASH POSTGRES_PASSWORD MOBILE_SIGNING_SECRET \
  MOBILE_SIGNING_SECRET_PREVIOUS JWT_SECRET METRICS_PASSWORD CHRONICLE_INTERNAL_WEB_SECRET \
  CHRONICLE_REVIEWER_ACCESS_SECRET GRAFANA_ADMIN_PASSWORD SMTP_PASSWORD OIDC_CLIENT_SECRET; do
  [[ -z "${!key+x}" ]] || {
    echo "secret ${key} reached Docker environment" >&2
    exit 83
  }
done

old_postgres="$(cat "${SELFHOST_ROTATION_TEST_OLD_POSTGRES_FILE}")"
generated="$(cat "${SELFHOST_ROTATION_TEST_GENERATED_FILE}")"
dashboard="$(cat "${SELFHOST_ROTATION_TEST_DASHBOARD_FILE}")"
for argument in "$@"; do
  for secret in "$old_postgres" "$generated" "$dashboard"; do
    [[ "$argument" != *"$secret"* ]] || {
      echo "secret reached Docker argv" >&2
      exit 84
    }
  done
  printf 'docker:%s\n' "$argument" >>"${SELFHOST_ROTATION_TEST_ARGS_LOG}"
done

if [[ "${1:-}" == inspect ]]; then
  printf 'true\n'
  exit 0
fi

if [[ "${1:-}" == run ]]; then
  plaintext="$(cat)"
  [[ "$plaintext" == "$dashboard" ]] || exit 85
  cat "${SELFHOST_ROTATION_TEST_BCRYPT_FILE}"
  printf '\n'
  exit 0
fi

[[ "${1:-}" == compose ]] || exit 86
shift
if [[ "${1:-}" == version ]]; then exit 0; fi
if [[ "${1:-}" == -p ]]; then shift 2; fi
case "${1:-}" in
  ps)
    service="${@: -1}"
    printf 'fixture-%s\n' "$service"
    ;;
  up)
    if [[ -n "${SELFHOST_ROTATION_TEST_FAIL_FIRST_UP_FILE:-}" && \
          ! -e "${SELFHOST_ROTATION_TEST_FAIL_FIRST_UP_FILE}" ]]; then
      : >"${SELFHOST_ROTATION_TEST_FAIL_FIRST_UP_FILE}"
      exit 87
    fi
    printf 'compose-up:%s\n' "$*" >>"${SELFHOST_ROTATION_TEST_ARGS_LOG}"
    ;;
  exec)
    if [[ "$*" == *'pg_dump'* ]]; then
      if [[ "${SELFHOST_ROTATION_TEST_PG_DUMP_FAIL:-false}" == true ]]; then
        printf '%s\n' '-- truncated fixture SQL dump'
        exit 98
      fi
      printf '%s\n' '-- fixture SQL dump'
      exit 0
    fi
    IFS= read -r -d '' auth_password || exit 88
    sql="$(cat)"
    current="$(cat "${SELFHOST_ROTATION_TEST_DB_PASSWORD_FILE}")"
    [[ "$auth_password" == "$current" ]] || exit 89
    if [[ "$sql" == *'ALTER ROLE CURRENT_USER'* ]]; then
      if [[ "$sql" == *"'$generated'"* ]]; then
        printf '%s' "$generated" >"${SELFHOST_ROTATION_TEST_DB_PASSWORD_FILE}"
      elif [[ "$sql" == *"'$old_postgres'"* ]]; then
        printf '%s' "$old_postgres" >"${SELFHOST_ROTATION_TEST_DB_PASSWORD_FILE}"
      else
        exit 90
      fi
    elif [[ "$sql" == *'SELECT 1;'* ]]; then
      printf '1\n'
    elif [[ "$sql" == *'FROM study_participants'* && "$sql" == *"participant_id = 'play-reviewer'"* ]]; then
      printf 'ok\n'
    elif [[ "$sql" == *"count(*) FILTER (WHERE a.amname <> 'tde_heap')"* ]]; then
      printf '0|7\n'
    elif [[ "$sql" == *'pg_tde_set_key_using_database_key_provider'* ]]; then
      key="$(printf '%s' "$sql" | sed -n \
        "s/.*pg_tde_set_key_using_database_key_provider('\([^']*\)', 'chronicle_keyring').*/\1/p" | tail -1)"
      [[ -n "$key" ]] || exit 96
      printf '%s|chronicle_keyring' "$key" >"${SELFHOST_ROTATION_TEST_TDE_STATE_FILE}"
    elif [[ "$sql" == *"key_name || '|' || provider_name"* ]]; then
      cat "${SELFHOST_ROTATION_TEST_TDE_STATE_FILE}"
      printf '\n'
    fi
    ;;
  run)
    [[ "$*" == *'--rm --no-deps db-init'* ]] || exit 97
    /bin/mkdir -p "$(dirname "${SELFHOST_ROTATION_TEST_KEYRING_BACKUP_FILE}")"
    printf 'fixture-current-live-keyring\n' >"${SELFHOST_ROTATION_TEST_KEYRING_BACKUP_FILE}"
    /bin/chmod 0600 "${SELFHOST_ROTATION_TEST_KEYRING_BACKUP_FILE}"
    ;;
  *) exit 91 ;;
esac
EOF

  cat >"${COMMAND_DIR}/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

for key in DASHBOARD_PASSWORD DASHBOARD_PASSWORD_HASH POSTGRES_PASSWORD MOBILE_SIGNING_SECRET \
  MOBILE_SIGNING_SECRET_PREVIOUS JWT_SECRET METRICS_PASSWORD CHRONICLE_INTERNAL_WEB_SECRET \
  CHRONICLE_REVIEWER_ACCESS_SECRET GRAFANA_ADMIN_PASSWORD SMTP_PASSWORD OIDC_CLIENT_SECRET; do
  [[ -z "${!key+x}" ]] || {
    echo "secret ${key} reached curl environment" >&2
    exit 92
  }
done

generated="$(cat "${SELFHOST_ROTATION_TEST_GENERATED_FILE}")"
dashboard="$(cat "${SELFHOST_ROTATION_TEST_DASHBOARD_FILE}")"
for argument in "$@"; do
  [[ "$argument" != *"$generated"* && "$argument" != *"$dashboard"* ]] || {
    echo "secret reached curl argv" >&2
    exit 93
  }
  printf 'curl:%s\n' "$argument" >>"${SELFHOST_ROTATION_TEST_ARGS_LOG}"
done

config="$(cat <&3)"
url="${@: -1}"
if [[ "$url" == *'/chronicle/' ]]; then
  escaped="${dashboard//\\/\\\\}"
  escaped="${escaped//\"/\\\"}"
  [[ "$config" == "user = \"researcher:${escaped}\"" ]] || exit 94
  printf '200'
  exit 0
fi

current="$(cat "${SELFHOST_ROTATION_TEST_GRAFANA_PASSWORD_FILE}")"
escaped="${current//\\/\\\\}"
escaped="${escaped//\"/\\\"}"
[[ "$config" == "user = \"admin:${escaped}\"" ]] || exit 95
if [[ "$url" == *'/api/user/password' ]]; then
  "${SELFHOST_ROTATION_TEST_REAL_PYTHON}" /dev/fd/3 \
    "${SELFHOST_ROTATION_TEST_GRAFANA_PASSWORD_FILE}" 3<<'PY'
import json
from pathlib import Path
import sys

state = Path(sys.argv[1])
document = json.load(sys.stdin)
current = state.read_text(encoding="utf-8")
assert document["oldPassword"] == current
assert document["newPassword"] == document["confirmNew"]
state.write_text(document["newPassword"], encoding="utf-8")
PY
fi
printf '200'
EOF

  /bin/chmod 0755 "${COMMAND_DIR}/openssl" "${COMMAND_DIR}/python3" \
    "${COMMAND_DIR}/docker" "${COMMAND_DIR}/curl"
}

run_rotation() {
  local fail_first_up="${1:-false}"
  shift || true
  local -a env_args=(
    "PATH=${COMMAND_DIR}:${PATH}"
    "SELFHOST_ROTATION_TEST_REAL_PYTHON=${REAL_PYTHON}"
    "SELFHOST_ROTATION_TEST_GENERATED_FILE=${GENERATED_FILE}"
    "SELFHOST_ROTATION_TEST_DASHBOARD_FILE=${DASHBOARD_FILE}"
    "SELFHOST_ROTATION_TEST_BCRYPT_FILE=${BCRYPT_FILE}"
    "SELFHOST_ROTATION_TEST_OLD_POSTGRES_FILE=${DB_PASSWORD_FILE}"
    "SELFHOST_ROTATION_TEST_DB_PASSWORD_FILE=${DB_PASSWORD_FILE}"
    "SELFHOST_ROTATION_TEST_GRAFANA_PASSWORD_FILE=${GRAFANA_PASSWORD_FILE}"
    "SELFHOST_ROTATION_TEST_TDE_STATE_FILE=${TDE_STATE_FILE}"
    "SELFHOST_ROTATION_TEST_KEYRING_BACKUP_FILE=${KEYRING_BACKUP_FILE}"
    "SELFHOST_ROTATION_TEST_ARGS_LOG=${ARGS_LOG}"
  )
  if [[ "$fail_first_up" == true ]]; then
    env_args+=("SELFHOST_ROTATION_TEST_FAIL_FIRST_UP_FILE=${FAIL_FIRST_UP_FILE}")
  fi
  if [[ "${CASE_PG_DUMP_FAIL:-false}" == true ]]; then
    env_args+=("SELFHOST_ROTATION_TEST_PG_DUMP_FAIL=true")
  fi
  (cd "$SELFHOST_DIR" && env "${env_args[@]}" /bin/bash ./rotate-secret.sh "$@") \
    >"$OUTPUT" 2>&1
}

write_transaction() {
  local kind="$1" action="$2" phase="$3"
  local transaction="${SELFHOST_DIR}/.chronicle-secret-rotation"
  /bin/mkdir "$transaction"
  /bin/chmod 0700 "$transaction"
  /bin/cp "${SELFHOST_DIR}/.env" "${transaction}/old.env"
  printf '%s\n' "$kind" >"${transaction}/kind"
  printf '%s\n' "$action" >"${transaction}/action"
  printf '%s\n' "$phase" >"${transaction}/phase"
  /bin/chmod 0600 "${transaction}/old.env" "${transaction}/kind" \
    "${transaction}/action" "${transaction}/phase"
}

replace_env_value() {
  local key="$1" value="$2" temporary="${SELFHOST_DIR}/.env.replacement"
  printf '%s\0%s\0' "$key" "$value" | \
    "$REAL_PYTHON" /dev/fd/3 "${SELFHOST_DIR}/.env" "$temporary" 3<<'PY'
from pathlib import Path
import re
import sys

source = Path(sys.argv[1])
destination = Path(sys.argv[2])
values = sys.stdin.buffer.read().split(b"\0")
if values and values[-1] == b"":
    values.pop()
if len(values) != 2:
    raise SystemExit("malformed fixture env update")
key, value = (item.decode("utf-8") for item in values)
text = source.read_text(encoding="utf-8")
pattern = re.compile(rf"^{re.escape(key)}=.*$", re.MULTILINE)
if len(pattern.findall(text)) != 1:
    raise SystemExit(f"expected exactly one {key}")
destination.write_text(pattern.sub(lambda _match: f"{key}='{value}'", text), encoding="utf-8")
PY
  /bin/chmod 0600 "$temporary"
  /bin/mv "$temporary" "${SELFHOST_DIR}/.env"
}

assert_custody() {
  local output="$1" args="$2"
  for secret in "$OLD_POSTGRES" "$OLD_MOBILE" "$OLD_JWT" "$OLD_METRICS" \
    "$OLD_INTERNAL" "$OLD_GRAFANA" "$DASHBOARD_PASSWORD" "$GENERATED"; do
    ! grep -Fq "$secret" "$output" || fail "secret was printed"
    [[ ! -e "$args" ]] || ! grep -Fq "$secret" "$args" || fail "secret reached subprocess argv"
  done
  if [[ -d "${SELFHOST_DIR}/.chronicle-secret-rotation" ]]; then
    fail "successful rotation left its transaction directory"
  fi
  receipt="$(find "${SELFHOST_DIR}/operator-receipts/secret-rotations" -type f -name '*.json' | head -1)"
  [[ -n "$receipt" && -s "$receipt" ]] || fail "successful rotation emitted no receipt"
  /bin/chmod 0600 "$receipt" 2>/dev/null || true
  for secret in "$OLD_POSTGRES" "$OLD_MOBILE" "$OLD_JWT" "$OLD_METRICS" \
    "$OLD_INTERNAL" "$OLD_GRAFANA" "$DASHBOARD_PASSWORD" "$GENERATED"; do
    ! grep -Fq "$secret" "$receipt" || fail "receipt contains a secret"
  done
}

setup_case restore-interlock
/bin/mkdir "${SELFHOST_DIR}/.chronicle-restore.lock"
set +e
run_rotation false --yes jwt
restore_interlock_status=$?
set -e
[[ "$restore_interlock_status" -ne 0 ]] || fail "rotation ignored an active restore lock"
[[ ! -e "${SELFHOST_DIR}/.chronicle-secret-rotation" ]] ||
  fail "restore interlock left a partial rotation transaction"
grep -Fq 'a restore is active or incomplete' "$OUTPUT" ||
  fail "rotation did not explain the restore interlock"

setup_case tde-restore-interlock
/bin/mkdir "${SELFHOST_DIR}/.chronicle-restore.lock"
set +e
run_rotation false --yes tde
tde_restore_interlock_status=$?
set -e
[[ "$tde_restore_interlock_status" -ne 0 ]] ||
  fail "TDE rotation ignored an active restore lock"
! grep -Fq pg_dump "$ARGS_LOG" ||
  fail "TDE rotation took a database backup before acquiring its operation lock"

setup_case jwt
run_rotation false --yes jwt
grep -Fqx "JWT_SECRET='$GENERATED'" "${SELFHOST_DIR}/.env" || fail "JWT secret was not updated"
grep -Fq 'compose-up:' "$ARGS_LOG" || fail "JWT rotation did not recreate the backend"
assert_custody "$OUTPUT" "$ARGS_LOG"

setup_case dashboard
{
  printf '%s\n' "$DASHBOARD_PASSWORD"
  printf '%s\n' "$DASHBOARD_PASSWORD"
} | (cd "$SELFHOST_DIR" && env \
  "PATH=${COMMAND_DIR}:${PATH}" \
  "SELFHOST_ROTATION_TEST_REAL_PYTHON=${REAL_PYTHON}" \
  "SELFHOST_ROTATION_TEST_GENERATED_FILE=${GENERATED_FILE}" \
  "SELFHOST_ROTATION_TEST_DASHBOARD_FILE=${DASHBOARD_FILE}" \
  "SELFHOST_ROTATION_TEST_BCRYPT_FILE=${BCRYPT_FILE}" \
  "SELFHOST_ROTATION_TEST_OLD_POSTGRES_FILE=${DB_PASSWORD_FILE}" \
  "SELFHOST_ROTATION_TEST_DB_PASSWORD_FILE=${DB_PASSWORD_FILE}" \
  "SELFHOST_ROTATION_TEST_GRAFANA_PASSWORD_FILE=${GRAFANA_PASSWORD_FILE}" \
  "SELFHOST_ROTATION_TEST_TDE_STATE_FILE=${TDE_STATE_FILE}" \
  "SELFHOST_ROTATION_TEST_ARGS_LOG=${ARGS_LOG}" \
  /bin/bash ./rotate-secret.sh dashboard) >"$OUTPUT" 2>&1 \
  || fail "dashboard rotation fixture failed"
grep -Fqx "DASHBOARD_PASSWORD_HASH='$BCRYPT'" "${SELFHOST_DIR}/.env" \
  || fail "dashboard bcrypt hash was not updated"
assert_custody "$OUTPUT" "$ARGS_LOG"

setup_case reviewer
run_rotation false --yes reviewer
grep -Fqx "CHRONICLE_REVIEWER_ACCESS_ENABLED='true'" "${SELFHOST_DIR}/.env" \
  || fail "reviewer rotation did not enable the exact reviewer route"
grep -Fqx "CHRONICLE_REVIEWER_ACCESS_SECRET='$GENERATED'" "${SELFHOST_DIR}/.env" \
  || fail "reviewer rotation did not publish the generated credential"
grep -Fq 'compose-up:up -d --wait --wait-timeout 300 --no-deps --force-recreate backend' "$ARGS_LOG" \
  || fail "reviewer rotation did not recreate only the backend"
assert_custody "$OUTPUT" "$ARGS_LOG"

setup_case mobile
run_rotation false --yes mobile begin
grep -Fqx "MOBILE_SIGNING_SECRET='$GENERATED'" "${SELFHOST_DIR}/.env" \
  || fail "mobile begin did not make the new key current"
grep -Fqx "MOBILE_SIGNING_SECRET_PREVIOUS='$OLD_MOBILE'" "${SELFHOST_DIR}/.env" \
  || fail "mobile begin did not retain the previous key"
assert_custody "$OUTPUT" "$ARGS_LOG"
/bin/rm -rf "${SELFHOST_DIR}/operator-receipts"
: >"$OUTPUT"; : >"$ARGS_LOG"
run_rotation false --yes mobile finalize
grep -Fqx "MOBILE_SIGNING_SECRET='$GENERATED'" "${SELFHOST_DIR}/.env" \
  || fail "mobile finalize changed the current key"
grep -Fqx "MOBILE_SIGNING_SECRET_PREVIOUS=''" "${SELFHOST_DIR}/.env" \
  || fail "mobile finalize did not remove the previous key"
assert_custody "$OUTPUT" "$ARGS_LOG"

setup_case postgres
run_rotation false --yes postgres
grep -Fqx "POSTGRES_PASSWORD='$GENERATED'" "${SELFHOST_DIR}/.env" \
  || fail "PostgreSQL password was not updated in .env"
[[ "$(cat "$DB_PASSWORD_FILE")" == "$GENERATED" ]] \
  || fail "PostgreSQL role password was not updated"
grep -Fq 'compose-up:up -d --wait --wait-timeout 300 --remove-orphans' "$ARGS_LOG" \
  || fail "PostgreSQL rotation did not reconcile the complete stack"
assert_custody "$OUTPUT" "$ARGS_LOG"

setup_case grafana
run_rotation false --yes grafana
grep -Fqx "GRAFANA_ADMIN_PASSWORD='$GENERATED'" "${SELFHOST_DIR}/.env" \
  || fail "Grafana password was not updated in .env"
[[ "$(cat "$GRAFANA_PASSWORD_FILE")" == "$GENERATED" ]] \
  || fail "Grafana API password was not updated"
assert_custody "$OUTPUT" "$ARGS_LOG"

setup_case tde
run_rotation false --yes tde
[[ "$(cat "$TDE_STATE_FILE")" == chronicle_key_*'|chronicle_keyring' ]] \
  || fail "TDE rotation did not activate a new principal key"
backup_count="$(find "${SELFHOST_DIR}/backups/secret-rotation" -type f -name '*.sql.gz' | wc -l | tr -d ' ')"
[[ "$backup_count" == 1 ]] || fail "TDE rotation did not retain exactly one fresh SQL backup"
gzip -t "$(find "${SELFHOST_DIR}/backups/secret-rotation" -type f -name '*.sql.gz' | head -1)" \
  || fail "TDE pre-rotation backup is not a valid gzip stream"
[[ -s "$KEYRING_BACKUP_FILE" ]] || fail "TDE rotation did not refresh the keyring backup"
assert_custody "$OUTPUT" "$ARGS_LOG"

setup_case rollback
set +e
run_rotation true --yes internal-web
rollback_status=$?
set -e
[[ "$rollback_status" -ne 0 ]] || fail "forced service failure unexpectedly succeeded"
grep -Fqx "CHRONICLE_INTERNAL_WEB_SECRET='$OLD_INTERNAL'" "${SELFHOST_DIR}/.env" \
  || fail "failed rotation did not restore the prior .env"
[[ ! -e "${SELFHOST_DIR}/.chronicle-secret-rotation" ]] \
  || fail "successful automatic rollback left a stale transaction"
for secret in "$OLD_INTERNAL" "$GENERATED"; do
  ! grep -Fq "$secret" "$OUTPUT" || fail "rollback output printed a secret"
  ! grep -Fq "$secret" "$ARGS_LOG" || fail "rollback put a secret in subprocess argv"
done

setup_case recover-jwt-forward
write_transaction jwt rotate env-published
replace_env_value JWT_SECRET "$GENERATED"
run_rotation false --yes recover --forward
grep -Fqx "JWT_SECRET='$GENERATED'" "${SELFHOST_DIR}/.env" \
  || fail "JWT forward recovery did not retain the published secret"
assert_custody "$OUTPUT" "$ARGS_LOG"

setup_case recover-internal-rollback
write_transaction internal-web rotate env-published
replace_env_value CHRONICLE_INTERNAL_WEB_SECRET "$GENERATED"
run_rotation false --yes recover --rollback
grep -Fqx "CHRONICLE_INTERNAL_WEB_SECRET='$OLD_INTERNAL'" "${SELFHOST_DIR}/.env" \
  || fail "internal-web rollback recovery did not restore the saved secret"
assert_custody "$OUTPUT" "$ARGS_LOG"

setup_case recover-postgres-forward
write_transaction postgres rotate env-published
replace_env_value POSTGRES_PASSWORD "$GENERATED"
run_rotation false --yes recover --forward
[[ "$(cat "$DB_PASSWORD_FILE")" == "$GENERATED" ]] \
  || fail "PostgreSQL forward recovery did not reconcile the database role"
assert_custody "$OUTPUT" "$ARGS_LOG"

setup_case recover-grafana-forward
write_transaction grafana rotate env-published
replace_env_value GRAFANA_ADMIN_PASSWORD "$GENERATED"
run_rotation false --yes recover --forward
[[ "$(cat "$GRAFANA_PASSWORD_FILE")" == "$GENERATED" ]] \
  || fail "Grafana forward recovery did not reconcile the API password"
assert_custody "$OUTPUT" "$ARGS_LOG"

setup_case recover-tde-forward
write_transaction tde rotate tde-metadata-ready
printf '%s\n' chronicle_key >"${SELFHOST_DIR}/.chronicle-secret-rotation/old-tde-key"
printf '%s\n' chronicle_key_recovery >"${SELFHOST_DIR}/.chronicle-secret-rotation/new-tde-key"
/bin/chmod 0600 "${SELFHOST_DIR}/.chronicle-secret-rotation/old-tde-key" \
  "${SELFHOST_DIR}/.chronicle-secret-rotation/new-tde-key"
run_rotation false --yes recover --forward
[[ "$(cat "$TDE_STATE_FILE")" == 'chronicle_key_recovery|chronicle_keyring' ]] \
  || fail "TDE forward recovery did not activate the saved new key"
assert_custody "$OUTPUT" "$ARGS_LOG"

setup_case recover-tde-pre-activation
write_transaction tde rotate prepared
# A hard stop can occur while publishing the pair. A partial file is safe to remove because
# the durable tde-metadata-ready checkpoint is always written before PostgreSQL is touched.
printf '%s\n' chronicle_key >"${SELFHOST_DIR}/.chronicle-secret-rotation/old-tde-key"
/bin/chmod 0600 "${SELFHOST_DIR}/.chronicle-secret-rotation/old-tde-key"
run_rotation false --yes recover --rollback
[[ ! -e "${SELFHOST_DIR}/.chronicle-secret-rotation" ]] \
  || fail "pre-activation TDE rollback did not remove its transaction"
[[ "$(cat "$TDE_STATE_FILE")" == 'chronicle_key|chronicle_keyring' ]] \
  || fail "pre-activation TDE rollback changed the active key"
grep -Fq 'before its durable key-activation checkpoint' "$OUTPUT" \
  || fail "pre-activation TDE rollback did not explain the safe boundary"

setup_case reject-tde-pre-activation-forward
write_transaction tde rotate prepared
set +e
run_rotation false --yes recover --forward
pre_activation_forward_status=$?
set -e
[[ "$pre_activation_forward_status" -ne 0 ]] \
  || fail "pre-activation TDE transaction allowed forward recovery"
[[ -d "${SELFHOST_DIR}/.chronicle-secret-rotation" ]] \
  || fail "rejected pre-activation TDE recovery discarded its transaction"
grep -Fq 'only recover --rollback is safe' "$OUTPUT" \
  || fail "rejected pre-activation TDE recovery did not explain the safe direction"

setup_case reject-tde-incomplete-checkpoint
write_transaction tde rotate tde-metadata-ready
printf '%s\n' chronicle_key >"${SELFHOST_DIR}/.chronicle-secret-rotation/old-tde-key"
/bin/chmod 0600 "${SELFHOST_DIR}/.chronicle-secret-rotation/old-tde-key"
set +e
run_rotation false --yes recover --rollback
incomplete_checkpoint_status=$?
set -e
[[ "$incomplete_checkpoint_status" -ne 0 ]] \
  || fail "TDE recovery accepted an incomplete durable metadata checkpoint"
[[ -d "${SELFHOST_DIR}/.chronicle-secret-rotation" ]] \
  || fail "incomplete TDE checkpoint was not preserved for diagnosis"

setup_case unprepared-recovery
/bin/mkdir "${SELFHOST_DIR}/.chronicle-secret-rotation"
/bin/chmod 0700 "${SELFHOST_DIR}/.chronicle-secret-rotation"
run_rotation false --yes recover --rollback
[[ ! -e "${SELFHOST_DIR}/.chronicle-secret-rotation" ]] \
  || fail "rollback recovery did not remove a pre-publication lock"

setup_case recovery-failure-preserved
write_transaction postgres rotate database-updated
replace_env_value POSTGRES_PASSWORD "$GENERATED"
printf '%s' 'fixture-unrelated-database-password' >"$DB_PASSWORD_FILE"
set +e
run_rotation false --yes recover --forward
recovery_status=$?
set -e
[[ "$recovery_status" -ne 0 ]] || fail "ambiguous PostgreSQL recovery unexpectedly succeeded"
[[ -d "${SELFHOST_DIR}/.chronicle-secret-rotation" ]] \
  || fail "failed recovery discarded its transaction evidence"
for secret in "$OLD_POSTGRES" "$GENERATED"; do
  ! grep -Fq "$secret" "$OUTPUT" || fail "failed recovery printed a secret"
  ! grep -Fq "$secret" "$ARGS_LOG" || fail "failed recovery put a secret in subprocess argv"
done

setup_case tde-partial-cleanup
CASE_PG_DUMP_FAIL=true
set +e
run_rotation false --yes tde
backup_failure_status=$?
set -e
unset CASE_PG_DUMP_FAIL
[[ "$backup_failure_status" -ne 0 ]] || fail "failed TDE backup unexpectedly allowed rotation"
if find "${SELFHOST_DIR}/backups/secret-rotation" -type f -name '*.partial' -print -quit 2>/dev/null | grep -q .; then
  fail "failed TDE pre-rotation backup left a partial file"
fi
[[ "$(cat "$TDE_STATE_FILE")" == 'chronicle_key|chronicle_keyring' ]] \
  || fail "TDE key changed after the pre-rotation backup failed"

echo "self-host secret-rotation test passed"
