package app.plink.android.notifications

import app.plink.android.protocol.PlinkEventType
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
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

    @Test
    fun inboundReplyConsumesMatchingRoute() {
        val registry = ReplyRouteRegistry()
        val route = registry.register(
            pairedDeviceId = "mac",
            sourceEnvelopeId = "evt-1",
            packageName = "com.example.messages",
            notificationKey = "key",
            conversationId = "thread",
            canReply = true
        )
        val reply = inboundReply(route.replyToken)

        val validated = InboundReplyValidator.consume(reply, registry, localDeviceId = "pixel")

        assertEquals("On it", validated.text)
        assertEquals(route, validated.route)
        assertEquals(0, registry.size())
    }

    @Test
    fun inboundReplyRejectsDifferentPairedDevice() {
        val registry = ReplyRouteRegistry()
        val route = registry.register("mac", "evt-1", "com.example.messages", "key", "thread", true)
        val reply = inboundReply(route.replyToken).copy(sourceDeviceId = "other-mac")

        assertThrows(IllegalArgumentException::class.java) {
            InboundReplyValidator.consume(reply, registry, localDeviceId = "pixel")
        }
        assertEquals(1, registry.size())
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

    private fun inboundReply(replyToken: String) = app.plink.android.protocol.PlinkEnvelope(
        id = "reply-1",
        type = PlinkEventType.MessageReply,
        sentAt = "2026-06-25T00:00:00Z",
        sourceDeviceId = "mac",
        targetDeviceId = "pixel",
        requiresAck = true,
        payload = buildJsonObject {
            put("sourceEnvelopeId", "evt-1")
            put("packageName", "com.example.messages")
            put("notificationKey", "key")
            put("replyToken", replyToken)
            put("text", " On it ")
        }
    )
}
