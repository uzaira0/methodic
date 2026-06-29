# Firebase Analytics/Crashlytics Replacement Evaluation

**Date:** 2026-04-03
**Task:** #15 -- Evaluate privacy implications and alternatives for Firebase in Chronicle Android

---

## 1. Current Firebase Usage Inventory

### 1.1 Firebase Dependencies (chronicle/app/build.gradle)

```
firebase-bom:34.9.0
firebase-analytics
firebase-crashlytics
firebase-messaging
```

Gradle plugins: `com.google.firebase.crashlytics`

### 1.2 Firebase Analytics Events

All events are defined in `FirebaseAnalyticsEvents.kt` (23 event constants). Each event sends:

| Parameter | Value | Sent to Google? |
|-----------|-------|-----------------|
| `participant_id` | SHA-256 hash, truncated to 16 hex chars (`hashForAnalytics()`) | Yes |
| `study_id` | Full UUID (e.g., `550e8400-e29b-41d4-a716-446655440000`) | Yes |

**Files logging analytics events:**
- `Enrollment.kt` -- ENROLLMENT_SUCCESS, ENROLLMENT_FAILURE
- `UsageMonitoringWorker.kt` -- USAGE_START, USAGE_SUCCESS, USAGE_FAILURE
- `UploadExecutor.kt` -- UPLOAD_SUCCESS, UPLOAD_START, UPLOAD_FAILURE, SUBMIT_FAILURE
- `NotificationsWorker.kt` -- NOTIFICATIONS_START, NOTIFICATIONS_FAILURE
- `SensorUploadWorker.kt` -- SENSOR_UPLOAD_START, SENSOR_UPLOAD_SUCCESS, SENSOR_UPLOAD_FAILURE, SENSOR_UPLOAD_RETRY
- `CombinedUploadWorker.kt` -- upload lifecycle events
- `UploadWorkerDelegate.kt` -- upload lifecycle events
- `ChronicleSink.kt` -- upload events
- `EnrollmentMonitoringWorker.kt` -- ENROLLMENT_MONITOR_SUCCESS, ENROLLMENT_MONITOR_FAILURE

### 1.3 Firebase Crashlytics Usage

**Crash reporting (`recordException`):**
- `Enrollment.kt` -- enrollment failures, generic exceptions
- `UploadWorker.kt` -- upload failures
- `UploadExecutor.kt` -- upload batch errors
- `Utils.kt` -- date parsing errors, UUID validation errors
- `EnrollmentSettings.kt` -- preference read errors
- `UsageMonitoringWorker.kt` -- monitoring failures
- `NotificationsWorker.kt` -- notification delivery failures

**Custom keys set on Crashlytics:**
- `userId` = `hashForAnalytics(participantId)` (16-char hex hash)
- `deviceId` = `hashForAnalytics(deviceId)` (16-char hex hash of server-assigned UUID)
- `studyId` = full study UUID

**Crashlytics log messages:**
- `Enrollment.kt` logs `"caught exception - studyId: \"$studyId\" ; participantId: \"$participantId\""` -- this sends the **plaintext participantId** to Crashlytics log storage.

**Collection control:**
- `MainActivity.kt` explicitly enables: `FirebaseCrashlytics.getInstance().setCrashlyticsCollectionEnabled(true)`

### 1.4 Firebase Cloud Messaging

