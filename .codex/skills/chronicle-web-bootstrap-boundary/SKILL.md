---
name: chronicle-web-bootstrap-boundary
description: Workflow for Chronicle web bootstrap and auth-boundary work. Use when changing chronicle-web bootstrap loading, config.json token fallback, cookie exchange/logout helpers, legacy bootstrap rendering, or Bun coverage around the bootstrap/auth path.
---

# Chronicle Web Bootstrap Boundary

Use this skill when the task touches the Chronicle web startup/auth boundary between the temporary `config.json` bootstrap token flow and the future institutional SSO path.

## Core workflow

1. Confirm whether the change affects bootstrap token loading, cookie exchange/logout, shell routing, or all three.
2. Prefer shared helpers under `chronicle-web/src/core/bootstrap/` and `chronicle-web/src/core/auth/bootstrap/` over adding more inline startup logic.
3. Keep Bun coverage current for the pure bootstrap/auth helpers before changing the remaining Jest compatibility lane.
4. Validate the boundary with `scripts/run-bootstrap-smoke.sh` before handoff.

## Key checks

- `cd chronicle-web && bun run check`
- `cd chronicle-web && bun test src/bun-legacy/fetchBootstrapToken.test.js src/bun-legacy/exchangeBootstrapToken.test.js src/bun-legacy/resolveLegacyBootstrapToken.test.js src/bun-legacy/storeAuthInfo.test.js src/bun-legacy/clearAuthInfo.test.js src/bun-legacy/logoutCookieSession.test.js src/bun-legacy/shellRouting.test.js`
- `cd chronicle-web && bunx playwright test e2e/modern-shell.spec.ts --grep "deep link directly"`

## Fast path

- Use `scripts/run-bootstrap-smoke.sh` in this skill for the repeatable validation sequence.
- Read `references/touchpoints.md` before editing `src/index.js`, `src/core/bootstrap/`, `src/core/auth/bootstrap/`, or the modern bootstrap session files.
