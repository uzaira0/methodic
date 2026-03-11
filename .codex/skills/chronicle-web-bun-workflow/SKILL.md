---
name: chronicle-web-bun-workflow
description: Workflow for the Bun-managed Chronicle web workspace. Use when changing chronicle-web package management, bun.lock, bunfig.toml, Bun dev/build/test scripts, the modern HTML build path, or any root automation and CI/hook files that run chronicle-web commands.
---

# Chronicle Web Bun Workflow

Use this skill when the task touches Bun-managed frontend tooling in `chronicle-web` or any root automation that drives it.

## Core workflow

1. Run `bun install --frozen-lockfile` in `chronicle-web` unless the task intentionally changes dependencies or the lockfile.
2. Run `bun run check`.
3. Run `bun run test -- --runInBand --watch=false`.
4. Run `bun run modern:build`.
5. For interactive validation, run `bun run modern:dev` or `bun run modern:preview`.

## Compatibility rule

Keep Bun as the package manager and top-level script runner. Keep Node available as a compatibility runtime while the legacy Jest / Webpack / Flow stack still exists.

## Fast path

- Use `scripts/run-bun-smoke.sh` in this skill for a repeatable Bun frontend validation pass.
- Read `references/touchpoints.md` before editing CI, hooks, root scripts, or repo docs that mention the web toolchain.

## Key files

- `chronicle-web/package.json`
- `chronicle-web/bunfig.toml`
- `chronicle-web/bun.lock`
- `chronicle-web/scripts/build-modern.ts`
- `scripts/chronicle-web-bun-smoke.sh`
- `.github/workflows/ci.yml`
- `.github/workflows/security-scan.yml`
- `.claude/hooks/post_edit_lint.py`
