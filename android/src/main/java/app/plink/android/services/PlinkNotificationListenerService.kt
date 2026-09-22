package app.plink.android.services

import android.content.ComponentName
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import app.plink.android.PlinkApplication
import app.plink.android.features.ContinuityFeature
import app.plink.android.notifications.NotificationMapper
import app.plink.android.notifications.NotificationArtwork
import app.plink.android.notifications.RemoteInputReplyRegistry
import app.plink.android.notifications.ReplyCapabilityGeneration
import app.plink.android.notifications.ReplyDispatchLock
import app.plink.android.notifications.ReplyRouteRegistry

class PlinkNotificationListenerService : NotificationListenerService() {
    private val replyRoutes = SharedReplyRoutes.registry
    private val replyActions = SharedReplyActions.registry

    private var lastRefreshScope: Pair<String, Long>? = null

    override fun onListenerConnected() {
        super.onListenerConnected()
        ReplyDispatchLock.serialized {
            SharedReplyDispatchAuthority.listenerConnected(this)
            replyRoutes.clear()
            replyActions.clear()
            SharedNotificationActions.registry.setListenerAvailable(true, forceReset = true)
            SharedNotificationActions.registry.setFeatureEnabled((applicationContext as PlinkApplication).featureSettings.isEnabled(ContinuityFeature.Messages))
            SharedNotificationActions.attach(this)
        }
        (applicationContext as PlinkApplication).sessionController.refreshMediaSessions()
    }

    override fun onListenerDisconnected() {
        super.onListenerDisconnected()
        if (revokeListenerReplies()) requestRebind(ComponentName(this, PlinkNotificationListenerService::class.java))
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

    private fun forward(sbn: StatusBarNotification?, removed: Boolean, snapshot: app.plink.android.notifications.NotificationActionSnapshot? = null) {
        sbn ?: return
        if (sbn.packageName == packageName) return
        val app = applicationContext as PlinkApplication
        val session = app.sessionController.snapshot() ?: return
        try {
            val handoff = ReplyDispatchLock.serialized {
                if (!SharedReplyDispatchAuthority.isListenerOwner(this)) return@serialized null
                if (snapshot != null && !SharedNotificationActions.registry.canApplySnapshot(snapshot, sbn.key)) return@serialized null
                replyRoutes.replaceForNotification(sbn.key)
                replyActions.replaceForNotification(sbn.key)
                val feature = if (sbn.notification?.category == android.app.Notification.CATEGORY_CALL) {
                    ContinuityFeature.Calls
                } else {
                    ContinuityFeature.Messages
                }
                if (feature == ContinuityFeature.Calls) SharedNotificationActions.registry.invalidateKey(sbn.key)
                if (!app.featureSettings.isEnabled(feature)) return@serialized null
                val mapper = NotificationMapper(
                    localDeviceId = session.localDeviceId,
                    pairedMacDeviceId = session.pairedDevice.id,
                    replyRoutes = replyRoutes,
                    replyActions = replyActions,
                    notificationActions = SharedNotificationActions.registry,
                    actionContext = this
                )
                if (removed) mapper.removed(sbn) else mapper.map(sbn)
            }
            handoff ?: return
            // Package lookup and drawable rendering must never hold the reply authority lock.
            val envelope = if (app.sessionController.status.value == SessionStatus.READY) {
                NotificationArtwork.decorate(handoff.envelope) {
                    NotificationArtwork.read(packageManager, sbn.packageName)
                }
            } else handoff.envelope
            ReplyDispatchLock.serialized {
                if (SharedReplyDispatchAuthority.isListenerOwner(this)) {
                    SharedNotificationEvents.trySend(envelope)
                    app.sessionController.sendEnvelope(envelope)
                }
            }
        } finally {
            session.sessionKey.fill(0)
        }
    }

    internal fun refreshActionSnapshot(force: Boolean) {
        val registry = SharedNotificationActions.registry
        val snapshot = ReplyDispatchLock.serialized {
            if (SharedReplyDispatchAuthority.isListenerOwner(this)) registry.captureSnapshot() else null
        } ?: return
        val identity = snapshot.session to snapshot.epoch
        if (!force && lastRefreshScope == identity) return
        // Framework access and artwork remain outside ReplyDispatchLock.
        val actual = runCatching { activeNotifications?.toList() }.getOrNull() ?: return
        if (registry.currentSession() != snapshot.session) return
        lastRefreshScope = identity
        val eligible = actual.filter { it.packageName != packageName && it.notification?.category != android.app.Notification.CATEGORY_CALL }
        eligible.take(128).forEach { forward(it, removed = false, snapshot = snapshot) }
        ReplyDispatchLock.serialized {
            if (!SharedReplyDispatchAuthority.isListenerOwner(this)) return@serialized
            registry.removeMissing(snapshot, eligible.mapTo(mutableSetOf()) { it.key }).forEach { tombstone ->
                val key = tombstone.payload["notificationKey"]?.let { (it as kotlinx.serialization.json.JsonPrimitive).content }
                if (key != null) { replyRoutes.removeByNotificationKey(key); replyActions.removeByNotificationKey(key) }
                SharedOutboundBridge.tryForward(tombstone)
            }
        }
    }

    private fun revokeListenerReplies(): Boolean = ReplyDispatchLock.serialized {
        lastRefreshScope = null
        if (!SharedReplyDispatchAuthority.listenerDisconnected(this)) return@serialized false
        SharedNotificationActions.detach(this)
        SharedNotificationActions.registry.setListenerAvailable(false)
        replyRoutes.clear()
        replyActions.clear()
        true
    }

}

internal object SharedReplyDispatchAuthority {
    private var listenerConnected = false
    private var listenerOwner: Any? = null
    private var listenerEpoch = 0L
    private var sessionGeneration = 0L
    private var sessionActive = false

    fun listenerConnected(owner: Any) {
        listenerOwner = owner
        listenerEpoch += 1
        listenerConnected = true
    }

    fun listenerDisconnected(owner: Any): Boolean {
        if (!isListenerOwner(owner)) return false
        listenerOwner = null
        listenerEpoch += 1
        listenerConnected = false
        return true
    }

    fun isListenerOwner(owner: Any): Boolean = listenerConnected && listenerOwner === owner

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
