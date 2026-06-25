package app.plink.android.protocol

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject

@Serializable
data class PlinkEnvelope(
    val version: Int = 1,
    val id: String,
    val type: String,
    val sentAt: String,
    val sourceDeviceId: String,
    val targetDeviceId: String,
    val requiresAck: Boolean = false,
    val payload: JsonObject
) {
    fun encode(): String = json.encodeToString(serializer(), this)

    companion object {
        private val json = Json {
            ignoreUnknownKeys = true
            encodeDefaults = true
            prettyPrint = false
        }

        fun decode(raw: String): PlinkEnvelope = json.decodeFromString(serializer(), raw)
    }
}

object PlinkEventType {
    const val PairingOffer = "pairing.offer"
    const val PairingConfirm = "pairing.confirm"
    const val DeviceStatus = "device.status"
    const val CallRinging = "call.ringing"
    const val CallEnded = "call.ended"
    const val MessageReceived = "message.received"
    const val MessageReply = "message.reply"
    const val ClipboardUpdated = "clipboard.updated"
    const val FileOffer = "file.offer"
    const val WebOpen = "web.open"
    const val MediaState = "media.state"
    const val MediaCommand = "media.command"
    const val PermissionState = "permission.state"
    const val Ack = "ack"
    const val Error = "error"
}
