fun bypass() {
    // ruleid: activity-recognition-single-owner
    client.requestActivityTransitionUpdates(request, pending)
    // ruleid: activity-recognition-single-owner
    client.requestSleepSegmentUpdates(pending, request)
    // ruleid: activity-recognition-single-owner
    client.removeActivityTransitionUpdates(pending)
    // ruleid: activity-recognition-single-owner
    client.removeSleepSegmentUpdates(pending)
}
