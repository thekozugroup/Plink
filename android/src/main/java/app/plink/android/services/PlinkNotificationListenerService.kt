package app.plink.android.services

import android.content.ComponentName
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import app.plink.android.PlinkApplication
import app.plink.android.features.ContinuityFeature
import app.plink.android.notifications.NotificationMapper
import app.plink.android.notifications.RemoteInputReplyRegistry
import app.plink.android.notifications.ReplyCapabilityGeneration
import app.plink.android.notifications.ReplyDispatchLock
import app.plink.android.notifications.ReplyRouteRegistry

class PlinkNotificationListenerService : NotificationListenerService() {
    private val replyRoutes = SharedReplyRoutes.registry
    private val replyActions = SharedReplyActions.registry

    override fun onListenerConnected() {
        super.onListenerConnected()
        ReplyDispatchLock.serialized {
            SharedReplyDispatchAuthority.listenerConnected()
            replyRoutes.clear()
            replyActions.clear()
        }
        (applicationContext as PlinkApplication).sessionController.refreshMediaSessions()
    }

    override fun onListenerDisconnected() {
        super.onListenerDisconnected()
        revokeListenerReplies()
        requestRebind(ComponentName(this, PlinkNotificationListenerService::class.java))
    }

    override fun onDestroy() {
        revokeListenerReplies()
        super.onDestroy()
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        forward(sbn, removed = false)
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification?) {
        forward(sbn, removed = true)
    }

    private fun forward(sbn: StatusBarNotification?, removed: Boolean) {
        sbn ?: return
        if (sbn.packageName == packageName) return
        val app = applicationContext as PlinkApplication
        val session = app.sessionController.snapshot() ?: return
        try {
            val handoff = ReplyDispatchLock.serialized {
                replyRoutes.replaceForNotification(sbn.key)
                replyActions.replaceForNotification(sbn.key)
                val feature = if (sbn.notification?.category == android.app.Notification.CATEGORY_CALL) {
                    ContinuityFeature.Calls
                } else {
                    ContinuityFeature.Messages
                }
                if (!app.featureSettings.isEnabled(feature)) return@serialized null
                val mapper = NotificationMapper(
                    localDeviceId = session.localDeviceId,
                    pairedMacDeviceId = session.pairedDevice.id,
                    replyRoutes = replyRoutes,
                    replyActions = replyActions
                )
                if (removed) mapper.removed(sbn) else mapper.map(sbn)
            }
            handoff ?: return
            SharedNotificationEvents.trySend(handoff.envelope)
            app.sessionController.sendEnvelope(handoff.envelope)
        } finally {
            session.sessionKey.fill(0)
        }
    }

    private fun revokeListenerReplies() {
        ReplyDispatchLock.serialized {
            SharedReplyDispatchAuthority.listenerDisconnected()
            replyRoutes.clear()
            replyActions.clear()
        }
    }
}

internal object SharedReplyDispatchAuthority {
    private var listenerConnected = false
    private var listenerEpoch = 0L
    private var sessionGeneration = 0L
    private var sessionActive = false

    fun listenerConnected() {
        listenerEpoch += 1
        listenerConnected = true
    }

    fun listenerDisconnected() {
        listenerEpoch += 1
        listenerConnected = false
    }

    fun sessionChanged(generation: Long, active: Boolean) {
        sessionGeneration = generation
        sessionActive = active
    }

    fun capture(): ReplyCapabilityGeneration? =
        if (listenerConnected && sessionActive) {
            ReplyCapabilityGeneration(listenerEpoch, sessionGeneration)
        } else {
            null
        }

    fun isCurrent(generation: ReplyCapabilityGeneration): Boolean =
        listenerConnected &&
            sessionActive &&
            generation.listenerEpoch == listenerEpoch &&
            generation.sessionGeneration == sessionGeneration
}

object SharedReplyRoutes {
    val registry = ReplyRouteRegistry()
}

object SharedReplyActions {
    val registry = RemoteInputReplyRegistry(
        capabilityGeneration = SharedReplyDispatchAuthority::capture
    )
}
