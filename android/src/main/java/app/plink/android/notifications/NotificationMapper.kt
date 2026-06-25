package app.plink.android.notifications

import android.app.Notification
import android.service.notification.StatusBarNotification
import app.plink.android.continuity.CallRingingEvent
import app.plink.android.continuity.ContinuityEnvelopeFactory
import app.plink.android.continuity.MessageReceivedEvent
import app.plink.android.protocol.PlinkEnvelope

data class NotificationHandoff(
    val envelope: PlinkEnvelope,
    val replyRoute: ReplyRoute?
)

class NotificationMapper(
    private val localDeviceId: String,
    private val pairedMacDeviceId: String,
    private val replyRoutes: ReplyRouteRegistry
) {
    fun map(sbn: StatusBarNotification): NotificationHandoff? {
        val notification = sbn.notification ?: return null
        val title = notification.extras.getCharSequence(Notification.EXTRA_TITLE)?.toString().orEmpty()
        val text = notification.extras.getCharSequence(Notification.EXTRA_TEXT)?.toString().orEmpty()
        if (title.isBlank() && text.isBlank()) return null

        val isCall = notification.category == Notification.CATEGORY_CALL
        val envelope = if (isCall) {
            ContinuityEnvelopeFactory.create(
                CallRingingEvent(
                    callerName = title.ifBlank { sbn.packageName },
                    callerHandle = text.ifBlank { "Pixel call" },
                    canDecline = true
                ),
                sourceDeviceId = localDeviceId,
                targetDeviceId = pairedMacDeviceId
            )
        } else {
            ContinuityEnvelopeFactory.create(
                MessageReceivedEvent(
                    conversationId = notification.shortcutId ?: sbn.key,
                    sender = title.ifBlank { sbn.packageName },
                    preview = text,
                    canReply = notification.actions?.any { action -> !action.remoteInputs.isNullOrEmpty() } == true
                ),
                sourceDeviceId = localDeviceId,
                targetDeviceId = pairedMacDeviceId
            )
        }

        val canReply = !isCall && notification.actions?.any { action -> !action.remoteInputs.isNullOrEmpty() } == true
        val route = if (canReply) {
            replyRoutes.register(
                pairedDeviceId = pairedMacDeviceId,
                sourceEnvelopeId = envelope.id,
                packageName = sbn.packageName,
                notificationKey = sbn.key,
                conversationId = notification.shortcutId,
                canReply = true
            )
        } else {
            null
        }

        val routedEnvelope = if (route != null) {
            envelope.copy(payload = kotlinx.serialization.json.JsonObject(envelope.payload + mapOf(
                "packageName" to kotlinx.serialization.json.JsonPrimitive(route.packageName),
                "notificationKey" to kotlinx.serialization.json.JsonPrimitive(route.notificationKey),
                "replyToken" to kotlinx.serialization.json.JsonPrimitive(route.replyToken)
            )))
        } else {
            envelope
        }

        return NotificationHandoff(envelope = routedEnvelope, replyRoute = route)
    }
}
