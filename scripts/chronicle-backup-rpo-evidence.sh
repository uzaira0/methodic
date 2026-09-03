#!/usr/bin/env bash
# Collect static backup/RPO evidence without reading backup contents or secrets.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPORT_DIR="${CHRONICLE_BACKUP_RPO_EVIDENCE_DIR:-/tmp/chronicle-backup-rpo-evidence}"
RUN_LIVE=0
REQUIRE_LIVE=0
LOCAL_DIR="$ROOT_DIR/k8s/backup/local"
OFFHOST_DIR="$ROOT_DIR/k8s/backup/offhost"
FORBIDDEN_EVIDENCE_PLACEHOLDER_PATTERN='TODO|TBD|FIXME|CHANGEME|REPLACE_WITH|REPLACE_ME|YOUR_|EXAMPLE_|INSERT_|lorem ipsum|/path/to/|<[^>]*(TODO|TBD|CHANGEME|REPLACE|YOUR|INSERT|EXAMPLE|PATH)[^>]*>'

usage() {
  cat <<'EOF'
Usage: scripts/chronicle-backup-rpo-evidence.sh [options]

Collects backup/RPO evidence for operator deployment readiness:
  - canonical checkout proof
  - rendered local and off-host backup Kubernetes manifests
  - backup artifact guardrail output
  - CronJob/PVC/posture inventory from rendered manifests
  - backup/RPO coverage matrix separating local rehearsal proof, off-host
    export mechanics, live drill evidence, and operator-supplied RPO evidence
  - source script/config checksums
  - optional live drill evidence if CHRONICLE_LIVE_BACKUP_DRILL_EVIDENCE points
    at a redacted evidence file
  - artifact SHA-256 manifest

Options:
  --report-dir DIR    Evidence output directory.
  --live              Attach redacted live drill evidence when provided.
  --require-live      Require CHRONICLE_LIVE_BACKUP_DRILL_EVIDENCE.
  -h, --help          Show this help.

This script does not query Kubernetes, decrypt backups, print Secret values, or
read backup payloads. Production approval should attach redacted CHRONICLE_RPO_EVIDENCE.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --report-dir)
      REPORT_DIR="${2:?--report-dir requires a value}"
      shift 2
      ;;
    --live)
      RUN_LIVE=1
      shift
      ;;
    --require-live)
      RUN_LIVE=1
      REQUIRE_LIVE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

mkdir -p "$REPORT_DIR"
SUMMARY="$REPORT_DIR/summary.tsv"
: > "$SUMMARY"

timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

record() {
  printf '%s\t%s\t%s\n' "$(timestamp)" "$1" "$2" | tee -a "$SUMMARY"
}

run_step() {
  local name="$1"
  shift
  local logfile="$REPORT_DIR/${name//[^A-Za-z0-9_.-]/_}.log"
  record "$name" "start"
  if "$@" >"$logfile" 2>&1; then
    record "$name" "pass"
  else
    local status=$?
    record "$name" "fail status=$status log=$logfile"
    cat "$logfile" >&2
    exit "$status"
  fi
}

sha256_file() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  else
    shasum -a 256 "$path" | awk '{print $1}'
  fi
}

validate_evidence_has_no_placeholders() {
  local label="$1"
  local evidence="$2"
  if grep -Eiq "$FORBIDDEN_EVIDENCE_PLACEHOLDER_PATTERN" "$evidence"; then
    echo "$label must not contain unresolved placeholders such as TODO, TBD, CHANGEME, REPLACE_WITH, YOUR_, EXAMPLE_, INSERT_, lorem ipsum, or /path/to/: $evidence" >&2
    return 1
  fi
}

render_overlay() {
  local overlay="$1"
  local output="$2"
  if command -v kubectl >/dev/null 2>&1; then
    kubectl kustomize "$overlay" > "$output"
  elif command -v kustomize >/dev/null 2>&1; then
    kustomize build "$overlay" > "$output"
  else
    echo "kubectl or kustomize is required to render backup overlays" >&2
    return 127
  fi
}

