# Chronicle Data Collection Modularization Refactor Plan

Date: 2026-05-20

Status: planning artifact only. Do not enact this plan from this document alone without an explicit execution request.

Skills encoded:

- `$outcome-driven-execution`: every phase has an outcome, acceptance checks, constraints, starting evidence, proof steps, and commit boundary.
- `$review-fixes`: every subphase ends with review/fix/verify before the next subphase begins.
- `$testing-encyclopedia`: every subphase includes correctness, integration, migration, security, resilience, and CI test obligations relevant to this repo.

## 0. Executive Decision Record

1. The refactor target is a modular, first-class Android data collection platform, not a quick package rename.
2. The current dirty state must be checkpointed before refactoring.
3. Submodules must be committed before the root repo records their pointer updates.
4. The first checkpoint commit is allowed to include all current dirty work because that is the selected boundary.
5. The refactor must preserve BCM local-hosting behavior.
6. The refactor must not spend implementation time on Twilio, Redshift, AWS/S3, Firebase/FCM, Alertmanager receivers, cloud deployment, or hosted staging.
7. Firebase classes that still exist in the Android app are legacy app code; do not expand Firebase usage during this work.
8. Public upload endpoints remain stable during this refactor.
9. Room schema compatibility is mandatory.
10. Already queued usage and sensor rows must survive the refactor.
11. Already enrolled devices must continue uploading without re-enrollment.
12. ActivityClass remains first-class on usage rows.
13. Device lifecycle events remain represented as system-origin usage-style events throughout this refactor.
14. Sensor inventory remains full for modeled Chronicle sensors.
15. Vendor/private Samsung sensors remain opt-in via settings and existing modeled sensor enums.
16. No screenshots, accessibility text, raw notifications, GPS, microphone, contacts, call logs, SMS, or browser history are introduced.
17. New collection modules must have explicit privacy classification and tests before activation.
18. Every subphase must end in review-fixes plus tests and guardrails.
19. Every subsubphase that touches code must add or update Semgrep and/or ast-grep guardrails where a regression class can be statically expressed.
20. No skipped test is allowed; an unavailable external system must be recorded as a blocker and replaced with the strongest local proof.
21. Every numbered implementation step inside a subphase is treated as a subsubphase.
22. A code-touching numbered step cannot be marked complete until its narrow test, static guardrail decision, and local review are complete.

## 1. Current Repo Findings

### 1.1 Git and Module State

1. Root branch is `develop...origin/develop`.
2. Root has dirty tracked files including `AGENTS.md`, `HANDOFF.md`, Docker/Traefik files, security scripts, docs, Gradle verification metadata, and Gradle conventions.
3. Root has untracked dogfood and mobile guardrail scripts.
4. Submodules `chronicle`, `chronicle-api`, `chronicle-server`, `chronicle-web`, `rhizome`, and `rhizome-client` are dirty from the root perspective.
5. `chronicle` Android submodule is on `develop` and includes mobile collection, sensor, Room, and dogfood changes.
6. `chronicle-models` exists as a local composite build dependency for Android/API/server model contracts.
7. `chronicle-api` has API/model tests related to Android sensor and usage event enum contracts.
8. `chronicle-server` has backend upload, settings, RLS, and security changes.
9. The root Gradle build aggregates `chronicle-api` and `chronicle-server`.
10. The Android app uses a composite build for local `chronicle-api` and `chronicle-models`.

### 1.2 Mobile Collection State

1. `ChronicleSensor` is still a pull interface with `poll(currentPollTimestamp, users)`.
2. `UsageEventsChronicleSensor` queries `UsageStatsManager.queryEvents`.
3. `UsageEventsChronicleSensor` maps Android event `className` into `activityClass`.
4. `UsageEventsChronicleSensor` stores a usage-events checkpoint in encrypted prefs.
5. `UsageMonitoringWorker` owns usage polling and direct queue writes.
6. `DeviceStateSampler` derives battery, network, power-save, screen, and keyguard state.
7. `DeviceLifecycleEventRecorder` writes lifecycle events directly to `dataQueue`.
8. `DeviceLifecycleEventRecorder` dedupes recent events with shared prefs.
9. `DeviceLifecycleReceiver` delegates broadcasts to lifecycle recorder/state sampler.
10. `PowerSaveModeReceiver` directly starts/stops `HardwareSensorService`.
11. `StartOnBoot`, `MainActivity`, `Enrollment`, and `SettingsActivity` directly start services/workers.
12. `HardwareSensorService` is a foreground service for hardware sensor collection.
13. `HardwareSensorService` owns a `SensorManager` listener lifecycle.
14. `HardwareSensorService` keeps the Methodic-style power-saver degraded mode.
15. `HardwareSensorService` stops collection at critical battery threshold.
16. `HardwareSensorService` buffers sensor samples in memory, then writes to `sensor_samples`.
17. `HardwareSensorService` also registers lifecycle receivers.
18. `SensorSettingsRefreshWorker` fetches `AndroidSensor` settings from the server.
19. `SensorSettingsRefreshWorker` starts/stops `HardwareSensorService` directly.
20. `SensorAvailabilityReporter` reports modeled Android sensor inventory.
21. `SensorUploadWorkerDelegate` uploads rows from `sensor_samples`.
22. `CombinedUploadWorker` coalesces usage and sensor upload paths.
23. `UploadExecutor` maps `ExtractedUsageEvent` to `ChronicleUsageEvent`.
24. `UploadExecutor` forwards `datum.activityClass`.
25. `ChronicleDb` is SQLCipher-backed Room version 9.
26. `ChronicleDb` includes `dataQueue`, `sensor_samples`, `upload_servers`, `upload_stats`, and usage poll checkpoints.
27. `UploadServerEntity` stores per-server auth mode, API key, cursors, failures, and upload timestamps.
28. Android unit tests exist for serialization, signing, sensor mapping, lifecycle recorder, sync strategy, and usage collection.
29. Android instrumented tests exist for Room and upload behavior.
30. Maestro flows exist for enrollment, settings, re-enrollment, and multi-server behavior.

### 1.3 Backend/API/Model State

1. Mobile enroll route is `POST /chronicle/v4/study/{studyId}/participant/{participantId}/enroll`.
2. Usage upload route is `POST /chronicle/v4/study/{studyId}/participant/{participantId}/android`.
3. Sensor upload route is `POST /chronicle/v4/study/{studyId}/participant/{participantId}/android/sensors`.
4. Sensor availability route is `POST /chronicle/v4/study/{studyId}/participant/{participantId}/android/sensors/availability`.
5. Android sensor settings route is `GET /chronicle/v3/study/{studyId}/settings/type/AndroidSensor`.
6. `StudySettingType` already includes `DataCollection`, `Sensor`, `AndroidSensor`, `DataQuality`, and `Pipeline`.
7. `AndroidSensorSetting` currently contains enabled sensors, sampling rate, active seconds, and duty cycle period.
8. `AndroidSensorType` already models accelerometer, gyroscope, magnetometer, gravity, linear acceleration, rotation vector, step counter, light, proximity, significant motion, tilt detector, screen orientation, and Samsung/private modeled sensors.
9. `ChronicleUsageEvent` contains nullable `activityClass`.
10. Backend stores `activity_class` through migration `V22__add_usage_event_activity_class.sql`.
11. `AppDataUploadService` validates enrolled participants and known data sources.
12. `AppDataUploadService` enforces upload batch size.
13. `AndroidSensorDataUploadService` stores sensor payload batches in upload buffer.
14. `MoveToEventStorageTask` moves Android usage upload buffer data into Postgres event storage.
15. `MoveAndroidSensorDataToStorageTask` moves Android sensor upload buffer data into sensor storage.
16. Backend tests include serialization, controller, E2E, fuzz, property, RLS, data quality, and migration tests.
17. Security rules include Semgrep for RLS, SQL injection, proxy headers, mobile config, export injection, file upload, ReDoS, and broad CWE patterns.
18. Security guardrails include ast-grep rules for RLS misuse.
19. The security runner exposes layers: `sast`, `sca`, `secrets`, `iac`, `sso`, `mobile`, `auth`, `injection`, `crypto`, `license`, `compliance`.
20. CI has JVM smoke, web quality, dependency scan, Android APK build, Maestro Android tests, and security suite workflows.

