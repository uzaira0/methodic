# W5 — Vulnerability-Scan Cadence & Compliance Evidence (HIPAA §164.308(a)(8))

**Workstream:** HIPAA-2028 Compliance Lane — W5 (continuous vuln-scan + pentest cadence + evidence)
**Controls:** HIPAA §164.308(a)(8) *Evaluation* (periodic technical security evaluation),
§164.308(a)(1)(ii)(A) *Risk analysis*; 2025 NPRM — vulnerability scan **at least every 6 months**
+ penetration test **at least annually**.
**Status:** Implemented. The cadence runs as a **scheduled GitHub Actions workflow**
(`.github/workflows/compliance-vuln-cadence.yml`) now that these repos are public and Actions
run; `scripts/compliance-scan.sh` remains the equivalent offline/self-hosted runner. Each cycle
emits a dated, retained, checksummed, HIPAA-mapped evidence bundle and imports per-scanner SARIF
into the GitHub Security tab.
See the lane design: `docs/superpowers/specs/2026-06-13-hipaa-2028-compliance-lane-design.md` (§91–99).

> **Note on the design caveat.** The lane design (§97) said GitHub-hosted Actions were
> infra-broken and the cadence had to run self-hosted. That is now **stale**: as of 2026-06-25
> all repos are public and Actions execute, so the cadence is primarily a scheduled GH Actions
> workflow (SHA-pinned, harden-runner egress-audited, actionlint + zizmor-clean at medium+). The
> self-hosted `scripts/compliance-scan.sh` is retained as the offline/air-gapped equivalent.

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

## 4. Scheduling

### 4a. Scheduled GitHub Actions workflow (primary)

`.github/workflows/compliance-vuln-cadence.yml` runs the cadence on a 6-month cron and is the
primary, audit-visible mechanism now that the repos are public and Actions execute:

```yaml
on:
  schedule:
    - cron: '30 3 1 1,7 *'   # 1 Jan + 1 Jul, 03:30 UTC — exactly twice a year (NPRM floor)
  workflow_dispatch:          # manual run; `cycle` input selects vuln-scan | pentest-prep
```

Four scanner jobs run in parallel — **OWASP Dependency-Check** (Gradle CVEs, CVSS>=7),
**OSV-Scanner** (Google vuln DB), **Grype** (Anchore DB), **Semgrep** (the repo CWE + RLS
ruleset). Each:

- Hardens the runner with `step-security/harden-runner` (egress **audit**).
- Is **SHA-pinned** (every `uses:` carries a 40-char commit SHA + `# vN` comment), the repo standard.
- Uploads its **SARIF into the GitHub Security tab** (categories `depcheck-cadence`,
  `osv-cadence`, `grype-cadence`, `semgrep-cadence`).

A final `evidence-bundle` job (`needs: [all four]`, `if: always()`) downloads every scanner
artifact and assembles the **dated, HIPAA-mapped bundle**: `manifest.json` (cycle metadata, next-due
date, per-scanner result, control refs), `compliance-report.md`, per-artifact `SHA256SUMS`
(tamper-evidence), and a job-summary render. The bundle artifact is named
`hipaa-vuln-evidence-<date>-<cycle>` with **730-day (2-year) retention**.

The workflow passes `actionlint` and `zizmor --min-severity medium` (the enforcing gate) clean.

### 4b. Self-hosted / offline equivalent (retained)

`scripts/compliance-scan.sh` runs the same scanners from cron on the self-hosted host (the same
in-file cron-header convention as `docker/backup-chronicle.sh`) for air-gapped / offline cycles:

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

Automated scanning does **not** satisfy the annual penetration-test requirement (2025 NPRM:
penetration test **at least annually**). The full cadence, scope, and retention are documented in
the companion artifact **`docs/security/compliance-evidence/W5-vuln-pentest-cadence.md`** and the
durable record lives in **`docs/security/pentest-register.md`**. In brief:

- **Frequency:** at least once per calendar year (independent of the 6-month automated scans).
- **Prep:** `scripts/compliance-scan.sh --cycle pentest-prep` (or the workflow's
  `workflow_dispatch` with `cycle=pentest-prep`) captures a point-in-time evidence snapshot to hand
  the testers and to file alongside their report.
- **Scope (baseline):** mobile API (`/chronicle/v3`, `/chronicle/v4`), web API
  (`/chronicle/api/web`), authn/authz (OIDC + API-key + RLS study isolation), Traefik edge (WAF,
  rate limiting). Expanded per the year's risk analysis.
- **Retention:** `pentest-prep` evidence bundles are **never pruned** (audit material); the register
  rows are kept indefinitely.
- **On completion:** file the report, log findings + remediation status in the register, open
  tracking issues for anything not fixed during the engagement.

---

## 6. Verification

**Local script:** `scripts/compliance-scan.sh` was exercised locally (`--dry-run`, then a real
`--layers compliance,secrets` run with the scoped dependency scan): it produced a dated bundle
with `gitleaks.sarif` (0), the conftest `compliance.json`, a scoped `trivy-deps.sarif`
(HIGH/CRITICAL dependency CVEs), a checksummed `manifest.json`, a rendered `compliance-report.md`,
and the Prometheus metric file — confirming the packaging, manifest, report, metrics, and prune path.

**GitHub Actions workflow:** `.github/workflows/compliance-vuln-cadence.yml` was validated locally
the way the workflow runs:

| Check | Command | Result (2026-06-25) |
|---|---|---|
| Workflow lint | `actionlint .github/workflows/compliance-vuln-cadence.yml` (shellcheck on PATH) | exit 0 — clean |
| Workflow SAST | `zizmor --offline --min-severity medium --config .github/zizmor.yml …` (v1.26.1) | "No findings to report" — exit 0 |
| OSV-Scanner | `osv-scanner scan --recursive .` | **No issues found** (357 documented suppressions in `osv-scanner.toml`) — exit 0 |
| Grype | `grype dir:.` | **No vulnerabilities found** — exit 0 |
| Semgrep | `semgrep scan --config tests/security/rules/cwe-comprehensive.yaml .` | **0 findings** (36 rules) — exit 0 |

All three runtime scanners are clean-or-documented-suppressed; the SARIF the workflow emits will
import into the Security tab with zero net new findings.

---

## 7. Source pointers

- **Scheduled GH Actions cadence (primary):** `.github/workflows/compliance-vuln-cadence.yml`
  (6-month cron, SHA-pinned, harden-runner, SARIF→Security tab, dated 2-year-retention bundle).
- **Cadence orchestrator (offline/self-hosted):** `scripts/compliance-scan.sh` (in-file cron header,
  `--cycle`, `--layers`, `--evidence-root`, `--retention-cycles`, `--dry-run`, `--prune`).
- **Scanner layers (reused):** `tests/security/run-all-security.sh`,
  `tests/security/rules/`, `tests/security/policies/docker_compose.rego`,
  `tests/security/gitleaks.toml`, `tests/security/ast-grep/`.
- **Pentest register:** `docs/security/pentest-register.md`.
- **Cadence convention mirrored:** `docker/backup-chronicle.sh` (dated dirs, manifest, metrics, retention).