render_backup_manifests() {
  render_overlay "$LOCAL_DIR" "$REPORT_DIR/local-backup-rendered.yaml"
  render_overlay "$OFFHOST_DIR" "$REPORT_DIR/offhost-backup-rendered.yaml"
}

write_source_checksums() {
  local output="$REPORT_DIR/backup-source-files.tsv"
  local rel
  {
    printf 'path\tsha256\n'
    for rel in \
      k8s/backup/local/kustomization.yaml \
      k8s/backup/local/backup.yaml \
      k8s/backup/local/scripts/backup.sh \
      k8s/backup/local/scripts/verify-latest.sh \
      k8s/backup/local/scripts/restore-drill.sh \
      k8s/backup/offhost/kustomization.yaml \
      k8s/backup/offhost/offhost-export.yaml \
      k8s/backup/offhost/scripts/export-latest.sh \
      tests/security/backup-artifact-guardrails.sh; do
      if [[ ! -f "$ROOT_DIR/$rel" ]]; then
        printf 'missing source file: %s\n' "$rel" >&2
        return 1
      fi
      printf '%s\t%s\n' "$rel" "$(sha256_file "$ROOT_DIR/$rel")"
    done
  } > "$output"
}

write_backup_inventory() {
  python3 - "$ROOT_DIR" "$REPORT_DIR" <<'PY'
import pathlib
import re
import sys

import yaml

root = pathlib.Path(sys.argv[1])
report = pathlib.Path(sys.argv[2])

def docs(path):
    return [doc for doc in yaml.safe_load_all(path.read_text(encoding="utf-8")) if isinstance(doc, dict)]

def config_literals(path):
    text = path.read_text(encoding="utf-8")
    rows = {}
    for match in re.finditer(r"^\s+- ([A-Za-z0-9_.-]+)=(.*)$", text, re.M):
        rows[match.group(1)] = match.group(2).strip()
    return rows

def find_docs(all_docs, kind, name):
    return [
        doc
        for doc in all_docs
        if doc.get("kind") == kind and (doc.get("metadata", {}) or {}).get("name") == name
    ]

def cron_row(doc):
    spec = doc.get("spec", {}) or {}
    pod_spec = spec.get("jobTemplate", {}).get("spec", {}).get("template", {}).get("spec", {})
    containers = pod_spec.get("containers", []) or []
    container = containers[0] if containers else {}
    security = container.get("securityContext", {}) or {}
    return {
        "name": (doc.get("metadata", {}) or {}).get("name", ""),
        "schedule": spec.get("schedule", ""),
        "suspend": str(spec.get("suspend", "")).lower(),
        "concurrency": spec.get("concurrencyPolicy", ""),
        "service_account": pod_spec.get("serviceAccountName", ""),
        "automount_token": str(pod_spec.get("automountServiceAccountToken", "")).lower(),
        "run_as_non_root": str((pod_spec.get("securityContext", {}) or {}).get("runAsNonRoot", "")).lower(),
        "read_only_root": str(security.get("readOnlyRootFilesystem", "")).lower(),
        "allow_privilege_escalation": str(security.get("allowPrivilegeEscalation", "")).lower(),
        "image": container.get("image", ""),
    }

local_docs = docs(report / "local-backup-rendered.yaml")
offhost_docs = docs(report / "offhost-backup-rendered.yaml")
local_literals = config_literals(root / "k8s/backup/local/kustomization.yaml")
offhost_literals = config_literals(root / "k8s/backup/offhost/kustomization.yaml")

cron_rows = [
    "profile\tname\tschedule\tsuspend\tconcurrency\tservice_account\tautomount_token\trun_as_non_root\tread_only_root\tallow_privilege_escalation\timage"
]
for profile, all_docs, names in [
    ("local", local_docs, ["chronicle-local-backup", "chronicle-local-backup-verify", "chronicle-local-restore-drill"]),
    ("offhost", offhost_docs, ["chronicle-offhost-backup-export"]),
]:
    for name in names:
        matches = find_docs(all_docs, "CronJob", name)
        if not matches:
            raise SystemExit(f"missing CronJob in rendered manifest: {name}")
        row = cron_row(matches[0])
        cron_rows.append(
            "\t".join(
                [
                    profile,
                    row["name"],
                    row["schedule"],
                    row["suspend"],
                    row["concurrency"],
                    row["service_account"],
                    row["automount_token"],
                    row["run_as_non_root"],
                    row["read_only_root"],
                    row["allow_privilege_escalation"],
                    row["image"],
                ]
            )
        )

pvc_rows = ["profile\tname\tstorage_class\tstorage\taccess_modes"]
for profile, all_docs, names in [
    ("local", local_docs, ["chronicle-local-backups"]),
    ("offhost", offhost_docs, ["chronicle-local-backups", "chronicle-offhost-backups"]),
]:
    for name in names:
        matches = find_docs(all_docs, "PersistentVolumeClaim", name)
        if not matches:
            raise SystemExit(f"missing PVC in rendered manifest: {name}")
        spec = matches[0].get("spec", {}) or {}
        storage = ((spec.get("resources", {}) or {}).get("requests", {}) or {}).get("storage", "")
        pvc_rows.append(
            "\t".join([profile, name, str(spec.get("storageClassName", "")), str(storage), ",".join(spec.get("accessModes", []) or [])])
        )

posture_rows = ["key\tvalue"]
for key in [
    "profile",
    "required_artifacts",
    "encryption",
    "rpo_tier",
    "max_data_loss",
    "max_backup_age_hours",
    "storage_scope",
    "production_cutover_requirement",
]:
    posture_rows.append(f"local.{key}\t{local_literals.get(key, '')}")
for key in [
    "export_profile",
    "target_name",
    "storage_scope",
    "production_cutover_requirement",
    "max_backup_age_hours",
]:
    posture_rows.append(f"offhost.{key}\t{offhost_literals.get(key, '')}")

blockers = []
required_local = {
    "profile": "chronicle-k8s-local-backup-v1",
    "rpo_tier": "degraded-local",
    "max_data_loss": "24h-if-latest-backup-verified",
    "max_backup_age_hours": "25",
    "storage_scope": "single-node-local-pvc",
    "production_cutover_requirement": "off-host-or-operator-managed-pitr-evidence",
}
for key, expected in required_local.items():
    if local_literals.get(key) != expected:
        blockers.append(f"local posture mismatch: {key}={local_literals.get(key)!r}, expected {expected!r}")

required_artifacts = local_literals.get("required_artifacts", "")
for artifact in [
    "database.dump.enc",
    "tde-keyring.tar.gz.enc",
    "audit-logs.tar.gz.enc",
    "deployment-evidence.tar.gz.enc",
    "artifact-sha256sums.txt",
    "manifest.json",
    "manifest.json.sha256",
]:
    if artifact not in required_artifacts:
        blockers.append(f"local required_artifacts missing {artifact}")

if offhost_literals.get("export_profile") != "chronicle-k8s-offhost-export-v1":
    blockers.append("offhost export profile is not chronicle-k8s-offhost-export-v1")
if offhost_literals.get("target_name") == "REPLACE_WITH_APPROVED_BACKUP_TARGET":
    posture_rows.append("offhost.target_status\tplaceholder-fail-closed")
else:
    posture_rows.append("offhost.target_status\tconfigured")
if offhost_literals.get("production_cutover_requirement") != "off-host-export-or-pitr-restore-evidence":
    blockers.append("offhost production cutover requirement is not explicit")

for row in cron_rows[1:]:
    fields = row.split("\t")
    name = fields[1]
    if fields[4] != "Forbid":
        blockers.append(f"{name} must use concurrencyPolicy Forbid")
    if fields[6] != "false":
        blockers.append(f"{name} must disable service-account token automount")
    if fields[7] != "true":
        blockers.append(f"{name} must run as non-root")
    if fields[8] != "true":
        blockers.append(f"{name} must use readOnlyRootFilesystem")
    if fields[9] != "false":
        blockers.append(f"{name} must disallow privilege escalation")

(report / "backup-cronjobs.tsv").write_text("\n".join(cron_rows) + "\n", encoding="utf-8")
(report / "backup-pvcs.tsv").write_text("\n".join(pvc_rows) + "\n", encoding="utf-8")
(report / "backup-recovery-posture.tsv").write_text("\n".join(posture_rows) + "\n", encoding="utf-8")
(report / "backup-rpo-static-blockers.txt").write_text("\n".join(blockers) + ("\n" if blockers else ""), encoding="utf-8")
if blockers:
    raise SystemExit("backup/RPO static blockers: " + ", ".join(blockers))
PY
}