## 2. Universal Execution Rules

### 2.1 Outcome-Driven Control State

Maintain this control state during execution:

1. Current hypothesis.
2. Last evidence.
3. Next proof step.
4. Risk to direction.
5. Autonomy status: `active`, `blocked`, or `done`.
6. Active phase.
7. Active subphase.
8. Active subsubphase.
9. Files intentionally touched.
10. Files read for contract verification.
11. Commands run.
12. Tests passed.
13. Tests failed.
14. Guardrails added.
15. Guardrails run.
16. Review-fixes findings.
17. Review-fixes fixes.
18. Review-fixes skips.
19. Commit hash for completed boundary.
20. Residual risks.

### 2.2 Review-Fixes Gate After Every Subphase

Run this after every subphase:

1. Capture `git diff` for the subphase.
2. Review for code reuse.
3. Review for code quality.
4. Review for efficiency.
5. Review for silent failures.
6. Review callers and callees.
7. Review idempotency.
8. Review async correctness.
9. Review dead code.
10. Fix actionable findings.
11. Re-read every file modified by the fixes.
12. Verify no fix introduced a new bug.
13. Verify no caller contract changed accidentally.
14. Verify no new duplication was introduced.
15. Verify types and imports still compile.
16. Record skipped findings with reason.
17. Run subphase narrow tests again.
18. Run applicable Semgrep/ast-grep guardrails again.
19. Commit only if the subphase boundary is clean and planned for commit.
20. Update execution notes.

### 2.3 Testing Encyclopedia Gate After Every Subphase

Run or add all applicable checks from this catalog:

1. Unit tests for changed pure logic.
2. Integration tests for service/DAO/API boundaries.
3. Android instrumented tests for Room, WorkManager, foreground services, and upload behavior.
4. Backend Testcontainers tests for upload/settings/storage.
5. Serialization tests for DTO and settings wire formats.
6. Contract/API parity tests for controller/spec path changes.
7. Migration tests for Room and Postgres schema changes.
8. Golden or snapshot tests for generated diagnostics/report payloads.
9. Property tests for parsers, validators, module setting normalization, and upload cursor behavior.
10. Fuzz tests for request parsing and malformed payload handling.
11. Type/static checks through Gradle/Kotlin compilation.
12. Lint/static analysis where configured.
13. Secret detection for new scripts/config.
14. SAST through Semgrep.
15. ast-grep guardrails for structural Kotlin mistakes.
16. Dependency/SCA checks when build/dependency files change.
17. Container/IaC checks when Docker or Traefik files change.
18. Offline/retry/idempotency tests for upload and queue behavior.
19. Crash recovery tests for local persistence changes.
20. Battery/performance tests for sensor/runtime behavior.

### 2.4 Static Guardrail Rule

For every code subsubphase, decide whether a regression class can be encoded as a rule:

1. If yes, add or update a Semgrep rule.
2. If yes and structural Kotlin matching is better, add or update an ast-grep rule.
3. If a shell/file-content guardrail is more reliable, add or update a security guardrail script.
4. If no static rule is feasible, add a test explaining why behavior must be runtime-verified.
5. Every new rule must have a positive fixture or source pattern it would catch.
6. Every new rule must have at least one allowed path or exception if legacy code must remain.
7. Every rule must run locally through `tests/security/run-all-security.sh` or a subscript it calls.
8. Rules must scan local-deployment paths only; ignored third-party feature paths stay outside new rule scope.
9. Rules must not depend on Redshift/AWS/Twilio/Firebase/Alertmanager being active.
10. Rule failures must block phase completion.

### 2.5 Subsubphase Completion Gate

Apply this gate to every numbered step that changes code, config, schema, scripts, CI, or tests:

1. Re-read the immediate file being changed.
2. Re-read the direct callers.
3. Re-read the direct callees.
4. Identify the narrowest unit or integration test that proves the step.
5. Add the missing narrow test before or with the behavior change.
6. Run the narrow test.
7. Decide whether a Semgrep rule can prevent the regression class.
8. Decide whether an ast-grep rule can prevent the regression class.
9. Add or update the static guardrail when it can be expressed deterministically.
10. Run the changed guardrail.
11. Confirm the step did not alter public API, except in Phase 9 where OpenAPI and contract tests are mandatory.
12. Confirm the step did not alter upload wire shape; this refactor preserves usage and sensor upload payloads.
13. Confirm the step did not add a new permission; permission additions are out of scope for this refactor.
14. Confirm the step did not weaken redaction.
15. Confirm the step did not bypass RLS or upload authorization.
16. Confirm no ignored third-party feature was expanded.
17. Inspect `git diff` for the step.
18. Record proof evidence in execution notes.
19. Leave the worktree in a state that can be reviewed.
20. Continue to the next numbered step only after all applicable items above are true.

## 3. Phase 0: Preflight and Checkpoint Commit

### 3.1 Subphase 0A: Freeze Current Reality

Steps:

1. Run `git status --short --branch`.
2. Run `git submodule status --recursive`.
3. Run `git -C chronicle status --short --branch`.
4. Run `git -C chronicle-api status --short --branch`.
5. Run `git -C chronicle-server status --short --branch`.
6. Run `git -C chronicle-web status --short --branch`.
7. Run `git -C rhizome status --short --branch`.
8. Run `git -C rhizome-client status --short --branch`.
9. Record dirty tracked files.
10. Record untracked files.
11. Record current HEADs.
12. Record local branches.
13. Record remotes.
14. Record submodule pointer diffs.
15. Record ignored build artifacts that must not be committed.
16. Confirm `.kotlin/` is build cache and not part of checkpoint.
17. Confirm no keystore or signing secret files are staged.
18. Confirm no APK binary is staged.
19. Confirm no DB dumps are staged.
20. Confirm no `.env` with secrets is staged.

Acceptance checks:

1. A checkpoint inventory exists in execution notes.
2. Every dirty repo/submodule is accounted for.
3. Every untracked file is classified as commit, ignore, or leave untracked.
4. No secret-bearing file is staged.
5. Review-fixes gate completes with no code changes.

### 3.2 Subphase 0B: Baseline Build/Test Before Checkpoint

Steps:

1. Export `JAVA_HOME=/home/uzair/.local/jdks/temurin-21`.
2. Run `./gradlew projects --no-daemon`.
3. Run `./gradlew :chronicle-api:validateOpenApiSpec --no-daemon`.
4. Run `./gradlew :chronicle-api:test --no-daemon`.
5. Run `./gradlew :chronicle-server:test --no-daemon`.
6. Run `./gradlew :chronicle-server:jacocoTestReport --no-daemon`.
7. Run `(cd chronicle && ./gradlew :app:testDebugUnitTest --no-daemon)`.
8. Run `(cd chronicle && ./gradlew :app:assembleDebug --no-daemon)`.
9. Run Android instrumented tests on available emulator/tablet: `(cd chronicle && ./gradlew :app:connectedDebugAndroidTest --no-daemon)`.
10. Run `tests/security/run-all-security.sh sast build/security/sast`.
11. Run `tests/security/run-all-security.sh mobile build/security/mobile`.
12. Run `tests/security/run-all-security.sh auth build/security/auth`.
13. Run `tests/security/run-all-security.sh injection build/security/injection`.
14. Run `tests/security/run-all-security.sh crypto build/security/crypto`.
15. Run `tests/security/run-all-security.sh compliance build/security/compliance`.
16. Run `tests/security/run-all-security.sh license build/security/license`.
17. Run `tests/security/run-all-security.sh secrets build/security/secrets`; install `gitleaks` first when missing.
18. Run `tests/security/run-all-security.sh iac build/security/iac`; install `checkov` and `hadolint` first when missing.
19. Run `tests/security/run-all-security.sh sca build/security/sca`; restore or install Bun dependencies first when missing.
20. Record every unavailable tool as a blocker or install prerequisite, not as a pass.

