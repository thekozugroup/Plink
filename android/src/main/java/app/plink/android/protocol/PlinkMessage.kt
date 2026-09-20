package app.plink.android.protocol

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction

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

        fun decode(raw: String): PlinkEnvelope {
            ReconnectPayloadPolicy.validateRawJSON(raw)
            ScreenPreviewPayloadPolicy.validateRawJSON(raw)
            FileTransferPayloadPolicy.validateRawJSON(raw)
            return decodeUnchecked(raw)
        }

        fun decode(raw: ByteArray): PlinkEnvelope = decode(decodeUtf8(raw))

        internal fun decodeUtf8(raw: ByteArray): String = Charsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
            .decode(ByteBuffer.wrap(raw))
            .toString()

        internal fun decodeUnchecked(raw: String): PlinkEnvelope =
            json.decodeFromString(serializer(), raw)
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
    const val FileAccept = "file.accept"
    const val FileChunk = "file.chunk"
    const val FileProgress = "file.progress"
    const val FileComplete = "file.complete"
    const val FileResult = "file.result"
    const val FileCancel = "file.cancel"
    const val ScreenRequest = "screen.request"
    const val ScreenState = "screen.state"
    const val ScreenPull = "screen.pull"
    const val ScreenFrame = "screen.frame"
    const val ScreenIdle = "screen.idle"
    const val ScreenStop = "screen.stop"
    const val WebOpen = "web.open"
    const val MediaState = "media.state"
    const val MediaCommand = "media.command"
    const val PermissionState = "permission.state"
    const val Ack = "ack"
    const val Error = "error"
    const val ReconnectHello = "reconnect.hello"
    const val ReconnectChallenge = "reconnect.challenge"
    const val ReconnectProof = "reconnect.proof"
    const val ReconnectReverse = "reconnect.reverse"
    const val ReconnectReverseProof = "reconnect.reverse_proof"
    const val ReconnectReady = "reconnect.ready"
    const val ReconnectCommit = "reconnect.commit"
    const val ReconnectDone = "reconnect.done"
}
