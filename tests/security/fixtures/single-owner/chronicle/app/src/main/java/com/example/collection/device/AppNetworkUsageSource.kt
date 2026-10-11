package fixture.owner

fun ownedRead(manager: android.app.usage.NetworkStatsManager) {
    manager.querySummary(1, null, 0L, 1L)
}
