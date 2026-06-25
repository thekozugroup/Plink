package app.plink.android.notifications

import app.plink.android.protocol.PlinkEventType
import org.junit.Assert.assertEquals
import org.junit.Test
import java.time.Instant

class ReplyRouteTest {
    @Test
    fun replyCommandRequiresText() {
        val route = route(canReply = true)
        val command = ReplyCommand(route, "On it", localDeviceId = "mac")

        assertEquals("On it", command.text)
    }

    @Test(expected = IllegalArgumentException::class)
    fun blankReplyFailsClosed() {
        ReplyCommand(route(canReply = true), " ", localDeviceId = "mac")
    }

    @Test(expected = IllegalArgumentException::class)
    fun nonReplyableRouteFailsClosed() {
        ReplyCommand(route(canReply = false), "Nope", localDeviceId = "mac")
    }

    @Test
    fun replyCommandTargetsPairedDeviceAndOriginalNotification() {
        val command = ReplyCommand(route(canReply = true), " On it ", localDeviceId = "mac")
        val envelope = command.toEnvelope(id = "reply-1", sentAt = Instant.parse("2026-06-25T00:00:00Z"))

        assertEquals(PlinkEventType.MessageReply, envelope.type)
        assertEquals("mac", envelope.sourceDeviceId)
        assertEquals("pixel", envelope.targetDeviceId)
        assertEquals("evt-1", envelope.payload["sourceEnvelopeId"].toString().trim('"'))
        assertEquals("On it", envelope.payload["text"].toString().trim('"'))
    }

    private fun route(canReply: Boolean): ReplyRoute = ReplyRoute(
        pairedDeviceId = "pixel",
        sourceEnvelopeId = "evt-1",
        packageName = "com.example.messages",
        notificationKey = "key",
        conversationId = "thread",
        canReply = canReply,
        replyToken = "token"
    )
}
