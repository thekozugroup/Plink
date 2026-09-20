package app.plink.android.services

import app.plink.android.protocol.PlinkEnvelope
import app.plink.android.transport.OutboundPlinkSender
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CompletableDeferred
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

class OutboundRequestRejectedException(message: String) : Exception(message)

class SerializedOutboundQueue(
    private val sender: OutboundPlinkSender,
    private val scope: CoroutineScope,
    capacity: Int = 64,
    private val outbox: EventOutbox? = null,
    private val isAllowed: (PlinkEnvelope) -> Boolean = { true }
) {
    private enum class AwaitableState { QUEUED, DISPATCHING, CANCELLED, COMPLETE }

    private class QueuedEnvelope(
        val envelope: PlinkEnvelope,
        val generation: Long,
        val completion: CompletableDeferred<Unit>? = null,
        val allowRevoked: Boolean = false,
        val stillValid: () -> Boolean = { true },
        var awaitableState: AwaitableState = AwaitableState.QUEUED
    )

    private val queue = Channel<QueuedEnvelope>(capacity)
    private val stateLock = Any()
    private val generations = mutableMapOf<String, Long>()
    private val queuedIds = mutableSetOf<String>()
    private val awaitable = mutableListOf<QueuedEnvelope>()
    private val retrySignals = Channel<Long>(Channel.CONFLATED)
    private val retryWorker = scope.launch {
        for (delayMillis in retrySignals) {
            if (delayMillis > 0) delay(delayMillis)
            retryPending()
        }
    }
    private val worker = scope.launch {
        for (request in queue) {
            val envelope = request.envelope
            val allowed = synchronized(stateLock) {
                queuedIds.remove(envelope.id)
                val mayDispatch = request.awaitableState == AwaitableState.QUEUED && request.stillValid() &&
                    (request.allowRevoked || (
                        request.generation == generationForLocked(envelope.type) && isAllowed(envelope)
                    ))
                request.awaitableState = if (mayDispatch) {
                    AwaitableState.DISPATCHING
                } else {
                    AwaitableState.CANCELLED
                }
                mayDispatch
            }
            if (!allowed) {
                completeAwaitable(request, OutboundRequestRejectedException("Outbound request was revoked."))
                continue
            }
            try {
                sender.send(envelope)
                runCatching { outbox?.remove(envelope.id) }
                retrySignals.trySend(0)
                completeAwaitable(request)
            } catch (cancellation: CancellationException) {
                completeAwaitable(request, cancellation)
                throw cancellation
            } catch (failure: Exception) {
                if (request.completion == null) {
                    // Eligible envelopes were persisted before enqueue. Keep original age on failure.
                    retrySignals.trySend(RETRY_DELAY_MILLIS)
                }
                completeAwaitable(request, failure)
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

    suspend fun sendAwaitable(envelope: PlinkEnvelope, allowRevoked: Boolean = false, stillValid: () -> Boolean = { true }) {
        val completion = CompletableDeferred<Unit>()
        val request = synchronized(stateLock) {
            if (!stillValid() || (!allowRevoked && !isAllowed(envelope))) return@synchronized null
            if (envelope.id in queuedIds) return@synchronized null
            QueuedEnvelope(
                envelope = envelope,
                generation = generationForLocked(envelope.type),
                completion = completion,
                allowRevoked = allowRevoked,
                stillValid = stillValid
            ).also {
                awaitable += it
                if (!enqueueLocked(it)) awaitable -= it
            }.takeIf { it in awaitable }
        } ?: throw OutboundRequestRejectedException("Outbound request was rejected.")

        try {
            completion.await()
        } catch (cancellation: CancellationException) {
            synchronized(stateLock) {
                if (request.awaitableState == AwaitableState.QUEUED) {
                    request.awaitableState = AwaitableState.CANCELLED
                    queuedIds.remove(request.envelope.id)
                }
            }
            throw cancellation
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
            awaitable.filter { it.envelope.type in types && it.awaitableState == AwaitableState.QUEUED }
                .forEach {
                    it.awaitableState = AwaitableState.CANCELLED
                    queuedIds.remove(it.envelope.id)
                    it.completion?.completeExceptionally(
                        OutboundRequestRejectedException("Outbound request was revoked.")
                    )
                }
            runCatching { outbox?.removeTypes(types) }
        }
    }

    private fun generationForLocked(type: String): Long = generations[type] ?: 0

    private fun enqueueLocked(envelope: PlinkEnvelope, generation: Long): Boolean =
        enqueueLocked(QueuedEnvelope(envelope, generation))

    private fun enqueueLocked(request: QueuedEnvelope): Boolean {
        if (!queuedIds.add(request.envelope.id)) return true
        val accepted = queue.trySend(request).isSuccess
        if (!accepted) queuedIds.remove(request.envelope.id)
        return accepted
    }

    private fun completeAwaitable(request: QueuedEnvelope, failure: Throwable? = null) {
        val completion = synchronized(stateLock) {
            request.awaitableState = AwaitableState.COMPLETE
            awaitable.remove(request)
            request.completion
        } ?: return
        if (failure == null) completion.complete(Unit) else completion.completeExceptionally(failure)
    }

    fun stop() {
        synchronized(stateLock) {
            awaitable.forEach {
                it.awaitableState = AwaitableState.CANCELLED
                it.completion?.completeExceptionally(
                    OutboundRequestRejectedException("Outbound queue stopped.")
                )
            }
            awaitable.clear()
        }
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

    suspend fun sendAwaitable(envelope: PlinkEnvelope, allowRevoked: Boolean = false, stillValid: () -> Boolean = { true }) {
        val active = synchronized(this) { queue }
            ?: throw OutboundRequestRejectedException("Outbound session is unavailable.")
        active.sendAwaitable(envelope, allowRevoked, stillValid)
    }

    fun retryPending() {
        synchronized(this) { queue }?.retryPending()
    }

    fun purge(types: Set<String>) {
        synchronized(this) { queue }?.purge(types)
    }
}
