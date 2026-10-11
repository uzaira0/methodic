fun owner() {
    context.startForegroundService(intent)
    startForeground(id, notification)
    startForeground(id, notification, type)
    ServiceCompat.startForeground(service, id, notification, type)
}
