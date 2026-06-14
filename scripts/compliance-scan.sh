#!/usr/bin/env bash
# Chronicle HIPAA-2028 compliance scan cadence (lane W5).
#
# Runs the existing security scanners (tests/security/run-all-security.sh layers + trivy)
# into a DATED, retained evidence bundle, then emits a manifest, a HIPAA-mapped compliance
# report, and Prometheus metrics. This is the 6-month vulnerability-scan cadence required by
# the 2025 HIPAA Security Rule NPRM (§164.308(a)(8) evaluation; §164.308(a)(1)(ii)(A) risk
# analysis). The annual penetration test is tracked separately in docs/security/pentest-register.md.
#
# It does NOT reinvent scanning — it orchestrates run-all-security.sh and packages the output
# for audit. Tools that are not installed are skipped and recorded (no silent gaps).
#
# Per project ops reality, GitHub-hosted Actions are unreliable on these repos; this runs on
# the self-hosted host via cron/systemd, the same way docker/backup-chronicle.sh does.
#
# Usage:
#   compliance-scan.sh [--cycle vuln-scan|pentest-prep] [--layers a,b,c]
#                      [--evidence-root DIR] [--retention-cycles N] [--dry-run] [--prune]
#
# Cron setup (self-hosted runner):
#   # 6-month vulnerability scan: 1st of Jan and Jul, 02:30
#   30 2 1 1,7 *  /opt/chronicle/scripts/compliance-scan.sh --prune >> /var/log/chronicle-compliance.log 2>&1
#   # annual pentest-prep evidence snapshot: 1st of Jan, 03:30 (precedes the external engagement)
#   30 3 1 1 *    /opt/chronicle/scripts/compliance-scan.sh --cycle pentest-prep >> /var/log/chronicle-compliance.log 2>&1
#
# Retention: keep the last N vuln-scan cycles (default 4 = 2 years at 6-month cadence) and ALL
# pentest-prep cycles. Evidence is HIPAA audit material; do not prune pentest-prep.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUN_ALL="$ROOT_DIR/tests/security/run-all-security.sh"

CYCLE="vuln-scan"
LAYERS="sast,sca,secrets,iac,compliance"
EVIDENCE_ROOT="${COMPLIANCE_EVIDENCE_ROOT:-/var/lib/chronicle/compliance-evidence}"
METRICS_FILE="${COMPLIANCE_METRICS_FILE:-/var/log/chronicle/compliance-scan-metrics.prom}"
RETENTION_CYCLES=4
DRY_RUN=0
PRUNE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --cycle) CYCLE="${2:?}"; shift 2 ;;
    --layers) LAYERS="${2:?}"; shift 2 ;;
    --evidence-root) EVIDENCE_ROOT="${2:?}"; shift 2 ;;
    --retention-cycles) RETENTION_CYCLES="${2:?}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --prune) PRUNE=1; shift ;;
    -h|--help) sed -n '1,40p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

# Stable cycle date. Allow override via COMPLIANCE_CYCLE_DATE for reproducible/test runs.
CYCLE_DATE="${COMPLIANCE_CYCLE_DATE:-$(date +%Y-%m-%d)}"
NEXT_DATE="$(date -d "${CYCLE_DATE} +6 months" +%Y-%m-%d 2>/dev/null || echo "unknown")"
EVIDENCE_DIR="${EVIDENCE_ROOT}/${CYCLE_DATE}_${CYCLE}"

log() { echo "[compliance-scan] $*"; }

if [ "$DRY_RUN" -eq 1 ]; then
  log "DRY RUN — would write evidence to: $EVIDENCE_DIR"
  log "  cycle=$CYCLE  layers=$LAYERS  next-cycle=$NEXT_DATE"
  log "  retention: keep $RETENTION_CYCLES vuln-scan cycles + all pentest-prep"
  log "  metrics: $METRICS_FILE"
  exit 0
fi

mkdir -p "$EVIDENCE_DIR"
log "evidence bundle: $EVIDENCE_DIR (cycle=$CYCLE)"

