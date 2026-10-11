fun owner() {
    ops.checkOpNoThrow(op, uid, pkg)
    manager.queryEvents(start, end)
    manager.queryUsageStats(interval, start, end)
}
