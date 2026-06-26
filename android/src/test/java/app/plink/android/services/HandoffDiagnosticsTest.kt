package app.plink.android.services

import app.plink.android.pairing.PairedDevice
import app.plink.android.protocol.PlinkEnvelope
import app.plink.android.protocol.PlinkEventType
import app.plink.android.transport.OutboundPlinkSender
import kotlinx.coroutines.delay
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class HandoffDiagnosticsTest {
    @After
    fun tearDown() {
        SharedSessionState.clear()
        SharedOutboundBridge.configure(null)
    }

    @Test
    fun sendFailsClosedWhenUnpaired() {
        SharedSessionState.clear()
        SharedOutboundBridge.configure(null)

        val result = HandoffDiagnostics.send(DiagnosticHandoff.Call)

        assertEquals(DiagnosticSendResult.NotPaired, result)
    }

    @Test
    fun sendForwardsDiagnosticEnvelopeWhenPaired() = runTest {
        val sender = RecordingSender()
        SharedSessionState.configure(
            ActivePlinkSession(
                localDeviceId = "pixel-1",
                pairedDevice = PairedDevice(
                    id = "mac-1",
                    name = "Mac",
                    platform = "macos",
                    endpoint = "192.168.1.5:45731",
                    sessionId = "session",
                    peerPublicKey = "mac-key",
                    localPublicKey = "pixel-key",
                    trusted = true
                ),
                sessionKey = ByteArray(32) { it.toByte() }
            )
        )
        SharedOutboundBridge.configure(sender)

        val result = HandoffDiagnostics.send(DiagnosticHandoff.Message)
        delay(100)

        assertTrue(result is DiagnosticSendResult.Sent)
        assertEquals(1, sender.sent.size)
        assertEquals(PlinkEventType.MessageReceived, sender.sent.single().type)
        assertEquals("pixel-1", sender.sent.single().sourceDeviceId)
        assertEquals("mac-1", sender.sent.single().targetDeviceId)
    }

    private class RecordingSender : OutboundPlinkSender {
        val sent = mutableListOf<PlinkEnvelope>()

        override suspend fun send(envelope: PlinkEnvelope) {
            sent += envelope
        }
    }
}
