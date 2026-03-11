# Bun Touchpoints

Load this file when Bun workflow changes need repo-wide follow-through.

## Web workspace

- `chronicle-web/package.json`
- `chronicle-web/bunfig.toml`
- `chronicle-web/bun.lock`
- `chronicle-web/tsconfig.json`
- `chronicle-web/scripts/build-modern.ts`
- `chronicle-web/README.md`

## Root automation

- `scripts/chronicle-preflight.sh`
- `scripts/chronicle-smoke.sh`
- `scripts/chronicle-web-bun-smoke.sh`
- `.claude/hooks/post_edit_lint.py`

## CI and security

- `.github/workflows/ci.yml`
- `.github/workflows/security-scan.yml`

## Repo guidance

- `AGENTS.md`
- `MEMORY.md`
