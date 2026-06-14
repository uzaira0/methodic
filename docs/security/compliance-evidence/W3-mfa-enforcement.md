# W3 — MFA Enforcement (HIPAA §164.312(d))

**Workstream:** HIPAA-2028 Compliance Lane — W3 (Turn MFA on)
**Control:** HIPAA Security Rule §164.312(d) — *Person or entity authentication.*
**Status:** Implemented and test-covered; **enforcement OFF by default.** This artifact
makes the control documented and discoverable; it does **not** turn enforcement on.
See the lane design: `docs/superpowers/specs/2026-06-13-hipaa-2028-compliance-lane-design.md` (§68–77, open question #3 §122).

---

## 1. Control mapping

The HIPAA Security Rule's person/entity-authentication standard is §164.312(d). Under the
January-2025 NPRM (the overhaul targeting ~2028 compliance), multi-factor authentication
moves from an **addressable** implementation specification to a **required** one. Chronicle
satisfies this for the interactive (researcher/web, OIDC-delegated) authentication path by
validating the RFC 8176 `amr` (Authentication Methods Reference) claim on every bearer token
when enforcement is enabled, and by a documented compensating control for the mobile
API-key path (§5 below).

| Requirement | Mechanism | Evidence |
|---|---|---|
| §164.312(d) person/entity authentication (interactive path) | JWT `amr` claim validated against accepted MFA methods (`mfa`, `otp`, `hwk`) via `MfaClaimValidator`, wired into the resource-server validator chain when `chronicle.security.require-mfa=true` | `MfaClaimValidatorTest`, `MfaEnforcementMatrixTest` |
| §164.312(d) person/entity authentication (mobile path) | Per-device, per-`(studyId, participantId, deviceId)` API keys (SHA-256 hashed, revocable) + request signing (`MobileApiSignatureFilter`) + per-device enrollment | See §5 compensating control |

---

## 2. Enforcement matrix

The enforcement behavior is the cross-product of the `chronicle.security.require-mfa`
configuration flag and the presence/value of the token's `amr` claim. Each cell is proven
by `MfaEnforcementMatrixTest` (integration: real HS256-signed JWTs decoded through the
production validator chain) backed by `MfaClaimValidatorTest` (unit) for the validator's
per-claim decision.

| require-mfa | `amr` claim | HTTP outcome | Proven by |
|---|---|---|---|
| `false` | present (`mfa`/`otp`/`hwk`) | **200** | `MfaEnforcementMatrixTest` |
| `false` | absent | **200** | `MfaEnforcementMatrixTest` |
| `false` | wrong (e.g. `pwd`) | **200** | `MfaEnforcementMatrixTest` |
| `true`  | present (`mfa`/`otp`/`hwk`) | **200** | `MfaEnforcementMatrixTest` |
| `true`  | absent | **401** | `MfaEnforcementMatrixTest` |
| `true`  | wrong (e.g. `pwd`) | **401** | `MfaEnforcementMatrixTest` |

**Mechanics of the 401:** when `require-mfa` is true and the `amr` claim is absent or carries
no accepted method, `MfaClaimValidator` returns an `OAuth2Error` with code
`insufficient_authentication`. `NimbusJwtDecoder` raises that as a `JwtValidationException`,
which Spring Security's bearer-token filter renders as HTTP **401**. When `require-mfa` is
false the validator is **not added to the chain at all**, so the `amr` claim is irrelevant and
all three rows resolve to 200.

---

## 3. Test pointers

- **Unit** — `com.openlattice.chronicle.security.MfaClaimValidatorTest`
  Cases: `amr` present-with-accepted-value → valid; absent → invalid; wrong-value → invalid;
  wrong-type → invalid; single `String` form of `amr` accepted (RFC 8176 allows array or string).
- **Integration** — `com.openlattice.chronicle.security.MfaEnforcementMatrixTest`
  Decodes real HS256-signed JWTs through the **production** validator chain
  (`buildJwtValidatorChain`) for every cell of the matrix in §2 — no prod/test drift.

---

## 4. Source pointers (validator + wiring)

- **Validator:** `chronicle-server/src/main/kotlin/com/openlattice/chronicle/security/MfaClaimValidator.kt`
  RFC 8176 `amr` validation; accepted methods `{mfa, otp, hwk}`; failure → `OAuth2Error("insufficient_authentication", …)`.
- **Validator-chain wiring:** `chronicle-server/src/main/kotlin/com/openlattice/chronicle/pods/servlet/ChronicleServerSecurityPod.kt`
  - Flag binding: `@Value("\${chronicle.security.require-mfa:false}")` (line 85–86) — default **false**.
  - Conditional add: `buildJwtValidatorChain(...)` adds `MfaClaimValidator()` to the chain **only when** `requireMfa` is true (lines 436–456, gate at 452–453); the chain is attached to the resource-server `NimbusJwtDecoder` at lines 420–421.
- **Mobile request signing:** `chronicle-server/src/main/kotlin/com/openlattice/chronicle/configuration/MobileApiSignatureFilter.kt` (compensating-control component, §5).

---

## 5. Mobile path compensating control (resolves open question #3)

The mobile data-collection path authenticates with **per-device API keys** (`X-Api-Key`
header), not interactive OIDC tokens. It has **no interactive step-up factor**, so
MFA-via-`amr` cannot apply to it — the `amr` claim only exists on the interactive OIDC/JWT
path. The documented §164.312(d) **compensating control** for the mobile path is:

- **Per-device API keys** scoped to a single `(studyId, participantId, deviceId)` tuple —
  not shared, not user-wide.
- **SHA-256 hashed at rest** — the raw key is never persisted.
- **Revocable** — a compromised or retired device's key is revoked without affecting other devices.
- **Request signing** — `MobileApiSignatureFilter` verifies an HMAC signature over device requests.
- **Per-device enrollment** — each device obtains its own key through enrollment, binding the
  credential to a single physical collector.

Taken together (device-scoped + hashed + revocable + signed + per-device-enrolled), this is
the compensating control that satisfies §164.312(d) person/entity authentication for the
mobile API-key path, in lieu of an interactive MFA step-up that the path cannot support.

---

## 6. How to enable in production

Enforcement is **off by default** and must stay off until the IdP is ready.

1. Configure the external IdP (OIDC broker / Keycloak) to **enforce MFA** at login and to
   **emit an `amr` claim** containing at least one of `mfa`, `otp`, `hwk` in the issued tokens.
2. **Only then** set the flag:
   - Property: `chronicle.security.require-mfa=true`
   - Env (Spring relaxed binding): `CHRONICLE_SECURITY_REQUIRE_MFA=true`
3. Validate end-to-end against the matrix in §2 (a login with MFA → 200; a token lacking
   `amr` → 401).

> **Lockout warning.** Setting `require-mfa=true` **before** the IdP emits a valid `amr`
> claim makes `MfaClaimValidator` reject **every** OIDC login (all interactive tokens lack
> the claim → 401), locking out all researcher/web access. Sequence: IdP first, flag second.