- `ChronicleFirebaseMessagingService.kt` -- receives push messages (now implementing settings push, Task #11)
- Topic subscriptions at enrollment: `study_{studyId}_settings`
- FCM is infrastructure, not analytics -- it does not send research data to Google

---

## 2. Privacy Risk Assessment

### 2.1 What Goes to Google

| Data | Destination | Risk Level |
|------|------------|------------|
| Hashed participant ID (16 hex chars) | Analytics + Crashlytics | **Medium** -- truncated SHA-256 is not directly reversible, but with a small participant pool (typical studies have 10-500 participants), brute-force reversal is trivial if participant ID format is known |
| Study UUID | Analytics + Crashlytics | **Low** -- UUIDs are opaque, but they link events to specific studies and could be correlated with public study registries |
| Plaintext participantId in crashlytics.log() | Crashlytics | **HIGH** -- `Enrollment.kt` line 247/319 passes raw participantId in log messages sent to Google |
| Hashed device ID | Crashlytics custom keys | **Low** -- server-assigned UUID hash, no real hardware identifier |
| Device model, OS version, app version | Automatic collection by Firebase SDK | **Low** -- standard telemetry, not research-specific |
| Firebase Installation ID (FID) | All Firebase services | **Medium** -- persistent device identifier controlled by Google, can be used for cross-app tracking |
| IP address | All Firebase services | **Medium** -- reveals participant geographic location |

### 2.2 HIPAA/GDPR Implications

- **HIPAA**: Study UUIDs + hashed participant IDs constitute "limited data sets" under HIPAA. Google is a subprocessor but Chronicle likely has no BAA (Business Associate Agreement) with Google for Firebase.
- **GDPR**: Firebase Installation ID and IP address are personal data under GDPR. Requires a lawful basis for transfer to Google (US-based processor). The plaintext participantId in crash logs is a clear violation if participant IDs contain identifying information.
- **IRB**: Most IRBs require disclosure of all third-party data recipients. Firebase Analytics and Crashlytics may not be listed in consent forms.

### 2.3 Immediate Remediation (regardless of replacement decision)

1. **Remove plaintext participantId from crashlytics.log() calls** in `Enrollment.kt` lines 247 and 319. Replace with hashed version.
2. **Disable automatic Firebase Analytics data collection** by adding to `AndroidManifest.xml`:
   ```xml
   <meta-data android:name="firebase_analytics_collection_deactivated" android:value="true" />
   ```
   Then enable selectively only for non-identifying events.

---

## 3. Alternative Evaluation

### 3.1 Self-Hosted Sentry (Crash Reporting Replacement)

**What it provides:** Crash reporting, error tracking, performance monitoring.

**Migration effort:**
- Replace `FirebaseCrashlytics` calls with Sentry SDK (~1 day)
- Deploy self-hosted Sentry (Docker Compose, needs ~4GB RAM minimum) (~0.5 day)
- Sentry Android SDK: `implementation 'io.sentry:sentry-android:7.x'`
- API is similar: `Sentry.captureException(e)` replaces `crashlytics.recordException(e)`

**Advantages:**
- All crash data stays on Chronicle infrastructure
- No data sent to third parties
- Full control over data retention
- No BAA needed with external provider
- Rich error context without privacy concerns

**Disadvantages:**
- Operational burden of self-hosting (database, Redis, Kafka)
- No automatic symbolication for native crashes (can be configured)
- Sentry self-hosted requires ~8GB disk minimum

**Recommendation: Strong candidate.** Sentry's self-hosted option is mature and widely used in healthcare/research. The migration is straightforward since the API patterns are similar.

### 3.2 PostHog (Analytics Replacement)

**What it provides:** Product analytics, event tracking, feature flags, session replay.

**Migration effort:**
- Replace `FirebaseAnalytics.logEvent()` calls with PostHog SDK (~1 day)
- Deploy self-hosted PostHog (Docker Compose + ClickHouse, needs ~8GB RAM) (~1 day)
- PostHog Android SDK: `implementation 'com.posthog:posthog-android:3.x'`

**Advantages:**
- Self-hosted: all data stays on Chronicle infrastructure
- Designed for privacy-first analytics
- Can disable automatic device/geo tracking
- Feature flags could replace FCM settings push for some use cases

**Disadvantages:**
- Heavy infrastructure footprint (ClickHouse is resource-intensive)
- More features than Chronicle needs (session replay, A/B testing)
- Community edition has feature limitations

**Recommendation: Possible but likely overkill.** Chronicle's analytics needs are simple (event counts by type). A lighter solution may suffice.

### 3.3 Plausible Analytics

**Not applicable.** Plausible is web-only analytics. No Android SDK. Not a viable replacement.

### 3.4 Keep Firebase, Strip All Identifiers

**Migration effort:**
- Remove participant_id and study_id from all analytics events (~0.5 day)
- Remove Crashlytics custom keys and log messages containing identifiers (~0.5 day)
- Disable Firebase automatic data collection, re-enable only for anonymous events
- Add `firebase_analytics_collection_deactivated` to manifest
- Use `FirebaseAnalytics.setAnalyticsCollectionEnabled()` with explicit opt-in

**Advantages:**
- Minimal code changes
- Keep Firebase infrastructure (FCM, crash monitoring)
- No new infrastructure to deploy

**Disadvantages:**
- Crash reports become less useful without study/participant context
- Analytics events become purely aggregate counts
- Still sends Firebase Installation ID and IP to Google
- BAA with Google still advisable for HIPAA compliance
- Trust model: relying on Google to honor data collection settings

**Recommendation: Acceptable short-term solution**, but does not fully address the subprocessor/BAA concern.

### 3.5 Hybrid Approach (Recommended)

| Function | Current | Recommended | Rationale |
|----------|---------|-------------|-----------|
| Crash reporting | Firebase Crashlytics | Self-hosted Sentry | Full crash context without sending identifiers to Google |
| Analytics | Firebase Analytics | Chronicle backend audit logs | Analytics events already correspond to backend-logged actions; no need for client-side analytics |
| Push messaging | Firebase Cloud Messaging | **Keep FCM** | FCM carries no research data, only trigger messages; no viable self-hosted alternative for Android push |
| Remote config | N/A | **Keep using FCM topics** (Task #11) | Study settings push via FCM data messages is the right pattern |

---

## 4. Recommended Implementation Plan

### Phase 1: Immediate (no infrastructure changes)
1. Remove plaintext participantId from Crashlytics log messages
2. Replace `hashForAnalytics(participantId)` in Crashlytics userId with a non-reversible session token
3. Stop sending study_id and participant_id to Firebase Analytics events (log only event names)
4. Add `firebase_analytics_collection_deactivated` to AndroidManifest.xml

### Phase 2: Medium-term (1-2 sprints)
5. Deploy self-hosted Sentry alongside Chronicle containers
6. Replace all `FirebaseCrashlytics` calls with Sentry SDK
7. Remove `firebase-crashlytics` and `firebase-analytics` dependencies
8. Keep only `firebase-messaging` for FCM push

### Phase 3: Validation
9. Verify no identifying data reaches Google (proxy/MITM test on Firebase traffic)
10. Update IRB documentation to remove Firebase as a data recipient
11. Update COMPLIANCE-MATRIX.md with new crash reporting architecture
12. Update privacy policy / consent forms

### Estimated Effort
- Phase 1: 0.5 day
- Phase 2: 2-3 days (including Sentry deployment and Docker Compose integration)
- Phase 3: 1 day

---

## 5. Files Requiring Changes

### Android app (chronicle/app/src/main/)
- `java/com/openlattice/chronicle/Enrollment.kt` -- analytics + crashlytics
- `java/com/openlattice/chronicle/MainActivity.kt` -- crashlytics init
- `java/com/openlattice/chronicle/utils/Utils.kt` -- crashlytics exception recording
- `java/com/openlattice/chronicle/preferences/EnrollmentSettings.kt` -- crashlytics custom keys
- `java/com/openlattice/chronicle/services/usage/UsageMonitoringWorker.kt` -- analytics + crashlytics
- `java/com/openlattice/chronicle/services/upload/UploadWorker.kt` -- crashlytics
- `java/com/openlattice/chronicle/services/upload/UploadExecutor.kt` -- analytics + crashlytics
- `java/com/openlattice/chronicle/services/upload/CombinedUploadWorker.kt` -- analytics + crashlytics
- `java/com/openlattice/chronicle/services/upload/UploadWorkerDelegate.kt` -- analytics + crashlytics
- `java/com/openlattice/chronicle/services/notifications/NotificationsWorker.kt` -- analytics + crashlytics
- `java/com/openlattice/chronicle/services/enrollment/EnrollmentMonitoringWorker.kt` -- analytics
- `java/com/openlattice/chronicle/services/sinks/ChronicleSink.kt` -- analytics
- `java/com/openlattice/chronicle/services/sensors/SensorUploadWorker.kt` -- analytics
- `kotlin/com/openlattice/chronicle/constants/FirebaseAnalyticsEvents.kt` -- event constants
- `AndroidManifest.xml` -- Firebase metadata

### Infrastructure (docker/)
- New Sentry Docker Compose service (Phase 2)

### Documentation (docs/)
- `COMPLIANCE-MATRIX.md` -- update crash reporting control
- `SECURITY-HARDENING-RECOMMENDATIONS.md` -- track progress