# ---------------------------------------------------------------------------
# Tool presence — layers/tools whose binary is absent are skipped + recorded.
# ---------------------------------------------------------------------------
declare -A LAYER_TOOL=(
  [sast]="semgrep" [sca]="bun" [secrets]="gitleaks" [iac]="checkov" [compliance]="conftest"
)
TOOLS_RUN=()
TOOLS_SKIPPED=()
declare -A LAYER_STATUS=()

run_layer() {
  local layer="$1"
  local tool="${LAYER_TOOL[$layer]:-}"
  if [ -n "$tool" ] && ! command -v "$tool" >/dev/null 2>&1; then
    log "SKIP layer '$layer' — required tool '$tool' not installed"
    TOOLS_SKIPPED+=("$layer:$tool")
    LAYER_STATUS[$layer]="skipped"
    return 0
  fi
  log "running layer '$layer'..."
  set +e
  "$RUN_ALL" "$layer" "$EVIDENCE_DIR" > "$EVIDENCE_DIR/${layer}.log" 2>&1
  local rc=$?
  set -e
  # rc 0 = clean; rc 1 = findings present (evidence still captured); >1 = tool error.
  LAYER_STATUS[$layer]="exit:${rc}"
  TOOLS_RUN+=("$layer")
  log "layer '$layer' done (exit ${rc}; evidence + ${layer}.log captured)"
}

IFS=',' read -r -a LAYER_ARR <<< "$LAYERS"
for layer in "${LAYER_ARR[@]}"; do
  run_layer "$layer"
done

# Dependency-vulnerability scan. Prefer the CI-canonical scanners (grype, then osv-scanner);
# fall back to trivy. Scoped to actionable dep CVEs (HIGH/CRITICAL), skipping build/vcs noise —
# secrets/IaC/SAST are already covered by the curated layers above, so this is vuln-only.
if command -v grype >/dev/null 2>&1; then
  log "running grype dependency scan..."
  set +e
  grype "dir:$ROOT_DIR" --only-fixed -o "sarif=$EVIDENCE_DIR/grype.sarif" > "$EVIDENCE_DIR/grype.log" 2>&1
  rc=$?; set -e
  LAYER_STATUS[grype]="exit:${rc}"; TOOLS_RUN+=("grype"); log "grype done (exit ${rc})"
elif command -v osv-scanner >/dev/null 2>&1; then
  log "running osv-scanner dependency scan..."
  set +e
  osv-scanner --recursive --format sarif --output "$EVIDENCE_DIR/osv.sarif" "$ROOT_DIR" > "$EVIDENCE_DIR/osv.log" 2>&1
  rc=$?; set -e
  LAYER_STATUS[osv]="exit:${rc}"; TOOLS_RUN+=("osv"); log "osv-scanner done (exit ${rc})"
elif command -v trivy >/dev/null 2>&1; then
  log "running trivy dependency scan (vuln, HIGH/CRITICAL, build/vcs dirs skipped)..."
  set +e
  trivy fs --quiet --scanners vuln --severity HIGH,CRITICAL \
    --skip-dirs '**/build' --skip-dirs '**/node_modules' --skip-dirs '**/dist' --skip-dirs '**/.git' \
    --format sarif --output "$EVIDENCE_DIR/trivy-deps.sarif" "$ROOT_DIR" > "$EVIDENCE_DIR/trivy.log" 2>&1
  rc=$?; set -e
  LAYER_STATUS[trivy]="exit:${rc}"; TOOLS_RUN+=("trivy"); log "trivy done (exit ${rc})"
else
  log "SKIP dependency-vulnerability scan — none of grype/osv-scanner/trivy installed"
  TOOLS_SKIPPED+=("dep-vuln:grype|osv-scanner|trivy")
fi

# ---------------------------------------------------------------------------
# Manifest + HIPAA-mapped compliance report + checksums (python: SARIF-aware).
# ---------------------------------------------------------------------------
STATUS_KV=""
for k in "${!LAYER_STATUS[@]}"; do STATUS_KV+="${k}=${LAYER_STATUS[$k]};"; done

python3 - "$EVIDENCE_DIR" "$CYCLE_DATE" "$CYCLE" "$NEXT_DATE" \
  "$(IFS=,; echo "${TOOLS_RUN[*]:-}")" "$(IFS=,; echo "${TOOLS_SKIPPED[*]:-}")" "$STATUS_KV" <<'PY'
