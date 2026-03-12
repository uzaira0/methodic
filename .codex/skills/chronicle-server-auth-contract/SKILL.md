---
name: chronicle-server-auth-contract
description: Workflow for Chronicle server auth/session controller work. Use when changing AuthTokenController, cookie issuance or logout behavior, the testing-login/session bridge, chronicle-server auth tests, or JVM smoke/CI wiring for the auth contract.
---

# Chronicle Server Auth Contract

Use this skill when the task touches the Chronicle server auth/session boundary:

- `chronicle-server/src/main/kotlin/com/openlattice/chronicle/controllers/AuthTokenController.kt`
- `chronicle-server/src/test/kotlin/com/openlattice/chronicle/controllers/AuthTokenControllerTest.kt`
- `scripts/chronicle-server-auth-smoke.sh`
- JVM smoke or CI wiring for the auth/session contract

## Workflow

1. Review the controller contract first.
   - Session: `GET /chronicle/v3/auth/session`
   - Testing bridge: `POST /chronicle/v3/auth/testing-login`
   - Transitional JWT bridge: `POST /chronicle/v3/auth/set-cookie`
   - Logout: `POST /chronicle/v3/auth/logout`

2. Prefer controller-level tests before broader Spring wiring.
   - Use `MockHttpServletRequest` and `MockHttpServletResponse`.
   - Mock `JwtDecoder` and `UserListingService`.
   - Assert cookie names, `httpOnly`, `Secure`, `SameSite`, path, and response metadata.

3. Keep the runtime guarantees stable.
   - Do not reintroduce browser-stored JWT as the main auth source.
   - Do not change cookie names lightly: `chronicle_auth`, `ol_csrf_token`.
   - Keep `/chronicle` cookie path and `SameSite=Strict` unless the deployment contract changes explicitly.
   - Treat `testing-login` as a temporary bridge, not the final SSO design.

4. Validate the affected surface.
   - Local shell checks:
     - `bash -n scripts/chronicle-server-auth-smoke.sh`
     - `bash -n scripts/chronicle-smoke.sh`
   - CI config:
     - ensure `.github/workflows/ci.yml` still runs the auth/session server test lane
   - JVM run when Java is available:
     - `./scripts/chronicle-server-auth-smoke.sh`

## References

- Read [references/touchpoints.md](references/touchpoints.md) for the main files and validation commands.
