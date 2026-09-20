package app.plink.android.security

import app.plink.android.protocol.PlinkEnvelope
import app.plink.android.protocol.PlinkEventType
import app.plink.android.protocol.FileTransferPayloadPolicy
import app.plink.android.protocol.ScreenPreviewPayloadPolicy
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import java.net.URI
import java.security.MessageDigest
import java.security.SecureRandom
import java.time.Instant
import java.util.Base64
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

@Serializable
data class SecurePlinkEnvelope(
    val envelope: PlinkEnvelope,
    val sequence: Long,
    val nonce: String,
    val issuedAt: String,
    val signature: String
) {
    fun signingInput(): String = listOf(sequence.toString(), issuedAt, nonce, envelope.encode()).joinToString("\n")
}

class SecureEnvelopeCodec(private val sessionKey: ByteArray) {
    fun seal(
        envelope: PlinkEnvelope,
        sequence: Long,
        nonce: String = UUID.randomUUID().toString(),
        issuedAt: Instant = Instant.now()
    ): SecurePlinkEnvelope {
        PayloadPolicy.requireAcceptable(envelope)
        val unsigned = SecurePlinkEnvelope(
            envelope = envelope,
            sequence = sequence,
            nonce = nonce,
            issuedAt = PlinkTime.canonicalTimestamp(issuedAt),
            signature = ""
        )
        return unsigned.copy(signature = sign(unsigned.signingInput()))
    }

    fun open(secureEnvelope: SecurePlinkEnvelope): PlinkEnvelope {
        val expected = sign(secureEnvelope.copy(signature = "").signingInput())
        require(MessageDigest.isEqual(expected.toByteArray(), secureEnvelope.signature.toByteArray())) {
            "Envelope signature failed verification."
        }
        PayloadPolicy.requireAcceptable(secureEnvelope.envelope)
        return secureEnvelope.envelope
    }

    private fun sign(input: String): String {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(sessionKey, "HmacSHA256"))
        return Base64.getEncoder().encodeToString(mac.doFinal(input.toByteArray(Charsets.UTF_8)))
    }
}

object PayloadPolicy {
    const val maxEnvelopeBytes: Int = 64 * 1024
    private val allowedUrlSchemes = setOf("http", "https")
    private val allowedEventTypes = setOf(
        PlinkEventType.PairingOffer,
        PlinkEventType.PairingConfirm,
        PlinkEventType.DeviceStatus,
        PlinkEventType.CallRinging,
        PlinkEventType.CallEnded,
        PlinkEventType.MessageReceived,
        PlinkEventType.MessageReply,
        PlinkEventType.ClipboardUpdated,
        PlinkEventType.FileOffer,
        PlinkEventType.WebOpen,
        PlinkEventType.MediaState,
        PlinkEventType.MediaCommand,
        PlinkEventType.PermissionState,
        PlinkEventType.Ack,
        PlinkEventType.Error
    ) + FileTransferPayloadPolicy.eventTypes + ScreenPreviewPayloadPolicy.eventTypes