write_rpo_coverage_matrix() {
  local matrix="$REPORT_DIR/backup-rpo-coverage-matrix.tsv"
  cat > "$matrix" <<'EOF'
control	evidence_artifact	local_static_status	cutover_use	stop_condition
local-encrypted-backup	local-backup-rendered.yaml;backup-recovery-posture.tsv;backup-artifact-guardrails/backup-artifact-guardrails.txt	covered-by-local-rehearsal	degraded-only	Local single-node PVC backups cannot satisfy preferred production RPO without approved degraded-RPO exception.
required-artifact-integrity	backup-recovery-posture.tsv;backup-rpo-static-blockers.txt;backup-artifact-guardrails/backup-artifact-guardrails.txt	covered-by-local-rehearsal	supporting-evidence	Any missing required artifact, manifest checksum, artifact-sha256sums.txt check, or unsafe latest symlink blocks backup acceptance.
restore-drill-mechanics	local-backup-rendered.yaml;live-backup-drill-evidence.txt	covered-by-static-and-optional-live	supporting-evidence	Strict cutover requires redacted restore or verification proof on a PHI/ePHI-approved target.
offhost-export-mechanics	offhost-backup-rendered.yaml;backup-cronjobs.tsv;backup-pvcs.tsv;backup-recovery-posture.tsv	covered-by-local-render	requires-approved-target	Placeholder OFFHOST_BACKUP_TARGET_NAME, suspended job without approved schedule, or missing offhost-export-receipt.json plus offhost-export-receipt.json.sha256 blocks RPO proof.
one-hour-rpo-path	CHRONICLE_RPO_EVIDENCE	required-strict-evidence	production-required	No WAL/PITR, hourly encrypted artifact, or operator-approved application-consistent snapshot evidence means preferred one-hour RPO is unproved.
fallback-restore-target	CHRONICLE_RPO_EVIDENCE	required-strict-evidence	production-required	No PHI/ePHI-approved fallback or restore-target evidence blocks production cutover.
key-custody-and-encryption	CHRONICLE_RPO_EVIDENCE;backup-rpo-evidence-manifest.txt	required-strict-evidence	production-required	Backup encryption or TDE/key custody stored with backup media, printed in logs, or omitted from evidence blocks production cutover.
freshness-and-cadence	CHRONICLE_RPO_EVIDENCE;live-backup-drill-evidence.txt	required-strict-evidence	production-required	No latest recovery-point freshness, cadence proof, or backup-age proof blocks production cutover.
artifact-transfer-receipt	CHRONICLE_RPO_EVIDENCE	required-strict-evidence	production-required	Off-host/hourly artifact export paths must include offhost-export-receipt.json or equivalent transfer receipt plus checksum proof.
EOF
  printf 'backup/RPO coverage matrix written: %s\n' "$matrix"
}

