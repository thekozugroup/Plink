package app.plink.android.services

import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification

class PlinkNotificationListenerService : NotificationListenerService() {
    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        // Production transport is wired through the repository layer.
        // This service remains intentionally thin and permission-gated.
    }
}