    fun requireAcceptable(envelope: PlinkEnvelope) {
        require(envelope.version == 1) { "Unsupported protocol version." }
        require(envelope.id.isNotBlank()) { "Envelope id is required." }
        require(envelope.type in allowedEventTypes) { "Unsupported event type." }
        require(envelope.sourceDeviceId.isNotBlank()) { "Source device id is required." }
        require(envelope.targetDeviceId.isNotBlank()) { "Target device id is required." }
        require(envelope.encode().toByteArray(Charsets.UTF_8).size <= maxEnvelopeBytes) {
            "Envelope exceeds $maxEnvelopeBytes bytes."
        }
        FileTransferPayloadPolicy.requireAcceptable(envelope)
        ScreenPreviewPayloadPolicy.requireAcceptable(envelope)

        if (envelope.type == PlinkEventType.WebOpen) {
            val rawUrl = envelope.payload["url"]?.jsonPrimitive?.content.orEmpty()
            require(isAllowedUrl(rawUrl)) { "URL scheme is not allowed." }
        }
        when (envelope.type) {
            PlinkEventType.CallRinging -> {
                requireString(envelope.payload, "callerName", maxLength = 200)
                requireString(envelope.payload, "callerHandle", maxLength = 200)
            }
            PlinkEventType.MessageReceived -> {
                requireString(envelope.payload, "sender", maxLength = 200)
                requireString(envelope.payload, "preview", maxLength = 4_000)
                if (envelope.payload["canReply"]?.jsonPrimitive?.booleanOrNull == true) {
                    requireString(envelope.payload, "packageName", maxLength = 300)
                    requireString(envelope.payload, "notificationKey", maxLength = 500)
                    requireString(envelope.payload, "replyToken", maxLength = 200)
                }
            }
            PlinkEventType.MessageReply -> {
                requireString(envelope.payload, "sourceEnvelopeId", maxLength = 200)
                requireString(envelope.payload, "packageName", maxLength = 300)
                requireString(envelope.payload, "notificationKey", maxLength = 500)
                requireString(envelope.payload, "replyToken", maxLength = 200)
                requireString(envelope.payload, "text", maxLength = 4_000)
            }
            PlinkEventType.ClipboardUpdated -> {
                requireString(envelope.payload, "text", maxLength = 64 * 1024)
            }
        }
    }

    fun isAllowedUrl(rawUrl: String): Boolean = runCatching {
        val scheme = URI(rawUrl).scheme?.lowercase() ?: return@runCatching false
        scheme in allowedUrlSchemes
    }.getOrDefault(false)

    private fun requireString(payload: JsonObject, key: String, maxLength: Int) {
        val value = payload[key]?.jsonPrimitive?.contentOrNull
        require(!value.isNullOrBlank()) { "payload.$key is required." }
        require(value.length <= maxLength) { "payload.$key exceeds $maxLength characters." }
    }
}

object PrivacyRedactor {
    private val sensitiveKeys = setOf("preview", "text", "callerHandle", "body", "message", "clipboard", "data", "name")

    fun redact(envelope: PlinkEnvelope): PlinkEnvelope {
        val redactedPayload = JsonObject(
            envelope.payload.mapValues { (key, value) ->
                if (key in sensitiveKeys) JsonPrimitive("[redacted]") else value
            }
        )
        return envelope.copy(payload = redactedPayload)
    }
}

@Serializable
data class EncryptedPlinkFrame(
    val version: Int = 1,
    val sequence: Long,
    val nonce: String,
    val issuedAt: String,
    val sourceDeviceId: String,
    val targetDeviceId: String,
    val cipherText: String,
    val signature: String
) {
    fun signingInput(): String = listOf(
        version.toString(),
        sequence.toString(),
        nonce,
        issuedAt,
        sourceDeviceId,
        targetDeviceId,
        cipherText
    ).joinToString("\n")
}

sealed interface AuthenticatedFrameResult {
    data class Message(val envelope: PlinkEnvelope) : AuthenticatedFrameResult
    data class RejectedScreen(val rejection: AuthenticatedScreenRejection) : AuthenticatedFrameResult
}

data class AuthenticatedScreenRejection(
    val sourceDeviceId: String,
    val targetDeviceId: String,
    val requestId: String?,
    val streamId: String?
)

class ReplayWindow(
    private val maxClockSkewSeconds: Long = 300
) {
    private val state = InMemoryFrameStateStore()

    @Synchronized
    fun accept(frame: EncryptedPlinkFrame, now: Instant = Instant.now()) {
        val issuedAt = Instant.parse(frame.issuedAt)
        require(issuedAt >= now.minusSeconds(maxClockSkewSeconds) && issuedAt <= now.plusSeconds(maxClockSkewSeconds)) {
            "Frame timestamp is outside the allowed clock skew."
        }
        state.accept("replay", frame.sequence, frame.nonce)
    }
}

class EncryptedFrameCodec(sessionKey: ByteArray) {
    private val keyScope = Base64.getEncoder().encodeToString(MessageDigest.getInstance("SHA-256").digest(sessionKey))
    fun stateScope(sourceDeviceId: String, targetDeviceId: String): String =
        listOf(keyScope, sourceDeviceId, targetDeviceId).joinToString("") { "${it.toByteArray(Charsets.UTF_8).size}:$it" }

