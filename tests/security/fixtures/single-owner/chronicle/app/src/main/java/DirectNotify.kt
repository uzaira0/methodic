import androidx.core.app.NotificationManagerCompat

fun direct(context: android.content.Context, manager: android.app.NotificationManager, notification: android.app.Notification) {
    // ruleid: notification-post-single-owner
    NotificationManagerCompat.from(context).notify(7, notification)
    // ruleid: notification-post-single-owner
    manager.notify("tag", 7, notification)
    postNotificationIfPermitted(context, 7, notification)
    synchronized(this) { (this as Object).notify() }
}
