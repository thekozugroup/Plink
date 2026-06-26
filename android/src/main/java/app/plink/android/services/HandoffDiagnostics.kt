package app.plink.android.services

import app.plink.android.continuity.CallRingingEvent
import app.plink.android.continuity.ClipboardUpdatedEvent
import app.plink.android.continuity.ContinuityEnvelopeFactory
import app.plink.android.continuity.MessageReceivedEvent
import app.plink.android.protocol.PlinkEnvelope

enum class DiagnosticHandoff(val label: String) {
    Call("Call"),
    Message("Message"),
    Clipboard("Clipboard")
}

object HandoffDiagnostics {
    fun send(kind: DiagnosticHandoff): DiagnosticSendResult {
        val session = SharedSessionState.snapshot()
            ?: return DiagnosticSendResult.NotPaired
        val envelope = envelope(kind, session.localDeviceId, session.pairedDevice.id)
        return if (SharedOutboundBridge.tryForward(envelope)) {
            DiagnosticSendResult.Sent(envelope)
        } else {
            DiagnosticSendResult.NotPaired
        }
    }

    fun envelope(kind: DiagnosticHandoff, localDeviceId: String, pairedDeviceId: String): PlinkEnvelope =
        ContinuityEnvelopeFactory.create(
            event = when (kind) {
                DiagnosticHandoff.Call -> CallRingingEvent(
                    callerName = "Plink Test",
                    callerHandle = "+1 555 0100"
                )
                DiagnosticHandoff.Message -> MessageReceivedEvent(
                    conversationId = "plink-diagnostic",
                    sender = "Plink Test",
                    preview = "Reply diagnostics are ready.",
                    canReply = true
                )
                DiagnosticHandoff.Clipboard -> ClipboardUpdatedEvent(
                    text = "Plink diagnostic clipboard"
                )
            },
            sourceDeviceId = localDeviceId,
            targetDeviceId = pairedDeviceId
        )
}

sealed interface DiagnosticSendResult {
    data class Sent(val envelope: PlinkEnvelope) : DiagnosticSendResult
    data object NotPaired : DiagnosticSendResult
}
