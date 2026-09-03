// Positive fixture for collection-queue-insert-only-in-sink (catalog #7).
// A direct dataQueue insert outside the sanctioned UsageEventSink.
package fixtures
fun bad(db: ChronicleDb, entry: QueueEntry) {
    db.queueEntryData().insertEntry(entry) // VIOLATION: not routed through UsageEventSink
}