Acceptance checks:

1. Baseline pass/fail table exists.
2. No refactor begins with unknown baseline.
3. Essential failures are fixed before checkpoint or documented as external blockers.
4. Security mobile guardrails pass.
5. RLS guardrails pass.

### 3.3 Subphase 0C: Checkpoint Commit Current Dirty Work

Steps:

1. Commit each dirty submodule first.
2. In `chronicle`, stage only intended files.
3. In `chronicle`, commit mobile dogfood/collection/security state.
4. In `chronicle-api`, stage only intended files.
5. In `chronicle-api`, commit API/model test state.
6. In `chronicle-server`, stage only intended files.
7. In `chronicle-server`, commit backend/security/local-hosting state.
8. In `chronicle-web`, stage only intended files.
9. In `chronicle-web`, commit web state if dirty changes are intentional.
10. In `rhizome`, stage only intended files.
11. In `rhizome`, commit intentional changes.
12. In `rhizome-client`, stage only intended files.
13. In `rhizome-client`, commit intentional changes.
14. Return to root.
15. Stage root files and updated submodule pointers.
16. Exclude build caches and secret material.
17. Commit root checkpoint.
18. Run `git status --short --branch`.
19. Run `git submodule status --recursive`.
20. Record checkpoint commit hashes.

Acceptance checks:

1. Root and submodules have no unintended dirty changes.
2. Checkpoint commits are isolated.
3. Root points to committed submodule SHAs.
4. No destructive Git command was used.
5. Review-fixes gate confirms the checkpoint contains only intended changes.

## 4. Phase 1: Architecture Boundary Specification

### 4.1 Subphase 1A: Define Module Taxonomy

Steps:

1. Define module ID naming rules.
2. Define stable IDs for `usage_events`.
3. Define stable IDs for `device_lifecycle`.
4. Define stable IDs for `hardware_sensors`.
5. Define stable IDs for `user_identification`.
6. Define stable IDs for `upload_telemetry`.
7. Define stable IDs for `sensor_availability`.
8. Define reserved IDs for known future modules and mark them inactive.
9. Define privacy classes.
10. Mark usage events as metadata/behavioral and study-controlled.
11. Mark device lifecycle as device-state metadata.
12. Mark hardware sensors as physical telemetry.
13. Mark user identification as local participant-label metadata.
14. Mark upload telemetry as operational diagnostics.
15. Mark sensor availability as device capability metadata.
16. Define disallowed-by-default sources.
17. Define allowed fields per module.
18. Define required diagnostics per module.
19. Define required tests per module.
20. Define required guardrails per module.

Static guardrails:

1. Semgrep rule: every new Android collection module class must declare module ID and privacy class.
2. ast-grep rule: module IDs must be enum/constant references, not raw duplicated string literals.
3. Shell guardrail: list known modules and fail if unknown package paths appear under collection modules.

Acceptance checks:

1. Module taxonomy exists in docs and code design notes.
2. No implementation change is part of planning; implementation changes happen only during the execution phase.
3. Review-fixes gate passes.

### 4.2 Subphase 1B: Define Shared Contracts

Steps:

1. Decide shared DTO location in `chronicle-models`.
2. Keep `StudySettingType.AndroidSensor`.
3. Add or reuse generalized `StudySettingType.DataCollection` only with backward compatibility.
4. Define `AndroidDataCollectionSetting`.
5. Define per-module setting entry.
6. Define module enabled flag.
7. Define collection cadence.
8. Define upload cadence.
9. Define battery policy.
10. Define network policy.
11. Define sensor-specific policy bridge.
12. Define diagnostics fields.
13. Define defaults.
14. Define serialization annotations.
15. Define unknown-module behavior.
16. Define missing-setting behavior.
17. Define legacy AndroidSensor fallback.
18. Define server-to-client precedence.
19. Define client local override policy.
20. Define audit/change summary needs.

Static guardrails:

1. Semgrep rule: study settings polymorphic DTOs must use explicit safe Jackson type handling.
2. Semgrep rule: Android collection settings must not include raw secret fields.
3. ast-grep rule: setting resolution cannot default privacy-sensitive modules to enabled.

Acceptance checks:

1. Serialization plan covers API/server/mobile.
2. Defaults are safe and backward compatible.
3. Review-fixes gate passes.

### 4.3 Subphase 1C: Define Mobile Internal Interfaces

Steps:

1. Define `DataCollectionModule`.
2. Define `CollectionModuleId`.
3. Define `CollectionPrivacyClass`.
4. Define `CollectionModuleStatus`.
5. Define `CollectionModuleDiagnostics`.
6. Define `CollectionSettingsResolver`.
7. Define `CollectionSink`.
8. Define `UsageEventSink`.
9. Define `SensorSampleSink`.
10. Define `CollectionModuleRegistry`.
11. Define `CollectionModuleManager`.
12. Define `CollectionScheduler`.
13. Define `CollectionUploadCoordinator`.
14. Define `CollectionLifecycleBridge`.
15. Define `CollectionBootCoordinator`.
16. Define `CollectionBatteryPolicy`.
17. Define `CollectionNetworkPolicy`.
18. Define failure result types.
19. Define logging/diagnostics contract.
20. Define no-op disabled module behavior.

Static guardrails:

1. ast-grep rule: direct calls to `HardwareSensorService.startService` outside the module manager are forbidden after migration.
2. ast-grep rule: direct calls to `DeviceLifecycleEventRecorder.recordAsync` outside lifecycle module are forbidden after migration.
3. ast-grep rule: direct writes to `queueEntryData().insertEntry` outside approved sinks/tests are forbidden after migration.

Acceptance checks:

1. Interfaces can be implemented without changing current runtime behavior.
2. Callers/callees are mapped before code movement.
3. Review-fixes gate passes.

### 4.4 Subphase 1D: Define Backend/API Compatibility

Steps:

1. Preserve v4 enrollment endpoint.
2. Preserve v4 Android usage endpoint.
3. Preserve v4 Android sensor endpoint.
4. Preserve v4 Android sensor availability endpoint.
5. Preserve v3 AndroidSensor settings endpoint.
6. Add generalized settings read only after existing endpoint remains green.
7. Do not require app update before server accepts old payloads.
8. Keep `ChronicleUsageEvent.activityClass`.
9. Keep upload batch limit behavior.
10. Keep participant/data source auth checks.
11. Keep RLS request connection context behavior.
12. Keep local Postgres target.
13. Avoid Redshift code expansion.
14. Avoid AWS/S3 assumptions.
15. Avoid Twilio/notification expansion.
16. Add controller tests for generalized settings only if endpoint changes.
17. Add contract drift tests for any new endpoint.
18. Update OpenAPI if public contract changes.
19. Update web generated types if public contract changes.
20. Update security allowlists only when necessary.

Static guardrails:

1. Semgrep rule: upload endpoints must keep size limits and validation.
2. Semgrep rule: settings endpoints cannot expose secrets.
3. ast-grep rule: RLS filter must not regain direct storage access.

Acceptance checks:

1. Existing client remains compatible.
2. Existing backend tests remain applicable.
3. Review-fixes gate passes.

## 5. Phase 2: Models and Serialization Contracts

### 5.1 Subphase 2A: Add Shared Module Models

Steps:

1. Add module ID enum.
2. Add privacy class enum.
3. Add collection module setting DTO.
4. Add collection module diagnostics DTO.
5. Add battery policy DTO.
6. Add network policy DTO.
7. Add cadence DTO.
8. Add defaults object.
9. Add Android data collection aggregate setting.
10. Include AndroidSensorSetting bridge field or derived bridge.
11. Ensure all DTOs implement `StudySetting` where needed.
12. Ensure Jackson deserializes defaults.
13. Ensure unknown JSON fields are handled consistently with existing models.
14. Ensure equality/hash behavior is deterministic.
15. Ensure source compatibility for Java callers where needed.
16. Add model unit tests.
17. Add serialization round-trip tests.
18. Add polymorphic study setting tests.
19. Add frontend-style JSON tests if existing patterns require it.
20. Add negative tests for unsafe defaults.

