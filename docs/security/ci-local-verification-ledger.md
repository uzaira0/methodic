# CI Local Verification Ledger

This document records the state of driving the entire Chronicle CI surface to
clean & green **locally** (no GitHub Actions billing required), per the plan in
`~/.claude/plans/gleaming-herding-cupcake.md`. Everything was run on this host
with real tools / containers / `act` / testcontainers — not simulated.

Status legend: ✅ GREEN-with-evidence · 🟡 suppressed/documented-with-justification ·
⛔ Tier-F structurally-unprovable-locally (NOT broken — provable only by a real
CI run or device/infra not present here).

---

## Tier F — Structurally unprovable on this host (the honest exclusions)

These are **not failures and not skips of fixable work**. They cannot be made
"green" on a single developer host by any means; the only proof is the real
control plane / device / external infra.

### Control-plane semantics (provable only by one real CI run)
- **GitHub enforcing `permissions:` blocks** — the runner-side privilege drop is
  enforced by GitHub's Actions control plane, not by anything runnable locally.
- **harden-runner egress *block* mode** — `step-security/harden-runner` only
  actually blocks egress on GitHub-hosted runners; locally it is inert.
- **Dependabot cooldown / grouping**, **OIDC `id-token` issuance**, **SARIF upload
  to code-scanning**, **required-status-check gating**, **workflow trigger routing
  (`on:` filters)** — all are GitHub-side. `actionlint`+`zizmor` validate the YAML
  is correct (done, green); the *enforcement* is control-plane only.
- Root cause that these never ran: the private-repo **spending-limit billing wall**
  (3-second die), not broken infra. Raising the limit (or going public) makes them
  run; that is a user action.

### Device-only / destructive
- **Android instrumented tests** (`connected*`/`androidTest`) — require a physical
  device and are **destructive** (wipe enrollment). Excluded by the standing safety
  rule; unit tests + lint + `-Werror` compile are green locally.

### Scheduled external monitors
- **canary-synthetic**, **cert-transparency**, **dns-monitor**,
  **backup-restore-test** — depend on production DNS, CT logs, and live backup
  infrastructure. Not reproducible on this host.

### Tier E live-stack DAST / load / fuzz (deliberately NOT run against prod)
The only backend on this host is the **live production container with real enrolled
study devices** (HIPAA). The following are intentionally **not** executed because
doing so would attack / pollute / load a live PHI system, and standing up an
isolated parallel stack collides with the prod stack's ports (see the stale
dev-compose note):
- **Schemathesis** API-contract fuzzing — would write generated garbage to the
  prod DB and load the API.
- **OWASP ZAP** active DAST — would direct attack traffic at the live system.
- **k6** performance/load — would impose DoS-shaped load on the live system.
- **security-suite aggressive live layers** (rate-limit hammering, WAF payload
  injection) — same reason.

These require a throwaway isolated stack to run safely; that is the correct place
for them, not this prod host. The **read-only** live signal that *is* safe was
checked: the edge returns `X-Content-Type-Options: nosniff` and enforces the
F5-forwarded-https routing (plain-HTTP paths 404 by design).

---

## Tier D — CodeQL (run locally; DBs built + security-and-quality suite)

CodeQL CLI 2.25.6, suite `security-and-quality`. The top-severity injection rules
(unsafe-deserialization, command-injection, SSRF, XXE, *-injection — all CVSS 9.x)
returned **zero** results on both languages.

**javascript-typescript** (152 app TS/TSX extracted): 6 → after triage/fix:
- 1 real, FIXED + re-scan-verified: `js/react/unused-or-undefined-state-property`
  (dead `error` state in `error-boundary.tsx`; removed — not surfaced because raw
  error detail could leak PHI; error still captured via telemetry).
- 5 FP-documented: 3 `js/syntax-error` (vendored Flow stubs `flow-typed/*.js` +
  generated `reports/mutation.html` — path-ignored), 2 `js/http-to-file-access`
  (dev-only `scripts/react19-readiness.mjs` writing a report from LOCAL package
  metadata, not network/attacker data; not shipped).

