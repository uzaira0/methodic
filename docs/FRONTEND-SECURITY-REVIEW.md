# Frontend Security Review

**Date**: 2026-04-05
**Scope**: `chronicle-web/src/` -- all non-test, non-vendor JavaScript/TypeScript

---

## 1. Auth Token Handling

**Rating: GOOD (previously remediated under F-P0-2)**

The JWT is **not** stored in localStorage. The codebase explicitly avoids this:

- `storeAuthInfo.js` sends the JWT to the backend via `POST /chronicle/v3/auth/set-cookie`, which sets it as an **httpOnly cookie**. Comments explicitly state: _"Do NOT store JWT in localStorage -- it's XSS-accessible"_.
- `getAuthToken.js` reads the token from an **in-memory** Immutable.js Configuration map (`getConfig().get('authToken')`), not from storage.
- `clearAuthInfo.js` calls the backend logout endpoint to clear the httpOnly cookie, and removes legacy localStorage keys.
- `newAxiosInstance.js` sets `withCredentials: true` so the httpOnly cookie is sent automatically.

**What is in localStorage** (non-sensitive):
| Key | Contents | Risk |
|-----|----------|------|
| `chronicle_user_info` | email, name, picture URL, user ID, roles | Low -- display-only, no JWT |
| `organization_id_map` | `{ userId: orgId }` mapping | Low -- UUIDs only |
| `chronicle-modern-workbench` | UI track state (activeTrack, completedTracks) | None |
| `chronicle-modern-ui-shell` | Sidebar collapsed, status dialog state | None |
| `chronicle-modern-studies-workbench` | Filter state (owner, query, stage) | None |

**Residual risk**: The `chronicle_user_info` key stores email and name. If the app is XSS'd, an attacker could exfiltrate researcher emails. This is low severity since the JWT (the real prize) is in an httpOnly cookie, but email addresses could enable targeted phishing.

**Recommendation**: Consider storing user display info in sessionStorage instead of localStorage to limit persistence, or move it to in-memory state and re-derive it from the JWT claims on each page load.

---

## 2. XSS Vectors

**Rating: GOOD -- no dangerous patterns found**

