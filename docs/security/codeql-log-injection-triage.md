# CodeQL `java/log-injection` (CWE-117) triage — chronicle-server + rhizome

Scope: 97 `java/log-injection` findings from the CodeQL `security-and-quality` SARIF
(`/tmp/cq-java.sarif`), 47 of them in `StudyController.kt`. This note records the
appender-level mitigation analysis and what was fixed vs left.

## Conclusion: (b) — NOT globally CRLF-neutralized at the appender

The production Log4j2 config **does** wire a framework-level rewrite policy, but that
policy only masks **secrets/PII**, not CR/LF. So the 97 findings are **not** mitigated
purely at the appender, and the log-injection class (forged log entries via injected
newlines) is real (though low severity — see "Risk" below).

### Evidence

`chronicle-server/src/main/kotlin/com/openlattice/chronicle/util/SensitiveDataRewritePolicy.kt`
is registered on every root appender via the `<Rewrite>` wrappers in
`chronicle-server/src/main/resources/log4j2.xml`:

- `log4j2.xml:65-68` — `<Rewrite name="RewriteConsole"> … <SensitiveDataRewritePolicy/>`
- `log4j2.xml:70-73` — `<Rewrite name="RewriteRolling"> … <SensitiveDataRewritePolicy/>`
- `log4j2.xml:95-98` — `<Root level="info">` refers ONLY to `RewriteConsole` + `RewriteRolling`,
  so the policy runs on the entire application log path.

However, `SensitiveDataRewritePolicy.mask()`
(`SensitiveDataRewritePolicy.kt:105-128`) only applies:
- KEYWORD_PATTERNS (Bearer/Basic/JSON-secret/key=value/jdbc) — `:61-80`
- NUMERIC_PATTERNS (SSN, credit-card) — `:86-92`

There is **no** `\r`/`\n` handling in that policy.

The pattern layouts are all `%d{ISO8601} %p [%t] %c - %m{nolookups}%n`
(`log4j2.xml:16,21,28,40`). `%m{nolookups}` only disables `${}` lookups (Log4Shell
hardening); it does **not** strip CR/LF. There is no `%enc{}{CRLF}`, no `%replace`,
and no layout-level newline neutralization anywhere under
`chronicle-server/src/main/resources/` or `rhizome/src/main/resources/`
(verified by `rg` for `enc{`, `CRLF`, `%replace`, `replace{`). The HIPAA AUDIT
appender (`log4j2.xml:76-86`) uses `%m%n` with **no** rewrite policy at all.

A `LogSanitizer` helper
(`chronicle-server/src/main/kotlin/com/openlattice/chronicle/util/LogSanitizer.kt`)
**does** exist and strips `\r`/`\n`, ANSI escapes, Unicode directional/zero-width
controls, other control chars, and truncates. It is applied **per call site**, not
globally — already in use in the SSRF/security filters (`SsrfValidator`,
`SecurityHardeningConfig`, `ParameterPollutionFilter`, `ObservabilityFilter`,
`SafeHttpClientFactory`, `WebhookService`).

### Risk

Low: the primary log sinks are file/console with millisecond ISO-8601 timestamps and
fixed `%p [%t] %c -` prefixes, so a forged "log line" injected via a newline still lacks
a valid timestamp/level prefix and is distinguishable on inspection. PII/secret leakage
(the higher-severity concern) **is** covered by the always-on `SensitiveDataRewritePolicy`.
The remaining exposure is log-forgery / forensic confusion via CR/LF on request-tainted
values.

## What was fixed (genuinely request-tainted, edge/pre-auth call sites)

Applied `LogSanitizer.sanitize*` to the values most directly attacker-controlled, in the
filters and the unauthenticated endpoint that see raw request input first:

| File | Line(s) | Tainted value sanitized |
|------|---------|--------------------------|
| `filters/ApiKeyAuthenticationFilter.kt` | 108 | `request.requestURI` → `sanitizeUri` |
| `filters/ApiKeyAuthenticationFilter.kt` | 116 | `pathStudyId`, `pathParticipantId` (URL-decoded from URI) → `sanitize(…, 100)` |
| `controllers/AuthTokenController.kt` | 251 | `error`, `errorDescription` (`@RequestParam` on unauthenticated `/oidc/callback`) → `sanitize` |
| `configuration/RateLimitFilter.kt` | 138, 155 | `requestPath` (`request.requestURI`) → `sanitizeUri` |
| `configuration/RateLimitFilter.kt` | 506 | `clientIp` (proxy-header-derivable) → `sanitizeIp`, `path` → `sanitizeUri` |