Static guardrails:

1. Semgrep rule for collection setting DTOs missing `StudySetting`.
2. Semgrep rule for enabled-by-default sensitive modules.
3. ast-grep rule for module IDs represented as raw strings in model code.

Acceptance checks:

1. `chronicle-api:test` passes.
2. `chronicle-server:test --tests '*Serialization*'` passes.
3. Review-fixes gate passes.

### 5.2 Subphase 2B: Add Compatibility Tests

Steps:

1. Test old `AndroidSensorSetting` JSON still round-trips.
2. Test new aggregate setting round-trips.
3. Test missing aggregate setting falls back to old AndroidSensor.
4. Test empty old AndroidSensor disables hardware sensors.
5. Test non-empty old AndroidSensor enables only hardware sensors.
6. Test usage events remain enabled by default only if current behavior requires it.
7. Test lifecycle module remains enabled by enrollment only.
8. Test user identification remains governed by existing preference.
9. Test upload telemetry diagnostics do not change upload payload.
10. Test sensor availability remains report-only.
11. Test unknown module ID does not crash settings deserialization.
12. Test duplicate module entries reject or normalize deterministically.
13. Test invalid cadence rejects.
14. Test negative sampling rate rejects or clamps explicitly.
15. Test duty active greater than period rejects or normalizes explicitly.
16. Test privacy class missing rejects in new DTOs.
17. Test DTOs do not serialize raw API keys.
18. Test DTOs do not serialize participant secret material.
19. Test OpenAPI spec includes new DTO only if endpoint exposed.
20. Test Java API consumers compile.

Static guardrails:

1. Semgrep rule preventing `apiKey` fields in collection diagnostics/settings DTOs.
2. Semgrep rule preventing `participantId` in diagnostics; diagnostics must use redacted participant references.
3. ast-grep rule for missing validation helper use in setting normalization.

Acceptance checks:

1. Model/API compatibility matrix is green.
2. Review-fixes gate passes.

## 6. Phase 3: Android Collection Core

### 6.1 Subphase 3A: Add Core Package Without Behavior Changes

Steps:

1. Create collection core package.
2. Add module interfaces.
3. Add module ID mapping.
4. Add privacy class mapping.
5. Add status model.
6. Add diagnostics model.
7. Add disabled module no-op.
8. Add result type for start.
9. Add result type for stop.
10. Add result type for poll.
11. Add result type for flush.
12. Add result type for upload handoff.
13. Add logging helper.
14. Add clock provider abstraction.
15. Add context provider abstraction only where testing needs it.
16. Add registry with no callsites switched yet.
17. Add unit tests for registry.
18. Add unit tests for disabled module.
19. Add unit tests for diagnostics.
20. Add compile-only integration test.

Static guardrails:

1. ast-grep rule requiring module classes to implement the core interface.
2. ast-grep rule forbidding direct Android context storage in singleton module objects.
3. Semgrep rule for swallowed module start/stop exceptions.

Acceptance checks:

1. Android unit tests pass.
2. No runtime behavior changed.
3. Review-fixes gate passes.

### 6.2 Subphase 3B: Add Collection Sinks

Steps:

1. Add usage event sink wrapping `StorageQueue`.
2. Add lifecycle event sink using usage event sink.
3. Add sensor sample sink wrapping `SensorSampleDao`.
4. Add upload stats sink because upload telemetry must be a module-owned boundary.
5. Preserve existing `QueueEntry` serialization.
6. Preserve existing `SensorSampleEntry` serialization.
7. Preserve upload queue size updates.
8. Preserve sensor queue cursor semantics.
9. Add transaction or batch semantics where Room supports it.
10. Add explicit failure result for write errors.
11. Add tests for successful usage write.
12. Add tests for lifecycle batch write.
13. Add tests for corrupt payload rejection if applicable.
14. Add tests for sensor sample write.
15. Add tests for queue size update.
16. Add tests for duplicate write behavior.
17. Add tests for idempotent no-op empty write.
18. Add tests for non-enrolled lifecycle skip.
19. Add Android instrumented tests for SQLCipher DB access boundaries.
20. Add tests for crash-safe persistence assumptions.

Static guardrails:

1. ast-grep rule: only approved sink classes and tests may call `queueEntryData().insertEntry`.
2. ast-grep rule: only approved sensor sink/service/upload tests may call `sensorSampleDao().insertAll`.
3. Semgrep rule: persistent sink failures must not be swallowed.

Acceptance checks:

1. Android unit tests pass.
2. Android instrumented Room tests pass.
3. Review-fixes gate passes.

### 6.3 Subphase 3C: Add Settings Resolver

Steps:

1. Add resolver reading existing encrypted prefs.
2. Add resolver reading `AndroidSensorSetting`.
3. Add resolver reading generalized collection setting.
4. Add resolver fallback order.
5. Add resolver default policy.
6. Add resolver for usage module.
7. Add resolver for lifecycle module.
8. Add resolver for hardware sensor module.
9. Add resolver for user identification module.
10. Add resolver for upload diagnostics module.
11. Add validation for cadence.
12. Add validation for battery policy.
13. Add validation for network policy.
14. Add validation for sensor sampling rate.
15. Add validation for sensor duty cycle.
16. Add unit tests for all defaults.
17. Add unit tests for legacy fallback.
18. Add unit tests for malformed settings.
19. Add unit tests for disabled modules.
20. Add unit tests for privacy-sensitive modules not enabled implicitly.

Static guardrails:

1. Semgrep rule: generalized setting resolver must call validation.
2. ast-grep rule: no module may read raw sensor prefs directly after migration except resolver.
3. Semgrep rule: invalid setting fallback must log and disable affected module, not silently enable it.

Acceptance checks:

1. Settings resolver tests pass.
2. Existing settings UI tests remain green.
3. Review-fixes gate passes.

## 7. Phase 4: Usage Events Module

### 7.1 Subphase 4A: Wrap Usage Polling

Steps:

1. Add `UsageEventsCollectionModule`.
2. Inject or construct `UsageEventsChronicleSensor`.
3. Preserve previous poll timestamp behavior.
4. Preserve current poll timestamp commit behavior.
5. Preserve `users` lookup behavior.
6. Preserve activity class mapping.
7. Preserve event type mapping.
8. Preserve timezone mapping.
9. Preserve app label lookup.
10. Preserve empty result behavior.
11. Add module diagnostics for last poll.
12. Add module diagnostics for event count.
13. Add module diagnostics for checkpoint timestamp.
14. Add failure diagnostics for `UsageStatsManager` errors.
15. Keep `UsageMonitoringWorker` call path stable initially.
16. Add unit tests for poll wrapper.
17. Add unit tests for checkpoint commit.
18. Add unit tests for empty events.
19. Add unit tests for activityClass preservation.
20. Add unit tests for diagnostics.

Static guardrails:

1. Semgrep rule: usage events collector must preserve `className` into `activityClass`.
2. ast-grep rule: upload mapper must keep forwarding `datum.activityClass`.
3. Shell guardrail updates in mobile upload guardrail.

Acceptance checks:

1. Existing `UsageCollectionDelegateTest` passes.
2. ActivityClass guardrail passes.
3. Review-fixes gate passes.

### 7.2 Subphase 4B: Migrate Usage Worker to Module Manager

Steps:

1. Add module manager path for usage polling.
2. Keep WorkManager unique work name unchanged.
3. Keep poll interval unchanged.
4. Keep upload scheduling unchanged.
5. Route poll result through usage sink.
6. Route lifecycle state sampler through lifecycle module only after Phase 5.
7. Avoid double enqueue while both old and new code exist.
8. Add an internal migration switch that defaults to current behavior until module parity is proven.
9. Remove direct usage sensor set from worker after tests.
10. Preserve log lines needed by dogfood scripts.
11. Add worker unit tests.
12. Add worker disabled-module test.
13. Add worker no-permission test if testable.
14. Add retry/failure test.
15. Add queue cursor test.
16. Add idempotency test for duplicate worker execution.
17. Add crash recovery test for partially failed poll before checkpoint commit.
18. Add Android instrumented test for real Room write.
19. Add Maestro smoke assertion if UI status changes.
20. Add debug bundle coverage for usage module state.

