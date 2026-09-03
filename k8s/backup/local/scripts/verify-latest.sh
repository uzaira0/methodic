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

for required_manifest_field in \
  '"artifact_checksum_file": "artifact-sha256sums.txt"' \
  '"rpo_tier": "degraded-local"' \
  '"max_data_loss": "24h-if-latest-backup-verified"' \
  '"max_backup_age_hours": "25"' \
  '"storage_scope": "single-node-local-pvc"' \
  '"production_cutover_requirement": "off-host-or-operator-managed-pitr-evidence"'; do
  if ! grep -Fq "$required_manifest_field" manifest.json; then
    echo "FATAL: manifest missing recovery posture field: ${required_manifest_field}" >&2
    exit 1
  fi
done
validate_backup_freshness

for artifact in database.dump.enc tde-keyring.tar.gz.enc audit-logs.tar.gz.enc deployment-evidence.tar.gz.enc; do
  test -s "$artifact"
  out="/work/${artifact%.enc}"
  openssl enc -aes-256-cbc -d -salt -pbkdf2 -iter 600000 \
    -in "$artifact" \
    -out "$out" \
    -pass env:BACKUP_ENCRYPTION_PASSPHRASE
  test -s "$out"
done

pg_restore --list /work/database.dump >/dev/null
tar -tzf /work/tde-keyring.tar.gz >/dev/null
tar -tzf /work/audit-logs.tar.gz >/dev/null
tar -tzf /work/deployment-evidence.tar.gz >/dev/null

echo "Chronicle Kubernetes backup verification passed: ${latest_dir}"
