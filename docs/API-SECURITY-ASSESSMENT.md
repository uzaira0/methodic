# Chronicle API Security Assessment

**Date:** 2026-04-05
**Scope:** Code-level review of all controller endpoints, Spring Security configuration, HMAC signing, authorization, and business logic.
**Type:** Static analysis (no live pentest)

---

## 1. Full Endpoint Inventory

### 1.1 Public (permitAll) Endpoints -- No Authentication Required

| Endpoint Pattern | Method | Controller | Purpose |
|---|---|---|---|
| `/chronicle/study/*/participant/**` | POST, GET | Legacy ChronicleStudyController | Legacy mobile enrollment, status |
| `/chronicle/v2/study/*/participant/**` | POST, GET | ChronicleControllerV2 | v2 mobile enrollment, upload |
| `/chronicle/data/study/*/participant/**` | POST, GET | Legacy ChronicleController | Legacy data upload |
| `/chronicle/v3/study/*/participant/*/ios/*` | POST | StudyController | iOS sensor data upload |
| `/chronicle/v3/study/*/participant/*/android/*` | POST | StudyController | Android usage/sensor upload |
| `/chronicle/v3/study/*/participant/*/*/enroll` | POST | StudyController | Device enrollment |
| `/chronicle/v3/study/*/settings/sensors` | GET | StudyController | Study sensor settings |
| `/chronicle/v3/study/*/settings` | GET | StudyController | Study settings (all) |
| `/chronicle/v3/study/*/participant/*/verify` | GET | StudyController | Participant verification |
| `/chronicle/v3/time-use-diary/**` | POST, GET | TimeUseDiaryController | TUD submission (participant-facing) |
| `/chronicle/v3/survey/*/participant/*/app-usage` | GET, POST | SurveyController | App usage survey (participant-facing) |
| `/chronicle/v3/survey/*/participant/*/device-usage` | GET, POST | SurveyController | Device usage survey (participant-facing) |
| `/chronicle/v3/survey/*/questionnaire/*` | GET | SurveyController | Questionnaire retrieval |
| `/chronicle/v3/survey/*/participant/*/questionnaire/*` | POST | SurveyController | Questionnaire submission |
| `/chronicle/v3/auth/session` | GET | AuthTokenController | Session check |
| `/chronicle/v3/auth/set-cookie` | POST | AuthTokenController | Cookie bootstrap |
| `/chronicle/v3/auth/testing-login` | POST | AuthTokenController | Testing login (should be dev-only) |
| `/chronicle/v3/auth/logout` | POST | AuthTokenController | Logout |
| `/chronicle/v3/notification/status` | POST | NotificationController | Twilio webhook callback |
| `/prometheus/**` | ALL | (metrics) | Prometheus scraping |

### 1.2 Authenticated Endpoints (JWT/Cookie/API Key Required)