**java-kotlin** (683 .kt + 146 .java — Kotlin extraction required forcing
in-process kotlinc so the CodeQL tracer could inject its extractor; the Kotlin
*daemon* is invisible to the tracer): 261 results. The security/correctness subset,
triaged + re-scan-verified:
- `java/dereferenced-value-is-always-null` — REAL, FIXED (1→0):
  `MoveToIosEventStorageTask.kt` guaranteed-NPE on a closure-mutated `var`.
- `java/unreleased-lock` — REAL, FIXED: `Rhizome.java` startup lock — `unlock()`
  moved into an innermost `finally` so it is reachable even if the banner/exit
  logic throws.
- `java/log-injection` (CWE-117) — 97→90: the 7 genuinely request-tainted /
  pre-auth edge sites (ApiKeyAuthenticationFilter, AuthTokenController OIDC
  callback, RateLimitFilter) sanitized via `LogSanitizer`. The ~90 residual are
  authenticated/ACL+RLS-gated UUID/enum/server-derived values; PII is already
  masked by the always-on `SensitiveDataRewritePolicy`. See
  `codeql-log-injection-triage.md`.
- `java/sql-injection` (1, ImportController) — FP: identifier flows through
  `SqlIdentifierValidator.validateImportTableName` allowlist; admin-gated.
- `java/spring-disabled-csrf-protection` (2) — intentional: both chains are
  `SessionCreationPolicy.STATELESS` + Bearer/OAuth2; the cookie-JWT path uses
  SameSite=Strict + a double-submit CSRF cookie.
- `java/sensitive-log` (3) — FP: log secret *names*/metadata/prefix, never the
  secret material.
- `java/insecure-cookie` (1) — FP: Secure is set on the next line via
  `useSecureCookie(request)` which honors the F5 `X-Forwarded-Proto: https`.
- `java/reference-equality-on-strings` (1) — intentional identity check in the
  log-mask policy (returns same ref iff nothing matched).
- Remainder are quality notes (missing-override, deprecated-call, whitespace,
  unused-param) — GitHub code-scanning surfaces these as notes, not gate failures.

**rhizome SpotBugs** — the `ignoreFailures=true` mask was hiding **9 real
high-confidence findings** (the earlier "0 bugs" read was an HTML-report parsing
artifact; the XML report had 9 `<BugInstance>`). All 9 fixed: 7 real bugs —
including job **progress never restored on node-failure resume**
(`AbstractDistributedJob`) and a **completely broken LocalTime serializer**
returning null/empty (`Jdk8StreamSerializers`) — and 2 justified FP suppressions.

**Playwright e2e — two genuine blockers, both honestly NOT green-from-clean:**

1. **WebKit (`desktop-webkit`, `tablet`=iPad Mini) is structurally unsupported on
   this host.** Not a missing package — Playwright's prebuilt WebKit links Ubuntu
   24.04 SONAMEs (`libicuuc.so.74`, `libjpeg.so.8`); this host is RHEL 9.8 with
   ICU 67 (`libicuuc.so.67`) and `libjpeg.so.62`. Different ABIs, not shimmable;
   `dnf` cannot provide ICU 74 / libjpeg 8. (`flite`/`libavif`/`libmanette`/
   `gstreamer1-plugin-libav` WERE installable and installed.) WebKit runs on the
   Ubuntu CI runner or in the official `mcr.microsoft.com/playwright` container.

2. **The suite is NOT self-contained — its apparent "209 passing" was a FALSE
   GREEN** (a masked-green in the exact spirit of this audit). It only passed by
   *reusing a stray `dev:local` server on :4173* that had (a) testing-login
   enabled and (b) prod-DB-proxied real data, plus (c) **90 visual-regression
   baselines that are NOT committed to git** (`git ls-files e2e/__screenshots__` =
   0). Proven by running from clean under `CI=1` (no reuse):
   - configured `bun run serve` = preview mode → **testing-login disabled (HTTP
     403)** → auth-dependent tests fail;
   - even with auth mocked, functional route tests (`modern-shell`) fail without
     real data, and visual-regression fails (uncommitted, data-coupled baselines).
   A flag-gated fixtures fix was prototyped (fixed auth) but **reverted** because
   it still could not reach green (data + baselines), and faking baselines would
   degrade coverage. Making e2e reproducible is a real harness decision the team
   should own: commit baselines (generated against a defined data fixture), serve
   a deterministic data fixture, and enable testing-login behind an e2e-only flag.

