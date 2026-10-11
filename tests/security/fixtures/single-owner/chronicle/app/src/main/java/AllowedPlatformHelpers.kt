fun guarded() {
    UsageAccess.queryEvents(context, start, end)
    UsageAccess.queryUsageStats(context, interval, start, end)
    startForegroundServiceIfPermitted(context, intent)
    promoteForegroundServiceIfPermitted(service, id, notification)
    registerPrivateReceiver(context, receiver, filter)
    registerSystemBroadcastReceiver(context, receiver, filter)
}
