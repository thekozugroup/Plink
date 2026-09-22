package app.plink.android.notifications

import android.app.Notification
import android.service.notification.StatusBarNotification
import app.plink.android.continuity.CallRingingEvent
import app.plink.android.continuity.ContinuityEnvelopeFactory
import app.plink.android.continuity.MessageReceivedEvent
import app.plink.android.protocol.PlinkEnvelope
import app.plink.android.protocol.PlinkEventType
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

data class NotificationHandoff(
    val envelope: PlinkEnvelope,
    val replyRoute: ReplyRoute?
)

class NotificationMapper(
    private val localDeviceId: String,
    private val pairedMacDeviceId: String,
    private val replyRoutes: ReplyRouteRegistry,
    private val replyActions: RemoteInputReplyRegistry? = null,
    private val notificationActions: NotificationActionRegistry? = null,
    private val actionContext: android.content.Context? = null,
    private val actionUserUnlocked: ((android.os.UserHandle) -> Boolean?)? = null
) {
    fun map(sbn: StatusBarNotification): NotificationHandoff? {
        replyRoutes.replaceForNotification(sbn.key)
        replyActions?.replaceForNotification(sbn.key)
        val notification = sbn.notification ?: return null
        val title = notification.extras.getCharSequence(Notification.EXTRA_TITLE)?.toString().orEmpty()
        val text = notification.extras.getCharSequence(Notification.EXTRA_TEXT)?.toString().orEmpty()
        if (title.isBlank() && text.isBlank()) return removed(sbn)

        val isCall = notification.category == Notification.CATEGORY_CALL
        if (isCall) notificationActions?.invalidateKey(sbn.key)
        if (isCall && !isIncomingCall(notification)) return removed(sbn)
        val envelope = if (isCall) {
            ContinuityEnvelopeFactory.create(
                CallRingingEvent(
                    callerName = title.ifBlank { sbn.packageName },
                    callerHandle = text.ifBlank { "Phone call" },
                    canDecline = false
                ),
                sourceDeviceId = localDeviceId,
                targetDeviceId = pairedMacDeviceId
            )
        } else {
            ContinuityEnvelopeFactory.create(
                MessageReceivedEvent(
                    conversationId = notification.shortcutId ?: sbn.key,
                    sender = title.ifBlank { sbn.packageName },
                    preview = text.ifBlank { title },
                    canReply = false
                ),
                sourceDeviceId = localDeviceId,
                targetDeviceId = pairedMacDeviceId
            )
        }

        val base = envelope.copy(payload = JsonObject(envelope.payload + mapOf(
            "packageName" to JsonPrimitive(sbn.packageName), "notificationKey" to JsonPrimitive(sbn.key)
        )))
        val specs = if (!isCall && actionContext != null) notification.actions.orEmpty().map { action ->
            AndroidNotificationActions.describe(actionContext, action, sbn.user,
                actionUserUnlocked ?: { AndroidNotificationActions.isUserUnlocked(actionContext, it) })
        } else emptyList()
        val offer = if (!isCall) notificationActions?.offer(base, specs) else null
        val safeIndex = if (notificationActions != null) specs.take(10).indexOfFirst {
            it.kind == "text" && !it.authenticationRequired
        }.takeIf { it >= 0 && offer?.claims?.containsKey(it) == true }
        else notification.actions?.indexOfFirst(::isEligibleReplyAction)?.takeIf { !isCall && it >= 0 }
        val replyAction = safeIndex?.let { notification.actions[it] }
        val route = if (replyAction != null) {
            val token = offer?.envelope?.payload?.get("action${safeIndex}Token")?.let {
                (it as JsonPrimitive).content
            } ?: java.util.UUID.randomUUID().toString()
            val candidate = replyRoutes.register(
                pairedDeviceId = pairedMacDeviceId, sourceEnvelopeId = envelope.id,
                packageName = sbn.packageName, notificationKey = sbn.key,
                conversationId = notification.shortcutId, canReply = true, replyToken = token
            )
            if (replyActions?.register(token, sbn.key, replyAction, offer?.claims?.get(safeIndex)) == true) candidate
            else { replyRoutes.consume(token); replyActions?.remove(token); null }
        } else null

        val identity = mapOf(
            "packageName" to JsonPrimitive(sbn.packageName),
            "notificationKey" to JsonPrimitive(sbn.key)
        )
        val capability = route?.let { mapOf(
            "canReply" to JsonPrimitive(true),
            "replyToken" to JsonPrimitive(it.replyToken)
        ) }.orEmpty()
        val offeredEnvelope = offer?.envelope ?: envelope
        val routedEnvelope = offeredEnvelope.copy(payload = JsonObject(offeredEnvelope.payload + identity + capability))

        return NotificationHandoff(envelope = routedEnvelope, replyRoute = route)
    }

    /** A tombstone retains notification identity after its reply capability is revoked. */
    fun removed(sbn: StatusBarNotification): NotificationHandoff {
        replyRoutes.removeByNotificationKey(sbn.key)
        replyActions?.removeByNotificationKey(sbn.key)
        val envelope = ContinuityEnvelopeFactory.create(
            MessageReceivedEvent(sbn.notification.shortcutId ?: sbn.key, sbn.packageName, "Notification removed.", false),
            localDeviceId, pairedMacDeviceId
        )
        val tombstone = envelope.copy(
            type = if (sbn.notification.category == Notification.CATEGORY_CALL) PlinkEventType.CallEnded else envelope.type,
            payload = JsonObject(envelope.payload + mapOf(
                "packageName" to JsonPrimitive(sbn.packageName),
                "notificationKey" to JsonPrimitive(sbn.key),
                "removed" to JsonPrimitive(true)
            ))
        )
        val offered = notificationActions?.offer(tombstone, emptyList(), removed = true)?.envelope ?: tombstone
        return NotificationHandoff(offered, null)
    }

    private fun isEligibleReplyAction(action: Notification.Action): Boolean {
        if (android.os.Build.VERSION.SDK_INT < 31) return false
        val inputs = action.remoteInputs ?: return false
        if (action.actionIntent == null || inputs.size != 1 || !inputs.single().allowFreeFormInput || !action.dataOnlyRemoteInputs.isNullOrEmpty()) return false
        if (android.os.Build.VERSION.SDK_INT >= 31 && (action.isAuthenticationRequired || action.actionIntent.isImmutable)) return false
        return true
    }

    private fun isIncomingCall(notification: Notification): Boolean {
        val callType = notification.extras.getInt("android.callType", 0)
        if (callType != 0) return callType == 1
        return notification.flags and Notification.FLAG_ONGOING_EVENT == 0 || notification.fullScreenIntent != null
    }
}
