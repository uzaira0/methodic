#!/usr/bin/env bash
set -euo pipefail

REPORT_DIR="${1:-/tmp/chronicle-backup-artifact-guardrails}"
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
mkdir -p "$REPORT_DIR"

BACKUP_SCRIPT="${ROOT_DIR}/docker/backup-chronicle.sh"
RESTORE_SCRIPT="${ROOT_DIR}/docker/restore-chronicle.sh"
DRILL_SCRIPT="${ROOT_DIR}/docker/quarterly-restore-drill.sh"
BACKUP_DR_TEST="${ROOT_DIR}/tests/security/backup-dr-test.sh"
K8S_OFFHOST_EXPORT_SCRIPT="${ROOT_DIR}/k8s/backup/offhost/scripts/export-latest.sh"
BACKUP_RPO_EVIDENCE_SCRIPT="${ROOT_DIR}/scripts/chronicle-backup-rpo-evidence.sh"

fail() {
  echo "backup artifact guardrail failed: $*" >&2
  exit 1
}

require_pattern() {
  local file="$1"
  local pattern="$2"
  local message="$3"
  if ! grep -Eq "$pattern" "$file"; then
    fail "$message ($file)"
  fi
}

for file in "$BACKUP_SCRIPT" "$RESTORE_SCRIPT" "$DRILL_SCRIPT" "$BACKUP_DR_TEST" "$K8S_OFFHOST_EXPORT_SCRIPT" "$BACKUP_RPO_EVIDENCE_SCRIPT"; do
  [ -f "$file" ] || fail "required script missing: $file"
  bash -n "$file"
done

require_pattern "$BACKUP_SCRIPT" '\.env\.production\.local' \
  "backup script must prefer the untracked production env file"
require_pattern "$BACKUP_SCRIPT" 'CHRONICLE_BACKUP_ENV_FILE' \
  "backup script must allow an explicit active env file"
require_pattern "$BACKUP_SCRIPT" 'deployment-manifest\.tar\.gz\.enc' \
  "backup script must include encrypted deployment evidence"
require_pattern "$BACKUP_SCRIPT" 'required_artifacts' \
  "backup manifest must declare required artifacts"
require_pattern "$BACKUP_SCRIPT" 'CHRONICLE_REQUIRE_AUDIT_BACKUP:-true' \
  "audit-log backup must fail closed by default"
require_pattern "$BACKUP_SCRIPT" 'audit-logs\.tar\.gz\.enc' \
  "backup script must include audit logs in the production recovery set"

require_pattern "$RESTORE_SCRIPT" 'DEFAULT_KEY="/etc/chronicle/backup-encryption-key"' \
  "restore script must default to the hardened backup key location"
require_pattern "$RESTORE_SCRIPT" 'docker-compose\.production\.yml' \
  "restore script must include the production compose overlay"
require_pattern "$RESTORE_SCRIPT" '\.env\.production\.local' \
  "restore script must consume restored production-local env files"
require_pattern "$RESTORE_SCRIPT" 'audit-logs\.tar\.gz\.enc' \
  "restore script must handle encrypted audit log artifacts"
require_pattern "$RESTORE_SCRIPT" 'docker volume create "\$AUDIT_VOLUME"' \
  "restore script must restore audit logs into the Docker audit volume"

require_pattern "$DRILL_SCRIPT" 'REQUIRED_ARTIFACTS=' \
  "quarterly drill must validate required artifact coverage"
require_pattern "$DRILL_SCRIPT" 'deployment-manifest\.tar\.gz\.enc' \
  "quarterly drill must validate deployment evidence"
require_pattern "$DRILL_SCRIPT" 'config-secrets\.tar\.gz\.enc' \
  "quarterly drill must validate config/secret backup"
require_pattern "$DRILL_SCRIPT" 'audit-logs\.tar\.gz\.enc' \
  "quarterly drill must validate audit log backup"

require_pattern "${ROOT_DIR}/k8s/backup/local/kustomization.yaml" 'rpo_tier=degraded-local' \
  "Kubernetes local backup profile must declare degraded-local RPO posture"
require_pattern "${ROOT_DIR}/k8s/backup/local/kustomization.yaml" 'max_backup_age_hours=25' \
  "Kubernetes local backup profile must declare a stale-backup threshold"
require_pattern "${ROOT_DIR}/k8s/backup/local/kustomization.yaml" 'storage_scope=single-node-local-pvc' \
  "Kubernetes local backup profile must declare single-node local storage scope"
