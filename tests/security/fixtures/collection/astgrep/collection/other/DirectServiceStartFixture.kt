// Positive fixture for collection-hardware-service-only-via-manager (catalog #9).
// A direct HardwareSensorService start/stop outside HardwareSensorsCollectionModule.
package fixtures
fun bad(context: Context) {
    HardwareSensorService.startService(context) // VIOLATION: bypasses module manager
    HardwareSensorService.stopService(context)  // VIOLATION: bypasses module manager
}
