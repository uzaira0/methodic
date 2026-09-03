// Positive fixture for collection-module-id-no-raw-string (catalog #2).
// A raw module-ID string literal in collection code instead of a CollectionModuleId.
package fixtures
fun bad() {
    val moduleId = "usage_events" // VIOLATION: raw string, not CollectionModuleId.USAGE_EVENTS.id
    println(moduleId)
}
