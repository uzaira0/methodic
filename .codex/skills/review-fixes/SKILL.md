---
name: review-fixes
description: Review workflow for Chronicle code changes with emphasis on regressions, swallowed errors, missing validation, and silent-failure patterns. Use when the user asks for a review, a fix review, `/review-fixes`, or wants confidence that recent changes are safe across chronicle-web, chronicle-server, chronicle-api, Docker, or CI.
---

# Review Fixes

Read [references/checklist.md](references/checklist.md) before reviewing.

## Workflow

1. Run targeted validation first.
   - Web-only changes: `cd chronicle-web && npm run check`
   - Mixed repo changes: `./scripts/chronicle-smoke.sh`
   - Fix-review sweep: `./scripts/silent-failure-hunter.sh`

2. Review findings first, not summaries.
   - Prioritize correctness bugs, behavioural regressions, broken contracts, and missing tests.
   - Call out places where code now relies on comments or conventions instead of enforced checks.

3. Treat these as high-risk Chronicle patterns:
   - swallowed `catch` blocks or best-effort cleanup that hides a real failure
   - auth/bootstrap changes that drift between `chronicle-web` and `chronicle-server`
   - Docker config changes that are not compose-validated
   - Type-policy claims that exceed actual Flow/TS coverage

4. If no findings are discovered, say so explicitly and mention residual risks or validation gaps.

## Output Shape

- Findings first, ordered by severity.
- File references for each finding.
- Brief open questions or assumptions after findings.
- Short change summary only after findings.
