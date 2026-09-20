package app.plink.android.services

import app.plink.android.protocol.PlinkEnvelope
import app.plink.android.transport.OutboundPlinkSender
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
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

class SerializedOutboundQueue(
    private val sender: OutboundPlinkSender,
    private val scope: CoroutineScope,
    capacity: Int = 64,
    private val outbox: EventOutbox? = null,
    private val isAllowed: (PlinkEnvelope) -> Boolean = { true }
) {
    private data class QueuedEnvelope(val envelope: PlinkEnvelope, val generation: Long)

    private val queue = Channel<QueuedEnvelope>(capacity)
    private val stateLock = Any()
    private val generations = mutableMapOf<String, Long>()
    private val queuedIds = mutableSetOf<String>()
    private val retrySignals = Channel<Long>(Channel.CONFLATED)
    private val retryWorker = scope.launch {
        for (delayMillis in retrySignals) {
            if (delayMillis > 0) delay(delayMillis)
            retryPending()
        }
    }
    private val worker = scope.launch {
        for ((envelope, generation) in queue) {
            val allowed = synchronized(stateLock) {
                queuedIds.remove(envelope.id)
                generation == generationForLocked(envelope.type) && isAllowed(envelope)
            }
            if (!allowed) continue
            try {
                sender.send(envelope)
                runCatching { outbox?.remove(envelope.id) }
                retrySignals.trySend(0)
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (_: Exception) {
                // Eligible envelopes were persisted before enqueue. Keep original age on failure.
                retrySignals.trySend(RETRY_DELAY_MILLIS)
            }
        }
    }

    val isRunning: Boolean get() = worker.isActive

    fun trySend(envelope: PlinkEnvelope): Boolean {
        return synchronized(stateLock) {
            if (!isAllowed(envelope)) return@synchronized false
            runCatching { outbox?.store(envelope) }
            enqueueLocked(envelope, generationForLocked(envelope.type))
        }
    }

    fun retryPending() {
        synchronized(stateLock) {
            val generationSnapshot = generations.toMap()
            runCatching { outbox?.pending().orEmpty() }.getOrDefault(emptyList()).forEach {
                if (isAllowed(it)) {
                    enqueueLocked(it, generationSnapshot[it.type] ?: 0)
                }
            }
        }
    }

    fun purge(types: Set<String>) {
        synchronized(stateLock) {
            types.forEach { type -> generations[type] = generationForLocked(type) + 1 }
            runCatching { outbox?.removeTypes(types) }
        }
    }

    private fun generationForLocked(type: String): Long = generations[type] ?: 0

    private fun enqueueLocked(envelope: PlinkEnvelope, generation: Long): Boolean {
        if (!queuedIds.add(envelope.id)) return true
        val accepted = queue.trySend(QueuedEnvelope(envelope, generation)).isSuccess
        if (!accepted) queuedIds.remove(envelope.id)
        return accepted
    }

    fun stop() {
        queue.close()
        retrySignals.close()
        worker.cancel()
        retryWorker.cancel()
    }

    private companion object {
        const val RETRY_DELAY_MILLIS = 5_000L
    }
}

object SharedOutboundBridge {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    @Volatile
    private var queue: SerializedOutboundQueue? = null

    fun configure(
        sender: OutboundPlinkSender?,
        outbox: EventOutbox? = null,
        isAllowed: (PlinkEnvelope) -> Boolean = { true }
    ) {
        val next = sender?.let { SerializedOutboundQueue(it, scope, outbox = outbox, isAllowed = isAllowed) }
        val previous = synchronized(this) {
            val current = queue
            queue = next
            current
        }
        previous?.stop()
        next?.retryPending()
    }

    fun tryForward(envelope: PlinkEnvelope): Boolean {
        return synchronized(this) { queue }?.trySend(envelope) == true
    }

    fun retryPending() {
        synchronized(this) { queue }?.retryPending()
    }

    fun purge(types: Set<String>) {
        synchronized(this) { queue }?.purge(types)
    }
}
