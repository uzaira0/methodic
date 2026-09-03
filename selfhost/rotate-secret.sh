#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
cd "$SCRIPT_DIR"

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

warn() {
  printf 'WARNING: %s\n' "$*" >&2
}

log() {
  printf '%s\n' "$*"
}

usage() {
  cat <<'EOF'
Usage:
  ./chronicle rotate-secret [--yes] dashboard
  ./chronicle rotate-secret [--yes] jwt
  ./chronicle rotate-secret [--yes] internal-web
  ./chronicle rotate-secret [--yes] reviewer
  ./chronicle rotate-secret [--yes] metrics
  ./chronicle rotate-secret [--yes] postgres
  ./chronicle rotate-secret [--yes] grafana
  ./chronicle rotate-secret [--yes] mobile begin|finalize|abort
  ./chronicle rotate-secret [--yes] tde
  ./chronicle rotate-secret recover --forward|--rollback [--yes]

Passwords and generated secrets are never accepted as command arguments or printed. The
dashboard command reads a chosen password silently; every other command generates a new
256-bit value directly into the mode-0600 .env file. Mobile rotation is deliberately two
phase: begin accepts the old and new app keys together, and finalize removes the old key
only after every supported mobile build has moved.

If a host crash leaves .chronicle-secret-rotation behind, do not delete it. Review the
runbook, confirm no rotation process remains, and use recover to finish the published
credential or restore the saved pre-rotation configuration.
EOF
}

ASSUME_YES=false
RECOVERY_DIRECTION=""
POSITIONAL=()
while (($#)); do
  case "$1" in
    --yes) ASSUME_YES=true ;;
    --forward|--rollback)
      [[ -z "$RECOVERY_DIRECTION" ]] || { usage >&2; fail "choose only one recovery direction"; }
      RECOVERY_DIRECTION="${1#--}"
      ;;
    -h|--help) usage; exit 0 ;;
    --*) usage >&2; fail "unknown option: $1" ;;
    *) POSITIONAL+=("$1") ;;
  esac
  shift
done

