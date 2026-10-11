fun owner() {
    val flags = android.app.PendingIntent.FLAG_MUTABLE
    client.requestActivityTransitionUpdates(request, pending)
    client.requestSleepSegmentUpdates(pending, request)
    client.removeActivityTransitionUpdates(pending)
    client.removeSleepSegmentUpdates(pending)
}
