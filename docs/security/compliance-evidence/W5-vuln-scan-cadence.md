# W5 — Vulnerability-Scan Cadence & Compliance Evidence (HIPAA §164.308(a)(8))

**Workstream:** HIPAA-2028 Compliance Lane — W5 (continuous vuln-scan + pentest cadence + evidence)
**Controls:** HIPAA §164.308(a)(8) *Evaluation* (periodic technical security evaluation),
§164.308(a)(1)(ii)(A) *Risk analysis*; 2025 NPRM — vulnerability scan **at least every 6 months**
+ penetration test **at least annually**.
**Status:** Implemented. Scanning runs on the self-hosted host (GitHub-hosted Actions are
unreliable on these repos); each cycle emits a dated, retained, checksummed evidence bundle.
See the lane design: `docs/superpowers/specs/2026-06-13-hipaa-2028-compliance-lane-design.md` (§91–99).

---

## 1. Control mapping

The 2025 NPRM makes periodic vulnerability scanning and annual penetration testing **required**.
The scanners already existed (semgrep, gitleaks, checkov, conftest, ast-grep, bun audit, plus
grype/osv/trivy and the OWASP/CodeQL CI jobs); the W5 gap was a **cadence** that runs them on a
schedule and packages the output as durable, audit-ready evidence. The operating principle of
this lane — *the tests are the compliance evidence* — is realized here as a dated bundle per cycle.

| Requirement | Mechanism | Evidence |
|---|---|---|
| §164.308(a)(8) periodic evaluation; NPRM 6-month vuln scan | `scripts/compliance-scan.sh` runs the curated scanner layers + a dependency-CVE scan into a dated bundle, on a 6-month cron | the dated `compliance-evidence/<date>_vuln-scan/` bundle |
| §164.308(a)(1)(ii)(A) risk analysis | findings aggregated into `manifest.json` + a HIPAA-mapped `compliance-report.md` per cycle | `manifest.json`, `compliance-report.md` |
| NPRM annual penetration test | tracked in `docs/security/pentest-register.md`; the `pentest-prep` cycle snapshots evidence for the testers | the register + `<date>_pentest-prep/` bundle |

---

## 2. What the orchestrator runs

`scripts/compliance-scan.sh` wraps the existing `tests/security/run-all-security.sh` layers
(it does **not** reinvent scanning) and adds the cadence/packaging:

- **Curated layers** (default `sast,sca,secrets,iac,compliance`): semgrep CWE + RLS guardrails;
  bun audit; gitleaks; checkov; conftest/OPA (incl. the W4 sslmode guard).
- **Dependency-CVE scan**: prefers `grype`, then `osv-scanner`, then `trivy fs` (vuln-only,
  HIGH/CRITICAL, build/vcs dirs skipped) — whichever is installed on the runner.
- **Tool-aware**: a layer whose tool is absent is **skipped and recorded** in the manifest
  (`tools_skipped`) and the report — a gap is never silently counted as a pass.
- Per-layer stdout is captured (`<layer>.log`); a layer exiting `1` (findings present) does **not**
  abort the cycle — the whole point is to capture the evidence.

---

## 3. Evidence bundle (per cycle)

Written to `${COMPLIANCE_EVIDENCE_ROOT:-/var/lib/chronicle/compliance-evidence}/<date>_<cycle>/`:

| Artifact | Purpose |
|---|---|
| `*.sarif`, `bun-audit.json`, `compliance.json` | raw scanner output (SARIF where supported) |
| `<layer>.log` | per-scanner stdout/stderr |
| `manifest.json` | cycle metadata, `tools_run`/`tools_skipped`, per-layer status, **sha256 checksums** of every artifact (tamper-evidence), findings totals, next-cycle date, control refs |
| `compliance-report.md` | HIPAA-mapped report: scanners + status, artifacts + per-artifact finding counts, control mapping, pentest pointer |

A Prometheus textfile metric is also written (`chronicle_compliance_scan_*` — timestamp,
findings total, scanners run/skipped) via the node_exporter textfile collector, the same pattern
as `backup-chronicle.sh` → `backup-verify-metrics.prom`.

---

## 4. Scheduling (self-hosted)

GitHub-hosted Actions are unreliable on these repos, so the cadence runs from cron on the
self-hosted host (the same way `docker/backup-chronicle.sh` does — in-file cron header):

```cron
# 6-month vulnerability scan (Jan + Jul), with retention pruning
30 2 1 1,7 *  /opt/chronicle/scripts/compliance-scan.sh --prune >> /var/log/chronicle-compliance.log 2>&1
# annual pentest-prep evidence snapshot (Jan), preceding the external engagement
30 3 1 1 *    /opt/chronicle/scripts/compliance-scan.sh --cycle pentest-prep >> /var/log/chronicle-compliance.log 2>&1
```

(systemd-timer equivalent: `OnCalendar=*-01,07-01 02:30`.)

**Retention:** `--prune` keeps the last `--retention-cycles` vuln-scan bundles (default 4 = 2 years
at a 6-month cadence) and **never** prunes `pentest-prep` bundles (audit material).

---

## 5. Annual penetration test

Automated scanning does **not** satisfy the annual penetration-test requirement. The engagement,
scope, firm, report location, and remediation status are tracked in
`docs/security/pentest-register.md`. The `--cycle pentest-prep` run captures a point-in-time
evidence snapshot to hand the testers and to file alongside their report.

---

## 6. Verification

`scripts/compliance-scan.sh` was exercised locally (`--dry-run`, then a real
`--layers compliance,secrets` run with the scoped dependency scan): it produced a dated bundle
with `gitleaks.sarif` (0), the conftest `compliance.json`, a scoped `trivy-deps.sarif`
(HIGH/CRITICAL dependency CVEs), a checksummed `manifest.json`, a rendered `compliance-report.md`,
and the Prometheus metric file — confirming the packaging, manifest, report, metrics, and prune
path. Per project memory, verification is done with local runs, not GitHub Actions.

---

## 7. Source pointers

- **Cadence orchestrator:** `scripts/compliance-scan.sh` (in-file cron header, `--cycle`,
  `--layers`, `--evidence-root`, `--retention-cycles`, `--dry-run`, `--prune`).
- **Scanner layers (reused):** `tests/security/run-all-security.sh`,
  `tests/security/rules/`, `tests/security/policies/docker_compose.rego`,
  `tests/security/gitleaks.toml`, `tests/security/ast-grep/`.
- **Pentest register:** `docs/security/pentest-register.md`.
- **Cadence convention mirrored:** `docker/backup-chronicle.sh` (dated dirs, manifest, metrics, retention).
