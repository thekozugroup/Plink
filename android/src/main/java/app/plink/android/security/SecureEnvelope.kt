package app.plink.android.security

import app.plink.android.protocol.PlinkEnvelope
import app.plink.android.protocol.PlinkEventType
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonPrimitive
import java.net.URI
import java.security.MessageDigest
import java.time.Instant
import java.util.Base64
import java.util.UUID
import javax.crypto.Mac
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
            issuedAt = issuedAt.toString(),
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

    fun requireAcceptable(envelope: PlinkEnvelope) {
        require(envelope.version == 1) { "Unsupported protocol version." }
        require(envelope.id.isNotBlank()) { "Envelope id is required." }
        require(envelope.sourceDeviceId.isNotBlank()) { "Source device id is required." }
        require(envelope.targetDeviceId.isNotBlank()) { "Target device id is required." }
        require(envelope.encode().toByteArray(Charsets.UTF_8).size <= maxEnvelopeBytes) {
            "Envelope exceeds $maxEnvelopeBytes bytes."
        }

        if (envelope.type == PlinkEventType.WebOpen) {
            val rawUrl = envelope.payload["url"]?.jsonPrimitive?.content.orEmpty()
            require(isAllowedUrl(rawUrl)) { "URL scheme is not allowed." }
        }
    }

    fun isAllowedUrl(rawUrl: String): Boolean = runCatching {
        val scheme = URI(rawUrl).scheme?.lowercase() ?: return@runCatching false
        scheme in allowedUrlSchemes
    }.getOrDefault(false)
}

object PrivacyRedactor {
    private val sensitiveKeys = setOf("preview", "text", "callerHandle", "body", "message", "clipboard")

    fun redact(envelope: PlinkEnvelope): PlinkEnvelope {
        val redactedPayload = JsonObject(
            envelope.payload.mapValues { (key, value) ->
                if (key in sensitiveKeys) JsonPrimitive("[redacted]") else value
            }
        )
        return envelope.copy(payload = redactedPayload)
    }
}