import json, sys, os, glob, hashlib, datetime

evidence_dir, cycle_date, cycle, next_date, tools_run, tools_skipped, status_kv = sys.argv[1:8]
tools_run = [t for t in tools_run.split(',') if t]
tools_skipped = [t for t in tools_skipped.split(',') if t]
statuses = dict(p.split('=', 1) for p in status_kv.split(';') if '=' in p)

def sarif_count(path):
    try:
        with open(path, encoding='utf-8') as f:
            doc = json.load(f)
        return sum(len(r.get('results', [])) for r in doc.get('runs', []))
    except Exception:
        return None

artifacts, checksums, findings = [], {}, {}
total_findings = 0
for path in sorted(glob.glob(os.path.join(evidence_dir, '*'))):
    name = os.path.basename(path)
    if name in ('manifest.json',) or name.endswith('.log'):
        continue
    if os.path.isfile(path):
        artifacts.append(name)
        with open(path, 'rb') as f:
            checksums[name] = 'sha256:' + hashlib.sha256(f.read()).hexdigest()
        if name.endswith('.sarif'):
            c = sarif_count(path)
            if c is not None:
                findings[name] = c
                total_findings += c

manifest = {
    'cycle_date': cycle_date,
    'cycle_type': cycle,
    'generated_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'next_cycle_date': next_date,
    'control_refs': [
        'HIPAA §164.308(a)(8) — Evaluation (periodic technical security evaluation)',
        'HIPAA §164.308(a)(1)(ii)(A) — Risk analysis',
        '2025 NPRM — vulnerability scan at least every 6 months',
    ],
    'tools_run': tools_run,
    'tools_skipped': tools_skipped,
    'layer_status': statuses,
    'artifacts': artifacts,
    'findings_by_artifact': findings,
    'findings_total': total_findings,
    'checksums': checksums,
    'retention': 'vuln-scan: last N cycles (default 2 years); pentest-prep: indefinite',
}
with open(os.path.join(evidence_dir, 'manifest.json'), 'w', encoding='utf-8') as f:
    json.dump(manifest, f, indent=2)

# HIPAA-mapped compliance report (audit artifact, mirrors the W3/W4 doc style).
lines = []
lines.append(f"# Compliance Scan Evidence — {cycle_date} ({cycle})\n")
lines.append(f"**Cycle:** {cycle}  ")
lines.append(f"**Generated:** {manifest['generated_at']}  ")
lines.append(f"**Next 6-month cycle:** {next_date}  ")
lines.append("**Control:** HIPAA §164.308(a)(8) Evaluation; §164.308(a)(1)(ii)(A) Risk analysis; "
             "2025 NPRM 6-month vulnerability-scan requirement.\n")
lines.append("This bundle is generated by `scripts/compliance-scan.sh`. Each scanner's raw SARIF/JSON "
             "and stdout log sit beside this report; `manifest.json` carries sha256 checksums for "
             "tamper-evidence.\n")
lines.append("## Scanners run\n")
lines.append("| Layer / scanner | Status |")
lines.append("|---|---|")
for k in sorted(statuses.keys()):
    lines.append(f"| {k} | {statuses[k]} |")
lines.append(f"\n**Total SARIF results across the bundle: {total_findings}** "
             "(per-artifact counts in the Artifacts section below). "
             "`exit:0` = clean; `exit:1` = findings present (review the artifact); "
             "`exit:>1` = scanner error; `skipped` = tool not installed on the runner.\n")
if tools_skipped:
    lines.append("## Skipped (tool not installed — gap, not a pass)\n")
    for t in tools_skipped:
        lines.append(f"- `{t}`")
    lines.append("")
lines.append("## Artifacts\n")
for a in artifacts:
    fc = findings.get(a)
    suffix = f" — {fc} results" if fc is not None else ""
    lines.append(f"- `{a}`{suffix}")
