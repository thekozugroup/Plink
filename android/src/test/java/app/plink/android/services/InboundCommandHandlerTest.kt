package app.plink.android.services

import app.plink.android.protocol.PlinkEnvelope
import app.plink.android.protocol.PlinkEventType
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class InboundCommandHandlerTest {
    @Test
    fun successfulExecutionReturnsCorrelatedAck() = runTest {
        val sent = mutableListOf<PlinkEnvelope>()
        val handler = InboundCommandHandler(
            localDeviceId = "pixel",
            pairedDeviceId = "mac",
            executeReply = {},
            executeMedia = { _, _ -> },
            send = { sent += it }
        )

        handler.handle(command(PlinkEventType.MessageReply))

        val ack = sent.single()
        assertEquals(PlinkEventType.Ack, ack.type)
        assertEquals("command-1", ack.payload["eventId"].toString().trim('"'))
        assertEquals("executed", ack.payload["status"].toString().trim('"'))
        assertEquals(PlinkEventType.MessageReply, ack.payload["action"].toString().trim('"'))
    }

    @Test
    fun executionFailureReturnsSafeCorrelatedError() = runTest {
        val sent = mutableListOf<PlinkEnvelope>()
        val handler = InboundCommandHandler(
            localDeviceId = "pixel",
            pairedDeviceId = "mac",
            executeReply = { error("secret pending intent detail") },
            executeMedia = { _, _ -> },
            send = { sent += it }
        )

        handler.handle(command(PlinkEventType.MessageReply))

        val failure = sent.single()
        assertEquals(PlinkEventType.Error, failure.type)
        assertEquals("command-1", failure.payload["eventId"].toString().trim('"'))
        assertEquals("execution_failed", failure.payload["code"].toString().trim('"'))
        assertEquals("The requested action could not be completed.", failure.payload["message"].toString().trim('"'))
    }

    @Test
    fun cancellationEscapesHandler() {
        val handler = InboundCommandHandler(
            localDeviceId = "pixel",
            pairedDeviceId = "mac",
            executeReply = { throw CancellationException("cancel") },
            executeMedia = { _, _ -> },
            send = {}
        )

        assertThrows(CancellationException::class.java) {
            kotlinx.coroutines.runBlocking { handler.handle(command(PlinkEventType.MessageReply)) }
        }
    }

    @Test
    fun mediaCommandUsesOpaqueSessionIdAndCommand() = runTest {
        var execution: Pair<String, String>? = null
        val handler = InboundCommandHandler(
            localDeviceId = "pixel",
            pairedDeviceId = "mac",
            executeReply = {},
            executeMedia = { sessionId, action -> execution = sessionId to action },
            send = {}
        )

        handler.handle(command(PlinkEventType.MediaCommand, "opaque-17", "next"))

        assertEquals("opaque-17" to "next", execution)
    }

    @Test
    fun explicitHandoffAcknowledgesThatUserActionIsPending() = runTest {
        val sent = mutableListOf<PlinkEnvelope>()
        val handler = InboundCommandHandler(
            localDeviceId = "pixel",
            pairedDeviceId = "mac",
            executeReply = {},
            executeMedia = { _, _ -> },
            executeHandoff = {},
            send = { sent += it }
        )

        handler.handle(command(PlinkEventType.WebOpen))

        assertEquals("awaiting_user", sent.single().payload["status"].toString().trim('"'))
    }

    @Test
    fun rejectsWrongCommandSourceBeforeExecution() = runTest {
        var executed = false
        val handler = InboundCommandHandler(
            localDeviceId = "pixel",
            pairedDeviceId = "mac",
            executeReply = { executed = true },
            executeMedia = { _, _ -> },
            send = {}
        )

        handler.handle(command(PlinkEventType.MessageReply).copy(sourceDeviceId = "other"))
        assertEquals(false, executed)
    }

    @Test
    fun outcomeSendFailureDoesNotAttemptSecondOutcome() = runTest {
        var sends = 0
        val handler = InboundCommandHandler(
            localDeviceId = "pixel",
            pairedDeviceId = "mac",
            executeReply = {},
            executeMedia = { _, _ -> },
            send = { sends += 1; error("offline") }
        )

        assertThrows(IllegalStateException::class.java) {
            kotlinx.coroutines.runBlocking { handler.handle(command(PlinkEventType.MessageReply)) }
        }
        assertEquals(1, sends)
    }

    private fun command(type: String, sessionId: String = "", action: String = "") = PlinkEnvelope(
        id = "command-1",
        type = type,
        sentAt = "2026-09-19T00:00:00Z",
        sourceDeviceId = "mac",
        targetDeviceId = "pixel",
        requiresAck = true,
        payload = buildJsonObject {
            if (sessionId.isNotEmpty()) put("sessionId", sessionId)
            if (action.isNotEmpty()) put("command", action)
        }
    )
}
