package app.plink.android.services

import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import app.plink.android.notifications.NotificationMapper
import app.plink.android.notifications.ReplyRouteRegistry

class PlinkNotificationListenerService : NotificationListenerService() {
    private val replyRoutes = SharedReplyRoutes.registry
    private val mapper by lazy {
        NotificationMapper(
            localDeviceId = "pixel-local",
            pairedMacDeviceId = "mac-paired",
            replyRoutes = replyRoutes
        )
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        sbn ?: return
        val handoff = mapper.map(sbn) ?: return
        SharedNotificationEvents.trySend(handoff.envelope)
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification?) {
        sbn?.key?.let(replyRoutes::removeByNotificationKey)
    }
}

object SharedReplyRoutes {
    val registry = ReplyRouteRegistry()
}
