---
name: chronicle-web-auth-migration
description: Workflow for the Chronicle web app's migration from localStorage-based JWT handling to backend-managed httpOnly cookies. Use when changing chronicle-web auth utilities, Axios/bootstrap auth setup, CSRF handling, Jest auth tests, or chronicle-server cookie endpoints under /chronicle/v3/auth.
---

# Chronicle Web Auth Migration

Read [references/files.md](references/files.md) before editing. This skill is for coordinated frontend and backend auth work, not isolated single-file edits.

## Invariants

- Do not reintroduce JWT storage in `localStorage`.
- Keep the auth cookie httpOnly and scoped to `/chronicle`.
- Keep the CSRF token readable by the browser so Axios can send it back in a header.
- Keep `withCredentials: true` on Axios instances that rely on cookie auth.
- Update frontend tests whenever utility behavior changes; many failures come from stale pre-migration expectations.

## Workflow

1. Map the full request path.
   - Bootstrap: `chronicle-web/src/index.js`
   - Utilities: `chronicle-web/src/core/auth/utils/*`
   - Axios setup: `chronicle-web/src/core/api/axios/*`
   - Backend cookie endpoints: `chronicle-server/src/main/kotlin/com/openlattice/chronicle/controllers/AuthTokenController.kt`

2. Decide whether the source of truth is:
   - in-memory auth state
   - httpOnly cookie presence
   - CSRF cookie/header pair
   Do not mix old localStorage assumptions back into the code or tests.

3. Update tests in the same change.
   - Mock `fetch` for `set-cookie` and `logout` flows.
   - Stop expecting `js-cookie` writes for the auth JWT when the code now delegates to the backend.
   - Align config and Axios tests with current `withCredentials` and allowed base URL behavior.

4. Validate at the web layer first.
   - `cd chronicle-web && npm test -- --runInBand --watch=false`
   - If backend endpoint behavior changed and Java is available, add server-side validation after the web suite is green.

## Hand-off Check

- Confirm the JWT is not persisted in `localStorage`.
- Confirm the CSRF flow still works for cookie-auth requests.
- Confirm Jest expectations match the implementation, especially for `fetch`, cookie writes, and auth token lookup.
