// Positive fixtures for the collection-modularization Semgrep rules (Phase 12).
//
// Each block below is a deliberate VIOLATION of one design §4 catalog rule. The
// Semgrep rule-id annotation comment preceding each block is the test convention:
// `semgrep --test` (and the `collection` security layer's fixture self-check)
// confirms the rule fires here. This file is NOT production code — it lives under
// tests/security/fixtures/ and is never compiled into the app or scanned by the
// `collection` layer's real-code targets.
//
// Rules covered: #1 (privacy invariant), #9 (sensitive default), #12 (Firebase /
// dangerous permission). The DTO rule #8 has its own fixture file
// (SecretDtoPositiveFixture.kt).
package tests.security.fixtures.collection

import android.content.Context

// ---------------------------------------------------------------------------
// Catalog #1: a DataCollectionModule impl with NO init-block privacy invariant.
// A conforming module asserts `require(privacyClass == id.privacyClass) { ... }`.
// This one omits it entirely → rule must fire.
// ruleid: chronicle-collection-module-must-assert-privacy-invariant
class BadModuleMissingInvariant(
    private val dep: String,
) : DataCollectionModule {
    override val id: CollectionModuleId = CollectionModuleId.USAGE_EVENTS
    override val privacyClass: CollectionPrivacyClass = id.privacyClass

    override fun status(): CollectionModuleStatus = CollectionModuleStatus.IDLE
    override fun start(context: Context): ModuleResult = ModuleResult.Skipped("x")
    override fun stop(context: Context): ModuleResult = ModuleResult.Skipped("x")
}

// ---------------------------------------------------------------------------
// Catalog #9: a coded default that enables a privacy-sensitive module.
// PHYSICAL_TELEMETRY / LOCAL_PARTICIPANT_LABEL must never be enabled by a default.
fun badDefaults(): CollectionModuleSetting {
    // ruleid: chronicle-collection-no-sensitive-default-enabled
    return CollectionDefaults.moduleSetting(CollectionModuleId.HARDWARE_SENSORS, enabled = true)
}

fun badDefaultLiteral(): CollectionModuleSetting {
    // ruleid: chronicle-collection-no-sensitive-default-enabled
    return CollectionModuleSetting(enabled = true, collectionCadence = 1, uploadCadence = 2)
}

// ---------------------------------------------------------------------------
// Catalog #12: a collection module emitting a new Firebase analytics event.
fun badFirebaseEvent(analytics: FirebaseAnalytics) {
    // ruleid: chronicle-collection-no-new-firebase-events
    analytics.logEvent("collection_module_started", null)
}

fun badCrashlytics(crashlytics: Crashlytics, e: Exception) {
    // ruleid: chronicle-collection-no-new-firebase-events
    crashlytics.recordException(e)
}

// ---------------------------------------------------------------------------
// Catalog #12 (cont.): a collection module referencing a dangerous permission.
fun badPermission(): String {
    // ruleid: chronicle-collection-no-dangerous-permission-request
    return "android.permission.ACCESS_FINE_LOCATION"
}

// ---------------------------------------------------------------------------
// Per-sensor authority / hardware gate: CollectionSettingsResolver must only be built inside
// CollectionLoopCoordinator.resolveCollectableSettings. A direct construction in any other
// function bypasses the per-device hardware gate and the legacy-bridge suppression → rule fires.
fun badDirectResolver(source: LegacySensorSettingSource): Any {
    // ruleid: chronicle-collection-resolver-construction-only-in-coordinator
    return CollectionSettingsResolver(source).resolveAll(generalized = null)
}