lines.append("\n## HIPAA control mapping\n")
lines.append("| Control | Covered by | Evidence |")
lines.append("|---|---|---|")
lines.append("| §164.312(a)(1) access control / injection (CWE) | semgrep (sast) | `semgrep.sarif` |")
lines.append("| §164.308(a)(1)(ii)(A) dependency vulns | bun audit (sca), grype/osv/trivy | `bun-audit.json`, `grype.sarif`/`osv.sarif`/`trivy-deps.sarif` |")
lines.append("| §164.308(a)(3) secret exposure | gitleaks (secrets) | `gitleaks.sarif` |")
lines.append("| §164.312(e)(1)/(a)(2)(iv) IaC posture (sslmode, no-new-priv) | checkov + conftest (iac/compliance) | `*checkov*`, `compliance.json` |")
lines.append("| §164.308(a)(8) periodic evaluation | this dated, retained, checksummed bundle | `manifest.json` |")
lines.append("\n## Annual penetration test\n")
lines.append("Automated scanning does not satisfy the **annual penetration test** requirement. Track "
             "the engagement and findings in `docs/security/pentest-register.md`; the `pentest-prep` "
             "cycle of this script captures a point-in-time evidence snapshot to hand the testers.\n")
with open(os.path.join(evidence_dir, 'compliance-report.md'), 'w', encoding='utf-8') as f:
    f.write('\n'.join(lines) + '\n')

print(f"manifest + report written: {total_findings} total SARIF results, "
      f"{len(tools_run)} scanners run, {len(tools_skipped)} skipped")
PY

# ---------------------------------------------------------------------------
# Prometheus textfile metrics (same pattern as backup-verify-metrics.prom).
# ---------------------------------------------------------------------------
write_metrics() {
  local total layers_run layers_skipped ts
  total="$(python3 -c "import json;print(json.load(open('$EVIDENCE_DIR/manifest.json'))['findings_total'])" 2>/dev/null || echo 0)"
  layers_run="${#TOOLS_RUN[@]}"
  layers_skipped="${#TOOLS_SKIPPED[@]}"
  ts="$(date +%s)"
  local tmp="${METRICS_FILE}.tmp"
  mkdir -p "$(dirname "$METRICS_FILE")" 2>/dev/null || true
  {
    echo "# HELP chronicle_compliance_scan_timestamp_seconds Unix time of the last compliance scan cycle."
    echo "# TYPE chronicle_compliance_scan_timestamp_seconds gauge"
    echo "chronicle_compliance_scan_timestamp_seconds{cycle=\"$CYCLE\"} $ts"
    echo "# HELP chronicle_compliance_scan_findings_total SARIF results across the latest bundle."
    echo "# TYPE chronicle_compliance_scan_findings_total gauge"
    echo "chronicle_compliance_scan_findings_total{cycle=\"$CYCLE\"} $total"
    echo "# HELP chronicle_compliance_scan_scanners_run Scanners executed in the latest cycle."
    echo "# TYPE chronicle_compliance_scan_scanners_run gauge"
    echo "chronicle_compliance_scan_scanners_run{cycle=\"$CYCLE\"} $layers_run"
    echo "# HELP chronicle_compliance_scan_scanners_skipped Scanners skipped (tool absent) in the latest cycle."
    echo "# TYPE chronicle_compliance_scan_scanners_skipped gauge"
    echo "chronicle_compliance_scan_scanners_skipped{cycle=\"$CYCLE\"} $layers_skipped"
  } > "$tmp" && mv "$tmp" "$METRICS_FILE" 2>/dev/null || log "WARN: could not write metrics to $METRICS_FILE"
}
write_metrics || true

# ---------------------------------------------------------------------------
# Retention: keep the last N vuln-scan cycles; never prune pentest-prep.
# ---------------------------------------------------------------------------
if [ "$PRUNE" -eq 1 ]; then
  log "pruning old vuln-scan cycles (keeping $RETENTION_CYCLES)..."
  mapfile -t old < <(ls -1d "${EVIDENCE_ROOT}"/*_vuln-scan 2>/dev/null | sort | head -n "-${RETENTION_CYCLES}" 2>/dev/null || true)
  for d in "${old[@]:-}"; do
    [ -n "$d" ] && [ -d "$d" ] || continue
    log "pruning $d"
    rm -rf "$d"
  done
fi

log "compliance scan cycle complete: $EVIDENCE_DIR"
log "  report:   $EVIDENCE_DIR/compliance-report.md"
log "  manifest: $EVIDENCE_DIR/manifest.json"
