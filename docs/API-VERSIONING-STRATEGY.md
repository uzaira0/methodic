# API Versioning Strategy

**Date**: 2026-04-05
**Scope**: Chronicle server API versions (legacy v1, v2, v3, v4) and Android/iOS client compatibility

---

## Current State Inventory

### API Version Layers

The server exposes four API version layers:

| Version | Base Path | Controller | Status |
|---------|-----------|------------|--------|
| **Legacy v1** | `/chronicle/study/` | `ChronicleStudyController` | Active -- used by old enrolled devices |
| **Legacy v2** | `/chronicle/v2/` | `ChronicleControllerV2` | Active -- EDM property resolution |
| **v3** | `/chronicle/v3/study/` | `StudyController` | Active -- primary API |
| **v4** | `/chronicle/v4/study/` | `StudyV4Controller` | Active -- device data endpoints |

### Endpoint Inventory

#### v3-only endpoints (StudyController on `/v3/study`)

These endpoints exist only in v3 and have no v4 equivalent:

| Method | Path | Purpose | Auth Required |
|--------|------|---------|---------------|
| POST | `/` | Create study | Yes |
| GET | `/{studyId}` | Get study | Yes (read) |
| PATCH | `/{studyId}` | Update study | Yes (owner) |
| DELETE | `/{studyId}` | Destroy study | Yes (owner) |
| GET | `/organization/{orgId}` | Get org studies | Yes (read) |
| GET | `/` | Get all studies | Yes |
| GET | `/{studyId}/settings` | Get study settings | Yes |
| GET | `/{studyId}/settings/type/{type}` | Get study setting by type | Varies |
| PATCH | `/{studyId}/settings/type/{type}` | Update study settings | Yes |
| GET | `/{studyId}/settings/audit` | Settings audit trail | Yes (read) |
| GET | `/{studyId}/permissions` | Get study permissions | Yes (owner) |
| POST | `/{studyId}/permissions` | Update study permissions | Yes (owner) |
| PUT | `/{studyId}/data-collection/` | Set data collection settings | Yes |
| POST | `/{studyId}/participant` | Register participant | Yes |
| DELETE | `/{studyId}/participants` | Delete participants | Yes |
| GET | `/{studyId}/participants` | List participants | Yes |
| GET | `/{studyId}/participants/stats` | Participant stats | Yes |
| GET | `/{studyId}/participants/data` | Get participant data | Yes |
| PATCH | `/{studyId}/participant/{pid}/status` | Update participation status | Yes |
| PATCH | `/{studyId}/participant/{pid}/annotations` | Update annotations | Yes |
| GET | `/{studyId}/participant/{pid}/verify` | Verify participant | No |
| GET | `/{studyId}/settings/sensors` | Get study sensors (deprecated) | No |
| GET | `/{studyId}/settings/type/AndroidSensor` | Get Android sensor settings | No |
| GET | `/{studyId}/devices` | Get study devices | Yes (read) |
| GET | `/{studyId}/android/sensors/availability` | Get sensor availability | Yes (read) |

#### v3 deprecated endpoints (replaced by v4)

| v3 Method | v3 Path | v4 Replacement | Change |
|-----------|---------|----------------|--------|
| POST | `/{studyId}/participant/{pid}/{deviceId}/enroll` | `/{studyId}/participant/{pid}/enroll` | Device ID moved from path to `X-Chronicle-Device-Id` header |
| POST | `/{studyId}/participant/{pid}/android/{deviceId}` | `/{studyId}/participant/{pid}/android` | Device ID moved to header |
| POST | `/{studyId}/participant/{pid}/android/{deviceId}/sensors` | `/{studyId}/participant/{pid}/android/sensors` | Device ID moved to header |
| POST | `/{studyId}/participant/{pid}/android/{deviceId}/sensors/availability` | `/{studyId}/participant/{pid}/android/sensors/availability` | Device ID moved to header |
| POST | `/{studyId}/participant/{pid}/ios/{deviceId}` | `/{studyId}/participant/{pid}/ios` | Device ID moved to header |

#### v4-only endpoints (StudyV4Controller on `/v4/study`)

| Method | Path | Purpose |
|--------|------|---------|
| POST | `/{studyId}/participant/{pid}/enroll` | Enroll device (device ID via header) |
| POST | `/{studyId}/participant/{pid}/android` | Upload Android usage events |
| POST | `/{studyId}/participant/{pid}/android/sensors` | Upload Android sensor data |
| POST | `/{studyId}/participant/{pid}/android/sensors/availability` | Report sensor availability |
| POST | `/{studyId}/participant/{pid}/ios` | Upload iOS sensor data |

#### Legacy v1 endpoints (ChronicleStudyController on `/chronicle/study`)

| Method | Path | Purpose | Used By |
|--------|------|---------|---------|
| POST | `/{studyId}/{pid}/{datasourceId}` | Enroll source | Old Android app versions |
| GET | `/{studyId}/{pid}/{datasourceId}` | Is known datasource | Old Android app versions |
| GET | `/{studyId}/notifications` | Notifications enabled | Current Android app |
| GET | `/{studyId}/{pid}/status` | Participation status | Current Android app |
| GET | `/{studyId}/questionnaires` | Study questionnaires | Current Android app |

#### Legacy v2 endpoints (ChronicleControllerV2 on `/chronicle/v2`)

