#!/usr/bin/env bash
set -euo pipefail

if [ -z "${BACKUP_ENCRYPTION_PASSPHRASE:-}" ]; then
  echo "FATAL: missing BACKUP_ENCRYPTION_PASSPHRASE" >&2
  exit 1
fi
if [ -z "${BACKUP_MAX_AGE_HOURS:-}" ]; then
  echo "FATAL: missing BACKUP_MAX_AGE_HOURS" >&2
  exit 1
fi

latest="/backups/latest"
if [ ! -L "$latest" ]; then
  echo "FATAL: latest backup symlink missing" >&2
  exit 1
fi

latest_dir="$(readlink -f "$latest")"
case "$latest_dir" in
  /backups/*) ;;
  *)
    echo "FATAL: latest backup symlink resolves outside /backups: ${latest_dir}" >&2
    exit 1
    ;;
esac
test -d "$latest_dir"
cd "$latest_dir"

validate_backup_freshness() {
  local timestamp now_epoch backup_epoch age_seconds max_age_seconds
  timestamp="$(basename "$latest_dir")"
  if ! [[ "$timestamp" =~ ^[0-9]{8}T[0-9]{6}Z$ ]]; then
    echo "FATAL: latest backup directory is not a UTC timestamp: ${timestamp}" >&2
    exit 1
  fi
  now_epoch="$(date -u +%s)"
  backup_epoch="$(date -u -d "${timestamp:0:4}-${timestamp:4:2}-${timestamp:6:2} ${timestamp:9:2}:${timestamp:11:2}:${timestamp:13:2} UTC" +%s)"
  if [ "$backup_epoch" -gt "$now_epoch" ]; then
    echo "FATAL: latest backup timestamp is in the future: ${timestamp}" >&2
    exit 1
  fi
  max_age_seconds=$(( BACKUP_MAX_AGE_HOURS * 3600 ))
  age_seconds=$(( now_epoch - backup_epoch ))
  if [ "$age_seconds" -gt "$max_age_seconds" ]; then
    echo "FATAL: latest backup age ${age_seconds}s exceeds ${BACKUP_MAX_AGE_HOURS}h threshold" >&2
    exit 1
  fi
}

validate_required_artifacts() {
  local required_artifacts artifact missing=0
  required_artifacts="$(sed -n 's/.*"required_artifacts": "\([^"]*\)".*/\1/p' manifest.json)"
  if [ -z "$required_artifacts" ]; then
    echo "FATAL: manifest missing required_artifacts" >&2
    exit 1
  fi

  IFS=',' read -r -a artifact_list <<< "$required_artifacts"
  for artifact in "${artifact_list[@]}"; do
    artifact="${artifact//[[:space:]]/}"
    if [ -z "$artifact" ]; then
      continue
    fi
    if [ ! -s "$artifact" ]; then
      echo "FATAL: manifest-declared required artifact missing or empty: $artifact" >&2
      missing=1
    fi
  done
  if [ "$missing" -ne 0 ]; then
    exit 1
  fi
}

sha256sum -c manifest.json.sha256
validate_required_artifacts
test -s artifact-sha256sums.txt
expected_checksum_file_sha="$(sed -n 's/.*"artifact_checksum_file_sha256": "\([0-9a-f]\{64\}\)".*/\1/p' manifest.json)"
if [ -z "$expected_checksum_file_sha" ]; then
  echo "FATAL: manifest missing artifact_checksum_file_sha256" >&2
  exit 1
fi
printf '%s  artifact-sha256sums.txt\n' "$expected_checksum_file_sha" | sha256sum -c -
sha256sum -c artifact-sha256sums.txt
validate_backup_freshness

openssl enc -aes-256-cbc -d -salt -pbkdf2 -iter 600000 \
  -in database.dump.enc \
  -out /work/database.dump \
  -pass env:BACKUP_ENCRYPTION_PASSPHRASE

mkdir -p /work/pgdata /work/pgsocket /work/tde-keyring
initdb -D /work/pgdata --auth-local=trust --auth-host=trust >/work/initdb.log

pg_ctl -D /work/pgdata \
  -l /work/postgres.log \
  -o "-c listen_addresses='' -c unix_socket_directories=/work/pgsocket -c shared_preload_libraries=pg_tde,pgaudit,pg_stat_statements" \
  -w start

cleanup() {
  pg_ctl -D /work/pgdata -m fast -w stop >/dev/null 2>&1 || true
}
trap cleanup EXIT

createdb -h /work/pgsocket -U postgres chronicle_restore
psql -h /work/pgsocket -U postgres -d chronicle_restore -v ON_ERROR_STOP=1 <<'SQL'
CREATE ROLE chronicle LOGIN;
SQL

if ! pg_restore \
  -h /work/pgsocket \
  -U postgres \
  -d chronicle_restore \
  --no-owner \
  --no-acl \
  --exit-on-error \
  /work/database.dump \
  >/work/pg_restore.log 2>&1; then
  echo "FATAL: pg_restore failed" >&2
  tail -120 /work/pg_restore.log >&2 || true
  exit 1
fi

table_count="$(psql -h /work/pgsocket -U postgres -d chronicle_restore -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema NOT IN ('pg_catalog','information_schema');")"
extension_count="$(psql -h /work/pgsocket -U postgres -d chronicle_restore -tAc "SELECT count(*) FROM pg_extension WHERE extname IN ('pg_tde','pgaudit');")"

if [ "${table_count}" -lt 1 ]; then
  echo "FATAL: restored database has no application tables" >&2
  exit 1
fi

if [ "${extension_count}" -lt 2 ]; then
  echo "FATAL: restored database missing pg_tde or pgaudit extension" >&2
  exit 1
fi

echo "Chronicle Kubernetes restore drill passed: tables=${table_count}, extensions=${extension_count}, source=${latest_dir}"