    private val aesKey = MessageDigest.getInstance("SHA-256").digest(sessionKey)
    private val hmacKey = MessageDigest.getInstance("SHA-256").digest("plink-frame-hmac".toByteArray() + sessionKey)

    fun seal(
        envelope: PlinkEnvelope,
        sequence: Long,
        nonce: String = UUID.randomUUID().toString(),
        issuedAt: Instant = Instant.now(),
        iv: ByteArray = randomIv()
    ): EncryptedPlinkFrame {
        PayloadPolicy.requireAcceptable(envelope)
        val canonicalIssuedAt = PlinkTime.canonicalTimestamp(issuedAt)
        val aad = aad(version = 1, sequence = sequence, nonce = nonce, issuedAt = canonicalIssuedAt, envelope = envelope)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(aesKey, "AES"), GCMParameterSpec(128, iv))
        cipher.updateAAD(aad)
        val encrypted = cipher.doFinal(envelope.encode().toByteArray(Charsets.UTF_8))
        val frame = EncryptedPlinkFrame(
            sequence = sequence,
            nonce = nonce,
            issuedAt = canonicalIssuedAt,
            sourceDeviceId = envelope.sourceDeviceId,
            targetDeviceId = envelope.targetDeviceId,
            cipherText = Base64.getEncoder().encodeToString(iv + encrypted),
            signature = ""
        )
        return frame.copy(signature = sign(frame.signingInput()))
    }

    fun open(
        frame: EncryptedPlinkFrame,
        replayWindow: ReplayWindow? = null,
        now: Instant = Instant.now(),
        expectedSourceDeviceId: String? = null,
        expectedTargetDeviceId: String? = null,
        stateStore: FrameStateStore? = null
    ): PlinkEnvelope = when (val result = openAuthenticated(
        frame = frame,
        replayWindow = replayWindow,
        now = now,
        expectedSourceDeviceId = expectedSourceDeviceId,
        expectedTargetDeviceId = expectedTargetDeviceId,
        stateStore = stateStore
    )) {
        is AuthenticatedFrameResult.Message -> result.envelope
        is AuthenticatedFrameResult.RejectedScreen -> throw IllegalArgumentException("Invalid screen message.")
    }

    fun openAuthenticated(
        frame: EncryptedPlinkFrame,
        replayWindow: ReplayWindow? = null,
        now: Instant = Instant.now(),
        expectedSourceDeviceId: String? = null,
        expectedTargetDeviceId: String? = null,
        stateStore: FrameStateStore? = null,
        wireBytes: Int? = null
    ): AuthenticatedFrameResult {
        require(frame.version == 1) { "Unsupported frame version." }
        if (expectedSourceDeviceId != null) {
            require(frame.sourceDeviceId == expectedSourceDeviceId) { "Unexpected source device." }
        }
        if (expectedTargetDeviceId != null) {
            require(frame.targetDeviceId == expectedTargetDeviceId) { "Unexpected target device." }
        }
        val expected = sign(frame.copy(signature = "").signingInput())
        require(MessageDigest.isEqual(expected.toByteArray(), frame.signature.toByteArray())) {
            "Frame signature failed verification."
        }
        val combined = Base64.getDecoder().decode(frame.cipherText)
        require(combined.size > 12) { "Encrypted frame is malformed." }
        val iv = combined.copyOfRange(0, 12)
        val encrypted = combined.copyOfRange(12, combined.size)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(aesKey, "AES"), GCMParameterSpec(128, iv))
        cipher.updateAAD(aad(frame))
        val raw = String(cipher.doFinal(encrypted), Charsets.UTF_8)
        val screen = ScreenPreviewPayloadPolicy.inspectAuthenticated(raw)
        if (screen == null) {
            val envelope = PlinkEnvelope.decode(raw)
            requireRouting(envelope, frame, expectedSourceDeviceId, expectedTargetDeviceId)
            PayloadPolicy.requireAcceptable(envelope)
            acceptFreshFrame(frame, replayWindow, now, stateStore)
            return AuthenticatedFrameResult.Message(envelope)
        }
        require(screen.sourceDeviceId == frame.sourceDeviceId && screen.targetDeviceId == frame.targetDeviceId) {
            "Screen routing mismatch."
        }
        if (expectedSourceDeviceId != null) {
            require(screen.sourceDeviceId == expectedSourceDeviceId) { "Unexpected source device." }
        }
        if (expectedTargetDeviceId != null) {
            require(screen.targetDeviceId == expectedTargetDeviceId) { "Unexpected target device." }
        }
        acceptFreshFrame(frame, replayWindow, now, stateStore)
        val envelope = runCatching {
            if (wireBytes != null) {
                require(wireBytes in 1..ScreenPreviewPayloadPolicy.maxScreenWireBytes) {
                    "Screen wire frame exceeds its limit."
                }
            }
            ScreenPreviewPayloadPolicy.validateRawJSON(raw)
            PlinkEnvelope.decodeUnchecked(raw).also {
                require(screen.type != null && it.type == screen.type) { "Ambiguous screen type." }
                requireRouting(it, frame, expectedSourceDeviceId, expectedTargetDeviceId)
                PayloadPolicy.requireAcceptable(it)
            }
        }.getOrNull()
        return if (envelope != null) {
            AuthenticatedFrameResult.Message(envelope)
        } else {
            AuthenticatedFrameResult.RejectedScreen(
                AuthenticatedScreenRejection(
                    sourceDeviceId = screen.sourceDeviceId,
                    targetDeviceId = screen.targetDeviceId,
                    requestId = screen.requestId,
                    streamId = screen.streamId
                )
            )
        }
    }

    private fun requireRouting(
        envelope: PlinkEnvelope,
        frame: EncryptedPlinkFrame,
        expectedSourceDeviceId: String?,
        expectedTargetDeviceId: String?
    ) {
        require(envelope.sourceDeviceId == frame.sourceDeviceId) { "Source device mismatch." }
        require(envelope.targetDeviceId == frame.targetDeviceId) { "Target device mismatch." }
        if (expectedSourceDeviceId != null) {
            require(envelope.sourceDeviceId == expectedSourceDeviceId) { "Unexpected source device." }
        }
        if (expectedTargetDeviceId != null) {
            require(envelope.targetDeviceId == expectedTargetDeviceId) { "Unexpected target device." }
        }
    }

    private fun acceptFreshFrame(
        frame: EncryptedPlinkFrame,
        replayWindow: ReplayWindow?,
        now: Instant,
        stateStore: FrameStateStore?
    ) {
        val issuedAt = Instant.parse(frame.issuedAt)
        require(issuedAt >= now.minusSeconds(300) && issuedAt <= now.plusSeconds(300)) { "Stale frame." }
        replayWindow?.accept(frame, now)
        stateStore?.accept(stateScope(frame.sourceDeviceId, frame.targetDeviceId), frame.sequence, frame.nonce)
    }

    private fun aad(frame: EncryptedPlinkFrame): ByteArray = listOf(
        frame.version.toString(),
        frame.sequence.toString(),
        frame.nonce,
        frame.issuedAt,
        frame.sourceDeviceId,
        frame.targetDeviceId
    ).joinToString("\n").toByteArray(Charsets.UTF_8)

    private fun aad(version: Int, sequence: Long, nonce: String, issuedAt: String, envelope: PlinkEnvelope): ByteArray =
        listOf(
            version.toString(),
            sequence.toString(),
            nonce,
            issuedAt,
            envelope.sourceDeviceId,
            envelope.targetDeviceId
        ).joinToString("\n").toByteArray(Charsets.UTF_8)

    private fun sign(input: String): String {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(hmacKey, "HmacSHA256"))
        return Base64.getEncoder().encodeToString(mac.doFinal(input.toByteArray(Charsets.UTF_8)))
    }

    private fun randomIv(): ByteArray = ByteArray(12).also { SecureRandom().nextBytes(it) }
}
