package app.plink.android.services

import app.plink.android.protocol.PlinkEnvelope
import app.plink.android.protocol.PlinkEventType
import app.plink.android.transport.OutboundPlinkSender
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.buildJsonObject
import org.junit.Assert.assertEquals
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class PlinkEventForwarderTest {
    @Test
    fun forwardsCapturedNotificationEventsToConfiguredSender() = runTest {
        val events = Channel<PlinkEnvelope>(capacity = Channel.BUFFERED)
        val sender = RecordingSender()
        val forwarder = PlinkEventForwarder(
            events.receiveAsFlow(),
            sender,
            CoroutineScope(UnconfinedTestDispatcher(testScheduler))
        )
        val envelope = PlinkEnvelope(
            id = "evt-1",
            type = PlinkEventType.Ack,
            sentAt = "2026-06-25T00:00:00Z",
            sourceDeviceId = "pixel",
            targetDeviceId = "mac",
            payload = buildJsonObject {}
        )

        forwarder.start()
        events.send(envelope)
        advanceUntilIdle()
        forwarder.stop()

        assertEquals(listOf(envelope), sender.sent)
    }

    private class RecordingSender : OutboundPlinkSender {
        val sent = mutableListOf<PlinkEnvelope>()

        override suspend fun send(envelope: PlinkEnvelope) {
            sent += envelope
        }
    }
}