## Masked-gate audit (sweep for other "silent-pass" gates like the rhizome SpotBugs mask)

After finding rhizome SpotBugs was masking 9 real findings, swept every repo for the
same class of problem: gates that pass silently while hiding findings (ignoreFailures,
abortOnError, soft-fails, HTML-only reports, baselines, mass-suppression). Two more
real masked gates found and fixed; the rest came back clean.

**FOUND + FIXED:**
- **chronicle-server SpotBugs** — enforcing (`ignoreFailures` default false) but, like
  rhizome, **never actually run** (billing wall), so it was silently RED with **10
  hidden high-confidence findings**. Now: XML report enabled (was HTML-only — the same
  fragility behind the original mis-read), findings resolved = **1 real fix**
  (`RefreshTokenService.rotateRefreshToken` silently swallowed a rollback failure →
  now logged + original exception rethrown) + 9 documented suppressions: 6
  `IL_INFINITE_RECURSIVE_LOOP` FPs (findbugs misreads Kotlin companion-`getKey()`),
  CSRF-disabled (intentional stateless API), `SecureRandom` one-shot at init
  (correct), and a security-reviewed RLS `ST_WRITE_TO_STATIC` (confirmed SAFE —
  `RLSDataSources` is a Kotlin `object` whose `appRole` is set-once `@Volatile`
  startup config; per-request state is a properly-cleared `ThreadLocal` — no
  cross-request leak). `spotbugsMain` now BUILD SUCCESSFUL, 0 BugInstance.
  **chronicle-api + rhizome-client SpotBugs verified 0 findings.**
- **Android `collection-*` Lint** — all 12 collection modules had `abortOnError false`
  (lint errors silently ignored) while only `app` enforced; `app` has no
  `checkDependencies`, so the libraries were genuinely ungated. Flipped all 12 to
  `abortOnError true` and verified `./gradlew lintDebug` BUILD SUCCESSFUL (0
  error-severity findings; warnings only, which abortOnError does not gate).

**SWEPT + CLEAN (no mask):**
- detekt — `maxIssues: 0`, `excludeCorrectable: false`, **no baseline file** (honestly strict).
- CI soft-fails — only `soft_fail: false` (checkov, explicitly enforced); no `continue-on-error`/`allow_failure` on real gates.
- Script `|| true` / `set +e` — all in adb/dogfood/debug-bundle device-telemetry scripts (benign), not CI gates.
- `test { ignoreFailures }` — false in chronicle-api, rhizome-client, chronicle-server, rhizome (enforced).
- Suppressions — 375 `@Suppress` (mostly Kotlin idiom), 10 `@SuppressFBWarnings`, 7 `nosemgrep`, 9 biome-ignore, 4 `@SuppressLint` — modest and documented; **0 `@Disabled`/`@Ignore` tests** (no masked tests).

## Notes on metric integrity (why some gates are documented, not maximized)

- **Mutation (pitest)** is set to the honest verified-achieved floor (73 on the
  pure-logic security scope; measured 76%), NOT an arbitrary 95–99%. The residual
  survivors are equivalent/logging mutants no behavioral test can kill; chasing a
  higher number would mean gaming the metric. See the long comment in
  `chronicle-server/build.gradle`.
- **JaCoCo line-coverage gate**: deliberately **absent**. The runnable-here unit
  exec is ~24% because most of the backend is Testcontainers-integration-tested
  (not aggregated into this exec); any floor it passes would be a misleading
  sandbag. Mutation testing strictly dominates line coverage and is the real
  test-quality gate. See the comment in `chronicle-server/build.gradle`.
