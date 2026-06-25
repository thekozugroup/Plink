package app.plink.android.security

import app.plink.android.protocol.PlinkEnvelope
import app.plink.android.protocol.PlinkEventType
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import java.time.Instant

class SecureEnvelopeTest {
    private val codec = SecureEnvelopeCodec("test-session-secret".toByteArray())

    @Test
    fun validEnvelopeOpens() {
        val envelope = messageEnvelope()
        val sealed = codec.seal(envelope, sequence = 7, nonce = "nonce", issuedAt = Instant.parse("2026-06-25T00:00:00Z"))

        assertEquals(envelope, codec.open(sealed))
    }

    @Test
    fun tamperedEnvelopeFailsClosed() {
        val sealed = codec.seal(messageEnvelope(), sequence = 7, nonce = "nonce")
        val tampered = sealed.copy(envelope = sealed.envelope.copy(sourceDeviceId = "attacker"))

        assertThrows(IllegalArgumentException::class.java) {
            codec.open(tampered)
        }
    }

    @Test
    fun unsafeWebUrlFailsPolicy() {
        val envelope = PlinkEnvelope(
            id = "evt-web",
            type = PlinkEventType.WebOpen,
            sentAt = "2026-06-25T00:00:00Z",
            sourceDeviceId = "pixel",
            targetDeviceId = "mac",
            payload = buildJsonObject { put("url", "javascript:alert(1)") }
        )

        assertThrows(IllegalArgumentException::class.java) {
            codec.seal(envelope, sequence = 1)
        }
    }

    @Test
    fun redactorMasksSensitiveFields() {
        val redacted = PrivacyRedactor.redact(messageEnvelope())

        assertEquals("\"[redacted]\"", redacted.payload["preview"].toString())
        assertEquals("\"Alex\"", redacted.payload["sender"].toString())
    }

    private fun messageEnvelope(): PlinkEnvelope = PlinkEnvelope(
        id = "evt-1",
        type = PlinkEventType.MessageReceived,
        sentAt = "2026-06-25T00:00:00Z",
        sourceDeviceId = "pixel",
        targetDeviceId = "mac",
        payload = buildJsonObject {
            put("sender", "Alex")
            put("preview", "Private message")
            put("canReply", true)
        }
    )
}
