#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
state_dir=${CHRONICLE_STATE_DIR:?Set CHRONICLE_STATE_DIR}
backup_root="$state_dir/backups/postgres"
max_age_seconds=${CHRONICLE_BACKUP_MAX_AGE_SECONDS:-21600}
mkdir -p "$backup_root"
chmod 0700 "$backup_root"

exec 9>"$backup_root/.backup.lock"
flock -n 9 || {
  echo "another Chronicle logical backup is running" >&2
  exit 1
}

latest="$backup_root/latest"
if [[ -L "$latest" && -f "$latest/complete" ]]; then
  age=$(( $(date +%s) - $(stat -c %Y "$latest/complete") ))
  if (( age >= 0 && age < max_age_seconds )); then
    echo "Chronicle logical backup is fresh ($age seconds old)"
    exit 0
  fi
fi

compose=(podman compose -f "$script_dir/compose.yml")
postgres_cid=$(podman ps \
  --filter label=io.podman.compose.project=chronicle-next \
  --filter label=io.podman.compose.service=postgres \
  --filter status=running \
  --format '{{.ID}}')
postgres_count=$(grep -c . <<<"$postgres_cid" || true)
if (( postgres_count != 1 )); then
  echo "Chronicle PostgreSQL is installed but not running" >&2
  exit 1
fi

stamp=$(date -u +%Y%m%dT%H%M%SZ)
work=$(mktemp -d "$backup_root/.incomplete-$stamp.XXXXXX")
trap 'rm -rf "$work"' EXIT
chmod 0700 "$work"

"${compose[@]}" exec -T postgres sh -euc '
  export PGPASSWORD="$(cat /run/secrets/postgres_password)"
  exec pg_dump -h 127.0.0.1 -U chronicle -d chronicle -Fc \
    --exclude-extension=pg_tde --exclude-extension=pgaudit
' > "$work/chronicle.dump"

"${compose[@]}" exec -T postgres pg_restore --list < "$work/chronicle.dump" > "$work/pg_restore.list"
"${compose[@]}" exec -T postgres sh -euc '
  export PGPASSWORD="$(cat /run/secrets/postgres_password)"
  exec psql -h 127.0.0.1 -U chronicle -d chronicle -X -v ON_ERROR_STOP=1 -At
' > "$work/oracle.json" <<'SQL'
SELECT jsonb_build_object(
  'captured_at', clock_timestamp(),
  'database_size_bytes', pg_database_size(current_database()),
  'public_regular_tables', (
    SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p')
  ),
  'tde_heap_tables', (
    SELECT count(*) FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_am a ON a.oid = c.relam
    WHERE n.nspname = 'public' AND c.relkind = 'r' AND a.amname = 'tde_heap'
  ),
  'rls_tables', (
    SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p') AND c.relrowsecurity
  ),
  'participants', (SELECT count(*) FROM study_participants),
  'devices', (SELECT count(*) FROM devices),
  'sensor_data', (SELECT count(*) FROM sensor_data),
  'android_sensor_data', (SELECT count(*) FROM android_sensor_data)
);
SQL

(cd "$work" && sha256sum chronicle.dump pg_restore.list oracle.json > SHA256SUMS)
printf '%s\n' "$stamp" > "$work/complete"
chmod 0600 "$work"/*
final="$backup_root/$stamp"
mv "$work" "$final"
ln -sfn "$stamp" "$latest.next"
mv -Tf "$latest.next" "$latest"
trap - EXIT
echo "$final"
