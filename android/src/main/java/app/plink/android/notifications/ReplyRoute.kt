package app.plink.android.notifications

import app.plink.android.protocol.PlinkEnvelope
import app.plink.android.protocol.PlinkEventType
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.time.Instant
import java.util.UUID

data class ReplyRoute(
    val pairedDeviceId: String,
    val sourceEnvelopeId: String,
    val packageName: String,
    val notificationKey: String,
    val conversationId: String?,
    val canReply: Boolean,
    val replyToken: String
) {
    init {
        require(pairedDeviceId.isNotBlank()) { "Paired device id is required." }
        require(sourceEnvelopeId.isNotBlank()) { "Source envelope id is required." }
        require(packageName.isNotBlank()) { "Package name is required." }
        require(notificationKey.isNotBlank()) { "Notification key is required." }
        require(replyToken.isNotBlank()) { "Reply token is required." }
    }

    fun requireReplyable(): ReplyRoute {
        require(canReply) { "Notification does not expose a reply action." }
        return this
    }
}

data class ReplyCommand(
    val route: ReplyRoute,
    val text: String,
    val localDeviceId: String
) {
    init {
        route.requireReplyable()
        require(text.isNotBlank()) { "Reply text cannot be blank." }
        require(localDeviceId.isNotBlank()) { "Local device id is required." }
    }

    fun toEnvelope(
        id: String = "reply_${UUID.randomUUID()}",
        sentAt: Instant = Instant.now()
    ): PlinkEnvelope = PlinkEnvelope(
        id = id,
        type = PlinkEventType.MessageReply,
        sentAt = sentAt.toString(),
        sourceDeviceId = localDeviceId,
        targetDeviceId = route.pairedDeviceId,
        requiresAck = true,
        payload = buildJsonObject {
            put("sourceEnvelopeId", route.sourceEnvelopeId)
            put("packageName", route.packageName)
            put("notificationKey", route.notificationKey)
            route.conversationId?.let { put("conversationId", it) }
            put("replyToken", route.replyToken)
            put("text", text.trim())
        }
    )
}

object ReplyRouteFactory {
    fun fromNotificationEnvelope(
        envelope: PlinkEnvelope,
        packageName: String,
        notificationKey: String,
        conversationId: String?,
        canReply: Boolean,
        replyToken: String
    ): ReplyRoute {
        require(envelope.type == PlinkEventType.MessageReceived) {
            "Reply routes can only be built from message notifications."
        }
        return ReplyRoute(
            pairedDeviceId = envelope.sourceDeviceId,
            sourceEnvelopeId = envelope.id,
            packageName = packageName,
            notificationKey = notificationKey,
            conversationId = conversationId,
            canReply = canReply,
            replyToken = replyToken
        )
    }
}