- **rhizome SpotBugs**: cannot use `ignoreFailures=false` (the module references
  optional websocket classes absent from the analysis classpath → exit-3
  `MISSING_CLASS`, not `BUGS_FOUND`). Enforced instead via an XML-report
  `<BugInstance>` count gate that fails on real findings while tolerating the
  missing-class artifact. See `rhizome/build.gradle`.

## Tier A + Tier B — driven green (final verification pass, 2026-06-25)

Re-ran every Tier A gating RED and every Tier B `analysis.yml` scanner from clean,
mirroring the exact CI invocation. All green; the three findings the pass surfaced
were fixed in the working tree (uncommitted).

**GREEN-with-evidence:**
- `:rhizome:test` — BUILD SUCCESSFUL (the `hazelcast.password` fixture holds; no JVM crash).
- `:chronicle-server:checkLicense` — BUILD SUCCESSFUL (the `kotlin-stdlib-common:2.3.21`
  `.pom` hash gap in `verification-metadata.xml` is resolved).
- Frontend (`chronicle-web`): `bun test src/modern/components` 188/188; `bun run dead-code`
  (knip) exit 0; `bun run size` — CSS 147.86/160 kB; `bun audit` + `npm audit --omit=dev`
  0 prod vulns; `typecheck` exit 0.
- `pmd` 0 findings; `bearer` 0 (skip-path scoped); `syft` SBOM 2121 pkgs; `conftest` 11/11;
  `checkov` 536/0 (CKV_DOCKER_2/3 pass on both keycloak Dockerfiles); `semgrep` RLS
  guardrails 0 (the 3 F5-forwarded-https `tls=true` lines `nosemgrep`-annotated).

**THREE FINDINGS FIXED (the pass was not a no-op):**
1. **detekt `LongMethod`** — `DeviceSettingsUploadService.upload` was 68 lines (>60) after the
   Pixel-QA audio/brightness binds. Extracted the per-column binding into `bindDeviceSettings()`
   + four `PreparedStatement.setXOrNull(index, value?)` extensions → `upload` is small, zero added
   branches, no `@Suppress` needed. `compileKotlin` SUCCESSFUL; detekt **0 weighted issues**.
2. **semgrep `chronicle-log-injection` FP** — `SecurityHardeningConfig.kt:174` logs `sanitizedUri`
   (already sanitized via `LogSanitizer.sanitizeUri`); the rule's `metavariable-regex` matched the
   var NAME "uri", not unsanitized input. Annotated `// nosemgrep: chronicle-log-injection` +
   rationale. log-injection findings now **0**.
3. **osv-scanner + grype `jackson-databind` CVEs** — runtime was 2.21.3 (7 advisories; OSV: 2.21.4
   clears 6, the 7th `GHSA-5jmj-h7xm-6q6v` needs 2.21.5 which was **never published to Maven
   Central**). Bumped the forced runtime jackson trio (core/databind **2.22.0**, annotations **2.22**)
   + `ext.jackson_version` 2.22.0 in `gradles/chronicle.gradle`, `chronicle-models`, `chronicle-api`.
   OSV query: 2.22.0 = **0 vulns**. Regenerated all 5 `gradle.lockfile`s + `verification-metadata.xml`
   (additive, header intact); recompiled; `chronicle-models:test` 196/196 (real jackson round-trips).
   Residuals — the dokka doc-gen classpath `jackson-databind:2.12.7.1` (chronicle-server/ +
   chronicle-api/ lockfiles) and the append-only `verification-metadata.xml` catalog entries
   (2.9.x–2.21.x) — documented-suppressed mirroring the existing woodstox-dokka precedent:
   per-module `osv-scanner.toml` (dokka, 5 GHSAs each) + `gradle/osv-scanner.toml` (stale catalog,
   8 GHSAs) + `.grype.yaml` (version-scoped to 2.12.7.1). `osv-scanner --recursive .` exit 0
   (357 filtered, "No issues found"); `grype --fail-on medium` exit 0. The Android app +
   `collection-base` jackson (2.21.1) is a separate build with no scanned lockfile — out of scope,
   left at 2.21.1.
</content>
</invoke>
