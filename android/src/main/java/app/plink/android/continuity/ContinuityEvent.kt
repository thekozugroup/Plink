package app.plink.android.continuity

import app.plink.android.protocol.PlinkEnvelope
import app.plink.android.protocol.PlinkEventType
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.time.Instant
import java.net.URI
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

data class MediaStateEvent(
    val sessionId: String,
    val title: String,
    val artist: String,
    val playing: Boolean,
    val canPlay: Boolean,
    val canPause: Boolean,
    val canNext: Boolean,
    val canPrevious: Boolean
) : ContinuityEvent {
    override val type: String = PlinkEventType.MediaState
    override val requiresAck: Boolean = false

    override fun payload(): JsonObject = buildJsonObject {
        put("sessionId", sessionId)
        put("title", title)
        put("artist", artist)
        put("playing", playing)
        put("canPlay", canPlay)
        put("canPause", canPause)
        put("canNext", canNext)
        put("canPrevious", canPrevious)
    }
}

sealed interface SharedText {
    data class Clipboard(val text: String) : SharedText
    data class Web(val url: String) : SharedText
}

object SharedTextClassifier {
    fun classify(text: String): SharedText {
        val value = text.trim()
        require(value.isNotEmpty()) { "Shared text cannot be blank." }
        val scheme = runCatching { URI(value).scheme?.lowercase() }.getOrNull()
        return if (scheme == "http" || scheme == "https") SharedText.Web(value) else SharedText.Clipboard(value)
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
