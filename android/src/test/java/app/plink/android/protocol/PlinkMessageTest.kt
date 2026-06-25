package app.plink.android.protocol

import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Test

class PlinkMessageTest {
    @Test
    fun envelopeRoundTrips() {
        val envelope = PlinkEnvelope(
            id = "evt-1",
            type = PlinkEventType.MessageReceived,
            sentAt = "2026-06-25T00:00:00Z",
            sourceDeviceId = "pixel",
            targetDeviceId = "mac",
            requiresAck = true,
            payload = buildJsonObject {
                put("sender", "Alex")
                put("canReply", true)
            }
        )

        val decoded = PlinkEnvelope.decode(envelope.encode())

        assertEquals(envelope, decoded)
    }
}