Static guardrails:

1. ast-grep rule: `UsageMonitoringWorker` may not instantiate collection sensors directly after migration.
2. Semgrep rule: worker failures must update diagnostics or return retry/failure.
3. ast-grep rule: no direct queue writes from worker after migration.

Acceptance checks:

1. Android unit tests pass.
2. Android instrumented tests pass.
3. Review-fixes gate passes.

## 8. Phase 5: Device Lifecycle Module

### 8.1 Subphase 5A: Wrap Lifecycle Event Building

Steps:

1. Add `DeviceLifecycleCollectionModule`.
2. Move event mapping behind module boundary.
3. Preserve boot completed mapping.
4. Preserve shutdown mapping.
5. Preserve screen on mapping.
6. Preserve screen off mapping.
7. Preserve user present mapping.
8. Preserve power connected mapping.
9. Preserve power disconnected mapping.
10. Preserve battery low mapping.
11. Preserve battery okay mapping.
12. Preserve low memory mapping.
13. Preserve Android system package value.
14. Preserve Android system label value.
15. Preserve activityClass values.
16. Preserve timezone behavior.
17. Preserve dedupe window.
18. Add module diagnostics for last event.
19. Add module diagnostics for dropped duplicate count.
20. Add tests for every lifecycle event.

Static guardrails:

1. Semgrep rule: lifecycle events must use Android system package, not arbitrary app package.
2. ast-grep rule: lifecycle event mapping must be centralized in lifecycle module.
3. Semgrep rule: lifecycle recorder write errors must not be silently ignored.

Acceptance checks:

1. `DeviceLifecycleEventRecorderTest` passes.
2. New lifecycle module tests pass.
3. Review-fixes gate passes.

### 8.2 Subphase 5B: Migrate Lifecycle Persistence

Steps:

1. Route lifecycle event writes through `CollectionSink`.
2. Keep `recordAsync` wrapper as compatibility shim initially.
3. Update `DeviceLifecycleReceiver` to use lifecycle module manager.
4. Update connectivity change path.
5. Update low memory path in hardware service.
6. Update low memory path in unlock service.
7. Update power save receiver path.
8. Update boot receiver path to call the lifecycle/module manager path.
9. Preserve non-enrolled skip behavior.
10. Preserve queue size update.
11. Preserve batch write behavior.
12. Add tests for non-enrolled skip.
13. Add tests for queue write failure.
14. Add tests for async executor failure visibility.
15. Add idempotency tests for repeated broadcasts.
16. Add crash recovery tests for queued lifecycle events.
17. Add Android instrumented queue persistence test.
18. Add dogfood report assertion for lifecycle event counts.
19. Add debug bundle assertion for lifecycle module state.
20. Remove direct writer only after tests pass.

Static guardrails:

1. ast-grep rule: no direct `DeviceLifecycleEventRecorder.recordAsync` outside approved shim/tests after migration.
2. ast-grep rule: no direct `QueueEntry` construction for lifecycle outside sink.
3. Semgrep rule: async lifecycle failures must log and mark diagnostics.

Acceptance checks:

1. Lifecycle unit tests pass.
2. Android instrumented tests pass.
3. Review-fixes gate passes.

## 9. Phase 6: Hardware Sensors Module

### 9.1 Subphase 6A: Extract Sensor Runtime Controller

Steps:

1. Add `HardwareSensorsCollectionModule`.
2. Extract `SensorRuntimeController` from foreground service logic.
3. Keep `HardwareSensorService` as Android service shell initially.
4. Preserve foreground notification behavior.
5. Preserve notification channel behavior.
6. Preserve battery receiver behavior.
7. Preserve lifecycle receiver behavior until lifecycle module owns it.
8. Preserve duty cycle behavior.
9. Preserve power-save degraded mode.
10. Preserve critical battery stop.
11. Preserve resume threshold if currently used.
12. Preserve sensor registration behavior.
13. Preserve trigger sensor behavior.
14. Preserve max report latency behavior.
15. Preserve buffer behavior.
16. Preserve flush-on-destroy behavior.
17. Preserve low-memory event behavior.
18. Add runtime unit tests with fake sensor gateway.
19. Add service shell test where feasible.
20. Add diagnostics for runtime state.

Static guardrails:

1. Semgrep rule: Methodic power-saver degraded mode remains present.
2. ast-grep rule: direct `SensorManager` access must live in sensor runtime/service package only.
3. Semgrep rule: service destroy flush failures must be logged and surfaced in diagnostics.

Acceptance checks:

1. Sensor mapping tests pass.
2. Sensor runtime tests pass.
3. Review-fixes gate passes.

### 9.2 Subphase 6B: Modularize Sensor Settings Refresh

Steps:

1. Route settings refresh through collection settings resolver.
2. Preserve `AndroidSensor` endpoint fetch.
3. Add generalized settings fetch only with fallback.
4. Preserve missing AndroidSensor 404 behavior.
5. Preserve disable-on-missing behavior.
6. Preserve restart-on-changed-settings behavior.
7. Preserve start-on-newly-enabled behavior.
8. Preserve stop-on-disabled behavior.
9. Preserve schedule sync on newly enabled.
10. Preserve availability reporting to all enabled servers.
11. Preserve upload status update on availability failure.
12. Add tests for unchanged settings.
13. Add tests for changed settings.
14. Add tests for missing settings.
15. Add tests for partial server failure.
16. Add tests for no enabled servers.
17. Add tests for malformed settings.
18. Add tests for privacy-sensitive sensors disabled by default.
19. Add debug bundle setting state.
20. Add dogfood report setting state.

Static guardrails:

1. ast-grep rule: settings refresh cannot directly start/stop hardware service after manager migration.
2. Semgrep rule: missing settings cannot silently continue with stale enabled sensors.
3. Semgrep rule: availability failures must update visible status.

Acceptance checks:

1. Sensor settings tests pass.
2. Mobile guardrail passes.
3. Review-fixes gate passes.

### 9.3 Subphase 6C: Modularize Sensor Upload

Steps:

1. Keep `/android/sensors` route unchanged.
2. Keep `SensorUploadWorkerDelegate` behavior initially.
3. Wrap delegate in upload module interface.
4. Preserve batch size 500.
5. Preserve TTL cleanup.
6. Preserve max sample count cleanup.
7. Preserve corrupt sample skip behavior but track malformed count.
8. Preserve multi-server upload loop.
9. Preserve cursor advancement.
10. Preserve min cursor deletion.
11. Preserve upload stats increments.
12. Preserve last sensor upload timestamp.
13. Preserve retry/failure semantics in combined upload.
14. Add unit tests for empty DB.
15. Add unit tests for corrupt rows.
16. Add unit tests for partial server failure.
17. Add unit tests for cursor deletion.
18. Add unit tests for TTL/cap cleanup.
19. Add integration tests for sensor payload model.
20. Add dogfood report sensor counts.

Static guardrails:

1. Semgrep rule: sensor upload must use cursor-based deletion, not delete-all-after-success.
2. ast-grep rule: `SensorUploadWorkerDelegate` cannot swallow corrupt batch without count/diagnostic.
3. Semgrep rule: upload batch constants must stay bounded.

Acceptance checks:

1. Combined upload tests pass.
2. Sensor upload tests pass.
3. Review-fixes gate passes.

## 10. Phase 7: User Identification Module

### 10.1 Subphase 7A: Encapsulate Current User Queue

Steps:

