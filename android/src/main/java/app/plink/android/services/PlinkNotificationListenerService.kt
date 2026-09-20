package app.plink.android.services

import android.content.ComponentName
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import app.plink.android.PlinkApplication
import app.plink.android.features.ContinuityFeature
import app.plink.android.notifications.NotificationMapper
import app.plink.android.notifications.RemoteInputReplyRegistry
import app.plink.android.notifications.ReplyRouteRegistry

class PlinkNotificationListenerService : NotificationListenerService() {
    private val replyRoutes = SharedReplyRoutes.registry
    private val replyActions = SharedReplyActions.registry

    override fun onListenerConnected() {
        super.onListenerConnected()
        (applicationContext as PlinkApplication).sessionController.refreshMediaSessions()
    }

    override fun onListenerDisconnected() {
        super.onListenerDisconnected()
        requestRebind(ComponentName(this, PlinkNotificationListenerService::class.java))
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        forward(sbn, removed = false)
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification?) {
        forward(sbn, removed = true)
    }

    private fun forward(sbn: StatusBarNotification?, removed: Boolean) {
        sbn ?: return
        replyRoutes.replaceForNotification(sbn.key)
        replyActions.replaceForNotification(sbn.key)
        val app = applicationContext as PlinkApplication
        val session = app.sessionController.snapshot() ?: return
        try {
            val feature = if (sbn.notification?.category == android.app.Notification.CATEGORY_CALL) {
                ContinuityFeature.Calls
            } else {
                ContinuityFeature.Messages
            }
            if (!app.featureSettings.isEnabled(feature)) return
            val mapper = NotificationMapper(
                localDeviceId = session.localDeviceId,
                pairedMacDeviceId = session.pairedDevice.id,
                replyRoutes = replyRoutes,
                replyActions = replyActions
            )
            val handoff = (if (removed) mapper.removed(sbn) else mapper.map(sbn)) ?: return
            SharedNotificationEvents.trySend(handoff.envelope)
            app.sessionController.sendEnvelope(handoff.envelope)
        } finally {
            session.sessionKey.fill(0)
        }
    }
}

object SharedReplyRoutes {
    val registry = ReplyRouteRegistry()
}

object SharedReplyActions {
    val registry = RemoteInputReplyRegistry()
}
