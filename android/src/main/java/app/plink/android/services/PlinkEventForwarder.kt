package app.plink.android.services

import app.plink.android.protocol.PlinkEnvelope
import app.plink.android.protocol.PlinkEventType
import app.plink.android.protocol.ScreenPreviewPayloadPolicy
import app.plink.android.transport.OutboundPlinkSender
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.joinAll
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
    private val isAllowed: (PlinkEnvelope) -> Boolean = { true },
    private val monotonicNanos: () -> Long = System::nanoTime,
    private val awaitPredecessors: suspend () -> Unit = {}
) {
    enum class EphemeralKind { CONTROL, DATA }

    interface EphemeralHandle {
        suspend fun await()
        fun cancel()
    }

    private enum class AwaitableState { QUEUED, ADMITTING, DISPATCHING, CANCELLED, COMPLETE }

    private class QueuedEnvelope(
        envelope: PlinkEnvelope,
        val generation: Long,
        val completion: CompletableDeferred<Unit>? = null,
        val allowRevoked: Boolean = false,
        val stillValid: () -> Boolean = { true },
        val ephemeralKind: EphemeralKind? = null,
        val expiresAtNanos: Long = Long.MAX_VALUE,
        val timeoutMillis: Int = DEFAULT_SEND_TIMEOUT_MILLIS,
        var awaitableState: AwaitableState = AwaitableState.QUEUED
    ) {
        val envelopeId = envelope.id
        val envelopeType = envelope.type
        var envelope: PlinkEnvelope? = envelope
        var expiryJob: Job? = null
        var dispatchJob: Deferred<Unit>? = null
    }

    private val queue = Channel<QueuedEnvelope>(capacity)
    private val stateLock = Any()
    private val generations = mutableMapOf<String, Long>()
    private val queuedIds = mutableSetOf<String>()
    private val awaitable = mutableListOf<QueuedEnvelope>()
    private val screenControls = ArrayDeque<QueuedEnvelope>()
    private var screenData: QueuedEnvelope? = null
    private val ephemeralEntries = mutableSetOf<QueuedEnvelope>()
    private var activeEphemeral: QueuedEnvelope? = null
    private val trackedEphemeralJobs = mutableSetOf<Job>()
    private var stopped = false
    private val signal = Channel<Unit>(Channel.CONFLATED)
    private val retrySignals = Channel<Long>(Channel.CONFLATED)
    private val retryWorker = scope.launch {
        for (delayMillis in retrySignals) {
            if (delayMillis > 0) delay(delayMillis)
            retryPending()
        }
    }
    private val worker = scope.launch {
        awaitPredecessors()
        while (isActive) {
            val request = nextRequest() ?: run {
                signal.receiveCatching().getOrNull() ?: break
                continue
            }
            dispatch(request)
        }
    }

    val isRunning: Boolean get() = worker.isActive

    fun trySend(envelope: PlinkEnvelope): Boolean {
        if (envelope.type.startsWith("screen.")) return false
        if (!runCatching { isAllowed(envelope) }.getOrDefault(false)) return false
        return synchronized(stateLock) {
            if (stopped) return@synchronized false
            runCatching { outbox?.store(envelope) }
            enqueueLocked(envelope, generationForLocked(envelope.type))
        }
    }

    suspend fun sendAwaitable(envelope: PlinkEnvelope, allowRevoked: Boolean = false, stillValid: () -> Boolean = { true }) {
        if (envelope.type.startsWith("screen.")) throw rejected("Screen messages require volatile admission.")
        val completion = CompletableDeferred<Unit>()
        val initiallyAllowed = runCatching {
            stillValid() && (allowRevoked || isAllowed(envelope))
        }.getOrDefault(false)
        if (!initiallyAllowed) throw OutboundRequestRejectedException("Outbound request was rejected.")
        val request = synchronized(stateLock) {
            if (stopped) return@synchronized null
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
                if (request.awaitableState == AwaitableState.QUEUED ||
                    request.awaitableState == AwaitableState.ADMITTING
                ) {
                    request.awaitableState = AwaitableState.CANCELLED
                    queuedIds.remove(request.envelopeId)
                }
            }
            throw cancellation
        }
    }

    fun sendEphemeral(
        envelope: PlinkEnvelope,
        kind: EphemeralKind,
        stillValid: () -> Boolean
    ): EphemeralHandle {
        require(envelope.type in ScreenPreviewPayloadPolicy.eventTypes)
        require((envelope.type in setOf(PlinkEventType.ScreenFrame, PlinkEventType.ScreenIdle)) ==
            (kind == EphemeralKind.DATA))
        val completion = CompletableDeferred<Unit>()
        if (!runCatching { stillValid() && isAllowed(envelope) }.getOrDefault(false)) {
            throw OutboundRequestRejectedException("Screen request was revoked.")
        }
        lateinit var expiryJob: Job
        val request = synchronized(stateLock) {
            if (stopped) return@synchronized null
            val entry = QueuedEnvelope(
                envelope = envelope,
                generation = generationForLocked(envelope.type),
                completion = completion,
                stillValid = stillValid,
                ephemeralKind = kind,
                expiresAtNanos = monotonicNanos() + EPHEMERAL_EXPIRY_NANOS,
                timeoutMillis = EPHEMERAL_SEND_TIMEOUT_MILLIS
            )
            val accepted = when (kind) {
                EphemeralKind.CONTROL -> if (
                    ephemeralEntries.count { it.ephemeralKind == EphemeralKind.CONTROL } < MAX_SCREEN_CONTROLS
                ) {
                    screenControls.addLast(entry)
                    true
                } else false
                EphemeralKind.DATA -> if (
                    ephemeralEntries.none { it.ephemeralKind == EphemeralKind.DATA }
                ) {
                    screenData = entry
                    true
                } else false
            }
            if (accepted) {
                awaitable += entry
                ephemeralEntries += entry
                expiryJob = scope.launch(start = CoroutineStart.LAZY) {
                    val remaining = entry.expiresAtNanos - monotonicNanos()
                    if (remaining > 0) {
                        delay(((remaining + 999_999L) / 1_000_000L).coerceAtLeast(1L))
                    }
                    expireEphemeral(entry)
                }
                entry.expiryJob = expiryJob
                trackEphemeralJobLocked(expiryJob)
                signal.trySend(Unit)
                entry
            } else null
        } ?: throw OutboundRequestRejectedException("Screen queue is full.")
        expiryJob.start()
        return object : EphemeralHandle {
            override suspend fun await() = completion.await()
            override fun cancel() = cancelEphemeral(request)
        }
    }

    fun purgeEphemeral(types: Set<String>) {
        val completions = mutableListOf<CompletableDeferred<Unit>>()
        val dispatches = mutableListOf<Deferred<Unit>>()
        synchronized(stateLock) {
            ephemeralEntries.filter { it.envelopeType in types }.forEach { request ->
                when (request.awaitableState) {
                    AwaitableState.QUEUED, AwaitableState.ADMITTING ->
                        terminateLocked(request)?.let(completions::add)
                    AwaitableState.DISPATCHING -> {
                        request.awaitableState = AwaitableState.CANCELLED
                        request.envelope = null
                        request.expiryJob?.cancel()
                        request.expiryJob = null
                        request.dispatchJob?.let(dispatches::add)
                    }
                    else -> Unit
                }
            }
        }
        dispatches.forEach { it.cancel() }
        completions.forEach { it.completeExceptionally(rejected("Screen send was purged.")) }
    }

    fun retryPending() {
        val generationSnapshot = synchronized(stateLock) { generations.toMap() }
        runCatching { outbox?.pending().orEmpty() }.getOrDefault(emptyList()).forEach { envelope ->
            if (envelope.type.startsWith("screen.")) {
                runCatching { outbox?.remove(envelope.id) }
                return@forEach
            }
            if (runCatching { isAllowed(envelope) }.getOrDefault(false)) synchronized(stateLock) {
                if (!stopped) enqueueLocked(envelope, generationSnapshot[envelope.type] ?: 0)
            }
        }
    }

    fun purge(types: Set<String>) {
        purgeEphemeral(types)
        val completions = mutableListOf<CompletableDeferred<Unit>>()
        synchronized(stateLock) {
            types.forEach { type -> generations[type] = generationForLocked(type) + 1 }
            awaitable.filter {
                it.envelopeType in types &&
                    (it.awaitableState == AwaitableState.QUEUED || it.awaitableState == AwaitableState.ADMITTING)
            }
                .forEach {
                    it.awaitableState = AwaitableState.CANCELLED
                    queuedIds.remove(it.envelopeId)
                    it.completion?.let(completions::add)
                }
        }
        completions.forEach { it.completeExceptionally(rejected("Outbound request was revoked.")) }
        runCatching { outbox?.removeTypes(types) }
    }

    private fun generationForLocked(type: String): Long = generations[type] ?: 0

    private fun enqueueLocked(envelope: PlinkEnvelope, generation: Long): Boolean =
        enqueueLocked(QueuedEnvelope(envelope, generation))

    private fun enqueueLocked(request: QueuedEnvelope): Boolean {
        if (stopped) return false
        if (!queuedIds.add(request.envelopeId)) return true
        val accepted = queue.trySend(request).isSuccess
        if (!accepted) queuedIds.remove(request.envelopeId)
        if (accepted) signal.trySend(Unit)
        return accepted
    }

    private fun completeAwaitable(request: QueuedEnvelope, failure: Throwable? = null) {
        val completion = synchronized(stateLock) { terminateLocked(request) } ?: return
        if (failure == null) completion.complete(Unit) else completion.completeExceptionally(failure)
    }

    private fun cancelEphemeral(request: QueuedEnvelope) {
        var completion: CompletableDeferred<Unit>? = null
        var dispatch: Deferred<Unit>? = null
        synchronized(stateLock) {
            when (request.awaitableState) {
                AwaitableState.QUEUED, AwaitableState.ADMITTING -> completion = terminateLocked(request)
                AwaitableState.DISPATCHING -> {
                    request.awaitableState = AwaitableState.CANCELLED
                    request.envelope = null
                    request.expiryJob?.cancel()
                    request.expiryJob = null
                    dispatch = request.dispatchJob
                }
                else -> Unit
            }
        }
        dispatch?.cancel()
        completion?.completeExceptionally(rejected("Screen send expired or was cancelled."))
    }

    private fun expireEphemeral(request: QueuedEnvelope) {
        val completion = synchronized(stateLock) {
            if ((request.awaitableState != AwaitableState.QUEUED &&
                    request.awaitableState != AwaitableState.ADMITTING) ||
                monotonicNanos() < request.expiresAtNanos
            ) return
            terminateLocked(request)
        }
        completion?.completeExceptionally(rejected("Screen send expired or was cancelled."))
    }

    fun stop() {
        val completions = mutableListOf<CompletableDeferred<Unit>>()
        val dispatches = mutableListOf<Deferred<Unit>>()
        synchronized(stateLock) {
            if (stopped) return
            stopped = true
            awaitable.forEach {
                it.awaitableState = AwaitableState.CANCELLED
                it.expiryJob?.cancel()
                it.expiryJob = null
                if (it.ephemeralKind != null) it.envelope = null
                it.dispatchJob?.let(dispatches::add)
                it.completion?.let(completions::add)
            }
            awaitable.clear()
            ephemeralEntries.clear()
            screenControls.clear()
            screenData = null
            activeEphemeral = null
        }
        dispatches.forEach { it.cancel() }
        completions.forEach { it.completeExceptionally(rejected("Outbound queue stopped.")) }
        queue.close()
        signal.close()
        retrySignals.close()
        worker.cancel()
        retryWorker.cancel()
    }

    suspend fun awaitStopped() {
        awaitPredecessors()
        worker.join()
        retryWorker.join()
        while (true) {
            val jobs = synchronized(stateLock) { trackedEphemeralJobs.toList() }
            if (jobs.isEmpty()) return
            jobs.joinAll()
        }
    }

    private fun nextRequest(): QueuedEnvelope? {
        queue.tryReceive().getOrNull()?.let { request ->
            synchronized(stateLock) {
                queuedIds.remove(request.envelopeId)
                if (request.awaitableState == AwaitableState.QUEUED) {
                    request.awaitableState = AwaitableState.ADMITTING
                }
            }
            return request
        }
        return synchronized(stateLock) {
            val request = screenControls.removeFirstOrNull() ?: screenData?.also { screenData = null }
            request?.also {
                if (it.awaitableState == AwaitableState.QUEUED) {
                    it.awaitableState = AwaitableState.ADMITTING
                }
            }
        }
    }

    private suspend fun dispatch(request: QueuedEnvelope) {
        val envelope = synchronized(stateLock) { request.envelope }
        if (envelope == null) {
            completeAwaitable(request, rejected("Outbound request was revoked."))
            return
        }
        val externallyAllowed = runCatching {
            request.stillValid() && (request.allowRevoked || isAllowed(envelope))
        }.getOrDefault(false)
        val dispatch = synchronized(stateLock) {
            val allowed = !stopped && request.awaitableState == AwaitableState.ADMITTING &&
                externallyAllowed && monotonicNanos() < request.expiresAtNanos &&
                (request.allowRevoked || request.generation == generationForLocked(request.envelopeType))
            if (!allowed) {
                request.awaitableState = AwaitableState.CANCELLED
                null
            } else {
                request.awaitableState = AwaitableState.DISPATCHING
                if (request.ephemeralKind == null) null else scope.async(start = CoroutineStart.LAZY) {
                    withTimeout(request.timeoutMillis.toLong()) {
                        sender.send(envelope, request.timeoutMillis)
                    }
                }.also { child ->
                    request.dispatchJob = child
                    activeEphemeral = request
                    trackEphemeralJobLocked(child)
                }
            }
        }
        if (request.awaitableState != AwaitableState.DISPATCHING) {
            completeAwaitable(request, rejected("Outbound request was revoked."))
            return
        }
        if (request.ephemeralKind == null) {
            dispatchOrdinary(request, envelope)
        } else {
            dispatchEphemeral(request, requireNotNull(dispatch))
        }
    }

    private suspend fun dispatchOrdinary(request: QueuedEnvelope, envelope: PlinkEnvelope) {
        try {
            sender.send(envelope)
            runCatching { outbox?.remove(envelope.id) }
            retrySignals.trySend(0)
            completeAwaitable(request)
        } catch (cancellation: CancellationException) {
            completeAwaitable(request, cancellation)
            throw cancellation
        } catch (failure: Exception) {
            if (request.completion == null) retrySignals.trySend(RETRY_DELAY_MILLIS)
            completeAwaitable(request, failure)
        }
    }

    private suspend fun dispatchEphemeral(request: QueuedEnvelope, dispatch: Deferred<Unit>) {
        try {
            dispatch.start()
            dispatch.await()
            completeAwaitable(request)
        } catch (cancellation: CancellationException) {
            val workerCancelled = currentCoroutineContext()[Job]?.isActive == false
            completeAwaitable(
                request,
                if (workerCancelled) cancellation else rejected("Screen send was cancelled.")
            )
            if (workerCancelled) throw cancellation
        } catch (failure: Exception) {
            completeAwaitable(request, failure)
        }
    }

    /** Caller holds stateLock. Payload/timer ownership ends here. */
    private fun terminateLocked(request: QueuedEnvelope): CompletableDeferred<Unit>? {
        if (request.awaitableState == AwaitableState.COMPLETE) return null
        request.awaitableState = AwaitableState.COMPLETE
        queuedIds.remove(request.envelopeId)
        awaitable.remove(request)
        screenControls.remove(request)
        if (screenData === request) screenData = null
        ephemeralEntries.remove(request)
        request.expiryJob?.cancel()
        request.expiryJob = null
        if (request.ephemeralKind != null) request.envelope = null
        request.dispatchJob = null
        if (activeEphemeral === request) activeEphemeral = null
        return request.completion
    }

    private fun trackEphemeralJobLocked(job: Job) {
        trackedEphemeralJobs += job
        job.invokeOnCompletion { synchronized(stateLock) { trackedEphemeralJobs -= job } }
    }

    private fun rejected(message: String) = OutboundRequestRejectedException(message)

    private companion object {
        const val RETRY_DELAY_MILLIS = 5_000L
        const val DEFAULT_SEND_TIMEOUT_MILLIS = 5_000
        const val EPHEMERAL_SEND_TIMEOUT_MILLIS = 1_000
        const val EPHEMERAL_EXPIRY_NANOS = 1_000_000_000L
        const val MAX_SCREEN_CONTROLS = 2
    }
}