- **No raw HTML injection** (React's dangerous inner HTML API) anywhere in src/.
- **No direct DOM innerHTML assignments** in application code.
- **No dynamic code execution** in application code.
- React's JSX auto-escaping is in effect for all rendered content.

The codebase uses standard React rendering patterns with no raw HTML injection points.

---

## 3. CSRF Protection

**Rating: GOOD -- double-submit cookie pattern implemented**

- `getCSRFToken.js` reads a CSRF token from a js-cookie accessible cookie (key: CSRF_COOKIE), validated against a UUID regex.
- `storeAuthInfo.js` obtains the CSRF token from the backend's set-cookie response, or generates a UUID fallback if the endpoint is unavailable.
- `newAxiosInstance.js` attaches the CSRF token as an `X-CSRF-Token` header on every request.
- The CSRF cookie is set with `SameSite: strict` and `secure: true` (except localhost).

**Minor concern**: The fallback path generates a client-side UUID when the backend set-cookie endpoint is unavailable. This means the backend must also have a fallback to accept client-generated CSRF tokens, which weakens the double-submit guarantee slightly. However, this is a graceful degradation path for development/older backends.

---

## 4. Sensitive Data in Client State

**Rating: ACCEPTABLE with caveats**

**Redux (legacy saga-based state)**:
- Study participant lists are fetched and stored in Redux state for the dashboard/study management views. This includes participantId, participation status, and device enrollment status.
- No SSNs, dates of birth, phone numbers, or addresses were found in the Redux state shape.

**Zustand stores (modern)**:
- `workbench-store.ts`, `ui-shell-store.ts`, `studies-workbench-store.ts` -- all store only UI preferences, no participant data.

**Concern**: Participant IDs flow through React component state (e.g., study-participants-page.tsx, participant-info-modal.tsx, participant-notes-editor.tsx). These are study-assigned identifiers (not direct PII), but participant notes entered by researchers could contain PII. This data lives in React component state (memory only, not persisted to localStorage), which is acceptable.

**Recommendation**: Ensure participant notes are never cached in browser storage. Currently they are not, but any future offline/caching feature should exclude this data.

---

## 5. API Key / Secret Exposure

**Rating: GOOD -- no secrets in frontend bundle**

- No hardcoded API keys, secrets, or private keys found in src/.
- The Google Analytics ID (G-WJ7BQMLPEK) is in index.html -- this is a public measurement ID, not a secret.
- API base URLs are derived dynamically from window.location.hostname in Configuration.js (localhost, staging.chronicle-screentime-app.research.bcm.edu, api.chronicle-screentime-app.research.bcm.edu, or self-hosted).
- No .env files are referenced in the source; environment-specific config is hostname-based.

---

## 6. CSP Compliance

**Rating: GOOD -- comprehensive CSP deployed**

The nginx frontend config (`docker/nginx.frontend.conf`) sets a full Content-Security-Policy:

```
default-src 'self';
script-src 'self' 'sha256-...' https://www.googletagmanager.com https://www.google-analytics.com;
style-src 'self' 'unsafe-inline';
img-src 'self' data: https://www.google-analytics.com https://www.googletagmanager.com;
font-src 'self';
connect-src 'self' https://www.google-analytics.com https://www.googletagmanager.com;
frame-src 'none';
frame-ancestors 'none';
form-action 'self';
worker-src 'self';
base-uri 'self';
object-src 'none';
```

**Strengths**:
- Inline scripts use hash-based allowlisting (sha256), not unsafe-eval.
- frame-src and frame-ancestors set to 'none' prevent clickjacking.
- object-src 'none' blocks Flash/plugin-based attacks.
- base-uri 'self' prevents base tag hijacking.

**Weakness**: `style-src 'unsafe-inline'` is present. This is common in React apps using CSS-in-JS (styled-components, emotion) but technically allows injected style tags. This is a low-severity concern since style injection alone rarely leads to data exfiltration, and eliminating it would require moving all inline styles to external sheets or nonce-based CSP.

**Missing from CSP in location blocks**: The static file location block does not repeat the CSP header. Nginx add_header in a location block replaces server-level headers. Static JS/CSS files served from this location will not have the CSP header. This is low risk since these are not HTML documents, but for defense-in-depth the CSP should be repeated there.

---

## 7. Additional Security Headers

All present in nginx config:
- X-Frame-Options: DENY
- X-Content-Type-Options: nosniff
- Referrer-Policy: strict-origin-when-cross-origin
- Cross-Origin-Resource-Policy: same-origin
- Permissions-Policy: accelerometer=(), camera=(), ... (denies all sensitive APIs)

**Missing**: Strict-Transport-Security (HSTS) is not set in the frontend nginx config. This may be set at the Traefik reverse proxy level, but should be verified.

---

## Summary of Findings

| Category | Severity | Status |
|----------|----------|--------|
| JWT in httpOnly cookie | -- | Remediated (F-P0-2) |
| User email in localStorage | Low | Accepted risk |
| No XSS vectors | -- | Clean |
| CSRF double-submit | -- | Implemented |
| Participant data in memory only | -- | Acceptable |
| No secrets in bundle | -- | Clean |
| CSP deployed | -- | Comprehensive |
| style-src unsafe-inline | Low | Accepted (CSS-in-JS) |
| CSP missing on static file locations | Low | Should fix |
| HSTS not in frontend config | Medium | Verify at proxy layer |

### Recommended Actions

1. **Verify HSTS** is set at the Traefik/load balancer level. If not, add the Strict-Transport-Security header to the nginx config.
2. **Add CSP to static file location block** to ensure defense-in-depth.
3. **Consider moving user display info** from localStorage to sessionStorage or in-memory state.
4. **Monitor** the chronicle_allow_testing_login localStorage flag in resolveLegacyBootstrapToken.js -- ensure this code path is disabled in production builds.