require_pattern "${ROOT_DIR}/k8s/backup/local/kustomization.yaml" 'production_cutover_requirement=off-host-or-operator-managed-pitr-evidence' \
  "Kubernetes local backup profile must require off-host/PITR evidence for production cutover"
require_pattern "${ROOT_DIR}/k8s/backup/local/kustomization.yaml" 'artifact-sha256sums\.txt' \
  "Kubernetes local backup profile must include an artifact checksum file in the required artifact set"
require_pattern "${ROOT_DIR}/k8s/backup/local/kustomization.yaml" 'manifest\.json\.sha256' \
  "Kubernetes local backup profile must include the manifest checksum in the required artifact set"
require_pattern "${ROOT_DIR}/k8s/backup/local/scripts/backup.sh" 'recovery_posture' \
  "Kubernetes backup manifests must include recovery posture metadata"
require_pattern "${ROOT_DIR}/k8s/backup/local/scripts/backup.sh" 'max_backup_age_hours' \
  "Kubernetes backup manifests must include the freshness threshold"
require_pattern "${ROOT_DIR}/k8s/backup/local/scripts/backup.sh" 'artifact_checksum_file' \
  "Kubernetes backup manifests must identify the artifact checksum file"
require_pattern "${ROOT_DIR}/k8s/backup/local/scripts/backup.sh" 'sha256sum[[:space:]]*\\' \
  "Kubernetes backup script must write encrypted artifact checksums"
require_pattern "${ROOT_DIR}/k8s/backup/local/scripts/verify-latest.sh" 'manifest-declared required artifact missing or empty' \
  "Kubernetes backup verifier must fail closed on missing manifest-declared artifacts"
require_pattern "${ROOT_DIR}/k8s/backup/local/scripts/verify-latest.sh" 'production_cutover_requirement' \
  "Kubernetes backup verifier must require recovery posture metadata"
require_pattern "${ROOT_DIR}/k8s/backup/local/scripts/verify-latest.sh" 'sha256sum -c artifact-sha256sums\.txt' \
  "Kubernetes backup verifier must validate encrypted artifact checksums"
require_pattern "${ROOT_DIR}/k8s/backup/local/scripts/verify-latest.sh" 'artifact_checksum_file_sha256' \
  "Kubernetes backup verifier must bind the artifact checksum file to the manifest"
require_pattern "${ROOT_DIR}/k8s/backup/local/scripts/verify-latest.sh" 'latest backup symlink resolves outside /backups' \
  "Kubernetes backup verifier must reject latest symlinks outside the backup root"
require_pattern "${ROOT_DIR}/k8s/backup/local/scripts/verify-latest.sh" 'validate_backup_freshness' \
  "Kubernetes backup verifier must enforce freshness"
require_pattern "${ROOT_DIR}/k8s/backup/local/scripts/verify-latest.sh" 'latest backup age .* exceeds' \
  "Kubernetes backup verifier must fail closed on stale backups"
require_pattern "${ROOT_DIR}/k8s/backup/local/scripts/restore-drill.sh" 'manifest-declared required artifact missing or empty' \
  "Kubernetes restore drill must fail closed on missing manifest-declared artifacts"
require_pattern "${ROOT_DIR}/k8s/backup/local/scripts/restore-drill.sh" 'sha256sum -c artifact-sha256sums\.txt' \
  "Kubernetes restore drill must validate encrypted artifact checksums before restore"
require_pattern "${ROOT_DIR}/k8s/backup/local/scripts/restore-drill.sh" 'artifact_checksum_file_sha256' \
  "Kubernetes restore drill must bind the artifact checksum file to the manifest"
require_pattern "${ROOT_DIR}/k8s/backup/local/scripts/restore-drill.sh" 'latest backup symlink resolves outside /backups' \
  "Kubernetes restore drill must reject latest symlinks outside the backup root"
require_pattern "${ROOT_DIR}/k8s/backup/local/scripts/restore-drill.sh" 'validate_backup_freshness' \
  "Kubernetes restore drill must enforce freshness before restore"
require_pattern "${ROOT_DIR}/k8s/backup/local/scripts/restore-drill.sh" 'latest backup age .* exceeds' \
  "Kubernetes restore drill must fail closed on stale backups"
require_pattern "${ROOT_DIR}/k8s/backup/offhost/kustomization.yaml" '../local' \
  "off-host backup export package must include the local backup/verifier/restore base"
require_pattern "${ROOT_DIR}/k8s/backup/offhost/kustomization.yaml" 'chronicle-k8s-offhost-export-v1' \
  "off-host backup export package must declare an evidence profile"
require_pattern "${ROOT_DIR}/k8s/backup/offhost/offhost-export.yaml" 'name:[[:space:]]*chronicle-offhost-backup-export' \
  "off-host backup export CronJob must exist"
