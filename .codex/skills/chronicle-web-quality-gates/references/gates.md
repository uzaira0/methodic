# Chronicle Web Gate Contract

## Blocking

- `bun run check`
- `bun run test`
- `bun run test:legacy -- --runInBand --watch=false`

## Advisory / Separate Backlog

- `bun run check:full` because the repo still has independent Flow/Jest legacy debt
- `bun run lint:css` because CSS-in-JS stylelint cleanup is not yet normalized into the blocking gate
- ESLint warnings emitted by `bun run check`

## Current Expectations

- ESLint 8 is required because `no-constant-binary-expression` is part of the requested rule set.
- `eslint-config-airbnb` and `eslint-plugin-flowtype` must stay on versions compatible with ESLint 8.
- `chronicle-web` remains Flow-first even though `tsconfig.app.json` exists.
- If you change the gate, update:
  - `chronicle-web/package.json`
  - `.github/workflows/ci.yml`
  - `scripts/chronicle-smoke.sh`
  - `AGENTS.md`
  - `MEMORY.md`
