# Review Checklist

## Required Commands

- `./scripts/silent-failure-hunter.sh`
- `./scripts/chronicle-smoke.sh`
- `cd chronicle-web && npm run check`

## Chronicle-Specific Review Targets

- Web auth bootstrap consistency between `chronicle-web` and `chronicle-server`
- Cookie/CSRF flow regressions
- Docker/Traefik config mismatches
- Claims of TypeScript safety in a still-Flow codebase
- Secret handling and accidental edits to `.env`-style files
