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
    fun unknownEventTypeFailsPolicy() {
        val envelope = messageEnvelope().copy(type = "unknown.event")

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

    @Test
    fun encryptedFrameRoundTripsAndRejectsReplay() {
        val frameCodec = EncryptedFrameCodec("test-session-secret".toByteArray())
        val replayWindow = ReplayWindow(maxClockSkewSeconds = 600)
        val issuedAt = Instant.parse("2026-06-25T00:00:00Z")
        val frame = frameCodec.seal(
            envelope = messageEnvelope(),
            sequence = 1,
            nonce = "frame-nonce",
            issuedAt = issuedAt,
            iv = ByteArray(12) { 7 }
        )

        assertEquals(messageEnvelope(), frameCodec.open(frame, replayWindow, now = issuedAt.plusSeconds(1)))
        assertThrows(IllegalArgumentException::class.java) {
            frameCodec.open(frame, replayWindow, now = issuedAt.plusSeconds(2))
        }
    }

    @Test
    fun encryptedFrameRejectsTampering() {
        val frameCodec = EncryptedFrameCodec("test-session-secret".toByteArray())
        val frame = frameCodec.seal(messageEnvelope(), sequence = 1, nonce = "frame-nonce")
        val tampered = frame.copy(cipherText = frame.cipherText.dropLast(2) + "xx")

        assertThrows(IllegalArgumentException::class.java) {
            frameCodec.open(tampered)
        }
    }

    @Test
    fun encryptedFrameRejectsUnexpectedDeviceIds() {
        val frameCodec = EncryptedFrameCodec("test-session-secret".toByteArray())
        val frame = frameCodec.seal(messageEnvelope(), sequence = 1, nonce = "frame-nonce")

        assertThrows(IllegalArgumentException::class.java) {
            frameCodec.open(
                frame,
                expectedSourceDeviceId = "other-pixel",
                expectedTargetDeviceId = "mac"
            )
        }
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
            put("packageName", "com.example.messages")
            put("notificationKey", "key")
            put("replyToken", "token")
        }
    )
}
