object DistributionRestrictedRuntime {
    fun notificationListenerAccessGranted() {
        manager.isNotificationListenerAccessGranted(component)
        NotificationManagerCompat.getEnabledListenerPackages(context)
    }
}
