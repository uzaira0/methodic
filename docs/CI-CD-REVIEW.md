# Chronicle CI/CD Pipeline Review

Reviewed: 2026-04-05

## Pipeline Inventory

### 1. Chronicle CI (`ci.yml`)

**Trigger**: Push to main/develop/master, all PRs, manual dispatch

**Jobs**:

| Job | What it does |
|-----|-------------|
| `chronicle-web` | Bun install, `bun run check` (lint/typecheck), Bun tests (modern + legacy compatibility), Jest legacy tests |
| `jvm-smoke` | JDK 17 setup, Gradle wrapper validation, `chronicle-api` tests, `chronicle-server` controller tests, JaCoCo coverage report |
| `mutation-testing` | Stryker mutation testing on chronicle-web (only on push to develop) |
| `repo-automation` | Docker Compose config validation, Bun workflow audit script, silent failure hunter script |

**Tests**: Yes -- web (Bun + Jest), API, controller, mutation
**Security scanning**: No (handled by dedicated workflows)

---

### 2. Chronicle Platform Build (`build.yaml`)

**Trigger**: All pushes

**What it does**:
- Builds the full Gradle project (skipping spotbugs and server tests)
- On develop/main: decrypts GPG signing key, publishes `chronicle-api`, `rhizome-client`, `rhizome` to GitHub Packages
- On PRs/feature branches: build-only validation (no publish)
- Uploads build artifacts (5-day retention)

**Tests**: Skipped (`-x :chronicle-server:test`); relies on `ci.yml` for test coverage

---

### 3. CodeQL Analysis (`codeql.yml`)

**Trigger**: Push to main, PRs to develop/main, weekly schedule (Monday 06:00 UTC)

**What it does**:
- **Java/Kotlin SAST**: Builds chronicle-server and chronicle-api classes, runs CodeQL with `security-and-quality` queries
- **JavaScript/TypeScript SAST**: Runs CodeQL on chronicle-web source (no build needed)
- Uploads SARIF results to GitHub Security tab

**Tests**: No (SAST only)
**Security scanning**: Yes -- interprocedural taint tracking, cross-function analysis

---

### 4. Security Vulnerability Scan (`security-scan.yml`)

**Trigger**: Push to develop/main, PRs to develop/main, weekly (Sunday 02:00 UTC), manual dispatch

**Jobs**:

| Job | Scanner | Target |
|-----|---------|--------|
| `gradle-security-scan` | OWASP Dependency-Check | JVM dependencies (CVE database) |
| `bun-security-scan` | `bun audit` | Frontend npm dependencies |
| `container-image-scan` | Grype | Backend + frontend Docker images |
| `security-summary` | (aggregation) | Generates summary and fails if any scan failed |

All results uploaded as SARIF to GitHub Security tab.

---

### 5. Security Suite (`security-suite.yml`)

**Trigger**: Push to develop, PRs to develop, manual dispatch

**What it does**: 25-layer security scanner running 10 layers in a parallel matrix:

| Layer | Tool(s) |
|-------|---------|
| sast | Semgrep |
| sca | Grype + bun audit |
| container | Grype image / Checkov misconfig |
| secrets | Gitleaks |
| iac | Checkov + Hadolint |
| auth | JWT structure analysis |
| injection | SQL injection pattern scan |
| crypto | Weak algorithm detection |
| license | OSV license compliance |
| compliance | OPA/Conftest policy-as-code |

15 additional layers (DAST, API fuzz, TLS, database, HIPAA, GDPR, etc.) are skipped in CI because they require a running stack.

---

### 6. Build and Deploy (`docker-build-deploy.yml`)

**Trigger**: Push to main/develop, manual dispatch

**What it does**:
- Runs on a **self-hosted runner**
- Checks for `.env` file existence
- Runs `docker compose -f docker-compose.prod.yml up -d --build --remove-orphans`
- Prunes old Docker images
- Shows container status

**This is the deployment workflow.** It deploys directly to production on push to main.

---

### 7. API Contract Testing (`api-contract.yml`)

**Trigger**: Push to develop, manual dispatch

**What it does**:
- Builds backend, starts Docker stack (backend + postgres)
- Runs Schemathesis against `chronicle.yaml` OpenAPI spec
- Tests all GET endpoints with 50 examples per endpoint
- Validates response schemas, status codes, content types

---

### 8. Performance Testing (`performance.yml`)

**Trigger**: Push to develop, manual dispatch

**Jobs**:

| Job | What it does |
|-----|-------------|
| `bundle-size` | Builds frontend, runs `size-limit` to check bundle size |
| `k6-load-test` | Starts Docker stack, runs k6 load test against study API |

---

### 9. Build Android APK (`build-android-apk.yml`)

**Trigger**: Manual dispatch only

**What it does**:
- Builds `chronicle-api` JAR from main repo
- Checks out Android repo (`uzaira0/chronicle`)
- Injects API JAR, patches server URL, patches signing config
- Builds debug or release APK
- Uploads APK artifact (30-day retention)

