fun bypass() {
    // ruleid: foreground-service-single-owner
    context.startForegroundService(intent)
    // ruleid: foreground-service-single-owner
    startForeground(id, notification)
    // ruleid: foreground-service-single-owner
    startForeground(id, notification, type)
    // ruleid: foreground-service-single-owner
    ServiceCompat.startForeground(service, id, notification, type)
}
