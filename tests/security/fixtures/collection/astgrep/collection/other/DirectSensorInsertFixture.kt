// Positive fixture for collection-sensor-insert-only-in-sink (catalog #8).
// A direct sensor_samples insert outside the sanctioned SensorSampleSink.
package fixtures
fun bad(db: ChronicleDb, samples: List<SensorSampleEntry>) {
    db.sensorSampleDao().insertAll(samples) // VIOLATION: not routed through SensorSampleSink
}
