package app.plink.android.services

import android.content.ComponentName
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import app.plink.android.PlinkApplication
import app.plink.android.features.ContinuityFeature
import app.plink.android.notifications.NotificationMapper
import app.plink.android.notifications.NotificationHandoff
import app.plink.android.notifications.NotificationCallClassifier
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
            val transition = ReplyDispatchLock.serialized {
                if (!SharedReplyDispatchAuthority.isListenerOwner(this)) return@serialized null
                if (snapshot != null && !SharedNotificationActions.registry.canApplySnapshot(snapshot, sbn.key)) return@serialized null
                replyRoutes.replaceForNotification(sbn.key)
                replyActions.replaceForNotification(sbn.key)
                val feature = if (NotificationCallClassifier.isCall(sbn.notification)) {
                    ContinuityFeature.Calls
                } else {
                    ContinuityFeature.Messages
                }
                val mapper = NotificationMapper(
                    localDeviceId = session.localDeviceId,
                    pairedMacDeviceId = session.pairedDevice.id,
                    replyRoutes = replyRoutes,
                    replyActions = replyActions,
                    notificationActions = SharedNotificationActions.registry,
                    actionContext = this
                )
                val handoff = if (!app.featureSettings.isEnabled(feature)) {
                    if (feature != ContinuityFeature.Calls) return@serialized null
                    if (app.featureSettings.isEnabled(ContinuityFeature.Messages)) {
                        // Query prior ownership before invalidation; never inspect call content here.
                        mapper.retireCallIfPreviouslyOffered(sbn)
                    } else {
                        SharedNotificationActions.registry.invalidateKey(sbn.key)
                        null
                    }
                } else {
                    if (feature == ContinuityFeature.Calls) SharedNotificationActions.registry.invalidateKey(sbn.key)
                    if (removed) mapper.removed(sbn) else mapper.map(sbn)
                }
                handoff?.let { Triple(it, SharedReplyDispatchAuthority.capture(),
                    if (it.retirementOnly) ContinuityFeature.Messages else feature) }
            }
            val (handoff, authority, feature) = transition ?: return
            // Package lookup and drawable rendering must never hold the reply authority lock.
            val envelope = if (!handoff.retirementOnly && app.sessionController.status.value == SessionStatus.READY) {
                NotificationArtwork.decorate(handoff.envelope) {
                    NotificationArtwork.read(packageManager, sbn.packageName)
                }
            } else handoff.envelope
            SharedReplyDispatchAuthority.publishHandoff(this, authority, handoff.copy(envelope = envelope),
                allowed = { app.featureSettings.isEnabled(feature) },
                retirementAllowed = { app.featureSettings.isEnabled(ContinuityFeature.Messages) }) { outgoing ->
                SharedNotificationEvents.trySend(outgoing)
                app.sessionController.sendEnvelope(outgoing)
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
        val eligible = actual.filter { it.packageName != packageName && !NotificationCallClassifier.isCall(it.notification) }
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

    /** Keep retirement and its call together under the existing reply -> admission publication order. */
    fun publishHandoff(owner: Any, generation: ReplyCapabilityGeneration?, handoff: NotificationHandoff,
                       allowed: () -> Boolean, retirementAllowed: () -> Boolean = allowed,
                       send: (app.plink.android.protocol.PlinkEnvelope) -> Unit): Boolean =
        ReplyDispatchLock.serialized {
            if (!isListenerOwner(owner) || !allowed()) return@serialized false
            // Unversioned ordinary previews retain existing offline/durable behavior.
            if ((handoff.retirement != null || handoff.retirementOnly) &&
                (generation == null || !isCurrent(generation))) return@serialized false
            val canRetire = (handoff.retirement != null || handoff.retirementOnly) && retirementAllowed()
            if (handoff.retirementOnly && !canRetire) return@serialized false
            if (canRetire && handoff.retirement != null) {
                send(handoff.retirement)
                // The sink can reenter this monitor and revoke authority during retirement.
                if (!isListenerOwner(owner) || generation == null || !isCurrent(generation) || !allowed()) {
                    return@serialized false
                }
            }
            send(handoff.envelope)
            true
        }
}

object SharedReplyRoutes {
    val registry = ReplyRouteRegistry()
}

object SharedReplyActions {
    val registry = RemoteInputReplyRegistry(
        capabilityGeneration = SharedReplyDispatchAuthority::capture
    )
}
