#!/usr/bin/env bash
set -euo pipefail

umask 077

require() {
  if [ -z "${!1:-}" ]; then
    echo "FATAL: missing required environment variable: $1" >&2
    exit 1
  fi
}

for var in POSTGRES_HOST POSTGRES_PORT POSTGRES_DB POSTGRES_USER PGPASSWORD BACKUP_ENCRYPTION_PASSPHRASE BACKUP_PROFILE BACKUP_REQUIRED_ARTIFACTS BACKUP_RPO_TIER BACKUP_MAX_DATA_LOSS BACKUP_MAX_AGE_HOURS BACKUP_STORAGE_SCOPE BACKUP_PRODUCTION_CUTOVER_REQUIREMENT; do
  require "$var"
done

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
backup_dir="/backups/${timestamp}"
artifact_dir="/backups/.staging-${timestamp}"
stage="/work/${timestamp}"

cleanup() {
  rm -rf "$stage" "$artifact_dir"
}
trap cleanup EXIT

if [ -e "$backup_dir" ] || [ -e "$artifact_dir" ]; then
  echo "FATAL: backup path already exists for ${timestamp}" >&2
  exit 1
fi

mkdir -p "$artifact_dir" "$stage"

encrypt_file() {
  local src="$1"
  local dst="$2"
  openssl enc -aes-256-cbc -salt -pbkdf2 -iter 600000 \
    -in "$src" \
    -out "$dst" \
    -pass env:BACKUP_ENCRYPTION_PASSPHRASE
}

sha256() {
  sha256sum "$1" | awk '{print $1}'
}

echo "Starting Chronicle Kubernetes backup ${timestamp}"

pg_dump \
  -h "$POSTGRES_HOST" \
  -p "$POSTGRES_PORT" \
  -U "$POSTGRES_USER" \
  -d "$POSTGRES_DB" \
  -Fc \
  -Z6 \
  > "${stage}/database.dump"
encrypt_file "${stage}/database.dump" "${artifact_dir}/database.dump.enc"
rm -f "${stage}/database.dump"

tar -czf "${stage}/tde-keyring.tar.gz" -C /source/tde-keyring .
encrypt_file "${stage}/tde-keyring.tar.gz" "${artifact_dir}/tde-keyring.tar.gz.enc"
rm -f "${stage}/tde-keyring.tar.gz"

tar --ignore-failed-read --warning=no-file-changed -czf "${stage}/audit-logs.tar.gz" -C /source/audit-logs .
encrypt_file "${stage}/audit-logs.tar.gz" "${artifact_dir}/audit-logs.tar.gz.enc"
rm -f "${stage}/audit-logs.tar.gz"

tar -czf "${stage}/deployment-evidence.tar.gz" -C /deployment-evidence .
encrypt_file "${stage}/deployment-evidence.tar.gz" "${artifact_dir}/deployment-evidence.tar.gz.enc"
rm -f "${stage}/deployment-evidence.tar.gz"

(cd "$artifact_dir" && sha256sum \
  database.dump.enc \
  tde-keyring.tar.gz.enc \
  audit-logs.tar.gz.enc \
  deployment-evidence.tar.gz.enc \
  > artifact-sha256sums.txt)

cat > "${artifact_dir}/manifest.json" <<EOF
{
  "schema_version": 1,
  "timestamp": "${timestamp}",
  "profile": "${BACKUP_PROFILE}",
  "database": {
    "host": "${POSTGRES_HOST}",
    "port": "${POSTGRES_PORT}",
    "database": "${POSTGRES_DB}",
    "user": "${POSTGRES_USER}"
  },
  "encryption": {
    "algorithm": "aes-256-cbc",
    "kdf": "pbkdf2",
    "iterations": 600000
  },
  "required_artifacts": "${BACKUP_REQUIRED_ARTIFACTS}",
  "artifact_checksum_file": "artifact-sha256sums.txt",
  "artifact_checksum_file_sha256": "$(sha256 "${artifact_dir}/artifact-sha256sums.txt")",
  "recovery_posture": {
    "rpo_tier": "${BACKUP_RPO_TIER}",
    "max_data_loss": "${BACKUP_MAX_DATA_LOSS}",
    "max_backup_age_hours": "${BACKUP_MAX_AGE_HOURS}",
    "storage_scope": "${BACKUP_STORAGE_SCOPE}",
    "production_cutover_requirement": "${BACKUP_PRODUCTION_CUTOVER_REQUIREMENT}"
  },
  "artifacts": {
    "database.dump.enc": "$(sha256 "${artifact_dir}/database.dump.enc")",
    "tde-keyring.tar.gz.enc": "$(sha256 "${artifact_dir}/tde-keyring.tar.gz.enc")",
    "audit-logs.tar.gz.enc": "$(sha256 "${artifact_dir}/audit-logs.tar.gz.enc")",
    "deployment-evidence.tar.gz.enc": "$(sha256 "${artifact_dir}/deployment-evidence.tar.gz.enc")"
  }
}
EOF

(cd "$artifact_dir" && sha256sum manifest.json > manifest.json.sha256)
mv "$artifact_dir" "$backup_dir"
ln -sfn "$timestamp" /backups/latest

find "$backup_dir" -maxdepth 1 -type f -print | sort
echo "Chronicle Kubernetes backup complete: ${backup_dir}"
trap - EXIT
rm -rf "$stage"
