package app.plink.android.services

import app.plink.android.protocol.PlinkEnvelope
import app.plink.android.protocol.PlinkEventType
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files
import java.time.Clock
import java.time.Duration
import java.time.Instant
import java.time.ZoneId

class DurableEventOutboxTest {
    @Test
    fun encryptedFileDoesNotContainNotificationTextOrReplyToken() {
        val directory = Files.createTempDirectory("plink-outbox").toFile()
        val outbox = DurableEventOutbox(directory, byteArrayOf(1, 2, 3), "mac", fixedClock())

        outbox.store(message("event-1", "private preview", "reply-secret"))

        val bytes = directory.walkTopDown().filter { it.isFile }.flatMap { it.readBytes().asSequence() }.toList()
            .toByteArray().decodeToString()
        assertFalse(bytes.contains("private preview"))
        assertFalse(bytes.contains("reply-secret"))
        val pending = outbox.pending().single()
        assertEquals("false", pending.payload["canReply"].toString())
        assertNull(pending.payload["replyToken"])
        assertEquals("\"notification-event-1\"", pending.payload["notificationKey"].toString())
        assertEquals("\"messages\"", pending.payload["packageName"].toString())
    }

    @Test
    fun coalescesDeviceAndMediaStateAndExcludesCommands() {
        val directory = Files.createTempDirectory("plink-outbox").toFile()
        val outbox = DurableEventOutbox(directory, byteArrayOf(4, 5, 6), "mac", fixedClock())

        outbox.store(envelope("battery-1", PlinkEventType.DeviceStatus, buildJsonObject { put("batteryLevel", 10) }))
        outbox.store(envelope("battery-2", PlinkEventType.DeviceStatus, buildJsonObject { put("batteryLevel", 20) }))
        outbox.store(envelope("media-1", PlinkEventType.MediaState, buildJsonObject { put("sessionId", "opaque"); put("title", "A") }))
        outbox.store(envelope("media-2", PlinkEventType.MediaState, buildJsonObject { put("sessionId", "opaque"); put("title", "B") }))

        assertFalse(outbox.store(envelope("command", PlinkEventType.MediaCommand, buildJsonObject { put("command", "pause") })))
        assertFalse(outbox.store(envelope("reply", PlinkEventType.MessageReply, buildJsonObject { put("text", "hi") })))
        assertFalse(outbox.store(envelope("call", PlinkEventType.CallRinging, buildJsonObject { put("caller", "Alex") })))
        assertEquals(listOf("battery-2", "media-2"), outbox.pending().map { it.id })
    }

    @Test
    fun expiresNotificationFallbackAndCapsOldestEntries() {
        val clock = MutableClock(Instant.parse("2026-09-20T00:00:00Z"))
        val directory = Files.createTempDirectory("plink-outbox").toFile()
        val outbox = DurableEventOutbox(directory, byteArrayOf(7, 8, 9), "mac", clock, capacity = 2)

        outbox.store(message("one", "one", "token-1"))
        outbox.store(message("two", "two", "token-2"))
        outbox.store(message("three", "three", "token-3"))
        assertEquals(listOf("two", "three"), outbox.pending().map { it.id })

        clock.now = clock.now.plus(Duration.ofSeconds(121))
        assertTrue(outbox.pending().isEmpty())
    }

    @Test
    fun keyedRemovalReplacesQueuedMessageWithoutReplyCapability() {
        val directory = Files.createTempDirectory("plink-outbox").toFile()
        val outbox = DurableEventOutbox(directory, byteArrayOf(7, 8, 9), "mac", fixedClock())
        outbox.store(message("posted", "private", "reply"))
        outbox.store(
            envelope(
                "removed",
                PlinkEventType.MessageReceived,
                buildJsonObject {
                    put("sender", "messages")
                    put("preview", "Notification removed.")
                    put("canReply", false)
                    put("packageName", "messages")
                    put("notificationKey", "notification-posted")
                    put("removed", true)
                }
            )
        )

        val pending = outbox.pending().single()
        assertEquals("removed", pending.id)
        assertEquals("true", pending.payload["removed"].toString())
        assertNull(pending.payload["replyToken"])
    }

    @Test
    fun expiryUsesOriginalSentAtAndFeaturePurgeRemovesQueuedEvents() {
        val clock = MutableClock(Instant.parse("2026-09-20T00:01:59Z"))
        val directory = Files.createTempDirectory("plink-outbox").toFile()
        val outbox = DurableEventOutbox(directory, byteArrayOf(7, 8, 9), "mac", clock)

        outbox.store(message("old", "old", "token"))
        clock.now = clock.now.plusSeconds(2)
        assertTrue(outbox.pending().isEmpty())

        val current = envelope(
            "current",
            PlinkEventType.DeviceStatus,
            buildJsonObject { put("batteryLevel", 50) },
            sentAt = clock.instant().toString()
        )
        outbox.store(current)
        outbox.removeTypes(setOf(PlinkEventType.DeviceStatus))
        assertTrue(outbox.pending().isEmpty())
    }

    private fun message(id: String, preview: String, token: String) = envelope(
        id,
        PlinkEventType.MessageReceived,
        buildJsonObject {
            put("sender", "Alex")
            put("preview", preview)
            put("canReply", true)
            put("packageName", "messages")
            put("notificationKey", "notification-$id")
            put("replyToken", token)
        }
    )

    private fun envelope(
        id: String,
        type: String,
        payload: kotlinx.serialization.json.JsonObject,
        sentAt: String = "2026-09-20T00:00:00Z"
    ) = PlinkEnvelope(
        id = id,
        type = type,
        sentAt = sentAt,
        sourceDeviceId = "pixel",
        targetDeviceId = "mac",
        payload = payload
    )

    private fun fixedClock(): Clock = Clock.fixed(Instant.parse("2026-09-20T00:00:00Z"), ZoneId.of("UTC"))

    private class MutableClock(var now: Instant) : Clock() {
        override fun getZone(): ZoneId = ZoneId.of("UTC")
        override fun withZone(zone: ZoneId?): Clock = this
        override fun instant(): Instant = now
    }
}