[[ ${#POSITIONAL[@]} -ge 1 && ${#POSITIONAL[@]} -le 2 ]] || {
  usage >&2
  exit 2
}
ROTATION_KIND="${POSITIONAL[0]}"
ROTATION_ACTION="${POSITIONAL[1]:-rotate}"
if [[ "$ROTATION_KIND" == recover ]]; then
  [[ ${#POSITIONAL[@]} -eq 1 && -n "$RECOVERY_DIRECTION" ]] || {
    usage >&2
    fail "recover requires exactly one of --forward or --rollback"
  }
  ROTATION_ACTION="$RECOVERY_DIRECTION"
elif [[ -n "$RECOVERY_DIRECTION" ]]; then
  usage >&2
  fail "--forward and --rollback are valid only with recover"
fi

for command in docker python3 openssl curl date; do
  command -v "$command" >/dev/null 2>&1 || fail "required command is unavailable: $command"
done
docker compose version >/dev/null 2>&1 || fail "the Docker Compose plugin is unavailable"
[[ -f .env && ! -L .env ]] || fail ".env must be a regular file; run ./chronicle setup first"
env_mode="$(stat -c '%a' .env 2>/dev/null || stat -f '%Lp' .env 2>/dev/null || true)"
[[ "$env_mode" == 600 ]] ||
  fail ".env is mode ${env_mode:-unknown}; run chmod 600 .env before rotating credentials"

# .env is the deployment authority. Load values for shell decisions without exporting the
# entire secret set into docker, curl, Python, or any other child process.
# shellcheck disable=SC1091
. ./.env
SECRET_ENV_KEYS=(
  DASHBOARD_PASSWORD DASHBOARD_PASSWORD_HASH POSTGRES_PASSWORD MOBILE_SIGNING_SECRET
  MOBILE_SIGNING_SECRET_PREVIOUS JWT_SECRET METRICS_PASSWORD
  CHRONICLE_INTERNAL_WEB_SECRET GRAFANA_ADMIN_PASSWORD SMTP_PASSWORD
  CHRONICLE_REVIEWER_ACCESS_SECRET
  OIDC_CLIENT_SECRET
)
for secret_key in "${SECRET_ENV_KEYS[@]}"; do
  export -n "${secret_key?}" 2>/dev/null || true
done

PROJECT="${COMPOSE_PROJECT_NAME:-chronicle-selfhost}"
STATE_TEXT="${CHRONICLE_STATE_DIR:-.}"
if [[ "$STATE_TEXT" == /* ]]; then
  STATE_ROOT="$STATE_TEXT"
else
  STATE_ROOT="${SCRIPT_DIR}/${STATE_TEXT#./}"
fi
STATE_ROOT="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$STATE_ROOT")"
[[ -d "$STATE_ROOT" ]] || fail "CHRONICLE_STATE_DIR does not exist: $STATE_ROOT"
: "${SECRET_ROTATION_WAIT_TIMEOUT_SECONDS:=300}"
[[ "$SECRET_ROTATION_WAIT_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] ||
  fail "SECRET_ROTATION_WAIT_TIMEOUT_SECONDS must be a positive integer"
(( SECRET_ROTATION_WAIT_TIMEOUT_SECONDS <= 3600 )) ||
  fail "SECRET_ROTATION_WAIT_TIMEOUT_SECONDS must not exceed 3600"

ROTATION_DIR="${STATE_ROOT}/.chronicle-secret-rotation"
UPGRADE_LOCK_DIR="${STATE_ROOT}/.chronicle-upgrade.lock"
RESTORE_LOCK_DIR="${STATE_ROOT}/.chronicle-restore.lock"
RECEIPT_DIR="${STATE_ROOT}/operator-receipts/secret-rotations"
TRANSACTION_ACTIVE=false
ROLLBACK_REQUIRED=false
EXTERNAL_CHANGED=false
APPLY_MODE=services
APPLY_SERVICES=()
OLD_SECRET=""
NEW_SECRET=""
OLD_TDE_KEY=""
NEW_TDE_KEY=""
RECEIPT_DETAIL=""
BACKUP_PARTIAL=""
SAVED_ROTATION_KIND=""
SAVED_ROTATION_ACTION=""
SAVED_ROTATION_PHASE=""
TRANSACTION_PREPARED=false
GRAFANA_URL=""

dc() {
  docker compose -p "$PROJECT" "$@"
}

confirm() {
  local prompt="$1" answer
  [[ "$ASSUME_YES" == true ]] && return 0
  [[ -t 0 ]] || fail "confirmation requires a terminal; review the runbook, then repeat with --yes"
  read -rp "${prompt} [y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]] || fail "rotation cancelled"
}

service_running() {
  local service="$1" container_id
  container_id="$(dc ps -q "$service" 2>/dev/null)"
  [[ -n "$container_id" ]] || fail "Compose service '$service' is not running"
  [[ "$(docker inspect -f '{{.State.Running}}' "$container_id" 2>/dev/null)" == true ]] ||
    fail "Compose service '$service' is not running"
}

write_phase() {
  local phase="$1"
  python3 - "$ROTATION_DIR" "$phase" <<'PY'
from pathlib import Path
import os
import sys

root = Path(sys.argv[1])
phase = sys.argv[2]
temporary = root / f".phase.{os.getpid()}"
destination = root / "phase"
flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
if hasattr(os, "O_NOFOLLOW"):
    flags |= os.O_NOFOLLOW
fd = os.open(temporary, flags, 0o600)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(f"{phase}\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, destination)
    directory_fd = os.open(root, os.O_RDONLY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)
finally:
    try:
        temporary.unlink()
    except FileNotFoundError:
        pass
PY
}

sync_transaction_metadata() {
  python3 - "$ROTATION_DIR" <<'PY'
from pathlib import Path
import os
import sys

root = Path(sys.argv[1])
for name in ("old.env", "kind", "action", "owner-pid", "started-at"):
    fd = os.open(root / name, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
directory_fd = os.open(root, os.O_RDONLY)
try:
    os.fsync(directory_fd)
finally:
    os.close(directory_fd)
PY
}

write_tde_recovery_metadata() {
  printf '%s\0%s\0' "$OLD_TDE_KEY" "$NEW_TDE_KEY" | python3 /dev/fd/3 "$ROTATION_DIR" 3<<'PY'
from pathlib import Path
import os
import sys

root = Path(sys.argv[1])
values = sys.stdin.buffer.read().split(b"\0")
if values and values[-1] == b"":
    values.pop()
if len(values) != 2 or any(not value for value in values):
    raise SystemExit("malformed TDE recovery metadata")

for name, value in zip(("old-tde-key", "new-tde-key"), values):
    temporary = root / f".{name}.{os.getpid()}"
    destination = root / name
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = os.open(temporary, flags, 0o600)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(value + b"\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, destination)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass

directory_fd = os.open(root, os.O_RDONLY)
try:
    os.fsync(directory_fd)
finally:
    os.close(directory_fd)
PY
}

begin_transaction() {
  local kind="$1" action="$2"
  [[ ! -e "$UPGRADE_LOCK_DIR" && ! -L "$UPGRADE_LOCK_DIR" ]] ||
    fail "an upgrade is active or incomplete ($UPGRADE_LOCK_DIR); do not rotate secrets concurrently"
  [[ ! -e "$RESTORE_LOCK_DIR" && ! -L "$RESTORE_LOCK_DIR" ]] ||
    fail "a restore is active or incomplete ($RESTORE_LOCK_DIR); do not rotate secrets concurrently"
  if ! /bin/mkdir "$ROTATION_DIR" 2>/dev/null; then
    fail "a prior secret rotation is active or incomplete ($ROTATION_DIR). Do not delete it; follow the interrupted-rotation procedure in docs/SECRET-ROTATION.md."
  fi
  if ! /bin/chmod 0700 "$ROTATION_DIR"; then
    /bin/rmdir "$ROTATION_DIR" 2>/dev/null || true
    fail "could not protect the secret-rotation transaction directory"
  fi
  # Close the check-then-mkdir race with the other state-changing operator commands. If a
  # competing lock appeared, this directory is still empty and can be released safely.
  if [[ -e "$UPGRADE_LOCK_DIR" || -L "$UPGRADE_LOCK_DIR" ]]; then
    /bin/rmdir "$ROTATION_DIR" 2>/dev/null || true
    fail "an upgrade started while the secret-rotation lock was being acquired; rotation did not start"
  fi
  if [[ -e "$RESTORE_LOCK_DIR" || -L "$RESTORE_LOCK_DIR" ]]; then
    /bin/rmdir "$ROTATION_DIR" 2>/dev/null || true
    fail "a restore started while the secret-rotation lock was being acquired; rotation did not start"
  fi
  /bin/cp .env "${ROTATION_DIR}/old.env"
  /bin/chmod 0600 "${ROTATION_DIR}/old.env"
  printf '%s\n' "$kind" >"${ROTATION_DIR}/kind"
  printf '%s\n' "$action" >"${ROTATION_DIR}/action"
  printf '%s\n' "$$" >"${ROTATION_DIR}/owner-pid"
  printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"${ROTATION_DIR}/started-at"
  /bin/chmod 0600 "${ROTATION_DIR}/kind" "${ROTATION_DIR}/action" \
    "${ROTATION_DIR}/owner-pid" "${ROTATION_DIR}/started-at"
  # The durable phase marker is the recovery commit point. Flush every file it refers to
  # before publishing it so a power loss cannot preserve `prepared` without its metadata.
  sync_transaction_metadata
  write_phase prepared
  TRANSACTION_ACTIVE=true
  ROLLBACK_REQUIRED=true
}

remove_transaction() {
  [[ -d "$ROTATION_DIR" ]] || return 0
  /bin/rm -f -- \
    "${ROTATION_DIR}/old.env" \
    "${ROTATION_DIR}/kind" \
    "${ROTATION_DIR}/action" \
    "${ROTATION_DIR}/phase" \
    "${ROTATION_DIR}/owner-pid" \
    "${ROTATION_DIR}/started-at" \
    "${ROTATION_DIR}/old-tde-key" \
    "${ROTATION_DIR}/new-tde-key"
  local phase_temporary
  for phase_temporary in \
      "${ROTATION_DIR}"/.phase.* \
      "${ROTATION_DIR}"/.old-tde-key.* \
      "${ROTATION_DIR}"/.new-tde-key.*; do
    [[ -e "$phase_temporary" || -L "$phase_temporary" ]] || continue
    /bin/rm -f -- "$phase_temporary"
  done
  /bin/rmdir "$ROTATION_DIR"
  TRANSACTION_ACTIVE=false
}

env_update() {
  (($# >= 2 && $# % 2 == 0)) || fail "internal error: env_update needs key/value pairs"
  {
    while (($#)); do
      printf '%s\0%s\0' "$1" "$2"
      shift 2
    done
  } | python3 /dev/fd/3 .env 3<<'PY'
from pathlib import Path
import os
import re
import sys

path = Path(sys.argv[1])
raw = sys.stdin.buffer.read().split(b"\0")
if raw and raw[-1] == b"":
    raw.pop()
if len(raw) % 2:
    raise SystemExit("malformed secret update payload")

allowed = {
    "DASHBOARD_PASSWORD_HASH",
    "POSTGRES_PASSWORD",
    "MOBILE_SIGNING_SECRET",
    "MOBILE_SIGNING_SECRET_PREVIOUS",
    "JWT_SECRET",
    "METRICS_PASSWORD",
    "CHRONICLE_INTERNAL_WEB_SECRET",
    "CHRONICLE_REVIEWER_ACCESS_ENABLED",
    "CHRONICLE_REVIEWER_ACCESS_SECRET",
    "GRAFANA_ADMIN_PASSWORD",
}
updates = {}
for index in range(0, len(raw), 2):
    key = raw[index].decode("ascii")
    value = raw[index + 1].decode("utf-8")
    if key not in allowed:
        raise SystemExit(f"unsupported secret key: {key}")
    if key in updates:
        raise SystemExit(f"duplicate secret update: {key}")
    if any(character in value for character in ("\x00", "\n", "\r", "'")):
        raise SystemExit(f"{key} contains a character that cannot be represented safely in .env")
    updates[key] = value

text = path.read_text(encoding="utf-8")
for key, value in updates.items():
    pattern = re.compile(rf"^{re.escape(key)}=.*$", re.MULTILINE)
    if len(pattern.findall(text)) != 1:
        raise SystemExit(f"expected exactly one {key} assignment in .env")
    replacement = f"{key}='{value}'"
    text = pattern.sub(lambda _match, replacement=replacement: replacement, text, count=1)

temporary = path.with_name(f".{path.name}.rotation-{os.getpid()}")
fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(text)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)
    directory_fd = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)
finally:
    try:
        temporary.unlink()
    except FileNotFoundError:
        pass
PY
  /bin/chmod 0600 .env
}

restore_old_env() {
  python3 - .env "${ROTATION_DIR}/old.env" <<'PY'
from pathlib import Path
import os
import sys

destination = Path(sys.argv[1])
source = Path(sys.argv[2])
data = source.read_bytes()
temporary = destination.with_name(f".{destination.name}.rollback-{os.getpid()}")
fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
try:
    with os.fdopen(fd, "wb") as handle:
        handle.write(data)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, destination)
    directory_fd = os.open(destination.parent, os.O_RDONLY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)
finally:
    try:
        temporary.unlink()
    except FileNotFoundError:
        pass
PY
  /bin/chmod 0600 .env
}

apply_configuration() {
  if [[ "$APPLY_MODE" == full ]]; then
    dc up -d --wait --wait-timeout "$SECRET_ROTATION_WAIT_TIMEOUT_SECONDS" --remove-orphans
  else
    ((${#APPLY_SERVICES[@]} > 0)) || fail "internal error: no services selected for rotation"
    dc up -d --wait --wait-timeout "$SECRET_ROTATION_WAIT_TIMEOUT_SECONDS" \
      --no-deps --force-recreate "${APPLY_SERVICES[@]}"
  fi
}

escape_curl_config_value() {
  local value="$1"
  case "$value" in
    *$'\n'*|*$'\r'*) return 2 ;;
  esac
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  CURL_CONFIG_VALUE="$value"
}

curl_basic_code() {
  local username="$1" password="$2" url="$3"
  escape_curl_config_value "${username}:${password}" || return 2
  curl --config /dev/fd/3 -sk -o /dev/null -w '%{http_code}' --max-time 15 "$url" \
    3< <(printf 'user = "%s"\n' "$CURL_CONFIG_VALUE")
}

grafana_change_password() {
  local old_password="$1" new_password="$2" url="$3" code
  escape_curl_config_value "admin:${old_password}" || return 2
  code="$({
    printf '%s\0%s\0' "$old_password" "$new_password" |
      python3 /dev/fd/3 3<<'PY'
import json
import sys

values = sys.stdin.buffer.read().split(b"\0")
if values and values[-1] == b"":
    values.pop()
if len(values) != 2:
    raise SystemExit("malformed Grafana password payload")
old, new = (value.decode("utf-8") for value in values)
sys.stdout.write(json.dumps({"oldPassword": old, "newPassword": new, "confirmNew": new}))
PY
  } | curl --config /dev/fd/3 -sS -o /dev/null -w '%{http_code}' --max-time 15 \
      -X PUT -H 'Content-Type: application/json' --data-binary @- "${url}/api/user/password" \
      3< <(printf 'user = "%s"\n' "$CURL_CONFIG_VALUE"))"
  [[ "$code" == 200 ]]
}

postgres_sql() {
  local auth_password="$1" sql="$2"
  {
    printf '%s\0' "$auth_password"
    printf '%s\n' "$sql"
  } | dc exec -T postgres /bin/bash -euc '
    IFS= read -r -d "" PGPASSWORD
    export PGPASSWORD
    exec psql -X -q -v ON_ERROR_STOP=1 -h 127.0.0.1 \
      -U "${POSTGRES_USER:-chronicle}" -d "${POSTGRES_DB:-chronicle}" -f -
  '
}

postgres_query() {
  local auth_password="$1" sql="$2"
  {
    printf '%s\0' "$auth_password"
    printf '%s\n' "$sql"
  } | dc exec -T postgres /bin/bash -euc '
    IFS= read -r -d "" PGPASSWORD
    export PGPASSWORD
    exec psql -X -qAt -v ON_ERROR_STOP=1 -h 127.0.0.1 \
      -U "${POSTGRES_USER:-chronicle}" -d "${POSTGRES_DB:-chronicle}" -f -
  '
}

reviewer_scope_state() {
  local study_id="${CHRONICLE_REVIEWER_STUDY_ID:?}" participant_id="${CHRONICLE_REVIEWER_PARTICIPANT_ID:?}"
  postgres_query "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is not set}" "
SELECT CASE
  WHEN NOT EXISTS (
    SELECT 1 FROM studies WHERE study_id = '${study_id}'::uuid
  ) THEN 'missing-study'
  WHEN NOT EXISTS (
    SELECT 1 FROM studies
    WHERE study_id = '${study_id}'::uuid
      AND lifecycle_status = 'ACTIVE'
      AND CURRENT_TIMESTAMP >= started_at
      AND CURRENT_TIMESTAMP < ended_at
  ) THEN 'inactive-study'
  WHEN NOT EXISTS (
    SELECT 1 FROM study_participants
    WHERE study_id = '${study_id}'::uuid AND participant_id = '${participant_id}'
  ) THEN 'missing-participant'
  WHEN NOT EXISTS (
    SELECT 1 FROM study_participants
    WHERE study_id = '${study_id}'::uuid AND participant_id = '${participant_id}'
      AND participation_status = 'ENROLLED'
  ) THEN 'inactive-participant'
  ELSE 'ok'
END;
"
}

postgres_can_auth() {
  postgres_query "$1" 'SELECT 1;' 2>/dev/null | grep -qx 1
}

postgres_alter_password() {
  local auth_password="$1" target_password="$2" escaped
  escaped="${target_password//\'/\'\'}"
  postgres_sql "$auth_password" "ALTER ROLE CURRENT_USER WITH PASSWORD '${escaped}';" >/dev/null
}

stamp_rotation() {
  local tracked_name="$1" note="$2" escaped_note
  escaped_note="${note//\'/\'\'}"
  postgres_sql "${POSTGRES_PASSWORD}" "
INSERT INTO secret_rotation_tracking (secret_name, last_rotated, rotated_by, notes)
VALUES ('${tracked_name}', NOW(), 'selfhost/rotate-secret.sh', '${escaped_note}')
ON CONFLICT (secret_name) DO UPDATE SET
  last_rotated = EXCLUDED.last_rotated,
  rotated_by = EXCLUDED.rotated_by,
  notes = EXCLUDED.notes;
" >/dev/null
}

tde_state() {
  postgres_query "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is not set}" \
    "SELECT key_name || '|' || provider_name FROM pg_tde_key_info();"
}

tde_set_active_key() {
  local key_name="$1" escaped_key
  escaped_key="${key_name//\'/\'\'}"
  postgres_sql "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is not set}" \
    "SELECT pg_tde_set_key_using_database_key_provider('${escaped_key}', 'chronicle_keyring');" \
    >/dev/null
}

verify_tde_encrypted_tables() {
  local counts plain encrypted
  counts="$(postgres_query "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is not set}" "
SELECT
  count(*) FILTER (WHERE a.amname <> 'tde_heap')::text || '|' ||
  count(*) FILTER (WHERE a.amname = 'tde_heap')::text
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
JOIN pg_am a ON a.oid = c.relam
WHERE n.nspname = 'public' AND c.relkind = 'r';
")"
  plain="${counts%%|*}"
  encrypted="${counts#*|}"
  [[ "$counts" == *'|'* && "$plain" =~ ^[0-9]+$ && "$encrypted" =~ ^[0-9]+$ ]] ||
    fail "could not verify the encrypted-table state after TDE rotation"
  [[ "$plain" -eq 0 && "$encrypted" -gt 0 ]] ||
    fail "TDE rotation verification found ${plain} plain and ${encrypted} encrypted public tables"
}

copy_and_verify_live_keyring() {
  local backup_keyring="${STATE_ROOT}/backups/keyring/chronicle-keyring.per" mode
  # db-init mounts both the live keyring volume and the host backup tree. Its copy is atomic,
  # byte-compared, and preserves an already rotated active key.
  dc run --rm --no-deps db-init
  [[ -s "$backup_keyring" ]] || fail "the rotated live keyring was not copied into the backup set"
  mode="$(python3 - "$backup_keyring" <<'PY'
from pathlib import Path
import stat
import sys

path = Path(sys.argv[1])
metadata = path.lstat()
if not stat.S_ISREG(metadata.st_mode) or path.is_symlink():
    raise SystemExit("keyring backup is not a regular file")
print(oct(stat.S_IMODE(metadata.st_mode))[2:])
PY
)"
  [[ "$mode" == 600 ]] || fail "the keyring backup is mode ${mode}, expected 600"
}

take_pre_rotation_backup() {
  command -v gzip >/dev/null 2>&1 || fail "gzip is required for the pre-rotation backup"
  command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is required for backup verification"
  local directory="${STATE_ROOT}/backups/secret-rotation"
  local timestamp partial final checksum
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  /bin/mkdir -p "$directory"
  /bin/chmod 0700 "${STATE_ROOT}/backups" "$directory" 2>/dev/null || true
  final="${directory}/chronicle-pre-tde-${timestamp}-$$.sql.gz"
  partial="${final}.partial"
  BACKUP_PARTIAL="$partial"
  if ! dc exec -T postgres /bin/bash -euc '
      PGPASSWORD="$POSTGRES_PASSWORD" exec pg_dump -h 127.0.0.1 \
        -U "${POSTGRES_USER:-chronicle}" -d "${POSTGRES_DB:-chronicle}" \
        --no-owner --no-privileges
    ' | gzip -9 >"$partial"; then
    /bin/rm -f -- "$partial"
    BACKUP_PARTIAL=""
    fail "the pre-rotation SQL dump failed"
  fi
  if [[ ! -s "$partial" ]] || ! gzip -t "$partial"; then
    /bin/rm -f -- "$partial"
    BACKUP_PARTIAL=""
    fail "the pre-rotation SQL dump failed gzip verification"
  fi
  /bin/mv "$partial" "$final"
  BACKUP_PARTIAL=""
  /bin/chmod 0600 "$final"
  checksum="$(sha256sum "$final" | awk '{print $1}')"
  RECEIPT_DETAIL="backup=${final};sha256=${checksum}"
}

write_receipt() {
  local kind="$1" action="$2" timestamp path
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  /bin/mkdir -p "$RECEIPT_DIR"
  /bin/chmod 0700 "$RECEIPT_DIR"
  path="${RECEIPT_DIR}/${timestamp}-${kind}-${action}-$$.json"
  ROTATION_RECEIPT_KIND="$kind" \
  ROTATION_RECEIPT_ACTION="$action" \
  ROTATION_RECEIPT_VERSION="${RELEASE_VERSION:-unknown}" \
  ROTATION_RECEIPT_TIMESTAMP="$timestamp" \
  ROTATION_RECEIPT_DETAIL="$RECEIPT_DETAIL" \
    python3 - "$path" <<'PY'
from pathlib import Path
import json
import os
import sys

path = Path(sys.argv[1])
document = {
    "schema_version": 1,
    "status": "completed",
    "secret": os.environ["ROTATION_RECEIPT_KIND"],
    "action": os.environ["ROTATION_RECEIPT_ACTION"],
    "release_version": os.environ["ROTATION_RECEIPT_VERSION"],
    "completed_at_utc": os.environ["ROTATION_RECEIPT_TIMESTAMP"],
}
detail = os.environ.get("ROTATION_RECEIPT_DETAIL", "")
if detail:
    document["verification"] = detail
temporary = path.with_name(f".{path.name}.tmp-{os.getpid()}")
fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(document, handle, indent=2, sort_keys=True)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)
    directory_fd = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)
finally:
    try:
        temporary.unlink()
    except FileNotFoundError:
        pass
PY
  /bin/chmod 0600 "$path"
  log "Rotation receipt: $path"
}

complete_transaction() {
  local kind="$1" action="$2"
  write_phase verified
  write_receipt "$kind" "$action"
  ROLLBACK_REQUIRED=false
  remove_transaction
}

rollback_on_error() {
  local original_status=$?
  trap - EXIT
  if [[ -n "$BACKUP_PARTIAL" ]]; then
    /bin/rm -f -- "$BACKUP_PARTIAL"
    BACKUP_PARTIAL=""
  fi
  if [[ "$original_status" -eq 0 || "$ROLLBACK_REQUIRED" != true || "$TRANSACTION_ACTIVE" != true ]]; then
    exit "$original_status"
  fi

  set +e
  warn "rotation failed; attempting to restore the previous credential and service configuration"
  local rollback_status=0
  if [[ "$EXTERNAL_CHANGED" == true ]]; then
    case "$ROTATION_KIND" in
      postgres)
        postgres_alter_password "$NEW_SECRET" "$OLD_SECRET" || rollback_status=1
        ;;
      grafana)
        grafana_change_password "$NEW_SECRET" "$OLD_SECRET" "$GRAFANA_URL" || rollback_status=1
        ;;
      tde)
        tde_set_active_key "$OLD_TDE_KEY" || rollback_status=1
        ;;
    esac
  fi

  if [[ "$rollback_status" -eq 0 && "$ROTATION_KIND" != tde ]]; then
    restore_old_env || rollback_status=1
    if [[ "$rollback_status" -eq 0 ]]; then
      apply_configuration >/dev/null 2>&1 || rollback_status=1
    fi
  fi

  if [[ "$rollback_status" -eq 0 ]]; then
    remove_transaction || rollback_status=1
    warn "the previous credential and service configuration were restored"
  fi
  if [[ "$rollback_status" -ne 0 ]]; then
    warn "automatic rollback was incomplete; preserve $ROTATION_DIR and follow docs/SECRET-ROTATION.md before restarting services"
  fi
  exit "$original_status"
}
trap rollback_on_error EXIT

env_value_from_file() {
  local path="$1" key="$2"
  python3 - "$path" "$key" <<'PY'
from pathlib import Path
import re
import shlex
import sys

path = Path(sys.argv[1])
key = sys.argv[2]
matches = []
for line in path.read_text(encoding="utf-8").splitlines():
    match = re.fullmatch(rf"{re.escape(key)}=(.*)", line)
    if match:
        matches.append(match.group(1))
if len(matches) != 1:
    raise SystemExit(f"expected exactly one {key} assignment in {path}")
raw = matches[0]
if raw == "":
    value = ""
else:
    values = shlex.split(raw, comments=False, posix=True)
    if len(values) != 1:
        raise SystemExit(f"cannot safely parse {key} in {path}")
    value = values[0]
if "\x00" in value or "\n" in value or "\r" in value:
    raise SystemExit(f"invalid control character in {key}")
sys.stdout.write(value)
PY
}

env_differs_from_saved() {
  local key current_value old_value
  for key in "$@"; do
    current_value="$(env_value_from_file .env "$key")" ||
      fail "could not read $key from the current .env"
    old_value="$(env_value_from_file "${ROTATION_DIR}/old.env" "$key")" ||
      fail "could not read $key from the saved pre-rotation .env"
    if [[ "$current_value" != "$old_value" ]]; then
      current_value=""; old_value=""
      return 0
    fi
    current_value=""; old_value=""
  done
  return 1
}

load_transaction() {
  local owner_pid=""
  [[ -d "$ROTATION_DIR" && ! -L "$ROTATION_DIR" ]] ||
    fail "no recoverable secret-rotation directory exists at $ROTATION_DIR"
  [[ ! -e "$UPGRADE_LOCK_DIR" && ! -L "$UPGRADE_LOCK_DIR" ]] ||
    fail "an upgrade is active or incomplete ($UPGRADE_LOCK_DIR); do not recover secrets concurrently"
  [[ ! -e "$RESTORE_LOCK_DIR" && ! -L "$RESTORE_LOCK_DIR" ]] ||
    fail "a restore is active or incomplete ($RESTORE_LOCK_DIR); do not recover secrets concurrently"

  if [[ -f "${ROTATION_DIR}/owner-pid" && ! -L "${ROTATION_DIR}/owner-pid" ]]; then
    owner_pid="$(<"${ROTATION_DIR}/owner-pid")"
    [[ "$owner_pid" =~ ^[1-9][0-9]*$ ]] || fail "rotation owner PID metadata is malformed"
    if kill -0 "$owner_pid" 2>/dev/null; then
      fail "rotation owner process $owner_pid still exists; do not run recovery concurrently"
    fi
  fi

  TRANSACTION_ACTIVE=true
  ROLLBACK_REQUIRED=false
  if [[ ! -e "${ROTATION_DIR}/phase" ]]; then
    TRANSACTION_PREPARED=false
    return 0
  fi

  python3 - "$ROTATION_DIR" <<'PY'
from pathlib import Path
import os
import stat
import sys

root = Path(sys.argv[1])
for name in ("old.env", "kind", "action", "phase"):
    path = root / name
    metadata = path.lstat()
    if path.is_symlink() or not stat.S_ISREG(metadata.st_mode):
        raise SystemExit(f"unsafe rotation transaction file: {path}")
    if stat.S_IMODE(metadata.st_mode) & 0o077:
        raise SystemExit(f"rotation transaction file is not private: {path}")
    if metadata.st_uid != os.geteuid():
        raise SystemExit(f"rotation transaction file has the wrong owner: {path}")
PY

  SAVED_ROTATION_KIND="$(<"${ROTATION_DIR}/kind")"
  SAVED_ROTATION_ACTION="$(<"${ROTATION_DIR}/action")"
  SAVED_ROTATION_PHASE="$(<"${ROTATION_DIR}/phase")"
  case "${SAVED_ROTATION_KIND}:${SAVED_ROTATION_ACTION}" in
    dashboard:rotate|jwt:rotate|internal-web:rotate|reviewer:rotate|metrics:rotate|postgres:rotate|grafana:rotate|tde:rotate|mobile:begin|mobile:finalize|mobile:abort) ;;
    *) fail "rotation transaction kind/action metadata is unsupported" ;;
  esac
  case "$SAVED_ROTATION_PHASE" in
    prepared|env-published|database-updated|grafana-updated|overlap-published|overlap-removed|overlap-aborted|tde-metadata-ready|tde-updated|verified) ;;
    *) fail "rotation transaction phase metadata is unsupported" ;;
  esac
  if [[ "$SAVED_ROTATION_KIND" == tde && "$SAVED_ROTATION_PHASE" != prepared ]]; then
    python3 - "$ROTATION_DIR" <<'PY'
from pathlib import Path
import os
import stat
import sys

root = Path(sys.argv[1])
for name in ("old-tde-key", "new-tde-key"):
    path = root / name
    metadata = path.lstat()
    if path.is_symlink() or not stat.S_ISREG(metadata.st_mode):
        raise SystemExit(f"unsafe TDE transaction file: {path}")
    if stat.S_IMODE(metadata.st_mode) & 0o077 or metadata.st_uid != os.geteuid():
        raise SystemExit(f"TDE transaction file is not private and operator-owned: {path}")
PY
  fi
  TRANSACTION_PREPARED=true
}

configure_recovery_apply() {
  APPLY_MODE=services
  APPLY_SERVICES=()
  case "$SAVED_ROTATION_KIND" in
    dashboard) APPLY_SERVICES=(web) ;;
    jwt|reviewer|metrics|mobile) APPLY_SERVICES=(backend) ;;
    internal-web) APPLY_SERVICES=(backend web) ;;
    postgres) APPLY_MODE=full ;;
    grafana) APPLY_SERVICES=(grafana) ;;
    tde) ;;
    *) fail "internal error: unsupported recovery kind" ;;
  esac
}

ensure_recovery_service_running() {
  local service="$1" container_id deadline
  container_id="$(dc ps -q "$service" 2>/dev/null || true)"
  if [[ -z "$container_id" ]]; then
    log "Starting the existing $service service for recovery (without dependent services)."
    dc up -d --no-deps "$service"
  fi
  deadline=$((SECONDS + SECRET_ROTATION_WAIT_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    container_id="$(dc ps -q "$service" 2>/dev/null || true)"
    if [[ -n "$container_id" ]] &&
        [[ "$(docker inspect -f '{{.State.Running}}' "$container_id" 2>/dev/null || true)" == true ]]; then
      return 0
    fi
    sleep 1
  done
  fail "Compose service '$service' did not enter the running state within ${SECRET_ROTATION_WAIT_TIMEOUT_SECONDS}s"
}

complete_recovery() {
  local detail="$1"
  RECEIPT_DETAIL="original_action=${SAVED_ROTATION_ACTION};original_phase=${SAVED_ROTATION_PHASE};${detail}"
  complete_transaction "$SAVED_ROTATION_KIND" "recover-${RECOVERY_DIRECTION}"
  log "Interrupted ${SAVED_ROTATION_KIND} rotation recovered ${RECOVERY_DIRECTION}."
}

recover_environment_rotation() {
  local -a keys=()
  configure_recovery_apply
  case "$SAVED_ROTATION_KIND" in
    dashboard) keys=(DASHBOARD_PASSWORD_HASH) ;;
    jwt) keys=(JWT_SECRET) ;;
    internal-web) keys=(CHRONICLE_INTERNAL_WEB_SECRET) ;;
    reviewer) keys=(CHRONICLE_REVIEWER_ACCESS_ENABLED CHRONICLE_REVIEWER_ACCESS_SECRET) ;;
    metrics) keys=(METRICS_PASSWORD) ;;
    mobile) keys=(MOBILE_SIGNING_SECRET MOBILE_SIGNING_SECRET_PREVIOUS) ;;
    *) fail "internal error: not an environment-only rotation" ;;
  esac

  if [[ "$RECOVERY_DIRECTION" == forward ]]; then
    env_differs_from_saved "${keys[@]}" ||
      fail "the current .env still has the saved pre-rotation value; recover --rollback, then start a new rotation"
    apply_configuration
    if [[ "$SAVED_ROTATION_KIND" == jwt ]]; then
      POSTGRES_PASSWORD="${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is not set}"
      stamp_rotation jwt_signing_secret "self-host JWT crash recovery" ||
        warn "JWT recovered, but its rotation timestamp could not be recorded"
    elif [[ "$SAVED_ROTATION_KIND:$SAVED_ROTATION_ACTION" == mobile:finalize ]]; then
      POSTGRES_PASSWORD="${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is not set}"
      stamp_rotation hmac_mobile_signing_key "self-host mobile crash recovery finalized" ||
        warn "mobile key recovered, but its rotation timestamp could not be recorded"
    fi
    if [[ "$SAVED_ROTATION_KIND" == dashboard ]]; then
      complete_recovery "web_health=verified;dashboard_auth=operator_check_required"
      warn "the cleartext dashboard password is not stored; rerun ./chronicle verify --dashboard-password"
    else
      complete_recovery "service_health=verified;published_configuration=retained"
    fi
  else
    restore_old_env
    apply_configuration
    complete_recovery "service_health=verified;previous_configuration=restored"
  fi
}

recover_postgres_rotation() {
  local current_secret old_secret
  configure_recovery_apply
  current_secret="$(env_value_from_file .env POSTGRES_PASSWORD)" ||
    fail "could not read POSTGRES_PASSWORD from the current .env"
  old_secret="$(env_value_from_file "${ROTATION_DIR}/old.env" POSTGRES_PASSWORD)" ||
    fail "could not read the saved pre-rotation POSTGRES_PASSWORD"
  [[ -n "$current_secret" && -n "$old_secret" ]] || fail "PostgreSQL recovery found an empty password"
  ensure_recovery_service_running postgres

  if [[ "$RECOVERY_DIRECTION" == forward ]]; then
    [[ "$current_secret" != "$old_secret" ]] ||
      fail "the new PostgreSQL password was never published; recover --rollback, then start a new rotation"
    if postgres_can_auth "$current_secret"; then
      :
    elif postgres_can_auth "$old_secret"; then
      postgres_alter_password "$old_secret" "$current_secret"
    else
      fail "neither the current nor saved PostgreSQL password authenticates; preserve the transaction directory"
    fi
    apply_configuration
    postgres_can_auth "$current_secret" || fail "PostgreSQL rejected the forward-recovered password"
    complete_recovery "database_auth=verified;compose_stack=healthy;published_configuration=retained"
  else
    if postgres_can_auth "$old_secret"; then
      :
    elif [[ "$current_secret" != "$old_secret" ]] && postgres_can_auth "$current_secret"; then
      postgres_alter_password "$current_secret" "$old_secret"
    else
      fail "neither the saved nor current PostgreSQL password authenticates; preserve the transaction directory"
    fi
    restore_old_env
    apply_configuration
    postgres_can_auth "$old_secret" || fail "PostgreSQL rejected the restored password"
    complete_recovery "database_auth=verified;compose_stack=healthy;previous_configuration=restored"
  fi
  current_secret=""; old_secret=""
}

grafana_can_auth() {
  local password="$1" code
  code="$(curl_basic_code admin "$password" "${GRAFANA_URL}/api/user")" || return 1
  [[ "$code" == 200 ]]
}

recover_grafana_rotation() {
  local current_secret old_secret host
  configure_recovery_apply
  current_secret="$(env_value_from_file .env GRAFANA_ADMIN_PASSWORD)" ||
    fail "could not read GRAFANA_ADMIN_PASSWORD from the current .env"
  old_secret="$(env_value_from_file "${ROTATION_DIR}/old.env" GRAFANA_ADMIN_PASSWORD)" ||
    fail "could not read the saved pre-rotation GRAFANA_ADMIN_PASSWORD"
  [[ -n "$current_secret" && -n "$old_secret" ]] || fail "Grafana recovery found an empty password"
  host="${GRAFANA_BIND:-127.0.0.1}"
  case "$host" in 0.0.0.0|::|'[::]') host=127.0.0.1 ;; esac
  GRAFANA_URL="http://${host}:${GRAFANA_PORT:-3000}"
  ensure_recovery_service_running grafana

  if [[ "$RECOVERY_DIRECTION" == forward ]]; then
    [[ "$current_secret" != "$old_secret" ]] ||
      fail "the new Grafana password was never published; recover --rollback, then start a new rotation"
    if grafana_can_auth "$current_secret"; then
      :
    elif grafana_can_auth "$old_secret"; then
      grafana_change_password "$old_secret" "$current_secret" "$GRAFANA_URL" ||
        fail "Grafana rejected the forward-recovery password change"
    else
      fail "neither the current nor saved Grafana password authenticates; preserve the transaction directory"
    fi
    apply_configuration
    grafana_can_auth "$current_secret" || fail "Grafana rejected the forward-recovered password"
    complete_recovery "grafana_auth=verified;published_configuration=retained"
  else
    if grafana_can_auth "$old_secret"; then
      :
    elif [[ "$current_secret" != "$old_secret" ]] && grafana_can_auth "$current_secret"; then
      grafana_change_password "$current_secret" "$old_secret" "$GRAFANA_URL" ||
        fail "Grafana rejected the rollback password change"
    else
      fail "neither the saved nor current Grafana password authenticates; preserve the transaction directory"
    fi
    restore_old_env
    apply_configuration
    grafana_can_auth "$old_secret" || fail "Grafana rejected the restored password"
    complete_recovery "grafana_auth=verified;previous_configuration=restored"
  fi
  current_secret=""; old_secret=""
}

create_and_activate_tde_key() {
  local key_name="$1" escaped_key
  escaped_key="${key_name//\'/\'\'}"
  postgres_sql "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is not set}" "
BEGIN;
SELECT pg_tde_create_key_using_database_key_provider('${escaped_key}', 'chronicle_keyring');
SELECT pg_tde_set_key_using_database_key_provider('${escaped_key}', 'chronicle_keyring');
INSERT INTO secret_rotation_tracking (secret_name, last_rotated, rotated_by, notes)
VALUES ('tde_principal_key', NOW(), 'selfhost/rotate-secret.sh', '${escaped_key}')
ON CONFLICT (secret_name) DO UPDATE SET
  last_rotated = EXCLUDED.last_rotated,
  rotated_by = EXCLUDED.rotated_by,
  notes = EXCLUDED.notes;
COMMIT;
" >/dev/null
}

recover_tde_rotation() {
  local state provider
  configure_recovery_apply
  OLD_TDE_KEY="$(<"${ROTATION_DIR}/old-tde-key")"
  NEW_TDE_KEY="$(<"${ROTATION_DIR}/new-tde-key")"
  [[ "$OLD_TDE_KEY" =~ ^[A-Za-z0-9_.-]{1,128}$ ]] || fail "saved old TDE key name is malformed"
  [[ "$NEW_TDE_KEY" =~ ^[A-Za-z0-9_.-]{1,128}$ ]] || fail "saved new TDE key name is malformed"
  [[ "$OLD_TDE_KEY" != "$NEW_TDE_KEY" ]] || fail "saved TDE key names are identical"
  ensure_recovery_service_running postgres
  state="$(tde_state)"
  provider="${state#*|}"
  [[ "$state" == *'|'* && "$provider" == chronicle_keyring ]] ||
    fail "could not verify the active chronicle_keyring TDE provider"

  if [[ "$RECOVERY_DIRECTION" == forward ]]; then
    case "${state%%|*}" in
      "$NEW_TDE_KEY") ;;
      "$OLD_TDE_KEY")
        # A prior automatic rollback may have left the new key in the keyring. Adopt it if
        # present; otherwise create and activate it as one database transaction.
        tde_set_active_key "$NEW_TDE_KEY" 2>/dev/null || create_and_activate_tde_key "$NEW_TDE_KEY"
        ;;
      *) fail "the active TDE key matches neither saved recovery key; preserve the transaction directory" ;;
    esac
    [[ "$(tde_state)" == "${NEW_TDE_KEY}|chronicle_keyring" ]] ||
      fail "forward recovery did not activate the saved new TDE key"
    stamp_rotation tde_principal_key "self-host TDE crash recovery forward" ||
      warn "TDE key recovered, but its rotation timestamp could not be recorded"
    copy_and_verify_live_keyring
    verify_tde_encrypted_tables
    complete_recovery "tde_provider=chronicle_keyring;encrypted_tables=verified;keyring_backup=verified"
  else
    case "${state%%|*}" in
      "$OLD_TDE_KEY") ;;
      "$NEW_TDE_KEY") tde_set_active_key "$OLD_TDE_KEY" ;;
      *) fail "the active TDE key matches neither saved recovery key; preserve the transaction directory" ;;
    esac
    [[ "$(tde_state)" == "${OLD_TDE_KEY}|chronicle_keyring" ]] ||
      fail "rollback recovery did not reactivate the saved old TDE key"
    stamp_rotation tde_principal_key "self-host TDE crash recovery rollback" ||
      warn "TDE key rolled back, but its tracking timestamp could not be recorded"
    copy_and_verify_live_keyring
    verify_tde_encrypted_tables
    complete_recovery "tde_provider=chronicle_keyring;encrypted_tables=verified;keyring_backup=verified;previous_key=reactivated"
  fi
  OLD_TDE_KEY=""; NEW_TDE_KEY=""
}

recover_transaction() {
  load_transaction
  if [[ "$TRANSACTION_PREPARED" != true ]]; then
    [[ "$RECOVERY_DIRECTION" == rollback ]] ||
      fail "the crash occurred before transaction preparation completed; only recover --rollback is safe"
    confirm "Confirm no secret-rotation process remains, then remove this pre-publication lock?"
    remove_transaction
    log "Removed an incomplete pre-publication rotation lock; .env was never changed by that transaction."
    return 0
  fi

  if [[ "$SAVED_ROTATION_KIND" == tde && "$SAVED_ROTATION_PHASE" == prepared ]]; then
    [[ "$RECOVERY_DIRECTION" == rollback ]] ||
      fail "TDE key activation had not reached its durable metadata checkpoint; only recover --rollback is safe"
    confirm "Confirm no secret-rotation process remains, then remove this pre-activation TDE lock?"
    remove_transaction
    log "Removed an interrupted TDE rotation before its durable key-activation checkpoint. The active database key was not changed by that transaction."
    return 0
  fi

  confirm "Confirm no secret-rotation process remains and recover ${SAVED_ROTATION_KIND} ${RECOVERY_DIRECTION}?"
  case "$SAVED_ROTATION_KIND" in
    dashboard|jwt|internal-web|reviewer|metrics|mobile) recover_environment_rotation ;;
    postgres) recover_postgres_rotation ;;
    grafana) recover_grafana_rotation ;;
    tde) recover_tde_rotation ;;
    *) fail "internal error: unsupported recovery kind" ;;
  esac
}

rotate_dashboard() {
  [[ "$ROTATION_ACTION" == rotate ]] || fail "dashboard accepts no action argument"
  case "${COMPOSE_FILE:-}" in
    *mode-*-internal.yml*) ;;
    *) fail "the dashboard password exists only in an internal-dashboard mode" ;;
  esac
  service_running web
  local password confirmation hash image host code
  printf 'Choose a new dashboard password (at least 16 characters). It is read silently,\n'
  printf 'sent to the digest-pinned Caddy image over stdin, and never printed.\n'
  read -rsp 'New dashboard password: ' password; printf '\n'
  read -rsp 'Confirm dashboard password: ' confirmation; printf '\n'
  [[ "$password" == "$confirmation" ]] || fail "dashboard passwords do not match"
  [[ ${#password} -ge 16 ]] || fail "dashboard password must be at least 16 characters"
  image="${CADDY_IMAGE:-}"
  case "$image" in
    ""|__CHRONICLE_*)
      image='caddy:2.10.2-alpine@sha256:4c6e91c6ed0e2fa03efd5b44747b625fec79bc9cd06ac5235a779726618e530d'
      ;;
  esac
  hash="$(printf '%s\n' "$password" | docker run --rm -i --network none --read-only \
    --entrypoint caddy "$image" hash-password | tr -d '\r\n')"
  [[ "$hash" == \$2* ]] || fail "Caddy did not return a bcrypt password hash"

  APPLY_SERVICES=(web)
  OLD_SECRET="${DASHBOARD_PASSWORD_HASH:-}"
  NEW_SECRET="$hash"
  begin_transaction dashboard rotate
  env_update DASHBOARD_PASSWORD_HASH "$hash"
  write_phase env-published
  apply_configuration

  host="${INTERNAL_BIND:-127.0.0.1}"
  [[ "$host" == 0.0.0.0 ]] && host=127.0.0.1
  code="$(curl_basic_code "${DASHBOARD_USER:-researcher}" "$password" \
    "https://${host}:${INTERNAL_PORT:-8081}/chronicle/")"
  [[ "$code" == 200 ]] || fail "new dashboard credential did not pass the internal HTTPS gate (HTTP $code)"
  RECEIPT_DETAIL="internal_dashboard_auth=verified"
  complete_transaction dashboard rotate
  password=""; confirmation=""; hash=""; NEW_SECRET=""; OLD_SECRET=""
  log "Dashboard password rotated and verified."
}

rotate_jwt() {
  [[ "$ROTATION_ACTION" == rotate ]] || fail "jwt accepts no action argument"
  service_running backend
  confirm "Rotate JWT signing and invalidate every active dashboard session?"
  APPLY_SERVICES=(backend)
  OLD_SECRET="${JWT_SECRET:?JWT_SECRET is not set}"
  NEW_SECRET="$(openssl rand -hex 32)"
  begin_transaction jwt rotate
  env_update JWT_SECRET "$NEW_SECRET"
  write_phase env-published
  apply_configuration
  POSTGRES_PASSWORD="${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is not set}"
  if ! stamp_rotation jwt_signing_secret "self-host JWT rotation"; then
    warn "JWT rotated, but its rotation timestamp could not be recorded"
  fi
  RECEIPT_DETAIL="backend_health=verified;sessions=invalidated"
  complete_transaction jwt rotate
  NEW_SECRET=""; OLD_SECRET=""
  log "JWT signing secret rotated. Existing dashboard sessions must sign in again."
}

rotate_internal_web() {
  [[ "$ROTATION_ACTION" == rotate ]] || fail "internal-web accepts no action argument"
  service_running backend
  service_running web
  confirm "Rotate the proxy-to-backend internal web secret and recreate both services?"
  APPLY_SERVICES=(backend web)
  OLD_SECRET="${CHRONICLE_INTERNAL_WEB_SECRET:?CHRONICLE_INTERNAL_WEB_SECRET is not set}"
  NEW_SECRET="$(openssl rand -hex 32)"
  begin_transaction internal-web rotate
  env_update CHRONICLE_INTERNAL_WEB_SECRET "$NEW_SECRET"
  write_phase env-published
  apply_configuration
  RECEIPT_DETAIL="backend_health=verified;web_health=verified"
  complete_transaction internal-web rotate
  NEW_SECRET=""; OLD_SECRET=""
  log "Internal web secret rotated; Caddy and the backend are synchronized."
}

rotate_reviewer() {
  [[ "$ROTATION_ACTION" == rotate ]] || fail "reviewer accepts no action argument"
  service_running backend
  service_running postgres
  [[ "${CHRONICLE_REVIEWER_STUDY_ID:-}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] ||
    fail "set CHRONICLE_REVIEWER_STUDY_ID to the synthetic reviewer study UUID first"
  [[ "${CHRONICLE_REVIEWER_PARTICIPANT_ID:-}" =~ ^[a-zA-Z0-9_.-]{1,255}$ ]] ||
    fail "set CHRONICLE_REVIEWER_PARTICIPANT_ID to a non-PII Chronicle participant ID first"
  local scope_state
  scope_state="$(reviewer_scope_state)" || fail "could not verify the configured Play reviewer scope"
  [[ "$scope_state" == ok ]] ||
    fail "configured Play reviewer scope is unavailable (${scope_state:-query-failed}); create or reactivate it in the dashboard first"
  confirm "Generate a new Play reviewer credential, invalidate the current one, and recreate the backend?"
  APPLY_SERVICES=(backend)
  OLD_SECRET="${CHRONICLE_REVIEWER_ACCESS_SECRET:-}"
  NEW_SECRET="$(openssl rand -hex 32)"
  begin_transaction reviewer rotate
  env_update CHRONICLE_REVIEWER_ACCESS_ENABLED true CHRONICLE_REVIEWER_ACCESS_SECRET "$NEW_SECRET"
  write_phase env-published
  apply_configuration
  RECEIPT_DETAIL="backend_health=verified;reviewer_scope=${CHRONICLE_REVIEWER_STUDY_ID}"
  complete_transaction reviewer rotate
  NEW_SECRET=""; OLD_SECRET=""
  log "Play reviewer credential rotated. Copy it from .env in a trusted editor directly into Play Console."
}

rotate_metrics() {
  [[ "$ROTATION_ACTION" == rotate ]] || fail "metrics accepts no action argument"
  service_running backend
  confirm "Rotate the backend metrics credential and recreate the backend?"
  APPLY_SERVICES=(backend)
  OLD_SECRET="${METRICS_PASSWORD:?METRICS_PASSWORD is not set}"
  NEW_SECRET="$(openssl rand -hex 32)"
  begin_transaction metrics rotate
  env_update METRICS_PASSWORD "$NEW_SECRET"
  write_phase env-published
  apply_configuration
  RECEIPT_DETAIL="backend_health=verified"
  complete_transaction metrics rotate
  NEW_SECRET=""; OLD_SECRET=""
  log "Metrics credential rotated. Update any separately configured scraper from the mode-0600 .env file."
}

rotate_postgres() {
  [[ "$ROTATION_ACTION" == rotate ]] || fail "postgres accepts no action argument"
  service_running postgres
  service_running backend
  confirm "Rotate the database role password and restart the complete Compose stack?"
  APPLY_MODE=full
  OLD_SECRET="${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is not set}"
  postgres_can_auth "$OLD_SECRET" || fail "the current .env password cannot authenticate to PostgreSQL"
  NEW_SECRET="$(openssl rand -hex 32)"
  begin_transaction postgres rotate
  env_update POSTGRES_PASSWORD "$NEW_SECRET"
  write_phase env-published
  postgres_alter_password "$OLD_SECRET" "$NEW_SECRET"
  EXTERNAL_CHANGED=true
  write_phase database-updated
  apply_configuration
  postgres_can_auth "$NEW_SECRET" || fail "PostgreSQL rejected the rotated password after restart"
  RECEIPT_DETAIL="database_auth=verified;compose_stack=healthy"
  complete_transaction postgres rotate
  POSTGRES_PASSWORD="$NEW_SECRET"
  NEW_SECRET=""; OLD_SECRET=""
  log "PostgreSQL password rotated and the complete stack returned healthy."
}

rotate_grafana() {
  [[ "$ROTATION_ACTION" == rotate ]] || fail "grafana accepts no action argument"
  [[ "${COMPOSE_FILE:-}" == *overlays/monitoring.yml* ]] ||
    fail "Grafana is not enabled in COMPOSE_FILE"
  service_running grafana
  confirm "Rotate the Grafana administrator password?"
  APPLY_SERVICES=(grafana)
  OLD_SECRET="${GRAFANA_ADMIN_PASSWORD:?GRAFANA_ADMIN_PASSWORD is not set}"
  NEW_SECRET="$(openssl rand -hex 32)"
  local host="${GRAFANA_BIND:-127.0.0.1}" code
  case "$host" in 0.0.0.0|::|'[::]') host=127.0.0.1 ;; esac
  GRAFANA_URL="http://${host}:${GRAFANA_PORT:-3000}"
  code="$(curl_basic_code admin "$OLD_SECRET" "${GRAFANA_URL}/api/user")"
  [[ "$code" == 200 ]] || fail "the current .env password cannot authenticate to Grafana (HTTP $code)"

  begin_transaction grafana rotate
  env_update GRAFANA_ADMIN_PASSWORD "$NEW_SECRET"
  write_phase env-published
  grafana_change_password "$OLD_SECRET" "$NEW_SECRET" "$GRAFANA_URL" ||
    fail "Grafana rejected the password change"
  EXTERNAL_CHANGED=true
  write_phase grafana-updated
  apply_configuration
  code="$(curl_basic_code admin "$NEW_SECRET" "${GRAFANA_URL}/api/user")"
  [[ "$code" == 200 ]] || fail "Grafana rejected the rotated password after restart (HTTP $code)"
  RECEIPT_DETAIL="grafana_auth=verified"
  complete_transaction grafana rotate
  GRAFANA_ADMIN_PASSWORD="$NEW_SECRET"
  NEW_SECRET=""; OLD_SECRET=""
  log "Grafana administrator password rotated and verified. The generated value remains only in .env."
}

rotate_mobile() {
  [[ "${MOBILE_SIGNING_ENABLED:-false}" == true && "${MOBILE_SIGNING_REQUIRED:-false}" == true ]] ||
    fail "controlled legacy mobile HMAC compatibility is disabled; public per-device-key clients require no shared-key rotation"
  service_running backend
  case "$ROTATION_ACTION" in
    begin)
      [[ -z "${MOBILE_SIGNING_SECRET_PREVIOUS:-}" ]] ||
        fail "a mobile signing-key overlap is already active; finalize or abort it first"
      confirm "Begin mobile-key rotation (old and new keys will both remain valid during rollout)?"
      APPLY_SERVICES=(backend)
      OLD_SECRET="${MOBILE_SIGNING_SECRET:?MOBILE_SIGNING_SECRET is not set}"
      NEW_SECRET="$(openssl rand -hex 32)"
      begin_transaction mobile begin
      env_update MOBILE_SIGNING_SECRET "$NEW_SECRET" MOBILE_SIGNING_SECRET_PREVIOUS "$OLD_SECRET"
      write_phase overlap-published
      apply_configuration
      RECEIPT_DETAIL="backend_health=verified;overlap=active"
      complete_transaction mobile begin
      NEW_SECRET=""; OLD_SECRET=""
      log "Mobile-key overlap is active for controlled legacy clients only; never provision this deployment-wide key into the public app."
      log "Do not finalize until every supported installed build has moved to the new key."
      ;;
    finalize)
      [[ -n "${MOBILE_SIGNING_SECRET_PREVIOUS:-}" ]] ||
        fail "no mobile signing-key overlap is active"
      [[ "$MOBILE_SIGNING_SECRET_PREVIOUS" != "$MOBILE_SIGNING_SECRET" ]] ||
        fail "current and previous mobile signing keys are identical"
      confirm "Finalize mobile-key rotation and reject every client still using the previous key?"
      APPLY_SERVICES=(backend)
      begin_transaction mobile finalize
      env_update MOBILE_SIGNING_SECRET_PREVIOUS ""
      write_phase overlap-removed
      apply_configuration
      POSTGRES_PASSWORD="${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is not set}"
      if ! stamp_rotation hmac_mobile_signing_key "self-host mobile rotation finalized"; then
        warn "mobile key finalized, but its rotation timestamp could not be recorded"
      fi
      RECEIPT_DETAIL="backend_health=verified;overlap=removed"
      complete_transaction mobile finalize
      log "Mobile signing-key rotation finalized; the previous key is no longer accepted."
      ;;
    abort)
      [[ -n "${MOBILE_SIGNING_SECRET_PREVIOUS:-}" ]] ||
        fail "no mobile signing-key overlap is active"
      confirm "Abort mobile-key rotation and make the previous key current again?"
      APPLY_SERVICES=(backend)
      begin_transaction mobile abort
      env_update MOBILE_SIGNING_SECRET "$MOBILE_SIGNING_SECRET_PREVIOUS" \
        MOBILE_SIGNING_SECRET_PREVIOUS ""
      write_phase overlap-aborted
      apply_configuration
      RECEIPT_DETAIL="backend_health=verified;overlap=aborted"
      complete_transaction mobile abort
      log "Mobile signing-key rotation aborted; the pre-rotation key is current again."
      ;;
    *) fail "mobile action must be begin, finalize, or abort" ;;
  esac
}

rotate_tde() {
  [[ "$ROTATION_ACTION" == rotate ]] || fail "tde accepts no action argument"
  [[ "${ENABLE_ENCRYPTION:-true}" == true ]] || fail "TDE encryption is disabled"
  [[ "${COMPOSE_FILE:-}" == *overlays/backups.yml* ]] ||
    fail "TDE rotation requires the supported backups overlay"
  service_running postgres
  confirm "Take a fresh SQL backup and rotate the pg_tde principal key online?"
  begin_transaction tde rotate
  take_pre_rotation_backup
  local state provider
  POSTGRES_PASSWORD="${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is not set}"
  state="$(tde_state)"
  OLD_TDE_KEY="${state%%|*}"
  provider="${state#*|}"
  [[ -n "$OLD_TDE_KEY" && "$state" == *'|'* ]] || fail "could not determine the active TDE key"
  [[ "$provider" == chronicle_keyring ]] ||
    fail "unexpected TDE provider '$provider' (expected chronicle_keyring)"
  NEW_TDE_KEY="chronicle_key_$(date -u +%Y%m%dT%H%M%SZ)_${RANDOM}"
  # Publish and fsync both candidate names and then a durable phase marker before changing
  # PostgreSQL. Thus `prepared` always means activation was never attempted, while
  # `tde-metadata-ready` is sufficient to recover either side of the database transaction.
  write_tde_recovery_metadata
  write_phase tde-metadata-ready
  # A connection loss can make the result of COMMIT ambiguous to the caller. Mark the
  # external operation as begun before invoking it so the EXIT trap either reactivates the
  # old key or preserves the durable transaction for explicit recovery.
  EXTERNAL_CHANGED=true
  create_and_activate_tde_key "$NEW_TDE_KEY"
  write_phase tde-updated
  state="$(tde_state)"
  [[ "$state" == "${NEW_TDE_KEY}|chronicle_keyring" ]] ||
    fail "TDE key verification did not report the newly activated key"
  copy_and_verify_live_keyring
  verify_tde_encrypted_tables
  RECEIPT_DETAIL="${RECEIPT_DETAIL};tde_provider=chronicle_keyring;encrypted_tables=verified;keyring_backup=verified"
  complete_transaction tde rotate
  log "TDE principal key rotated after a verified fresh SQL backup."
}

case "$ROTATION_KIND" in
  recover) recover_transaction ;;
  dashboard) rotate_dashboard ;;
  jwt) rotate_jwt ;;
  internal-web) rotate_internal_web ;;
  reviewer) rotate_reviewer ;;
  metrics) rotate_metrics ;;
  postgres) rotate_postgres ;;
  grafana) rotate_grafana ;;
  mobile) rotate_mobile ;;
  tde) rotate_tde ;;
  *) usage >&2; fail "unknown secret: $ROTATION_KIND" ;;
esac
