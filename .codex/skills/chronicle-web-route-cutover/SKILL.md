---
name: chronicle-web-route-cutover
description: Workflow for Chronicle web route-cutover work where the legacy webpack shell and the modern Bun/Tailwind shell must coexist. Use when changing chronicle-web/src/index.js, legacy-vs-modern bootstrap loading, webpack TS/CSS interop for modern routes, the /modern route prefix, or validations that must cover both legacy and modern shells.
---

# Chronicle Web Route Cutover

Use this skill when the task touches the boundary between the legacy Flow/Webpack app and the modern Bun/Tailwind shell.

## Core workflow

1. Confirm whether the change affects legacy bootstrapping, modern bootstrapping, or both.
2. Validate the mixed-runtime path with `scripts/run-route-cutover-smoke.sh`.
3. If webpack is involved, restore generated `chronicle-web/build/` outputs before commit unless the task explicitly targets them.
4. Keep route-cutover commits narrow. Do not bundle unrelated auth, survey, or TUD work into the same change unless the runtime contract forces it.

## Key checks

- `cd chronicle-web && bun run check`
- `cd chronicle-web && bun run build:dev`
- `cd chronicle-web && bun run test:legacy -- --runInBand --watch=false`
- `cd chronicle-web && bun run e2e`

## Fast path

- Use `scripts/run-route-cutover-smoke.sh` in this skill for the repeatable validation sequence.
- Read `references/touchpoints.md` before editing `src/index.js`, webpack config, or modern bootstrap files.