| Controller | Auth Check Method | Endpoints |
|---|---|---|
| **StudyController** | `ensureReadAccess`, `ensureWriteAccess`, `ensureOwnerAccess`, `ensureAuthenticated`, `ensureAdminAccess` | createStudy, getStudy, getOrgStudies, updateStudy, destroyStudy, deleteStudyParticipants, registerParticipant, updateStudySettings, getStudyPermissions, updateStudyPermissions, getAllStudies, getParticipantsData, updateParticipationStatus, getStudyParticipants, getParticipantStats, setChronicleDataCollectionSettings, getStudyDevices, getStudySensorAvailability, getStudySettingsAudit, updateParticipantAnnotations |
| **AdminController** | `ensureAdminAccess` | moveToEventStorage, reloadCache, getUserPrincipals, getCurrentUserPrincipals |
| **ImportController** | `ensureAdminAccess` | All import endpoints |
| **PermissionsController** | `ensureOwnerAccess` | updateAcl, updateAcls, getAcl, getAcls, getAclExplanation |
| **OrganizationController** | Various AclKey checks | CRUD for organizations |
| **NotificationController** | `ensureReadAccess`, `ensureWriteAccess` on AclKey(studyId) | Researcher notification settings, send notifications |
| **SurveyController** | `ensureReadAccess`, `ensureWriteAccess`, `ensureOwnerAccess` on AclKey(studyId) | getAppsFilteredForStudyAppUsageSurvey, setAppsFilteredForStudyAppUsageSurvey, createQuestionnaire, deleteQuestionnaire, updateQuestionnaire, getQuestionnaireResponses |
| **TimeUseDiaryController** | `accessCheck`, `ensureReadAccess` | getParticipantTUDSubmissionIdsByDate, getStudyTUDSubmissionIdsByDate, getStudyTUDSubmissions |
| **TokenRevocationController** | `ensureAdminAccess` (for revoke-all, stats); JWT auth (for revoke-self) | Token revocation endpoints |
| **WebhookController** | `@RequiresStudyAccess` | CRUD for webhooks |
| **ExportController** | `@RequiresStudyAccess(EXPORT_DATA/READ_STUDY)` + `@RateLimit(SENSITIVE)` | Async export, download |
| **StudyLifecycleController** | `@RequiresStudyAccess(MODIFY_STUDY/DELETE_DATA/READ_STUDY)` | archive, unarchive, clone, schedule deletion |
| **AnonymizationController** | `@RequiresStudyAccess` | get/update anonymization config |
| **DataQualityController** | `@RequiresStudyAccess(READ_STUDY)` | Data quality dashboard |
| **ParticipantPurgeController** | `@RequiresStudyAccess(DELETE_DATA)` | Preview/execute purge |
| **StudyComplianceController** | `ensureReadAccess`, `ensureAdminAccess` | Compliance violations, notifications |
| **StudyLimitsController** | `ensureAdminAccess`, `ensureReadAccess` | Study limits |
| **PipelineController** | `@RequiresStudyAccess` | Pipeline CRUD |
| **DashboardController** | `@RequiresStudyAccess(READ_STUDY)` | Dashboard data |
| **ApiKeyController** | `@RequiresStudyAccess` | API key management |

### 1.3 StudyV4Controller Endpoints (Public -- inherit v3 permitAll rules)

| Endpoint | Method | Purpose |
|---|---|---|
| `.../v4/.../enroll` | POST | Device enrollment (device ID via header) |
| `.../v4/.../android` | POST | Android usage upload |
| `.../v4/.../android/sensors` | POST | Android sensor upload |
| `.../v4/.../android/sensors/availability` | POST | Sensor availability report |
| `.../v4/.../ios` | POST | iOS sensor upload |

---

## 2. Findings by Severity

### CRITICAL

**(None found)**

The codebase demonstrates a mature security posture. No critical vulnerabilities were identified.

### HIGH

#### H-1: HMAC Signing Defaults to Disabled and Non-Enforced

**File:** `MobileApiSecurityConfig.kt`, `MobileSecurityConfiguration`
**Lines:** 97-99 (config), 170-187 (defaults)

The `MobileSecurityConfiguration` defaults to `enabled=false` and `signingRequired=false`. When HMAC is enabled but `signingRequired=false`, unsigned requests are silently accepted with only a warning log. The HMAC filter also only applies to `/api/mobile` path prefix, which does NOT match any of the actual public mobile endpoints (which use `/chronicle/v3/study/...`).

**Impact:** All unauthenticated mobile endpoints (enrollment, data upload, sensor data, survey submission, TUD) have zero request integrity protection. An attacker who knows a valid studyId+participantId can submit forged data.

**Recommendation:**
1. Change the HMAC filter path check from `/api/mobile` to match the actual public mobile endpoint paths (`/chronicle/v3/study/*/participant/*`, etc.).
2. Set `signingRequired=true` in production configuration.
3. Enforce HMAC on all v4 endpoints as a migration path.

#### H-2: Testing Login Endpoint Has No Spring Profile Gate

**File:** `AuthTokenController.kt`
**Lines:** 117-161

The `/testing-login` endpoint is `permitAll` in Spring Security and gated only by a runtime configuration flag (`userListingService.issueTestingToken()`). The code contains a `TODO` acknowledging this should be gated behind `@Profile("!production")`.

**Impact:** If the testing token configuration is accidentally enabled in production, any unauthenticated user can obtain a valid JWT session. This is an authentication bypass.

**Recommendation:** Gate the endpoint with `@Profile("!production")` or `@ConditionalOnProperty` so that it cannot be enabled via config alone in production.