require_pattern "${ROOT_DIR}/k8s/backup/offhost/offhost-export.yaml" 'suspend:[[:space:]]*true' \
  "off-host backup export CronJob must be suspended until a target is approved"
require_pattern "${ROOT_DIR}/k8s/backup/offhost/offhost-export.yaml" 'claimName:[[:space:]]*chronicle-local-backups' \
  "off-host backup export must read from the local backup PVC"
require_pattern "${ROOT_DIR}/k8s/backup/offhost/offhost-export.yaml" 'readOnly:[[:space:]]*true' \
  "off-host backup export must mount the local backup PVC read-only"
require_pattern "${ROOT_DIR}/k8s/backup/offhost/offhost-export.yaml" 'claimName:[[:space:]]*chronicle-offhost-backups' \
  "off-host backup export must write to an explicit off-host backup PVC"
require_pattern "$K8S_OFFHOST_EXPORT_SCRIPT" 'OFFHOST_BACKUP_TARGET_NAME' \
  "off-host backup export must require a named approved target"
require_pattern "$K8S_OFFHOST_EXPORT_SCRIPT" 'OFFHOST_BACKUP_TARGET_NAME must identify an approved operator target' \
  "off-host backup export must reject placeholder targets"
require_pattern "$K8S_OFFHOST_EXPORT_SCRIPT" 'latest backup symlink resolves outside /backups' \
  "off-host backup export must reject latest symlinks outside the backup root"
require_pattern "$K8S_OFFHOST_EXPORT_SCRIPT" 'latest backup age .* exceeds' \
  "off-host backup export must fail closed on stale backups"
require_pattern "$K8S_OFFHOST_EXPORT_SCRIPT" 'sha256sum -c manifest\.json\.sha256' \
  "off-host backup export must validate the manifest checksum before transfer"
require_pattern "$K8S_OFFHOST_EXPORT_SCRIPT" 'sha256sum -c artifact-sha256sums\.txt' \
  "off-host backup export must validate encrypted artifact checksums before transfer"
require_pattern "$K8S_OFFHOST_EXPORT_SCRIPT" 'manifest-declared artifact is not allowed for off-host export' \
  "off-host backup export must allow only encrypted artifacts and checksum manifests"
require_pattern "$K8S_OFFHOST_EXPORT_SCRIPT" 'offhost-export-receipt\.json' \
  "off-host backup export must write a transfer receipt"
require_pattern "$K8S_OFFHOST_EXPORT_SCRIPT" 'offhost-export-receipt\.json\.sha256' \
  "off-host backup export must checksum the transfer receipt"
require_pattern "$BACKUP_RPO_EVIDENCE_SCRIPT" 'backup-rpo-evidence-manifest\.txt' \
  "backup/RPO evidence script writes a manifest"
require_pattern "$BACKUP_RPO_EVIDENCE_SCRIPT" 'backup-rpo-coverage-matrix\.tsv' \
  "backup/RPO evidence script writes a coverage matrix"
require_pattern "$BACKUP_RPO_EVIDENCE_SCRIPT" 'CHRONICLE_LIVE_BACKUP_DRILL_EVIDENCE' \
  "backup/RPO evidence supports redacted live drill evidence"
require_pattern "$BACKUP_RPO_EVIDENCE_SCRIPT" 'FORBIDDEN_EVIDENCE_PLACEHOLDER_PATTERN' \
  "backup/RPO evidence rejects unresolved placeholders"
require_pattern "$BACKUP_RPO_EVIDENCE_SCRIPT" 'validate_evidence_has_no_placeholders "CHRONICLE_LIVE_BACKUP_DRILL_EVIDENCE"' \
  "live backup evidence is checked for placeholders"

require_pattern "$BACKUP_DR_TEST" 'Production Recoverability Artifact Set' \
  "backup DR tests must include production artifact coverage"
require_pattern "$BACKUP_DR_TEST" 'decrypt_backup_file' \
  "backup DR tests must support current and legacy encryption iteration counts"

cat > "${REPORT_DIR}/backup-artifact-guardrails.txt" <<EOF
Backup artifact guardrails passed.
Validated scripts:
- ${BACKUP_SCRIPT}
- ${RESTORE_SCRIPT}
- ${DRILL_SCRIPT}
- ${BACKUP_DR_TEST}
- ${K8S_OFFHOST_EXPORT_SCRIPT}
- ${BACKUP_RPO_EVIDENCE_SCRIPT}
EOF

cat "${REPORT_DIR}/backup-artifact-guardrails.txt"
