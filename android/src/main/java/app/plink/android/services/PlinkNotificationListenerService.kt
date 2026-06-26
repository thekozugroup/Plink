package app.plink.android.services

import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import app.plink.android.notifications.NotificationMapper
import app.plink.android.notifications.RemoteInputReplyRegistry
import app.plink.android.notifications.ReplyRouteRegistry

class PlinkNotificationListenerService : NotificationListenerService() {
    private val replyRoutes = SharedReplyRoutes.registry
    private val replyActions = SharedReplyActions.registry
    private val mapper by lazy {
        NotificationMapper(
            localDeviceId = "pixel-local",
            pairedMacDeviceId = "mac-demo",
            replyRoutes = replyRoutes,
            replyActions = replyActions
        )
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        sbn ?: return
        val handoff = mapper.map(sbn) ?: return
        SharedNotificationEvents.trySend(handoff.envelope)
        SharedOutboundBridge.tryForward(handoff.envelope)
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification?) {
        sbn?.key?.let { key ->
            replyRoutes.removeByNotificationKey(key)
            replyActions.removeByNotificationKey(key)
        }
    }
}

object SharedReplyRoutes {
    val registry = ReplyRouteRegistry()
}

object SharedReplyActions {
    val registry = RemoteInputReplyRegistry()
}