#### H-3: Study Settings Endpoint Exposes All Settings Without Authentication

**File:** `StudyController.kt`
**Lines:** 1237-1255

`getStudySettings()` has the comment "No permissions check since this is assumed to be invoked from a non-authenticated context" and the matching `permitAll` rule in Spring Security. This exposes ALL study settings (including notification settings, data collection settings, sensor configurations) to anyone who knows a study UUID.

**Impact:** Information disclosure. An attacker can enumerate study UUIDs and read their full configuration. Study settings may contain operational details useful for further attacks.

**Recommendation:** Either restrict this to the specific settings mobile apps need (e.g., just sensor settings) or require at minimum a study-scoped API key / HMAC signature.

### MEDIUM

#### M-1: Legacy Endpoints Use Overly Broad permitAll Wildcards

**File:** `ChronicleServerSecurityPod.kt`
**Lines:** 128-135

The legacy and v2 `permitAll` patterns (`/chronicle/study/*/participant/**`, `/chronicle/v2/study/*/participant/**`, `/chronicle/data/study/*/participant/**`) use double-star wildcards that match any sub-path. The legacy controllers themselves have limited endpoints, but the broad wildcards could inadvertently match new endpoints added under those paths.

**Impact:** Future endpoints accidentally placed under these paths would be publicly accessible.

**Recommendation:** Narrow the wildcards to match only the specific legacy endpoint paths, or add a sunset date for removing legacy endpoint support entirely.

#### M-2: No CSRF Token Verification on State-Changing Cookie-Authenticated Requests

**File:** `ChronicleServerSecurityPod.kt`
**Lines:** 106-109

Spring CSRF is disabled. The system uses SameSite=Strict cookies plus a custom CSRF cookie (`ol_csrf_token`), but there is no server-side CSRF token validation filter. The CSRF cookie is set as `httpOnly=false` so the frontend can read it, but no filter validates that the token is sent back in a request header.

**Impact:** While SameSite=Strict cookies provide strong CSRF protection against cross-origin attacks, the custom CSRF cookie is security theater without server-side verification. Subdomains or same-site pages could still forge requests.

**Recommendation:** Either implement a filter that validates `X-CSRF-Token` header matches the `ol_csrf_token` cookie value, or document that SameSite=Strict is the sole CSRF defense and remove the misleading CSRF cookie.

#### M-3: Enrollment Lacks Rate Limiting

**File:** `StudyController.kt`
**Lines:** 168-220 (enroll endpoint)

The enrollment endpoint (`/chronicle/v3/study/*/participant/*/*/enroll`) is public (no auth) and has no `@RateLimit` annotation. An attacker can brute-force participant IDs by attempting enrollment against known study UUIDs.

**Impact:** Participant ID enumeration and potential DoS via mass enrollment attempts.

**Recommendation:** Add `@RateLimit(type = RateLimitType.AUTH)` to the enrollment endpoint.

#### M-4: Concurrent Enrollment Race Condition is Mitigated but Imperfect

**File:** `EnrollmentService.kt`
**Lines:** 66-69, 210-244

Device registration uses `INSERT ... ON CONFLICT DO UPDATE SET device_token = EXCLUDED.device_token`. This prevents duplicate enrollment crashes but silently updates the device token. Two concurrent enrollments for the same participant+device could race and the last-write-wins for the token value.

**Impact:** Low -- the database unique constraint prevents data corruption, but concurrent enrollments may produce unpredictable token state. The `registerDeviceOrGetId` method generates a new `deviceId` that is thrown away if the insert conflicts, which is wasteful but not a security issue.

**Recommendation:** Consider `INSERT ... ON CONFLICT DO NOTHING` and then SELECT to return the existing device ID, avoiding phantom token updates.

#### M-5: Prometheus Endpoint Unrestricted

**File:** `ChronicleServerSecurityPod.kt`
**Lines:** 173-175

The `/prometheus/**` endpoint is `permitAll` with a comment noting it "should be restricted to Prometheus container IP via Traefik middleware." If Traefik is misconfigured, operational metrics (pool sizes, wait times, error rates) are publicly exposed.