Server-derived / DB-sourced values logged alongside these (e.g. `keyInfo.keyId`,
`keyInfo.studyId`, `keyInfo.participantId`, retry-after seconds) were left as-is — they
are not request-tainted.

## What was left (documented, not fixed)

The remaining ~90 findings (47 in `StudyController.kt`, and the service-layer files
`AppDataUploadService`, `SurveysService`, `StudyService`, `EnrollmentService`,
`TimeUseDiaryService`, `RoleService`, `OrganizationMemberService`, `NotificationService`,
`ParticipantPurgeService`, `StudyComplianceService`,
`ParticipantCollectionAcknowledgmentService`, `DataDownloadService`, `ApiKeyService`,
`HazelcastPrincipalService`, `AuthorizingComponent`, and the exception handlers in
`ChronicleServerExceptionHandler` / rhizome `BaseExceptionHandler`) were left because:

1. They are authenticated paths (study/admin/participant ops) gated by
   `AuthorizingComponent` ACL + RLS, so the actor is a known principal, not an anonymous
   attacker — the log-forgery threat model is much weaker.
2. Most logged values are server-derived/validated (UUID `studyId`/`organizationId`
   bound via `@PathVariable UUID`, enum `CollectionModuleId`, counts, principal IDs)
   rather than free-form request strings — UUID/enum parsing already rejects CR/LF.
3. PII/secret leakage on these lines is already covered by the always-on
   `SensitiveDataRewritePolicy` (the higher-severity concern).

If a future hardening pass wants belt-and-suspenders coverage, the durable fix is to add
CR/LF neutralization at the appender (e.g. a `%replace{%m}{[\r\n]}{ }` segment in each
`PatternLayout`, or extend `SensitiveDataRewritePolicy.mask()` to also collapse `\r`/`\n`)
— that would neutralize all 97 at one point instead of per call site.

---

# CodeQL high-value findings triage (non-log-injection)

## `java/sql-injection` — `controllers/ImportController.kt:434` — FALSE POSITIVE (documented)

`importSystemApps` interpolates `sourceTable` into raw SQL at `:434`
(`INSERT INTO … SELECT * FROM $sourceTable`). The value originates from
`config.systemAppsTable` (`@RequestBody ImportStudiesConfiguration`), **but it is passed
through `SqlIdentifierValidator.validateImportTableName(...)` at `:431` before use**.

`SqlIdentifierValidator.validateImportTableName`
(`util/SqlIdentifierValidator.kt:247-298`):
- rejects blank (`:248`) and `>255` chars (`:256`);
- splits on `.`, rejects `>2` segments (`:270-277`);
- requires **each** segment to match `VALID_IDENTIFIER_PATTERN = ^[a-zA-Z_][a-zA-Z0-9_]*$`
  (`:26`, enforced `:278-286`) — this rejects every SQL-injection metacharacter
  (whitespace, quotes, `;`, parens, `--`, `*`, hyphens), leading digits, and empty
  segments;
- rejects system catalogs `pg_*` / `information_schema` (`:288-294`).

Table/schema names cannot be JDBC bind parameters, so allowlist-style identifier
validation is the correct mitigation. The endpoint is additionally admin-gated
(`ensureAdminAccess()` at `:429`). CodeQL flags it because it does not model the regex as
a sanitizer (sanitizer-not-recognized FP). **No change.**

## `java/spring-disabled-csrf-protection` ×2 — INTENTIONAL / CORRECT (documented)

- `pods/servlet/ChronicleServerSecurityPod.kt:194` — `.csrf { it.disable() }`
- `rhizome/.../auth0/Auth0SecurityPod.java:65` — `.csrf(AbstractHttpConfigurer::disable)`

Both filter chains are **stateless** and use **header/Bearer JWT** auth, where Spring's
session-CSRF token is inapplicable:
- `ChronicleServerSecurityPod.kt:202` — `SessionCreationPolicy.STATELESS`; OAuth2
  resource server + `chronicleTokenResolver()` Bearer (`:195-201`).