| Method | Path | Purpose | Used By |
|--------|------|---------|---------|
| POST | `/edm` | Get property type IDs | Current Android app |
| POST | `/{studyId}/{pid}/{datasourceId}` | Upload data | Old clients |
| GET | `/{studyId}/{pid}/{datasourceId}` | Is known datasource | Old clients |
| GET | `/status` | Health check | Monitoring |

---

## Android App Current API Usage

Based on `ChronicleStudyApi.kt` (app version 46, `2026-02-12`), the Android app calls:

| Endpoint | Version Used |
|----------|-------------|
| Enroll device | **v4** (header-based) |
| Verify participant | **v3** |
| Upload usage events | **v4** (header-based) |
| Upload sensor data | **v4** (header-based) |
| Get sensor settings | **v3** |
| Report sensor availability | **v4** (header-based) |
| Get participation status | **Legacy v1** |
| Is notifications enabled | **Legacy v1** |
| Get questionnaires | **Legacy v1** |
| Get property type IDs | **Legacy v2** |

**Key finding**: The current Android app (v46) still depends on legacy v1 and v2 endpoints for participation status, notifications, questionnaires, and EDM resolution.

---

## Recommended Deprecation Timeline

### Phase 1: Migrate legacy v1/v2 endpoints to v3/v4 (Q2 2026)

**Target**: App version 48+

1. Add v3 endpoints for:
   - `GET /v3/study/{studyId}/participant/{pid}/status` (already exists as PATCH; add GET)
   - `GET /v3/study/{studyId}/notifications` (new)
   - `GET /v3/study/{studyId}/questionnaires` (new)
2. Add v3 endpoint for EDM resolution or embed property type IDs in the study settings response.
3. Update Android app to use v3/v4 exclusively.
4. Mark legacy v1/v2 endpoints as `@Deprecated` with deprecation logging.

### Phase 2: v3 deprecated endpoint sunset (Q3 2026)

**Target**: 90 days after app version 48 reaches >95% adoption

1. Add deprecation response headers (`Deprecation: true`, `Sunset: <date>`) to v3 deprecated endpoints (device ID in path).
2. Log deprecated endpoint usage with study ID and app version for tracking.
3. After sunset date, return `410 Gone` for v3 deprecated endpoints.

### Phase 3: Legacy v1/v2 shutdown (Q4 2026)

**Target**: 180 days after Phase 1 app version reaches >99% adoption

1. Return `410 Gone` for all legacy v1/v2 endpoints.
2. Remove `ChronicleStudyController`, `ChronicleController`, and `ChronicleControllerV2`.

---

## Minimum App Version Enforcement

### Mechanism: HTTP 426 Upgrade Required

Add a servlet filter or Spring interceptor that:

1. Reads the `User-Agent` or a custom `X-Chronicle-App-Version` header from mobile requests.
2. Compares against a configurable minimum version (stored in DB or config).
3. Returns `426 Upgrade Required` with a JSON body if the app version is below minimum:

```json
{
  "error": "upgrade_required",
  "message": "Please update the Chronicle app to continue.",
  "minimumVersion": 48,
  "updateUrl": "https://play.google.com/store/apps/details?id=com.openlattice.chronicle"
}
```

### Implementation Sketch

```kotlin
@Component
class MinimumAppVersionFilter(
    private val configService: ConfigService
) : OncePerRequestFilter() {

    override fun doFilterInternal(
        request: HttpServletRequest,
        response: HttpServletResponse,
        filterChain: FilterChain
    ) {
        val appVersion = request.getHeader("X-Chronicle-App-Version")?.toIntOrNull()
        val minVersion = configService.getMinimumAppVersion()

        if (appVersion != null && appVersion < minVersion) {
            response.status = 426
            response.contentType = "application/json"
            response.writer.write("""{"error":"upgrade_required","minimumVersion":$minVersion}""")
            return
        }

        filterChain.doFilter(request, response)
    }
}
```

### App-Side Requirements

1. The Android app must send `X-Chronicle-App-Version: <versionCode>` on every request.
2. The app must handle 426 responses by showing an update prompt with a Play Store link.
3. The app should gracefully degrade (retry, queue uploads) if the update is not immediate.

---

## Migration Checklist for Clients

### Android App

- [ ] Add `X-Chronicle-App-Version` header to Retrofit `OkHttpClient` interceptor
- [ ] Replace legacy v1 `getParticipationStatus` with v3 equivalent
- [ ] Replace legacy v1 `isNotificationsEnabled` with v3 equivalent
- [ ] Replace legacy v1 `getStudyQuestionnaires` with v3 equivalent
- [ ] Replace legacy v2 `getPropertyTypeIds` with v3 equivalent or embedded config
- [ ] Handle HTTP 426 response with update prompt UI
- [ ] Remove all legacy v1/v2 endpoint references from `ChronicleStudyApi.kt`
- [ ] Bump `versionCode` to 48+ for the migrated release

### Web Frontend

- [ ] Verify all API calls use `/v3/` paths (current state: confirmed via `getApiBaseUrl.js`)
- [ ] No action needed -- web frontend already uses v3 exclusively

### iOS App (if applicable)

- [ ] Same migration as Android for any legacy endpoint usage
- [ ] Add `X-Chronicle-App-Version` header

### Server

- [ ] Create v3 equivalents of legacy v1 endpoints still in use
- [ ] Add `MinimumAppVersionFilter` with configurable version threshold
- [ ] Add deprecation logging to all legacy endpoints
- [ ] Add `Deprecation` and `Sunset` response headers to deprecated v3 endpoints
- [ ] Create monitoring dashboard for deprecated endpoint call volume
- [ ] Schedule legacy controller removal after adoption thresholds are met