**Impact:** Information disclosure of operational metrics.

**Recommendation:** Add IP-based access control at the application level as defense-in-depth, not just at the reverse proxy.

#### M-6: Twilio Webhook Lacks Origin Verification

**File:** `NotificationController.kt`
**Lines:** 178-190

The `/chronicle/v3/notification/status` endpoint is `permitAll` and accepts `MessageSid` and `MessageStatus` parameters without verifying they came from Twilio (no Twilio signature validation).

**Impact:** An attacker can forge notification status updates, potentially marking real notifications as delivered when they weren't, or causing incorrect notification state.

**Recommendation:** Validate the Twilio request signature (`X-Twilio-Signature` header) using the Twilio library's `RequestValidator`.

### LOW

#### L-1: getQuestionnaire Lacks Auth Check (Intentional but Risky)

**File:** `SurveyController.kt`
**Lines:** 284-302

`getQuestionnaire()` (the authenticated version at `GET /chronicle/v3/survey/{studyId}/questionnaire/{questionnaireId}`) has no `ensureReadAccess` call. It matches the `permitAll` pattern for the participant-facing questionnaire retrieval. This is likely intentional so participants can retrieve questionnaires without auth, but it means authenticated users can also read any study's questionnaires.

**Impact:** Low -- questionnaire content is not PHI, but it reveals study methodology.

**Recommendation:** Document this as intentional behavior. Consider adding auth for the researcher-facing version if questionnaire content is sensitive.

#### L-2: participantId Validation Not Applied Consistently

**File:** Various controllers

`validateParticipantId()` (regex `^[a-zA-Z0-9_.-]+$`, max 255 chars) is called in `enroll`, `uploadAndroidUsageEventData`, and all v4 endpoints. However, it is NOT called in:
- `submitTimeUseDiary` (TimeUseDiaryController)
- `submitQuestionnaireResponses` (SurveyController)
- `submitAppUsageSurvey` (SurveyController)
- Legacy `enrollSource` (ChronicleStudyController)
- Legacy `upload` (ChronicleController, ChronicleControllerV2)

**Impact:** Low -- the participantId is used as a parameterized SQL bind variable, so SQL injection is not possible. But invalid participant IDs could cause data integrity issues.

**Recommendation:** Apply `validateParticipantId()` in all public endpoints that accept participant IDs.

#### L-3: destroyStudy Only Deletes from 3 of 10 Data Tables

**File:** `StudyController.kt`
**Lines:** 587-597

The `destroyStudy` method documents that it only creates deletion jobs for 3 tables (`chronicle_usage_events`, `time_use_diary_submissions`, `app_usage_survey`). Seven tables are not covered: `chronicle_usage_stats`, `preprocessed_usage_events`, `sensor_data`, `android_sensor_data`, `questionnaire_submissions`, `participant_stats`, `upload_buffer`.

**Impact:** Data retention violation -- PHI may remain in the database after study deletion, which is a HIPAA concern.

**Recommendation:** Create deletion job types for all 10 data tables. This is already noted as a TODO in the code.

#### L-4: Unbounded Survey Response Lists

**File:** `SurveyController.kt`, `TimeUseDiaryController.kt`

`submitAppUsageSurvey(@RequestBody surveyResponses: List<AppUsage>)` and `submitTimeUseDiary(@RequestBody responses: List<TimeUseDiaryResponse>)` accept unbounded lists. While the 10MB request size limit in `SecurityHardeningConfig` provides a ceiling, a sufficiently large list within 10MB could still cause memory pressure during deserialization and database insertion.

**Impact:** Potential DoS via large payloads within the 10MB limit.

**Recommendation:** Add `@Size(max = N)` constraints on request body lists.

---

## 3. Security Controls Assessment

### 3.1 Authentication Chain -- STRONG

- HS256 JWT with issuer/audience/timestamp validation
- Cookie-based auth (httpOnly, Secure, SameSite=Strict)
- API key authentication as alternate path
- JWT blocklist for token revocation (HIPAA credential revocation)
- Rate limiting on auth endpoints (5 req/min)

### 3.2 Authorization Model -- STRONG

