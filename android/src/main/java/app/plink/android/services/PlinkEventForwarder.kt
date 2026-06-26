package app.plink.android.services

import app.plink.android.protocol.PlinkEnvelope
import app.plink.android.transport.OutboundPlinkSender
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.launch

class PlinkEventForwarder(
    private val events: Flow<PlinkEnvelope>,
    private val sender: OutboundPlinkSender,
    private val scope: CoroutineScope
) {
    private var job: Job? = null

    fun start() {
        if (job?.isActive == true) return
        job = scope.launch {
            events.collect { envelope ->
                sender.send(envelope)
            }
        }
    }

    fun stop() {
        job?.cancel()
        job = null
    }
}

object SharedOutboundBridge {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    @Volatile
    private var sender: OutboundPlinkSender? = null

    fun configure(sender: OutboundPlinkSender?) {
        this.sender = sender
    }

    fun tryForward(envelope: PlinkEnvelope): Boolean {
        val activeSender = sender ?: return false
        scope.launch { activeSender.send(envelope) }
        return true
    }
}
