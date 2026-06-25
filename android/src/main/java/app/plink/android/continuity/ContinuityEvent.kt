package app.plink.android.continuity

import app.plink.android.protocol.PlinkEnvelope
import app.plink.android.protocol.PlinkEventType
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.time.Instant
import java.util.UUID

sealed interface ContinuityEvent {
    val type: String
    val requiresAck: Boolean

    fun payload(): JsonObject
}

data class CallRingingEvent(
    val callerName: String,
    val callerHandle: String,
    val canAnswer: Boolean = false,
    val canDecline: Boolean = true
) : ContinuityEvent {
    override val type: String = PlinkEventType.CallRinging
    override val requiresAck: Boolean = true

    override fun payload(): JsonObject = buildJsonObject {
        put("callerName", callerName)
        put("callerHandle", callerHandle)
        put("canAnswer", canAnswer)
        put("canDecline", canDecline)
    }
}

data class MessageReceivedEvent(
    val conversationId: String,
    val sender: String,
    val preview: String,
    val canReply: Boolean
) : ContinuityEvent {
    override val type: String = PlinkEventType.MessageReceived
    override val requiresAck: Boolean = true

    override fun payload(): JsonObject = buildJsonObject {
        put("conversationId", conversationId)
        put("sender", sender)
        put("preview", preview)
        put("canReply", canReply)
    }
}

data class ClipboardUpdatedEvent(
    val text: String,
    val localOnly: Boolean = false
) : ContinuityEvent {
    override val type: String = PlinkEventType.ClipboardUpdated
    override val requiresAck: Boolean = false

    override fun payload(): JsonObject = buildJsonObject {
        put("text", text)
        put("localOnly", localOnly)
    }
}

data class WebOpenEvent(val url: String) : ContinuityEvent {
    override val type: String = PlinkEventType.WebOpen
    override val requiresAck: Boolean = false

    override fun payload(): JsonObject = buildJsonObject {
        put("url", url)
    }
}

data class DeviceStatusEvent(
    val batteryLevel: Int,
    val charging: Boolean,
    val network: String
) : ContinuityEvent {
    override val type: String = PlinkEventType.DeviceStatus
    override val requiresAck: Boolean = false

    override fun payload(): JsonObject = buildJsonObject {
        put("batteryLevel", batteryLevel)
        put("charging", charging)
        put("network", network)
    }
}

object ContinuityEnvelopeFactory {
    fun create(
        event: ContinuityEvent,
        sourceDeviceId: String,
        targetDeviceId: String,
        now: Instant = Instant.now()
    ): PlinkEnvelope = PlinkEnvelope(
        id = "evt_${UUID.randomUUID()}",
        type = event.type,
        sentAt = now.toString(),
        sourceDeviceId = sourceDeviceId,
        targetDeviceId = targetDeviceId,
        requiresAck = event.requiresAck,
        payload = event.payload()
    )
}