- AclKey-based permission system (READ, WRITE, OWNER, LINK)
- `AuthorizingComponent` interface enforces access checks in controllers
- `@RequiresStudyAccess` annotation with AOP aspect for newer controllers
- Row-Level Security (RLS) at the database level via `RLSContextFilter`
- Admin access checks for sensitive operations
- Pagination limits enforced via `PaginationDefaults.clampLimit/clampOffset`

### 3.3 Input Validation -- GOOD

- `@Valid` on most `@RequestBody` parameters
- `@Validated` on all controllers
- `validateParticipantId()` regex validation (inconsistently applied -- see L-2)
- `SqlIdentifierValidator` for dynamic table names in import endpoints
- `SecurityHardeningConfig`: null byte blocking, parameter length limits, request size limits
- `JacksonSecurityConfig`: default typing disabled, FAIL_ON_UNKNOWN_PROPERTIES, polymorphic type validator

### 3.4 HMAC Enforcement -- INCOMPLETE (see H-1)

- Well-designed: HMAC-SHA256 with timestamp + nonce + body hash
- Constant-time comparison (timing attack resistant)
- Distributed nonce cache via Hazelcast (replay prevention)
- **But:** Filter targets wrong path prefix; disabled by default; not enforced when enabled

### 3.5 CORS -- STRONG

- Strict origin allowlist (no wildcards with credentials)
- TRACE/TRACK blocked
- Preflight caching
- Development mode flag for local testing

### 3.6 Security Headers -- STRONG

- X-Content-Type-Options, X-Frame-Options, X-XSS-Protection, Referrer-Policy, Permissions-Policy
- Cache-Control: no-cache, no-store
- Defense-in-depth (backup to reverse proxy headers)

### 3.7 Audit Logging -- COMPREHENSIVE

- Dual audit system (legacy `AuditingManager` + new `AuditService`)
- PHI access tracking with field-level granularity
- Success and failure logging on all operations
- Settings change audit trail with before/after values
- Log sanitization via `LogSanitizer`

---

## 4. Summary of Recommended Actions

| Priority | Finding | Action |
|---|---|---|
| **HIGH** | H-1: HMAC path mismatch | Fix `isMobileApiRequest()` to match actual mobile paths; enforce in production |
| **HIGH** | H-2: Testing login lacks profile gate | Add `@Profile("!production")` or `@ConditionalOnProperty` |
| **HIGH** | H-3: Settings endpoint exposes all settings | Restrict to minimum needed settings, or add HMAC/API-key requirement |
| **MEDIUM** | M-2: CSRF cookie not verified server-side | Implement verification filter or remove misleading cookie |
| **MEDIUM** | M-3: Enrollment lacks rate limiting | Add `@RateLimit` to enrollment endpoints |
| **MEDIUM** | M-5: Prometheus unrestricted at app level | Add IP-based filter as defense-in-depth |
| **MEDIUM** | M-6: Twilio webhook lacks signature verification | Validate `X-Twilio-Signature` |
| **LOW** | L-2: Inconsistent participantId validation | Apply `validateParticipantId()` to all public endpoints |
| **LOW** | L-3: Incomplete study deletion | Create deletion jobs for remaining 7 tables |
| **LOW** | L-4: Unbounded list parameters | Add `@Size(max = N)` constraints |

---

## 5. Notable Positive Security Controls

1. **Row-Level Security (RLS):** Database-level enforcement via `RLSContextManager` and PostgreSQL RLS policies provides defense-in-depth beyond application-level authorization.

2. **Jackson hardening:** Polymorphic deserialization disabled by default; strict allowlist when needed; FAIL_ON_UNKNOWN_PROPERTIES prevents mass assignment.

3. **Request size limiting:** Both Content-Length-based and streaming size enforcement (for chunked transfer encoding).

4. **Token revocation:** JWT blocklist with Hazelcast distributed cache; global revocation for secret compromise scenarios.

5. **Comprehensive audit trail:** HIPAA-grade audit logging with PHI field tracking, before/after values for settings changes, and dual audit system for migration safety.

6. **Device identifier stripping:** `EnrollmentService.stripDeviceIdentifiers()` removes `deviceId`, `fcmRegistrationToken`, and `apnDeviceToken` before persisting device metadata, reducing PII exposure in the database.