- `Auth0SecurityPod.java:74` — `SessionCreationPolicy.STATELESS`; OAuth2 resource server +
  `CookieOrBearerTokenResolver` (`:67-72,92-94`).

The chronicle server's cookie-bearer JWT flow is defended by **SameSite=Strict** auth/CSRF
cookies + a custom double-submit CSRF cookie issued by `AuthTokenController`
(`ChronicleServerSecurityPod.kt:191-193`; cookie attributes set in
`AuthTokenController.addCookie`). No cookie-based ambient session exists that Spring's CSRF
token would protect. **No change.**

## `java/sensitive-log` ×3 — FALSE POSITIVES (documented)

- `services/security/SecretRotationService.kt:350` and `:353` — log the secret's **name**
  (e.g. `JWT_SECRET`), the **max-age policy** in days, the **last-rotated date**, and
  **age in days** (`logOverdueWarnings`, `:342-360`). No secret **value** is logged — this
  is rotation metadata for ops alerting.
- `services/security/HoneyTokenService.kt:151` — logs the honey token's descriptive
  **name** and **prefix** only. The secret material is `rawKey` inside
  `fullKey = "ck_${prefix}_$rawKey"` (`:138-139`); only the SHA-256 `hash` is persisted
  (`:140,145`) and only the non-secret `prefix` is stored unhashed for lookup (`:146`).
  `rawKey`/`fullKey` are never logged. A honey token is a decoy by design.

**No change** for all three.

## `java/insecure-cookie` — `controllers/AuthTokenController.kt:633` — FALSE POSITIVE (documented)

CodeQL flags the `Cookie` built in `addCookie` because it cannot prove the Secure flag is
set. It **is** set on the next line: `cookie.secure = useSecureCookie(request)` (`:634`).
`useSecureCookie` (`:93-100`) honors an explicit `chronicle.security.cookie.secure`
override, else delegates to `isSecureRequest` (`:107-110`), which returns `true` when
`request.isSecure` **or** `X-Forwarded-Proto: https` **or** the proxy header is absent
(defaults true), returning `false` only when `X-Forwarded-Proto` is explicitly `http`.

This is exactly the F5-VIP forwarded-HTTPS case: the backend sees forwarded HTTP with
`X-Forwarded-Proto: https`, so Secure **is** applied. `HttpOnly` is caller-controlled
(`:633`, set true for auth cookies) and `SameSite` is set (`:637`, `Strict` for
auth/CSRF). **No change** — Secure is correctly, F5-awarely set.

## `java/reference-equality-on-strings` — `util/SensitiveDataRewritePolicy.kt:45` — INTENTIONAL / CORRECT (documented)

`if (masked === original) return event` (`:45`) is a deliberate **identity** check, not a
value compare. `mask()` is documented and implemented to return **the same reference** it
was given when nothing matched (`:103-104` doc, `:127` `return if (changed) result else input`),
and a **new** `String` when masking occurred. So `===` precisely answers "did `mask()`
short-circuit and hand back my own object?" → skip allocating a new `LogEvent`. There is
no leak risk: if anything was masked, `mask` returns a different object, `===` is false,
and the masked event is rebuilt/forwarded. Using `==` would only add a redundant value
comparison. **No change.**

# Real fixes applied (non-log-injection)

| Finding | File:line | Fix |
|---------|-----------|-----|
| `java/unreleased-lock` | `rhizome/.../core/Rhizome.java:200` | Moved `startupLock.lock()` out of the `try` (now immediately before it) so the `finally`/`unlock()` only runs when the lock is definitely held — removes the `IllegalMonitorStateException`-if-`lock()`-throws path. Behavior otherwise identical. |
| `java/dereferenced-value-is-always-null` | `chronicle-server/.../storage/tasks/MoveToIosEventStorageTask.kt:379` | `odt`/`timezone` are `var`s mutated inside a `forEach` closure, so Kotlin cannot smart-cast them non-null after `checkNotNull`. Bound the non-null `checkNotNull` return values into `val recordedDateTime`/`val recordedTimezone` and dereference those. Same exception messages, same `atZoneSameInstant` call. |