---

### 10. Maestro Android UI Tests (`maestro-android-test.yml`)

**Trigger**: PRs to main/develop, nightly schedule (03:00 UTC), manual dispatch

**What it does**:
- Builds Android APK and Chronicle backend
- Runs Maestro UI test flows on Android emulators
- **Tiered testing**: PRs test API levels 26, 33, 35; nightly tests full matrix (26-35)
- Starts backend directly (no Docker-in-Docker), seeds test data
- Captures failure screenshots and logcat on failure
- Publishes JUnit test reports

---

## Summary Matrix

| Workflow | Push main | Push develop | PR | Schedule | Manual | Tests | Security |
|----------|-----------|-------------|-----|----------|--------|-------|----------|
| ci.yml | Y | Y | Y | - | Y | Y | - |
| build.yaml | Y | Y | Y* | - | - | - | - |
| codeql.yml | Y | - | Y | Weekly | - | - | Y |
| security-scan.yml | Y | Y | Y | Weekly | Y | - | Y |
| security-suite.yml | - | Y | Y** | - | Y | - | Y |
| docker-build-deploy.yml | Y | Y | - | - | Y | - | - |
| api-contract.yml | - | Y | - | - | Y | Y | - |
| performance.yml | - | Y | - | - | Y | Y | - |
| build-android-apk.yml | - | - | - | - | Y | - | - |
| maestro-android-test.yml | - | - | Y | Nightly | Y | Y | - |

*PR validation build only (no publish)
**PRs to develop only

## Gaps

### 1. No Staging Environment

The deployment workflow (`docker-build-deploy.yml`) deploys directly to production on push to main or develop. There is no staging or pre-production environment for smoke testing before production deployment.

### 2. No Rollback Mechanism

The deploy workflow does `docker compose up --build`. There is no:
- Image tagging with git SHA or version
- Previous image preservation
- Automated rollback on health check failure
- Blue/green or canary deployment strategy

A failed deployment requires manual intervention.

### 3. No Deployment Gating

Deployment is not gated on CI/security checks passing. The `docker-build-deploy.yml` workflow triggers independently on push, not as a downstream job of `ci.yml` or `security-scan.yml`. A push to main that fails CI will still deploy.

### 4. No Integration Tests in CI

The `ci.yml` workflow runs unit tests and controller tests, but does not spin up the full stack to run integration tests. API contract tests (`api-contract.yml`) only run on push to develop, not on PRs.

### 5. No Database Migration Validation

No workflow validates that database migrations apply cleanly. A bad migration could break the production deployment.

### 6. No Smoke Tests Post-Deploy

After `docker compose up`, the deploy workflow shows `docker compose ps` but does not run health checks, API smoke tests, or verify the application is actually serving traffic correctly.

### 7. Limited PR Coverage

Several workflows only trigger on push to develop, not on PRs:
- API contract tests
- Performance tests (bundle size + k6)
- Security suite

This means PRs can be merged without these checks passing.

### 8. No Artifact Versioning for Deployment

Docker images are built locally on the self-hosted runner, not pushed to a registry with version tags. There is no audit trail of which image version is running in production.

### 9. No Secret Scanning on PRs

Gitleaks runs in the security suite but only on pushes to develop and PRs to develop. PRs to main are not covered by secret scanning from the security suite.

### 10. No DAST in CI

The 15 "running stack" security layers (DAST, API fuzzing, TLS validation, etc.) are documented as skipped in CI. These should run in a scheduled pipeline against a staging environment.

## Recommendations

### High Priority

1. **Gate deployment on CI success**: Make `docker-build-deploy.yml` a reusable workflow called after `ci.yml` and `security-scan.yml` pass, or use GitHub branch protection rules requiring status checks.

2. **Add rollback capability**: Tag Docker images with git SHA, push to a registry (GHCR), and add a rollback workflow that redeploys the previous known-good image.

3. **Add post-deploy smoke tests**: After `docker compose up`, hit `/admin/healthcheck`, verify Prometheus scrape, and confirm key API endpoints return expected responses.

4. **Run API contract tests on PRs**: Change `api-contract.yml` trigger to include `pull_request` events.

### Medium Priority

5. **Add a staging environment**: Deploy to staging on push to develop, production on push to main (after staging validation).

6. **Add database migration testing**: Run migrations against a fresh database in CI to catch schema errors before deployment.

7. **Push images to GHCR**: Build and push versioned images in CI, then deploy by pulling a specific tag rather than building on the deployment host.

8. **Add deployment notifications**: Post to Slack/email on deployment success/failure.

### Low Priority

9. **Add canary deployments**: Deploy new version alongside old, shift traffic gradually, auto-rollback on error rate increase.

10. **Schedule DAST scans**: Run the 15 skipped security layers against a staging environment on a weekly schedule.

11. **Add dependency update automation**: Use Dependabot or Renovate to auto-create PRs for dependency updates, running security scans on each.

12. **Add build provenance**: Sign container images and generate SBOMs for supply chain security (SLSA compliance).
