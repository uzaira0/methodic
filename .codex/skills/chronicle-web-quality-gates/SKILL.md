---
name: chronicle-web-quality-gates
description: Maintain the Chronicle web app's quality gates. Use when updating chronicle-web ESLint rules, TypeScript policy scaffolding, package scripts, Claude hooks, GitHub Actions checks, or when deciding which web warnings should remain advisory versus blocking.
---

# Chronicle Web Quality Gates

Use this when the task is about `chronicle-web` validation policy rather than product behavior.

Read [references/gates.md](references/gates.md) if you need the current gate contract and backlog boundaries.

## Workflow

1. Keep the requested blocking gate narrow and honest.
   - `bun run check` is the blocking web gate: TypeScript policy scaffold + ESLint.
   - `bun run test` is the Bun-native modern-shell regression gate.
   - `bun run test:legacy -- --runInBand --watch=false` is the legacy compatibility regression gate.
   - `bun run check:full` is intentionally broader and may expose separate Flow/Jest legacy backlog.

2. Do not overstate TypeScript coverage.
   - `tsconfig.app.json` is a policy scaffold while source remains Flow-based.
   - New TS flags are acceptable only if docs and CI do not imply a full TS migration already happened.

3. When adding lint rules, separate bug-catching from legacy-style churn.
   - Requested correctness rules can be blocking.
   - Legacy warnings that would require repo-wide rewrites should stay advisory until explicitly queued.

4. Keep automation aligned.
   - `.claude/settings.json` and hooks should match the package scripts.
   - `.github/workflows/ci.yml` should call the same blocking commands used locally.
   - `scripts/chronicle-smoke.sh` should stay consistent with the CI gate.

5. If lint or hooks auto-modify files, review for semantic drift.
   - Styled-components files are especially easy to damage with the wrong parser or fixer.
   - Re-run `bun run check` and the relevant test lanes after any auto-fix pass.
