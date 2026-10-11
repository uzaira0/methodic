package fixture

fun copiedFlags(): Int {
    // ruleid: pending-intent-mutability-single-owner
    return android.app.PendingIntent.FLAG_MUTABLE
}