object SharedOutboundBridge {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    @Volatile
    private var queue: SerializedOutboundQueue? = null
    private val retired = mutableListOf<SerializedOutboundQueue>()

    @Synchronized
    fun configure(
        sender: OutboundPlinkSender?,
        outbox: EventOutbox? = null,
        isAllowed: (PlinkEnvelope) -> Boolean = { true }
    ) {
        val previous = queue
        queue = null
        if (previous != null) retired += previous
        previous?.stop()
        val predecessors = retired.toList()
        val next = sender?.let {
            SerializedOutboundQueue(it, scope, outbox = outbox, isAllowed = isAllowed,
                awaitPredecessors = { predecessors.forEach { old -> old.awaitStopped() } })
        }
        queue = next
        if (previous != null) scope.launch {
            previous.awaitStopped()
            synchronized(this@SharedOutboundBridge) { retired.remove(previous) }
        }
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

    fun sendEphemeral(
        envelope: PlinkEnvelope,
        kind: SerializedOutboundQueue.EphemeralKind,
        stillValid: () -> Boolean
    ): SerializedOutboundQueue.EphemeralHandle {
        val active = synchronized(this) { queue }
            ?: throw OutboundRequestRejectedException("Outbound session is unavailable.")
        return active.sendEphemeral(envelope, kind, stillValid)
    }

    fun purgeEphemeral(types: Set<String>) {
        synchronized(this) { queue }?.purgeEphemeral(types)
    }

    suspend fun awaitQuiescence() {
        while (true) {
            val queues = synchronized(this) {
                (retired + listOfNotNull(queue)).distinct().also { retired.clear() }
            }
            queues.forEach { it.awaitStopped() }
            if (synchronized(this) { retired.isEmpty() && queue == null }) return
        }
    }
}
