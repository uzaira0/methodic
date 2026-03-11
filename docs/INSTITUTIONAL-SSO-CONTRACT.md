## Chronicle Institutional SSO Contract

Updated: 2026-03-11

### Scope

This document defines the target authentication contract for Chronicle as Auth0 is retired in favor of institutional SSO. It covers the server and web interface boundary only; it does not pick a specific identity provider implementation.

### Current Transitional Model

- `chronicle-web` may bootstrap a JWT from `/chronicle/config.json` in test-only environments.
- The browser exchanges that JWT with `POST /chronicle/v3/auth/set-cookie`.
- `chronicle-server` validates the JWT and sets:
  - `chronicle_auth` as an `httpOnly`, `Secure`, `SameSite=Strict` cookie scoped to `/chronicle`
  - `ol_csrf_token` as a readable cookie scoped to `/chronicle`
- Subsequent API calls rely on cookies plus the `X-CSRF-Token` header.

This bootstrap path is temporary. Institutional SSO should replace only the token acquisition step, not the cookie and CSRF contract.

### Target Institutional SSO Contract

1. The browser is redirected to the institution-managed SSO entry point.
2. The identity provider returns to Chronicle on an explicitly configured callback URL.
3. `chronicle-server` completes the SSO exchange server-side and issues Chronicle-managed cookies.
4. The frontend reads session state from a session/bootstrap endpoint, not from a browser-stored JWT.
5. Logout clears Chronicle cookies and, when required, redirects to an explicitly configured institutional logout URL.

### Required Runtime Guarantees

- Chronicle must not assume Auth0 domains anywhere in its runtime defaults.
- External redirect domains must be configured explicitly per deployment.
- SSRF allowlists must be configured explicitly per deployment.
- The frontend must not require `localStorage` JWT persistence to function.
- Any user profile data cached in browser storage must be treated as transitional legacy state and removable without breaking auth.

### Server Responsibilities

- Keep `/chronicle/v3/auth/set-cookie` and `/chronicle/v3/auth/logout` stable until the SSO callback flow replaces the bootstrap-token step.
- Accept a JWT only as a temporary migration bridge or test-environment bootstrap.
- Move the long-lived authenticated session to Chronicle cookies, not JS-readable bearer tokens.
- Reject open redirects unless the destination is same-origin or explicitly configured.
- Reject outbound HTTP targets unless they are explicitly allowed.

### Web Responsibilities

- Treat `/chronicle/config.json` as a testing-only bootstrap path.
- Use `withCredentials: true` for authenticated API requests.
- Send `X-CSRF-Token` using the readable CSRF cookie.
- Keep route guards and Axios refresh behavior aligned on the same bootstrap/session replay contract until SSO replaces the test-token path.
- Move user/session bootstrap toward a dedicated session endpoint once institutional SSO is live.

### Deployment Inputs Needed Before Final Cutover

- Institutional login URL
- Institutional logout URL
- Callback URL(s)
- Post-logout return URL(s)
- Redirect allowlist entries
- SSRF allowlist entries for the SSO provider and any related metadata endpoints
- Mapping rules for user identity, email, organization membership, and admin roles

### Immediate Follow-Up Work

- Remove Auth0-specific runtime defaults from redirect and SSRF configuration.
- Inventory remaining `Auth0Pod` and `Auth0Configuration` wiring in `chronicle-server`.
- Finish removing the remaining legacy browser-storage cleanup values and `/chronicle/config.json` dependencies from the web runtime.
- Define the session/bootstrap endpoint that the modern shell will call once SSO is active.
