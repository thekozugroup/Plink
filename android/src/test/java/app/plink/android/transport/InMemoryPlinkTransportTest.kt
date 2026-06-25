package app.plink.android.transport

import app.plink.android.protocol.PlinkEnvelope
import app.plink.android.protocol.PlinkEventType
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.buildJsonObject
import org.junit.Assert.assertEquals
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class InMemoryPlinkTransportTest {
    @Test
    fun sendEmitsInboundEnvelope() = runTest {
        val transport = InMemoryPlinkTransport()
        val envelope = PlinkEnvelope(
            id = "evt-1",
            type = PlinkEventType.Ack,
            sentAt = "2026-06-25T00:00:00Z",
            sourceDeviceId = "pixel",
            targetDeviceId = "mac",
            payload = buildJsonObject {}
        )

        val received = async { transport.inbound.first() }
        transport.send(envelope)

        assertEquals(envelope, received.await())
    }
}
