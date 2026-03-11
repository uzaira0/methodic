---
name: chronicle-institutional-sso
description: Workflow for Chronicle's migration from Auth0 and test-token bootstrap auth to institutional SSO. Use when auditing or changing Auth0Pod/Auth0Configuration wiring, `/chronicle/config.json` bootstrap paths, redirect and SSRF allowlists, backend cookie/session endpoints, or legacy browser-stored user/auth metadata.
---

# Chronicle Institutional SSO

Use this skill when the task is larger than the original cookie-migration slice and now touches the Auth0 retirement path, institutional SSO contract, or deployment-specific security allowlists.

## Read first

- `docs/INSTITUTIONAL-SSO-CONTRACT.md`
- `docs/AUTH0-DEPENDENCY-INVENTORY.md`
- `docs/SECURITY-HARDENING.md` when redirects, SSRF, or CSP are in scope
- `references/touchpoints.md` for the file map

## Workflow

1. Run the drift audit first.
   - Use `scripts/run-sso-drift-audit.sh`.
   - Add `--strict` when you want the audit to fail on reintroduced Auth0 defaults.

2. Decide which layer is being changed.
   - Server bootstrap and pods: `chronicle-server`
   - Web bootstrap and legacy auth helpers: `chronicle-web`
   - Deployment/security defaults and docs: root `docs/` and `docker/`

3. Keep the contract stable while migrating.
   - Do not reintroduce JWT persistence in browser storage.
   - Do not add implicit external-domain defaults back into redirect or SSRF config.
   - Treat `/chronicle/config.json` as a temporary testing bridge, not the final login design.
   - Prefer explicit deployment config over provider-specific hardcoded defaults.

4. Validate the affected surface.
   - Web auth/helper changes: `cd chronicle-web && bun run test:bun` and `cd chronicle-web && bun run test:legacy -- --runInBand --watch=false`
   - Root deployment/security doc changes: `docker compose -f docker/docker-compose.traefik.yml config -q`
   - Server runtime changes: add JVM validation if Java is available locally

## When to split commits

- Commit `chronicle-web` changes in the nested repo first, then update the root pointer separately.
- Keep contract docs, inventory/audit docs, and runtime behavior changes in separate commits unless one change would be misleading without the other.

## References

- Use `references/touchpoints.md` for the main files.
- Use `references/checks.md` for the current audit categories and validation expectations.
