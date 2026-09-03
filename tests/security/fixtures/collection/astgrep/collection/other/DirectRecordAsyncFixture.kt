// Positive fixture for collection-lifecycle-record-only-via-module (catalog #10).
// A direct recordAsync call outside the lifecycle module / its shim.
package fixtures
fun bad(context: Context, event: ExtractedUsageEvent) {
    DeviceLifecycleEventRecorder.recordAsync(context, event) // VIOLATION: bypasses lifecycle module
}
