fun bypass() {
    // ruleid: notification-listener-access-single-owner
    manager.isNotificationListenerAccessGranted(component)
    // ruleid: notification-listener-access-single-owner
    NotificationManagerCompat.getEnabledListenerPackages(context)
}