validate_live_evidence() {
  local evidence="${CHRONICLE_LIVE_BACKUP_DRILL_EVIDENCE:-}"
  local output="$REPORT_DIR/live-backup-drill-evidence.txt"
  if [[ -z "$evidence" ]]; then
    if [[ "$REQUIRE_LIVE" == "1" ]]; then
      echo "CHRONICLE_LIVE_BACKUP_DRILL_EVIDENCE is required for --require-live" >&2
      return 1
    fi
    printf 'live_evidence=not_provided\n' > "$output"
    record "live-backup-drill-evidence" "skip CHRONICLE_LIVE_BACKUP_DRILL_EVIDENCE not set"
    return 0
  fi
  if [[ ! -r "$evidence" ]]; then
    echo "CHRONICLE_LIVE_BACKUP_DRILL_EVIDENCE is not readable: $evidence" >&2
    return 1
  fi
  if grep -Eiq 'password[=:]|token[=:]|api[_-]?key[=:]|authorization:[[:space:]]*(bearer|basic)|-----BEGIN .*PRIVATE KEY-----|PGPASSWORD|BACKUP_ENCRYPTION_PASSPHRASE|secret value|kubeconfig|client-key-data:' "$evidence"; then
    echo "CHRONICLE_LIVE_BACKUP_DRILL_EVIDENCE must not contain raw secrets or kubeconfig material: $evidence" >&2
    return 1
  fi
  validate_evidence_has_no_placeholders "CHRONICLE_LIVE_BACKUP_DRILL_EVIDENCE" "$evidence" || return 1
  for pattern in \
    'backup|recovery point|latest backup' \
    'verify|verification|artifact-sha256sums|checksum|sha256' \
    'restore|drill|recovered' \
    'RPO|max data loss|backup age|freshness' \
    'encrypt|key custody|TDE|backup encryption'; do
    if ! grep -Eiq "$pattern" "$evidence"; then
      echo "CHRONICLE_LIVE_BACKUP_DRILL_EVIDENCE missing required proof pattern: $pattern ($evidence)" >&2
      return 1
    fi
  done
  {
    printf 'live_evidence=%s\n' "$evidence"
    printf 'sha256=%s\n' "$(sha256_file "$evidence")"
  } > "$output"
}

