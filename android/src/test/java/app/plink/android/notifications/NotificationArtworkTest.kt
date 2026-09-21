package app.plink.android.notifications

import app.plink.android.protocol.PlinkEnvelope
import app.plink.android.protocol.PlinkEventType
import app.plink.android.security.PayloadPolicy
import java.util.Base64
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.*
import org.junit.Test

class NotificationArtworkTest {
    @Test fun labelUsesScalarLimitAndRemovesControlsWithoutSplittingEmoji() {
        val label = NotificationArtwork.cleanName("\n\u0000\u202e" + "😀".repeat(81) + "\u2028")!!
        assertEquals(80, label.codePointCount(0, label.length))
        assertEquals("😀".repeat(80), label)
        assertNull(NotificationArtwork.cleanName("\n\t\u202e"))
        assertEquals("Mail", NotificationArtwork.cleanName("Ma\n\u2028\u202eil"))
    }

    @Test fun collectionFailuresAndOversizedIconDoNotDiscardLabel() {
        assertEquals(NotificationArtwork.Metadata(), NotificationArtwork.read({ error("missing package") }, { error("draw failed") }))
        val metadata = NotificationArtwork.read({ "Mail" }, { ByteArray(16_385) })
        assertEquals("Mail", metadata.name)
        assertNull(metadata.iconPng)
        val bytes = ByteArray(16_384)
        val accepted = NotificationArtwork.read({ "Mail" }, { bytes })
        val encoded = requireNotNull(accepted.iconPng)
        assertEquals(21_848, encoded.length)
        assertArrayEquals(bytes, Base64.getDecoder().decode(encoded))
        assertFalse(encoded.contains('\n'))
    }

    @Test fun metadataPreservesReplyIdentityAndNeverDecoratesRemovalsOrCommands() {
        val base = envelope()
        val metadata = NotificationArtwork.Metadata("Mail", "aWNvbg==")
        val decorated = NotificationArtwork.decorate(base) { metadata }
        for ((key, value) in base.payload) assertEquals(key, value, decorated.payload[key])
        assertEquals(base.copy(payload = decorated.payload), decorated)
        assertEquals(JsonPrimitive("Mail"), decorated.payload["sourceAppName"])
        assertEquals(JsonPrimitive("aWNvbg=="), decorated.payload["sourceAppIconPng"])
        assertEquals(base, NotificationArtwork.decorate(base) { error("Optional lookup failed") })
        var unnecessaryLoads = 0
        val load = { unnecessaryLoads++; metadata }
        val removed = base.copy(payload = JsonObject(base.payload + ("removed" to JsonPrimitive(true))))
        assertEquals(removed, NotificationArtwork.decorate(removed, load))
        assertEquals(base.copy(type = PlinkEventType.CallEnded), NotificationArtwork.decorate(base.copy(type = PlinkEventType.CallEnded), load))
        assertEquals(base.copy(type = PlinkEventType.MessageReply), NotificationArtwork.decorate(base.copy(type = PlinkEventType.MessageReply), load))
        assertEquals(0, unnecessaryLoads)
    }

    @Test fun wholeEnvelopeBudgetDropsIconThenNameWithoutChangingOriginalFields() {
        val metadata = NotificationArtwork.Metadata("Mail", Base64.getEncoder().encodeToString(ByteArray(16_384)))
        val base = envelope()
        fun paddedTo(size: Int): PlinkEnvelope {
            val withEmpty = base.copy(payload = JsonObject(base.payload + ("extra" to JsonPrimitive(""))))
            val padding = size - withEmpty.encode().toByteArray(Charsets.UTF_8).size
            return withEmpty.copy(payload = JsonObject(withEmpty.payload + ("extra" to JsonPrimitive("x".repeat(padding)))))
        }
        val near = paddedTo(PayloadPolicy.maxEnvelopeBytes - 100)
        val nameOnly = NotificationArtwork.decorate(near) { metadata }
        assertNull(nameOnly.payload["sourceAppIconPng"])
        assertEquals(JsonPrimitive("Mail"), nameOnly.payload["sourceAppName"])
        PayloadPolicy.requireAcceptable(nameOnly)
        val full = paddedTo(PayloadPolicy.maxEnvelopeBytes)
        assertEquals(full, NotificationArtwork.decorate(full) { metadata })
        PayloadPolicy.requireAcceptable(full)
    }

    private fun envelope() = PlinkEnvelope(id = "metadata-test", type = PlinkEventType.MessageReceived,
        sentAt = "2026-09-21T00:00:00Z", sourceDeviceId = "phone", targetDeviceId = "mac",
        payload = buildJsonObject {
            put("sender", "Sender"); put("preview", "Text"); put("packageName", "test.mail")
            put("notificationKey", "key"); put("replyToken", "token"); put("canReply", true)
        })
}
