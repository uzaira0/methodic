fun postNotificationIfPermitted(context: android.content.Context, id: Int, notification: android.app.Notification): Boolean {
    androidx.core.app.NotificationManagerCompat.from(context).notify(null, id, notification)
    return true
}
