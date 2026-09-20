package app.plink.android.services

import app.plink.android.protocol.PlinkEnvelope
import app.plink.android.protocol.PlinkEventType
import kotlinx.coroutines.CancellationException
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.time.Instant
import java.util.UUID

class InboundCommandHandler(
    private val localDeviceId: String,
    private val pairedDeviceId: String,
    private val executeReply: (PlinkEnvelope) -> Unit,
    private val executeMedia: (sessionId: String, command: String) -> Unit,
    private val executeHandoff: (PlinkEnvelope) -> Unit = {},
    private val send: suspend (PlinkEnvelope) -> Unit
) {
    suspend fun handle(command: PlinkEnvelope) {
        if (command.sourceDeviceId != pairedDeviceId || command.targetDeviceId != localDeviceId) return
        val outcome = try {
            when (command.type) {
                PlinkEventType.MessageReply -> executeReply(command)
                PlinkEventType.MediaCommand -> executeMedia(
                    command.requiredString("sessionId"),
                    command.requiredString("command")
                )
                PlinkEventType.WebOpen, PlinkEventType.ClipboardUpdated -> executeHandoff(command)
                else -> return
            }
            outcome(command, PlinkEventType.Ack, buildJsonObject {
                put("eventId", command.id)
                put(
                    "status",
                    if (command.type == PlinkEventType.WebOpen || command.type == PlinkEventType.ClipboardUpdated) {
                        "awaiting_user"
                    } else {
                        "executed"
                    }
                )
                put("action", command.type)
            })
        } catch (cancellation: CancellationException) {
            throw cancellation
        } catch (_: Exception) {
            outcome(command, PlinkEventType.Error, buildJsonObject {
                put("eventId", command.id)
                put("code", "execution_failed")
                put("message", "The requested action could not be completed.")
            })
        }
        send(outcome)
    }

    private fun outcome(command: PlinkEnvelope, type: String, payload: kotlinx.serialization.json.JsonObject) =
        PlinkEnvelope(
            id = "outcome_${UUID.randomUUID()}",
            type = type,
            sentAt = Instant.now().toString(),
            sourceDeviceId = localDeviceId,
            targetDeviceId = pairedDeviceId,
            payload = payload
        )

    private fun PlinkEnvelope.requiredString(key: String): String {
        val value = payload[key]?.jsonPrimitive?.contentOrNull
        require(!value.isNullOrBlank()) { "payload.$key is required." }
        return value
    }
}
