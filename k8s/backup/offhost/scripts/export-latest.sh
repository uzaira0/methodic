#!/usr/bin/env bash
set -euo pipefail

umask 077

require() {
  if [ -z "${!1:-}" ]; then
    echo "FATAL: missing required environment variable: $1" >&2
    exit 1
  fi
}

for var in OFFHOST_BACKUP_TARGET_NAME OFFHOST_STORAGE_SCOPE OFFHOST_EXPORT_PROFILE OFFHOST_PRODUCTION_CUTOVER_REQUIREMENT BACKUP_MAX_AGE_HOURS; do
  require "$var"
done

if [[ "$OFFHOST_BACKUP_TARGET_NAME" == REPLACE_* || "$OFFHOST_BACKUP_TARGET_NAME" == CHANGEME* ]]; then
  echo "FATAL: OFFHOST_BACKUP_TARGET_NAME must identify an approved operator target" >&2
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

cd "$latest_dir"
sha256sum -c manifest.json.sha256
test -s artifact-sha256sums.txt
expected_checksum_file_sha="$(sed -n 's/.*"artifact_checksum_file_sha256": "\([0-9a-f]\{64\}\)".*/\1/p' manifest.json)"
if [ -z "$expected_checksum_file_sha" ]; then
  echo "FATAL: manifest missing artifact_checksum_file_sha256" >&2
  exit 1
fi
printf '%s  artifact-sha256sums.txt\n' "$expected_checksum_file_sha" | sha256sum -c -
sha256sum -c artifact-sha256sums.txt

required_artifacts="$(sed -n 's/.*"required_artifacts": "\([^"]*\)".*/\1/p' manifest.json)"
if [ -z "$required_artifacts" ]; then
  echo "FATAL: manifest missing required_artifacts" >&2
  exit 1
fi

artifact_list=()
IFS=',' read -r -a raw_artifacts <<< "$required_artifacts"
for artifact in "${raw_artifacts[@]}"; do
  artifact="${artifact//[[:space:]]/}"
  if [ -z "$artifact" ]; then
    continue
  fi
  case "$artifact" in
    *.enc|artifact-sha256sums.txt|manifest.json|manifest.json.sha256) ;;
    *)
      echo "FATAL: manifest-declared artifact is not allowed for off-host export: $artifact" >&2
      exit 1
      ;;
  esac
  if [ ! -s "$artifact" ]; then
    echo "FATAL: manifest-declared required artifact missing or empty: $artifact" >&2
    exit 1
  fi
  if [ -L "$artifact" ]; then
    echo "FATAL: manifest-declared required artifact must not be a symlink: $artifact" >&2
    exit 1
  fi
  artifact_list+=("$artifact")
done

destination="/offhost-backups/${timestamp}"
staging="/offhost-backups/.staging-${timestamp}"
if [ -e "$destination" ] || [ -e "$staging" ]; then
  echo "FATAL: off-host export path already exists for ${timestamp}" >&2
  exit 1
fi

mkdir -p "$staging"
cleanup() {
  rm -rf "$staging"
}
trap cleanup EXIT

for artifact in "${artifact_list[@]}"; do
  install -m 0600 "$artifact" "${staging}/${artifact}"
done

(cd "$staging" && sha256sum -c manifest.json.sha256)
(cd "$staging" && sha256sum -c artifact-sha256sums.txt)

receipt="${staging}/offhost-export-receipt.json"
cat > "$receipt" <<EOF
{
  "schema_version": 1,
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "source_backup": "${timestamp}",
  "export_profile": "${OFFHOST_EXPORT_PROFILE}",
  "target_name": "${OFFHOST_BACKUP_TARGET_NAME}",
  "storage_scope": "${OFFHOST_STORAGE_SCOPE}",
  "production_cutover_requirement": "${OFFHOST_PRODUCTION_CUTOVER_REQUIREMENT}",
  "source_age_seconds": ${age_seconds},
  "max_backup_age_hours": ${BACKUP_MAX_AGE_HOURS},
  "artifact_checksum_file": "artifact-sha256sums.txt",
  "manifest_checksum_file": "manifest.json.sha256",
  "exported_artifacts": "$(printf '%s\n' "${artifact_list[@]}" | paste -sd, -)"
}
EOF
chmod 0600 "$receipt"
sha256sum "$receipt" > "${staging}/offhost-export-receipt.json.sha256"
chmod 0600 "${staging}/offhost-export-receipt.json.sha256"

mv "$staging" "$destination"
ln -sfn "$timestamp" /offhost-backups/latest
trap - EXIT

echo "Chronicle off-host backup export passed: source=${latest_dir} destination=${destination}"
