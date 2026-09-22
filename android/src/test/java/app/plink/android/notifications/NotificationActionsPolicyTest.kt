package app.plink.android.notifications

import app.plink.android.protocol.PlinkEnvelope
import app.plink.android.security.PayloadPolicy
import app.plink.android.security.PrivacyRedactor
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class NotificationActionsPolicyTest {
    private val session = "12345678-1234-4234-8234-123456789abc"
    private fun enable(value: JsonElement = JsonPrimitive(1)) = PlinkEnvelope(
        id = "synthetic-enable", type = "notification.actions.enable", sentAt = "2026-09-22T00:00:00Z",
        sourceDeviceId = "synthetic-mac", targetDeviceId = "synthetic-phone", requiresAck = true,
        payload = buildJsonObject { put("actionsVersion", value); put("actionsSession", session) }
    )

    @Test fun acceptsNegotiationInExistingAuthenticatedPayloadPolicy() {
        PayloadPolicy.requireAcceptable(enable())
    }

    @Test fun rejectsNonIntegerVersionAndUnexpectedAuthorityFields() {
        listOf(JsonPrimitive(true), JsonPrimitive("1"), JsonPrimitive(1.0)).forEach { value ->
            assertTrue(runCatching { PayloadPolicy.requireAcceptable(enable(value)) }.isFailure)
        }
        val command = enable()
        assertTrue(runCatching { PayloadPolicy.requireAcceptable(command.copy(
            payload = JsonObject(command.payload + ("component" to JsonPrimitive("synthetic")))
        )) }.isFailure)
    }

    @Test fun newCapabilityAndIdentityFieldsNeverSurviveDiagnosticRedaction() {
        val secretFields = listOf("actionsSession", "actionToken", "action0Token", "action0Label", "action0InputLabel",
            "sourceEnvelopeId", "packageName", "notificationKey", "replyToken", "sourceAppIconPng")
        val command = enable().copy(payload = JsonObject(secretFields.associateWith { JsonPrimitive("synthetic-private") }))
        assertFalse(PrivacyRedactor.redact(command).encode().contains("synthetic-private"))
    }
}
