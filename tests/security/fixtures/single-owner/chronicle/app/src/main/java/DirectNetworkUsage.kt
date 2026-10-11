package fixture

fun copiedRead(manager: android.app.usage.NetworkStatsManager) {
    // ruleid: network-usage-single-owner
    manager.querySummary(1, null, 0L, 1L)
}
