fun bypass() {
    // ruleid: usage-access-single-owner
    ops.checkOpNoThrow(op, uid, pkg)
    // ruleid: usage-access-single-owner
    manager.queryEvents(start, end)
    // ruleid: usage-access-single-owner
    manager.queryUsageStats(interval, start, end)
}
