package app.plink.android.notifications

import app.plink.android.protocol.NotificationActionsPolicy
import app.plink.android.protocol.PlinkEnvelope
import app.plink.android.security.PayloadPolicy
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File

class NotificationActionsFixtureTest {
    @Test fun sharedHandwrittenRawWireVectorsUseProductionValidators() {
        val path = "shared/protocol/v1/notification-actions/v1-cases.json"
        val root = generateSequence(File(requireNotNull(System.getProperty("user.dir")))) { it.parentFile }.first { File(it, path).isFile }
        val fixture = Json.parseToJsonElement(File(root, path).readText()).jsonObject
        assertEquals(1, fixture.getValue("schemaVersion").jsonPrimitive.int)
        fixture.getValue("cases").jsonArray.forEach { rawCase ->
            val case = rawCase.jsonObject
            val name = case.getValue("name").jsonPrimitive.content
            val raw = case.getValue("rawEnvelope").jsonPrimitive.content
            val kind = case.getValue("kind").jsonPrimitive.content
            val expected = case.getValue("valid").jsonPrimitive.boolean
            if (kind in setOf("offer", "legacy")) {
                val envelope = PlinkEnvelope.decode(raw)
                PayloadPolicy.requireAcceptable(envelope) // Invalid extension must preserve text.
                val validOffer = NotificationActionsPolicy.hasValidOffer(envelope)
                assertEquals(name, kind == "offer" && expected, validOffer)
                val disposition = if (validOffer) "v1" else if (envelope.payload.keys.any(NotificationActionsPolicy::reserved)) "readonly" else "legacy"
                case["expectedOfferDisposition"]?.jsonPrimitive?.content?.let { assertEquals(name, it, disposition) }
            } else {
                val accepted = runCatching { PayloadPolicy.requireAcceptable(PlinkEnvelope.decode(raw)) }.isSuccess
                assertEquals(name, expected, accepted)
            }
        }
    }
}