1. Add `UserIdentificationCollectionModule`.
2. Preserve `EnrollmentSettings.setTargetUser`.
3. Preserve `UserQueueEntry`.
4. Preserve current user shared pref key.
5. Preserve "Not set" behavior.
6. Preserve user lookup by timestamp in usage collection.
7. Preserve unlock monitoring service behavior.
8. Add diagnostics for enabled state.
9. Add diagnostics for last target user update.
10. Avoid uploading raw extra identifiers.
11. Add unit tests for target user write.
12. Add unit tests for disabled user identification.
13. Add unit tests for timestamp lookup.
14. Add unit tests for "Not set" mapping to empty user.
15. Add unit tests for repeated target user selection.
16. Add instrumented DB test for user queue.
17. Add privacy test for diagnostics redaction.
18. Add debug bundle redaction assertion.
19. Add UI status test if diagnostics screen changes.
20. Add migration no-op test.

Static guardrails:

1. Semgrep rule: debug bundle must not dump user queue raw contents.
2. ast-grep rule: target user writes must go through module/settings abstraction.
3. Semgrep rule: user identification module cannot collect Android account/contact identity.

Acceptance checks:

1. Existing usage tests pass.
2. New user identification tests pass.
3. Review-fixes gate passes.

## 11. Phase 8: Upload Telemetry and Diagnostics Module

### 11.1 Subphase 8A: Normalize Upload State

Steps:

1. Add upload telemetry module.
2. Preserve `UploadServerEntity` fields.
3. Preserve usage last upload timestamp.
4. Preserve sensor last upload timestamp.
5. Preserve consecutive failure counters.
6. Preserve last error fields.
7. Preserve upload stats table.
8. Expose queue depth per data stream.
9. Expose last worker result.
10. Expose next scheduled upload if WorkManager supports it.
11. Expose retry state.
12. Expose constraints state.
13. Expose disabled server state.
14. Expose malformed row counts.
15. Expose partial failure counts.
16. Redact API keys.
17. Redact device secrets.
18. Redact participant secrets where possible.
19. Add diagnostics tests.
20. Add debug bundle tests.

Static guardrails:

1. Semgrep rule: diagnostics DTOs/scripts cannot include `apiKey`.
2. Semgrep rule: diagnostics cannot include `MOBILE_SIGNING_SECRET`.
3. ast-grep rule: WorkManager diagnostics cannot report success when worker returned retry/failure.

Acceptance checks:

1. Upload status tests pass.
2. Debug bundle guardrails pass.
3. Review-fixes gate passes.

### 11.2 Subphase 8B: Preserve Combined Upload Semantics

Steps:

1. Keep `COMBINED_UPLOAD_WORK_NAME`.
2. Keep `COMBINED_UPLOAD_IMMEDIATE_WORK_NAME`.
3. Keep legacy cancellation behavior for old workers.
4. Preserve usage upload first.
5. Preserve sensor upload second.
6. Preserve partial failure retry.
7. Preserve max retry failure behavior.
8. Preserve stats cleanup.
9. Preserve Firebase expansion freeze; do not add new Firebase events.
10. Add local logging/diagnostics instead of new external telemetry.
11. Add tests for both success.
12. Add tests for usage fail/sensor success.
13. Add tests for usage success/sensor fail.
14. Add tests for both fail.
15. Add tests for repeated attempts.
16. Add tests for stats cleanup failure.
17. Add tests for no servers.
18. Add tests for disabled modules.
19. Add tests for immediate upload.
20. Add Android instrumented WorkManager test for combined upload scheduling.

Static guardrails:

1. ast-grep rule: `CombinedUploadWorker` cannot return success on failed delegate.
2. Semgrep rule: upload worker failures must not only log and continue to success.
3. Shell guardrail: dogfood report must include upload queue depth and failures.

Acceptance checks:

1. Combined upload tests pass.
2. Auto-upload E2E script still parses.
3. Review-fixes gate passes.

## 12. Phase 9: Backend Settings and Upload Compatibility

### 12.1 Subphase 9A: Backend Generalized Settings Read

Steps:

1. Add generalized Android collection settings after Phase 2 model contracts are committed.
2. Keep existing `AndroidSensor` settings endpoint.
3. Add tests for old endpoint returning old settings.
4. Add tests for missing old endpoint behavior.
5. Add tests for new setting storage.
6. Add tests for old-to-new fallback.
7. Add tests for new-to-old sensor bridge.
8. Add audit test for settings change summary.
9. Add serialization tests.
10. Add controller tests.
11. Add service tests.
12. Add permission tests.
13. Add RLS tests for settings read/write because settings are study-scoped data.
14. Add contract drift tests.
15. Update OpenAPI for every exposed route or DTO change.
16. Update web generated types after every OpenAPI change.
17. Avoid Redshift cleanup.
18. Avoid cloud provider assumptions.
19. Avoid notification integration changes.
20. Avoid SSO changes; SSO is outside this refactor.

Static guardrails:

1. Semgrep rule: mobile settings endpoint cannot require web session auth if app needs public read.
2. Semgrep rule: settings update must be authenticated/admin-scoped.
3. ast-grep rule: no direct RLS context manager call in settings service.

Acceptance checks:

1. Backend tests pass.
2. Contract drift tests pass.
3. Review-fixes gate passes.

### 12.2 Subphase 9B: Backend Upload Guards Remain Stable

Steps:

1. Verify usage upload batch size limit.
2. Verify sensor upload batch size limit.
3. Verify participant enrollment check.
4. Verify data source check.
5. Verify API key/device auth behavior.
6. Verify replay/idempotency behavior as currently designed.
7. Verify malformed payload rejection.
8. Verify malformed row handling.
9. Verify upload buffer insert transaction behavior.
10. Verify move-to-storage task behavior.
11. Verify `activity_class` persistence.
12. Verify sensor sample persistence.
13. Verify upload metrics.
14. Verify rejected upload metrics.
15. Verify logs include the existing request/correlation identifier when the request context provides one.
16. Verify logs do not leak API keys.
17. Verify logs do not leak raw request bodies.
18. Verify RLS context on query connection.
19. Verify local Postgres migrations.
20. Verify no Redshift dependency is introduced.

Static guardrails:

1. Semgrep rule: Android upload controllers must call upload services, not write SQL directly.
2. Semgrep rule: upload request body must have size validation or service batch limit.
3. ast-grep rule: upload services cannot bypass participant/source-device checks.

Acceptance checks:

1. `DataUploadE2ETest` passes.
2. Upload service tests pass.
3. Review-fixes gate passes.

## 13. Phase 10: Gradle Module Split

### 13.1 Subphase 10A: Prepare Android Build Split

Steps:

1. Inventory current app dependencies.
2. Identify dependencies needed by collection core.
3. Identify dependencies needed by usage module.
4. Identify dependencies needed by lifecycle module.
5. Identify dependencies needed by sensors module.
6. Identify dependencies needed by upload module.
7. Identify dependencies that must remain app-only.
8. Identify resources needed by service notifications.
9. Identify manifest entries needed by modules.
10. Identify generated BuildConfig needs.
11. Identify Room schema ownership.
12. Identify Proguard/R8 effects.
13. Identify test fixtures.
14. Identify Firebase references to freeze or isolate.
15. Identify SQLCipher dependency location.
16. Identify WorkManager dependency location.
17. Identify Retrofit dependency location.
18. Identify Jackson dependency location.
19. Identify AndroidX lifecycle dependency location.
20. Record split dependency graph.

Static guardrails:

1. Shell guardrail: Android modules cannot depend on app module.
2. Gradle check: no circular dependencies.
3. Semgrep rule: no local jar shadowing in Android app/libs remains.

Acceptance checks:

1. Dependency graph is acyclic.
2. Existing build still passes before moving code.
3. Review-fixes gate passes.

### 13.2 Subphase 10B: Create Android Library Modules

Steps:

1. Add `:collection-core`.
2. Add `:collection-usage`.
3. Add `:collection-lifecycle`.
4. Add `:collection-sensors`.
5. Add `:collection-upload`.
6. Add module build files.
7. Add test dependencies.
8. Add consumer Proguard rules for every new Android library module.
9. Add Android manifest snippets for library-owned services/receivers and verify final merged manifest.
10. Move only core interfaces first.
11. Compile.
12. Move usage module.
13. Compile.
14. Move lifecycle module.
15. Compile.
16. Move sensor module.
17. Compile.
18. Move upload module.
19. Compile.
20. Run Android tests.

