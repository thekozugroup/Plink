package app.plink.android.protocol

import app.plink.android.security.EncryptedFrameCodec
import app.plink.android.security.PayloadPolicy
import app.plink.android.security.PrivacyRedactor
import app.plink.android.security.ReplayWindow
import java.time.Instant
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class CompanionMetadataPolicyTest {
    private fun envelope(address: String = "10:20:30:40:50:60") = PlinkEnvelope(
        id = "companion-metadata", type = PlinkEventType.DeviceCompanion,
        sentAt = "2026-10-16T00:00:00Z", sourceDeviceId = "mac", targetDeviceId = "pixel",
        payload = buildJsonObject { put("bluetoothAddress", address) }
    )

    @Test fun exactUppercaseAddressOrExplicitUnavailableAreAccepted() {
        for (address in listOf("10:20:30:40:50:60", "A0:B1:C2:D3:E4:F5", "")) {
            val event = envelope(address)
            PayloadPolicy.requireAcceptable(event)
            assertEquals(address, CompanionMetadataPolicy.address(event))
        }
    }

    @Test fun metadataCannotRequestAcknowledgement() {
        assertThrows(IllegalArgumentException::class.java) {
            PayloadPolicy.requireAcceptable(envelope().copy(requiresAck = true))
        }
    }

    @Test fun placeholdersMalformedAndWrongTypedAddressesAreRejected() {
        val invalid = listOf("00:00:00:00:00:00", "FF:FF:FF:FF:FF:FF", "02:00:00:00:00:00",
            "aa:bb:cc:dd:ee:ff", " 10:20:30:40:50:60", "10-20-30-40-50-60", "10:20:30:40:50", "100:20:30:40:50:60")
        for (address in invalid) {
            assertThrows(address, IllegalArgumentException::class.java) { PayloadPolicy.requireAcceptable(envelope(address)) }
        }
        for (value in listOf(JsonNull, JsonPrimitive(123), JsonPrimitive(true), JsonArray(emptyList()))) {
            assertThrows(IllegalArgumentException::class.java) {
                PayloadPolicy.requireAcceptable(envelope().copy(payload = buildJsonObject { put("bluetoothAddress", value) }))
            }
        }
        assertThrows(IllegalArgumentException::class.java) {
            PayloadPolicy.requireAcceptable(envelope().copy(payload = buildJsonObject {
                put("bluetoothAddress", "10:20:30:40:50:60"); put("name", "not-identity")
            }))
        }
    }

    @Test fun encryptedMetadataRequiresCorrectPeerKeyRoutingAndFreshFrame() {
        val now = Instant.parse("2026-10-16T00:00:00Z")
        val codec = EncryptedFrameCodec("authenticated-pair-key".toByteArray())
        val event = envelope()
        val frame = codec.seal(event, sequence = 1, issuedAt = now)
        assertThrows(IllegalArgumentException::class.java) {
            codec.open(frame, now = now, expectedSourceDeviceId = "other-mac", expectedTargetDeviceId = "pixel")
        }
        assertThrows(IllegalArgumentException::class.java) {
            EncryptedFrameCodec("different-pair-key".toByteArray()).open(frame, now = now)
        }
        val replay = ReplayWindow()
        assertEquals(event, codec.open(frame, replay, now, "mac", "pixel"))
        assertThrows(IllegalArgumentException::class.java) { codec.open(frame, replay, now, "mac", "pixel") }
    }

    @Test fun diagnosticRedactionRemovesBluetoothAddress() {
        assertEquals(JsonPrimitive("[redacted]"), PrivacyRedactor.redact(envelope()).payload["bluetoothAddress"])
    }
}
