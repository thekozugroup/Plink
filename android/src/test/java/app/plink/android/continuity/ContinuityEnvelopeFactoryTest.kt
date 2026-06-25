package app.plink.android.continuity

import app.plink.android.protocol.PlinkEventType
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant

class ContinuityEnvelopeFactoryTest {
    @Test
    fun callEventMapsToProtocolEnvelope() {
        val envelope = ContinuityEnvelopeFactory.create(
            event = CallRingingEvent("Alex", "+15551234567"),
            sourceDeviceId = "pixel",
            targetDeviceId = "mac",
            now = Instant.parse("2026-06-25T00:00:00Z")
        )

        assertEquals(PlinkEventType.CallRinging, envelope.type)
        assertTrue(envelope.requiresAck)
        assertEquals("Alex", envelope.payload["callerName"].toString().trim('"'))
    }
}
