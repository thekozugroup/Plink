package app.plink.android.services

import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import app.plink.android.notifications.NotificationMapper
import app.plink.android.notifications.RemoteInputReplyRegistry
import app.plink.android.notifications.ReplyRouteRegistry

class PlinkNotificationListenerService : NotificationListenerService() {
    private val replyRoutes = SharedReplyRoutes.registry
    private val replyActions = SharedReplyActions.registry

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        sbn ?: return
        val session = SharedSessionState.snapshot() ?: return
        val mapper = NotificationMapper(
            localDeviceId = session.localDeviceId,
            pairedMacDeviceId = session.pairedDevice.id,
            replyRoutes = replyRoutes,
            replyActions = replyActions
        )
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
