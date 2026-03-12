## Chronicle Institutional SSO Contract

Updated: 2026-03-12

### Scope

This document defines the target authentication contract for Chronicle as Auth0 is retired in favor of institutional SSO. It covers the server and web interface boundary only; it does not pick a specific identity provider implementation.

### Current Transitional Model

- `chronicle-web` checks `GET /chronicle/v3/auth/session` on startup.
- When no SSO-backed session exists, test-friendly environments may use
  `POST /chronicle/v3/auth/testing-login` to mint a server-managed session.
- Transitional tooling may still POST a JWT to `/chronicle/v3/auth/set-cookie`,
  but the active web runtime no longer depends on `/chronicle/config.json`.
- `chronicle-server` sets:
  - `chronicle_auth` as an `httpOnly`, `Secure`, `SameSite=Strict` cookie scoped to `/chronicle`
  - `ol_csrf_token` as a readable cookie scoped to `/chronicle`
- Subsequent API calls rely on cookies plus the `X-CSRF-Token` header.

Institutional SSO should replace only the session acquisition step, not the
cookie and CSRF contract.

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

- Keep `/chronicle/v3/auth/session`, `/chronicle/v3/auth/testing-login`,
  `/chronicle/v3/auth/set-cookie`, and `/chronicle/v3/auth/logout` stable until
  the SSO callback flow replaces the testing-login bridge.
- Accept a JWT only as a temporary migration bridge or manual test/bootstrap path.
- Move the long-lived authenticated session to Chronicle cookies, not JS-readable bearer tokens.
- Reject open redirects unless the destination is same-origin or explicitly configured.
- Reject outbound HTTP targets unless they are explicitly allowed.

### Web Responsibilities

- Treat `/chronicle/v3/auth/session` as the source of truth for current auth state.
- Treat `/chronicle/v3/auth/testing-login` as the temporary testing bridge.
- Use `withCredentials: true` for authenticated API requests.
- Send `X-CSRF-Token` using the readable CSRF cookie.
- Keep route guards and Axios refresh behavior aligned on the same session/bootstrap replay contract until SSO replaces the testing-login path.
- Do not reintroduce `/chronicle/config.json` as an active runtime dependency.

### Deployment Inputs Needed Before Final Cutover

- Institutional login URL
- Institutional logout URL
- Callback URL(s)
- Post-logout return URL(s)
- Redirect allowlist entries
- SSRF allowlist entries for the SSO provider and any related metadata endpoints
- Mapping rules for user identity, email, organization membership, and admin roles

### Immediate Follow-Up Work

- Replace the testing-login bridge with the real institutional redirect/callback flow.
- Remove the remaining legacy deployment references to `/chronicle/config.json`
  and `auth0.yaml`.
- Finish removing legacy browser-storage cleanup values once all active sessions
  have passed through the Chronicle-owned storage keys.
- Define the callback, logout, and role-mapping inputs for the chosen SSO provider.
