package app.plink.android.notifications

import app.plink.android.protocol.PlinkEventType
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import java.time.Instant

class ReplyRouteTest {
    private val exactReply = "\t  Plink encrypted roundtrip ✓\nCafe\u0301 👩‍💻\n  "

    @Test
    fun replyCommandRequiresText() {
        val route = route(canReply = true)
        val command = ReplyCommand(route, exactReply, localDeviceId = "mac")

        assertArrayEquals(exactReply.toByteArray(), command.text.toByteArray())
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
        val command = ReplyCommand(route(canReply = true), exactReply, localDeviceId = "mac")
        val envelope = command.toEnvelope(id = "reply-1", sentAt = Instant.parse("2026-06-25T00:00:00Z"))

        assertEquals(PlinkEventType.MessageReply, envelope.type)
        assertEquals("mac", envelope.sourceDeviceId)
        assertEquals("pixel", envelope.targetDeviceId)
        assertEquals("evt-1", envelope.payload["sourceEnvelopeId"].toString().trim('"'))
        assertArrayEquals(exactReply.toByteArray(), envelope.payload.getValue("text").jsonPrimitive.content.toByteArray())
    }

    @Test
    fun inboundReplyPreservesExactTextUntilFinalDispatch() {
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

        val validated = InboundReplyValidator.validate(reply, registry, localDeviceId = "pixel")

        assertArrayEquals(exactReply.toByteArray(), validated.text.toByteArray())
        assertEquals(route, validated.route)
        assertEquals(1, registry.size())
    }

    @Test
    fun inboundReplyRejectsDifferentPairedDevice() {
        val registry = ReplyRouteRegistry()
        val route = registry.register("mac", "evt-1", "com.example.messages", "key", "thread", true)
        val reply = inboundReply(route.replyToken).copy(sourceDeviceId = "other-mac")

        assertThrows(IllegalArgumentException::class.java) {
            InboundReplyValidator.validate(reply, registry, localDeviceId = "pixel")
        }
        assertEquals(1, registry.size())
    }

    @Test
    fun inboundReplyRejectsDifferentConversation() {
        val registry = ReplyRouteRegistry()
        val route = registry.register("mac", "evt-1", "com.example.messages", "key", "thread", true)
        val reply = inboundReply(route.replyToken).copy(
            payload = buildJsonObject {
                put("sourceEnvelopeId", "evt-1")
                put("packageName", "com.example.messages")
                put("notificationKey", "key")
                put("conversationId", "other-thread")
                put("replyToken", route.replyToken)
                put("text", "On it")
            }
        )

        assertThrows(IllegalArgumentException::class.java) {
            InboundReplyValidator.validate(reply, registry, localDeviceId = "pixel")
        }
        assertEquals(1, registry.size())
    }

    @Test
    fun blankInboundReplyDoesNotConsumeUsableRoute() {
        val registry = ReplyRouteRegistry()
        val route = registry.register("mac", "evt-1", "com.example.messages", "key", "thread", true)

        assertThrows(IllegalArgumentException::class.java) {
            InboundReplyValidator.validate(
                inboundReply(route.replyToken, text = "\t\r\n"),
                registry,
                localDeviceId = "pixel"
            )
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

    private fun inboundReply(replyToken: String, text: String = exactReply) = app.plink.android.protocol.PlinkEnvelope(
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
            put("conversationId", "thread")
            put("replyToken", replyToken)
            put("text", text)
        }
    )
}
