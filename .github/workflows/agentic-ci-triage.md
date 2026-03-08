---
name: AI CI Failure Triage
description: AI analyzes failed CI runs, identifies root cause, and suggests fixes
on:
  workflow_run:
    workflows: ["*"]
    types: [completed]
    branches: [develop, main]
    conclusions: [failure]
permissions:
  actions: read
  issues: write
  pull-requests: write
---

# AI CI Failure Triage

You are triaging a failed CI workflow run for the Chronicle project — a Java/Gradle backend, React frontend, Android app, and Docker deployment infrastructure.

## Instructions

1. **Identify the failed workflow run** and fetch its logs.

2. **Determine the failure category**:
   - **Build failure**: Gradle compilation errors, missing dependencies, React build errors
   - **Test failure**: Unit test, integration test, or Maestro E2E test failures
   - **Security scan failure**: Trivy vulnerability findings from `security-scan.yml`
   - **Docker failure**: Image build errors, compose issues
   - **Submodule failure**: Missing submodule commits (common — see note below)

3. **Submodule issues** are a frequent cause of CI failures in this project:
   - The repo uses git submodules (`chronicle`, `chronicle-api`, `chronicle-server`, `chronicle-web`, `rhizome`, `rhizome-client`)
   - CI uses `actions/checkout@v4` with `submodules: recursive` and `--depth=1`
   - If a submodule commit SHA referenced by the main repo hasn't been pushed to the submodule remote, CI fails with `upload-pack: not our ref`
   - Fix: push the submodule branch first, then push the main repo

4. **Analyze the root cause** by reading the relevant log section. Look for:
   - The first error in the log (not cascading failures)
   - Missing environment variables or secrets
   - Flaky test indicators (timeouts, race conditions)
   - Version mismatches between dependencies

5. **Post a comment** on the associated PR (if any) or create an issue with:
   - **Summary**: One-line description of the failure
   - **Root cause**: What specifically failed and why
   - **Suggested fix**: Concrete steps or code changes to resolve the issue
   - **Log excerpt**: The relevant error lines (keep it brief)
