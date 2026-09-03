// Positive fixture for collection-settings-resolver-only-via-coordinator.
// A NEW collection class that resolves settings by constructing CollectionSettingsResolver
// directly, bypassing CollectionLoopCoordinator.resolveCollectableSettings (and thus the
// per-device hardware gate + per-sensor authority). The rule must FIRE on the construction.
package fixtures
fun bad(source: LegacySensorSettingSource, fetched: AndroidDataCollectionSetting) =
    CollectionSettingsResolver(source).resolveAll(generalized = fetched) // VIOLATION: bypasses the coordinator gate