write_manifest() {
  local manifest="$REPORT_DIR/backup-rpo-evidence-manifest.txt"
  {
    printf 'date_utc=%s\n' "$(timestamp)"
    printf 'repo=%s\n' "$ROOT_DIR"
    printf 'live_requested=%s\n' "$RUN_LIVE"
    printf 'live_required=%s\n' "$REQUIRE_LIVE"
    printf 'strict_cutover_rpo_evidence=%s\n' "CHRONICLE_RPO_EVIDENCE"
    printf 'strict_cutover_note=%s\n' "local-single-node-backup-is-rehearsal-only"
    printf 'artifact\tsha256\n'
    for artifact in \
      local-backup-rendered.yaml \
      offhost-backup-rendered.yaml \
      backup-source-files.tsv \
      backup-cronjobs.tsv \
      backup-pvcs.tsv \
      backup-recovery-posture.tsv \
      backup-rpo-coverage-matrix.tsv \
      backup-rpo-static-blockers.txt \
      live-backup-drill-evidence.txt \
      backup-artifact-guardrails/backup-artifact-guardrails.txt; do
      printf '%s\t%s\n' "$artifact" "$(sha256_file "$REPORT_DIR/$artifact")"
    done
  } > "$manifest"
}

run_step "canonical-preflight-explain" "${REPO_CANONICAL_PREFLIGHT:-repo-canonical-preflight}" --explain
run_step "canonical-preflight" "${REPO_CANONICAL_PREFLIGHT:-repo-canonical-preflight}"
run_step "render-backup-manifests" render_backup_manifests
run_step "backup-source-checksums" write_source_checksums
run_step "backup-rpo-static-inventory" write_backup_inventory
run_step "backup-rpo-coverage-matrix" write_rpo_coverage_matrix
run_step "backup-artifact-guardrails" "$ROOT_DIR/tests/security/backup-artifact-guardrails.sh" "$REPORT_DIR/backup-artifact-guardrails"
if [[ "$RUN_LIVE" == "1" ]]; then
  run_step "live-backup-drill-evidence" validate_live_evidence
else
  printf 'live_evidence=not_requested\n' > "$REPORT_DIR/live-backup-drill-evidence.txt"
  record "live-backup-drill-evidence" "skip --live not set"
fi
run_step "write-backup-rpo-evidence-manifest" write_manifest

record "evidence" "complete report_dir=$REPORT_DIR"
printf 'Chronicle backup/RPO evidence complete: %s\n' "$REPORT_DIR"
