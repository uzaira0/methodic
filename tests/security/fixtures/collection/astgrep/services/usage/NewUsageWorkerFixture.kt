// Positive fixture for collection-worker-no-direct-sensor-instantiation (catalog #11).
// A NEW usage worker (not the legacy UsageMonitoringWorker) instantiating a sensor.
package fixtures
class AnotherUsageWorker {
    fun work(context: Context) {
        val sensor = UsageEventsChronicleSensor(context) // VIOLATION: direct sensor instantiation
        sensor.toString()
    }
}