Static guardrails:

1. Gradle task or script verifies module dependencies.
2. ast-grep rule: app module cannot contain collection implementation packages after split.
3. Semgrep rule: collection modules cannot import UI activities except explicit notification intent boundary.

Acceptance checks:

1. `:app:assembleDebug` passes.
2. All moved module tests pass.
3. Review-fixes gate passes.

### 13.3 Subphase 10C: Preserve Manifest and Runtime Behavior

Steps:

1. Verify receivers remain registered.
2. Verify foreground service remains declared.
3. Verify permissions remain unchanged.
4. Verify notification channel still exists.
5. Verify boot receiver still starts correct manager.
6. Verify settings refresh still schedules.
7. Verify usage monitoring still schedules.
8. Verify combined upload still schedules.
9. Verify sensor service starts only when enabled.
10. Verify user identification starts only when enabled.
11. Verify power save receiver behavior.
12. Verify battery optimization dialog behavior.
13. Verify debug config receiver behavior.
14. Verify cleartext debug network config remains debug-only.
15. Verify signing config still works.
16. Verify BuildConfig mobile signing secret still available where needed.
17. Verify no accidental permission additions.
18. Verify no exported component regressions.
19. Verify Android 26 compatibility.
20. Verify Android 35/36 compatibility.

Static guardrails:

1. Semgrep/generic rule for unexpected dangerous permissions.
2. Semgrep/generic rule for exported components without explicit need.
3. Shell guardrail for debug-only cleartext config.

Acceptance checks:

1. APK builds.
2. Maestro flow passes on key API levels.
3. Review-fixes gate passes.

## 14. Phase 11: Data Quality and Dogfood Tooling

### 14.1 Subphase 11A: Collection Coverage Reports

Steps:

1. Report usage event count.
2. Report activityClass coverage percent.
3. Report top missing activityClass packages.
4. Report lifecycle event count.
5. Report shutdown/startup events.
6. Report screen/keyguard events.
7. Report battery/power/network events.
8. Report sensor sample count.
9. Report sensor sample types.
10. Report sensor availability matrix.
11. Report last upload timestamps.
12. Report upload queue depth.
13. Report sensor queue depth.
14. Report malformed row counts.
15. Report duplicate/replay counts, using zero plus a `not_tracked` field only until backend counters exist.
16. Report clock skew.
17. Report future timestamp rows.
18. Report stale participants.
19. Report app version/device inventory.
20. Redact secrets and participant-sensitive values.

Static guardrails:

1. Shell guardrail: dogfood report must include activityClass coverage.
2. Shell guardrail: dogfood report must include full sensor inventory.
3. Shell guardrail: dogfood report must not print API keys/secrets.

Acceptance checks:

1. Dogfood report script parses.
2. Report runs against local Postgres.
3. Review-fixes gate passes.

### 14.2 Subphase 11B: Battery and Long-Run Tests

Steps:

1. Preserve battery harness plugged-in rejection.
2. Add baseline battery capture.
3. Add final battery capture.
4. Add wake lock stats capture.
5. Add network stats capture.
6. Add sensor stats capture.
7. Add upload counts capture.
8. Add queue depth before/after.
9. Add app process uptime.
10. Add WorkManager state.
11. Add foreground service state.
12. Add Android dumpsys battery reset guidance.
13. Add 2h profile.
14. Add 8h profile.
15. Add 24h profile.
16. Add offline interval profile.
17. Add reconnect upload profile.
18. Add power-save profile.
19. Add low-battery profile.
20. Add artifact bundle.

Static guardrails:

1. Shell guardrail: battery harness must reject charging tests by default.
2. Shell guardrail: long-run script must collect final upload counts.
3. Shell guardrail: debug bundle must redact app secrets.

Acceptance checks:

1. Scripts parse.
2. Short smoke run works on emulator or tablet.
3. Review-fixes gate passes.

## 15. Phase 12: Static Security and Structural Guardrails

### 15.1 Subphase 12A: Semgrep Collection Rules

Steps:

1. Add rule for module privacy declaration.
2. Add rule for no raw API keys in diagnostics.
3. Add rule for no participant secrets in logs.
4. Add rule for no direct raw request body logs.
5. Add rule for upload batch bounds.
6. Add rule for settings validation.
7. Add rule for no enabled sensitive default.
8. Add rule for no Firebase expansion in collection modules.
9. Add rule for no screenshots/accessibility/GPS/mic permissions.
10. Add rule for no direct storage writes from non-sinks using the strongest Semgrep pattern available.
11. Add rule tests or fixture comments.
12. Add rule to security runner.
13. Run SAST.
14. Fix findings.
15. Re-run SAST.
16. Write SARIF locally for every Semgrep run.
17. Document false positives.
18. Narrow paths to avoid ignored features.
19. Include Android source paths.
20. Include backend source paths.

Acceptance checks:

1. `tests/security/run-all-security.sh sast build/security/sast` passes.
2. Mobile collection rules are active.
3. Review-fixes gate passes.

### 15.2 Subphase 12B: ast-grep Collection Rules

Steps:

1. Add rule for no direct `queueEntryData().insertEntry`.
2. Add rule for no direct `sensorSampleDao().insertAll`.
3. Add rule for no direct `HardwareSensorService.startService`.
4. Add rule for no direct `HardwareSensorService.stopService`.
5. Add rule for no direct `DeviceLifecycleEventRecorder.recordAsync`.
6. Add rule for no `UsageMonitoringWorker` direct sensor instantiation.
7. Add rule for no app module imports from collection implementation after split.
8. Add rule for module classes missing interface implementation.
9. Add rule for raw module string IDs.
10. Add rule for direct RLS bypass remains active.
11. Add rules to runner.
12. Run ast-grep rules manually.
13. Fix findings.
14. Re-run rules.
15. Document approved exceptions.
16. Add source fixtures or documented positive/negative examples for every ast-grep rule.
17. Scope tests to Kotlin Android/backend paths.
18. Avoid false positives in tests; intentional test-path exceptions must be encoded as rule path exclusions.
19. Ensure CI installs ast-grep.
20. Ensure reports are emitted.

Acceptance checks:

1. ast-grep collection guardrails pass.
2. RLS ast-grep guardrails still pass.
3. Review-fixes gate passes.

### 15.3 Subphase 12C: Security Runner Integration

Steps:

1. Add collection guardrails to `mobile` layer or new `collection` layer.
2. Keep existing valid layers stable.
3. Update security suite workflow if new layer added.
4. Update local command documentation.
5. Ensure reports directory is created.
6. Ensure missing tooling errors clearly.
7. Ensure CI installs needed tools.
8. Ensure mobile layer runs without secrets when build is skipped intentionally.
9. Ensure signing-secret guardrail remains active for dogfood builds.
10. Ensure no ignored third-party features block local deployment.
11. Run `mobile` layer.
12. Run `sast` layer.
13. Run `secrets` layer.
14. Run `iac` layer if Docker touched.
15. Run `compliance` if compose touched.
16. Run `auth` if backend auth touched.
17. Run `injection` if backend SQL touched.
18. Run `crypto` if crypto/security touched.
19. Run `license` if deps touched.
20. Record reports.

Acceptance checks:

1. Security runner covers collection rules.
2. Security suite workflow remains valid.
3. Review-fixes gate passes.

## 16. Phase 13: Full Verification Matrix

### 16.1 Subphase 13A: JVM and Backend Verification

Steps:

1. `./gradlew projects --no-daemon`.
2. `./gradlew :chronicle-api:validateOpenApiSpec --no-daemon`.
3. `./gradlew :chronicle-api:test --no-daemon`.
4. `./gradlew :chronicle-server:test --no-daemon`.
5. `./gradlew :chronicle-server:jacocoTestReport --no-daemon`.
6. Run targeted serialization tests.
7. Run targeted upload service tests.
8. Run targeted settings tests.
9. Run targeted RLS tests.
10. Run targeted migration tests.
11. Run targeted data quality tests.
12. Run targeted contract parity tests.
13. Run targeted fuzz tests if included in normal test task.
14. Run JMH only if performance-sensitive code changed and time permits.
15. Generate SBOM if deps changed.
16. Run license report if deps changed.
17. Run OpenAPI type generation if API changed.
18. Fail on stale generated files.
19. Fix failures.
20. Re-run failed command then full command.

Acceptance checks:

1. JVM/backend matrix green.
2. No skipped relevant backend tests.
3. Review-fixes gate passes.

### 16.2 Subphase 13B: Android Verification

Steps:

1. `(cd chronicle && ./gradlew :app:testDebugUnitTest --no-daemon)`.
2. `(cd chronicle && ./gradlew :app:assembleDebug --no-daemon)`.
3. `(cd chronicle && ./gradlew :app:connectedDebugAndroidTest --no-daemon)`.
4. Run API 26 emulator.
5. Run API 33 emulator.
6. Run API 35 or 36 emulator.
7. Run real tablet install when the tablet is physically/network reachable; otherwise record the exact ADB blocker and run emulator replacement.
8. Run enrollment smoke.
9. Run usage collection smoke.
10. Run lifecycle event smoke.
11. Run sensor settings refresh smoke.
12. Run sensor collection smoke.
13. Run upload now smoke.
14. Run automatic upload smoke.
15. Run offline collection smoke.
16. Run reconnect upload smoke.
17. Run battery harness short profile.
18. Run debug bundle.
19. Run dogfood report.
20. Fix and re-run failures.

Acceptance checks:

1. Android test matrix green or external device blocker documented.
2. APK installs and launches.
3. Review-fixes gate passes.

### 16.3 Subphase 13C: Security and Supply Chain Verification

Steps:

1. Run SAST layer.
2. Run mobile layer.
3. Run secrets layer.
4. Run auth layer.
5. Run injection layer.
6. Run crypto layer.
7. Run compliance layer.
8. Run license layer.
9. Run SCA layer.
10. Run IaC layer if Docker touched.
11. Run Trivy filesystem scan; install Trivy first when missing.
12. Run Trivy image scan for every image built during the refactor.
13. Run gitleaks.
14. Run dependency audit for web if touched.
15. Run Gradle dependency verification.
16. Verify pinned actions remain pinned by SHA.
17. Verify no local jars in Android app.
18. Verify SBOM is generated after dependency changes.
19. Fix findings.
20. Re-run failed layers.

Acceptance checks:

1. Security matrix green.
2. SCA matrix green or tool unavailable blocker documented.
3. Review-fixes gate passes.

## 17. Phase 14: Commit and Push Sequence

### 17.1 Subphase 14A: Commit Discipline

Steps:

1. Commit after each completed phase or major subphase.
2. Do not mix checkpoint and refactor commits.
3. Do not mix model/API/server/mobile splits in one commit; use one commit per subsystem boundary.
4. Commit submodule changes before root pointer changes.
5. Use pathspecs.
6. Never use `git reset --hard`.
7. Never use `git checkout --` to discard user work.
8. Never amend.
9. Include test evidence in commit message body for major commits.
10. Keep doc-only commits separate.
11. Run `git status` before every commit.
12. Run relevant tests before every commit.
13. Run review-fixes before every commit.
14. Confirm no secrets staged.
15. Confirm no APKs staged.
16. Confirm no build caches staged.
17. Confirm no DB dumps staged.
18. Confirm generated files are staged only when they are required source artifacts such as Room schemas or generated API types.
19. Record commit hash.
20. Continue only from clean intended state.

Acceptance checks:

1. Commit graph is reviewable.
2. Root/submodule state is consistent.
3. Review-fixes gate passes.

### 17.2 Subphase 14B: Push Discipline

Steps:

1. Confirm remotes.
2. Confirm branch.
3. Confirm user requested push.
4. Push submodule branches first if submodule commits exist.
5. Push root branch after submodule pushes succeed.
6. Verify remote contains submodule commits.
7. Verify root remote references reachable submodule SHAs.
8. Verify CI starts.
9. Monitor CI.
10. Fix CI failures.
11. Re-run CI after every pushed fix commit.
12. Do not force push.
13. Do not push secrets.
14. Do not push APKs.
15. Record pushed branch names.
16. Record CI links.
17. Record failed jobs.
18. Record fixes.
19. Record final status.
20. Produce closure report.

Acceptance checks:

1. Remote state is consistent.
2. CI status is known.
3. Review-fixes gate passes.

## 18. Final Completion Criteria

The refactor is not complete until all are true:

1. Checkpoint commit exists before refactor commits.
2. Root and submodule commits are consistent.
3. Android collection modules are separated by responsibility.
4. Existing app behavior is preserved.
5. Existing upload endpoints are preserved.
6. Existing queued data survives.
7. Existing enrolled devices do not require re-enrollment.
8. ActivityClass remains collected and uploaded.
9. Lifecycle events remain collected and uploaded.
10. Hardware sensors remain selectively enabled and uploaded.
11. Sensor availability remains reported.
12. Upload diagnostics are redacted and useful.
13. Backend generalized settings are backward compatible.
14. Room migrations pass.
15. Postgres migrations pass.
16. Unit tests pass.
17. Integration tests pass.
18. Android instrumented tests pass.
19. Backend E2E tests pass.
20. Serialization tests pass.
21. Contract drift tests pass.
22. Fuzz/property tests pass where configured.
23. Security SAST passes.
24. ast-grep guardrails pass.
25. Mobile guardrails pass.
26. Secrets scan passes.
27. SCA/dependency scan passes or unavailable tooling is documented as a blocker.
28. IaC/compliance checks pass if infrastructure touched.
29. `$review-fixes` has been applied after every subphase.
30. No skipped issue remains undocumented.

## 19. Command Reference

Use these commands during execution:

```bash
export JAVA_HOME=/home/uzair/.local/jdks/temurin-21

git status --short --branch
git submodule status --recursive

./gradlew projects --no-daemon
./gradlew :chronicle-api:validateOpenApiSpec --no-daemon
./gradlew :chronicle-api:test --no-daemon
./gradlew :chronicle-server:test --no-daemon
./gradlew :chronicle-server:jacocoTestReport --no-daemon

(cd chronicle && ./gradlew :app:testDebugUnitTest --no-daemon)
(cd chronicle && ./gradlew :app:assembleDebug --no-daemon)
(cd chronicle && ./gradlew :app:connectedDebugAndroidTest --no-daemon)

tests/security/run-all-security.sh sast build/security/sast
tests/security/run-all-security.sh mobile build/security/mobile
tests/security/run-all-security.sh secrets build/security/secrets
tests/security/run-all-security.sh iac build/security/iac
tests/security/run-all-security.sh sso build/security/sso
tests/security/run-all-security.sh auth build/security/auth
tests/security/run-all-security.sh injection build/security/injection
tests/security/run-all-security.sh crypto build/security/crypto
tests/security/run-all-security.sh license build/security/license
tests/security/run-all-security.sh compliance build/security/compliance
tests/security/run-all-security.sh sca build/security/sca
```

## 20. Non-Goals

1. Do not implement Twilio/SMS.
2. Do not implement Alertmanager outbound notification receivers.
3. Do not implement Redshift runtime, migration, flush, or cleanup.
4. Do not implement AWS/S3 runtime features.
5. Do not implement Firebase/FCM expansion.
6. Do not implement cloud deployment runbooks.
7. Do not implement screenshots.
8. Do not implement accessibility text capture.
9. Do not implement GPS/location capture.
10. Do not implement microphone capture.
11. Do not implement notification content capture.
12. Do not implement browser history capture.
13. Do not rewrite SSO.
14. Do not change public upload routes.
15. Do not require re-enrollment.
16. Do not delete local queues.
17. Do not remove current dogfood scripts.
18. Do not loosen RLS guardrails.
19. Do not suppress security findings without documented reason.
20. Do not declare MVP-ready until verification matrix is green.
