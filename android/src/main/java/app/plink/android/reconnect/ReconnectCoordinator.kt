package app.plink.android.reconnect

import android.os.SystemClock
import app.plink.android.protocol.PlinkEnvelope
import app.plink.android.protocol.PlinkEventType
import app.plink.android.protocol.ReconnectEndpoint
import app.plink.android.protocol.ReconnectPayload
import app.plink.android.protocol.ReconnectPayloadPolicy
import app.plink.android.security.AuthenticatedFrameResult
import app.plink.android.security.EncryptedFrameCodec
import app.plink.android.security.FrameStateStore
import app.plink.android.transport.PairTransmitGate
import app.plink.android.transport.SecureSocketPlinkExchange
import app.plink.android.transport.ObservedSocketTuple
import app.plink.android.transport.openSecureSocketPlinkExchange
import java.io.Closeable
import java.security.SecureRandom
import java.util.Base64
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withContext

enum class ReconnectFailureReason(val wireName: String) {
    NO_CANDIDATE("no_candidate"),
    UNAVAILABLE_NETWORK_OR_PERMISSION("unavailable_network_or_permission"),
    UNSUPPORTED_ENDPOINT("unsupported_endpoint"),
    TIMEOUT_OR_INCOMPATIBLE_PEER("timeout_or_incompatible_peer"),
    AUTHENTICATION_FAILED("authentication_failed"),
    STORAGE_ERROR("storage_error")
}

sealed interface ReconnectState {
    data class Idle(val currentAddresses: List<String>) : ReconnectState
    data class Reconnecting(val stage: String, val currentAddresses: List<String>) : ReconnectState
    data class Disconnecting(val currentAddresses: List<String>) : ReconnectState
    data class ConnectedInternetUnverified(val currentAddresses: List<String>) : ReconnectState
    data class Failed(val reason: ReconnectFailureReason, val currentAddresses: List<String>) : ReconnectState
    data class Cancelled(val currentAddresses: List<String>) : ReconnectState
}

data class ReconnectDiagnostics(
    val proofId: String,
    val c1: ObservedSocketTuple,
    val c2: ObservedSocketTuple,
    val ordinaryAdmissionInitiallyClosed: Boolean
)

interface ReconnectBindingResolver {
    fun resolveInbound(tuple: app.plink.android.transport.ObservedSocketTuple, macListenerPort: Int): ReconnectLiveBinding?
}

class ReconnectCoordinator internal constructor(
    private val localDeviceId: String,
    private val peerDeviceId: String,
    private val sessionId: String,
    sessionKey: ByteArray,
    private val codec: EncryptedFrameCodec,
    private val frameStateStore: FrameStateStore,
    private val transmitGate: PairTransmitGate,
    private val endpointStore: ReconnectEndpointStore,
    private val bindingResolver: ReconnectBindingResolver,
    private val scope: CoroutineScope,
    private val lifecycleOwner: ReconnectLifecycleOwner,
    private val suspendOrdinaryAndAwait: suspend (attemptToken: ReconnectAttemptToken) -> Boolean,
    private val prepareReplacement: suspend (attemptToken: ReconnectAttemptToken, binding: ReconnectLiveBinding) -> Boolean,
    private val publishReplacement: suspend (attemptToken: ReconnectAttemptToken, binding: ReconnectLiveBinding) -> Boolean,
    private val revokeAttempt: (attemptToken: ReconnectAttemptToken, wasPublished: Boolean) -> Boolean,
    private val awaitRevokedResources: suspend () -> Unit,
    private val ordinaryAdmissionOpen: () -> Boolean,
    private val isCurrentPair: () -> Boolean,
    private val monotonicMillis: () -> Long = SystemClock::elapsedRealtime
) : Closeable {
    private val ownedSessionKey = sessionKey.copyOf()
    private val ownerMutex = Mutex()
    private val revocationCleanupPending = AtomicBoolean(false)
    private class ActiveHandshake(val token: ReconnectAttemptToken) {
        var binding: ReconnectLiveBinding? = null
        var networkInvalidated = false
    }
    // Accessed under the coordinator monitor, including from network callbacks.
    private var activeHandshake: ActiveHandshake? = null
    @Volatile private var activeJob: Job? = null
    @Volatile private var activeInbound: SecureSocketPlinkExchange? = null
    @Volatile private var activeReverse: SecureSocketPlinkExchange? = null
    @Volatile private var closed = false
    @Volatile private var lastHelloAt = Long.MIN_VALUE
    @Volatile private var addresses: List<String> = emptyList()
    private val _state = MutableStateFlow<ReconnectState>(ReconnectState.Idle(emptyList()))
    val state: StateFlow<ReconnectState> = _state.asStateFlow()
    @Volatile private var successfulDiagnostics: ReconnectDiagnostics? = null

    fun diagnostics(): ReconnectDiagnostics? = successfulDiagnostics
    val isClosed: Boolean get() = closed
    val hasActiveAttempt: Boolean get() = activeJob?.isActive == true

    fun updateAddresses(values: List<String>) {
        addresses = values.distinct().take(4)
        _state.value = when (val current = _state.value) {
            is ReconnectState.Idle -> current.copy(currentAddresses = addresses)
            is ReconnectState.Reconnecting -> current.copy(currentAddresses = addresses)
            is ReconnectState.Disconnecting -> current.copy(currentAddresses = addresses)
            is ReconnectState.ConnectedInternetUnverified -> current.copy(currentAddresses = addresses)
            is ReconnectState.Failed -> current.copy(currentAddresses = addresses)
            is ReconnectState.Cancelled -> current.copy(currentAddresses = addresses)
        }
    }

    /** Called only after the listener authenticated and replay-accepted the first frame. */
    fun receiveHello(exchange: SecureSocketPlinkExchange, envelope: PlinkEnvelope): Boolean {
        if (closed || envelope.type != PlinkEventType.ReconnectHello) return false
        val now = monotonicMillis()
        synchronized(this) {
            if (activeJob?.isActive == true ||
                lastHelloAt != Long.MIN_VALUE && now - lastHelloAt < HELLO_RATE_LIMIT_MILLIS
            ) return false
            lastHelloAt = now
            val attemptToken = lifecycleOwner.begin(PHONE_ATTEMPT_MILLIS) ?: return false
            val handshake = ActiveHandshake(attemptToken)
            activeHandshake = handshake
            activeInbound = exchange
            activeJob = scope.launch {
                ownerMutex.withLock { runAttempt(handshake, exchange, envelope) }
            }.also { job ->
                job.invokeOnCompletion {
                    synchronized(this@ReconnectCoordinator) {
                        if (activeJob === job) activeJob = null
                        if (activeInbound === exchange) activeInbound = null
                        if (activeHandshake === handshake) activeHandshake = null
                    }
                }
            }
        }
        return true
    }

    fun cancel() {
        scope.launch { cancelAndAwait() }
    }

    suspend fun cancelAndAwait() {
        cancelOwned(closing = false)
        if (!closed) _state.value = ReconnectState.Cancelled(addresses)
    }

    fun networkChanged() {
        val (handshake, binding, job) = synchronized(this) {
            val handshake = activeHandshake ?: return
            // Before resolution, runAttempt resolves and validates the current network itself.
            val binding = handshake.binding ?: return
            val job = activeJob?.takeIf { it.isActive } ?: return
            Triple(handshake, binding, job)
        }
        scope.launch {
            if (runCatching { binding.validateCurrent() }.isSuccess) return@launch
            synchronized(this@ReconnectCoordinator) {
                if (closed || activeHandshake !== handshake || handshake.binding !== binding ||
                    activeJob !== job || !job.isActive
                ) return@launch
                val invalidation = lifecycleOwner.invalidate(handshake.token, revokeAttempt)
                if (!invalidation.invalidated) return@launch
                handshake.networkInvalidated = true
                if (invalidation.cleanupRequired) revocationCleanupPending.set(true)
                android.util.Log.i("PlinkReconnect", "stage=network_change category=binding_invalid")
                activeInbound?.close()
                activeReverse?.close()
                job.cancel()
                // The captured job's finally block owns revocation cleanup and failure publication.
            }
        }
    }

    fun liveBindingInvalidated() {
        if (!closed) _state.value = ReconnectState.Failed(
            ReconnectFailureReason.UNAVAILABLE_NETWORK_OR_PERMISSION,
            addresses
        )
    }

    private suspend fun cancelOwned(closing: Boolean) {
        val invalidation = if (closing) {
            lifecycleOwner.close(revokeAttempt)
        } else {
            lifecycleOwner.invalidate(revoke = revokeAttempt)
        }
        if (invalidation.cleanupRequired) revocationCleanupPending.set(true)
        val job = synchronized(this) {
            activeInbound?.close()
            activeReverse?.close()
            activeJob?.also { it.cancel() }
        }
        job?.cancelAndJoin()
        awaitPendingRevocation()
    }

    private suspend fun runAttempt(
        handshake: ActiveHandshake,
        c1: SecureSocketPlinkExchange,
        hello: PlinkEnvelope
    ) {
        val attemptToken = handshake.token
        val admissionInitiallyClosed = !ordinaryAdmissionOpen()
        var completed = false
        try {
            withTimeout(PHONE_ATTEMPT_MILLIS) {
                lastReverseTuple = null
                successfulDiagnostics = null
                requireCurrent(attemptToken)
                _state.value = ReconnectState.Reconnecting("verifying", addresses)
                val helloPayload = ReconnectPayloadPolicy.payload(hello)
                require(hello.sourceDeviceId == peerDeviceId && hello.targetDeviceId == localDeviceId)
                val tuple = c1.tuple
                require(helloPayload.phone.address == tuple.localAddress && helloPayload.phone.port == tuple.localPort)
                require(helloPayload.mac.address == tuple.remoteAddress)
                val binding = bindingResolver.resolveInbound(tuple, helloPayload.mac.port)
                    ?: fail(ReconnectFailureReason.UNAVAILABLE_NETWORK_OR_PERMISSION)
                require(binding.peer == helloPayload.mac && binding.listenerPort == helloPayload.phone.port)
                synchronized(this@ReconnectCoordinator) {
                    requireCurrent(attemptToken)
                    check(activeHandshake === handshake)
                    handshake.binding = binding
                }
                binding.validateCurrent()

                val proof = nonce()
                val challengePayload = helloPayload.copy(proof = proof)
                c1.write(control(PlinkEventType.ReconnectChallenge, challengePayload), IO_TIMEOUT_MILLIS) {
                    requireCurrent(attemptToken)
                    binding.validateCurrent()
                }
                val proofEnvelope = message(c1.read(IO_TIMEOUT_MILLIS, ReconnectPayloadPolicy.maxEncryptedJsonBytes))
                requireControl(proofEnvelope, PlinkEventType.ReconnectProof, challengePayload)
                requireCurrent(attemptToken)
                c1.close()

                _state.value = ReconnectState.Disconnecting(addresses)
                check(suspendOrdinaryAndAwait(attemptToken)) { "Ordinary cleanup did not complete." }
                requireCurrent(attemptToken)

                val reverseNonce = nonce()
                val reversePayload = challengePayload.copy(reverseProof = reverseNonce)
                val c2 = openSecureSocketPlinkExchange(
                    host = binding.peer.address,
                    port = binding.peer.port,
                    codec = codec,
                    stateStore = frameStateStore,
                    transmitGate = transmitGate,
                    expectedSourceDeviceId = peerDeviceId,
                    expectedTargetDeviceId = localDeviceId,
                    timeoutMillis = IO_TIMEOUT_MILLIS,
                    binding = binding.socketBinding
                )
                activeReverse = c2
                c2.use {
                    lastReverseTuple = it.tuple
                    require(it.tuple.localAddress == helloPayload.phone.address)
                    require(it.tuple.remoteAddress == helloPayload.mac.address && it.tuple.remotePort == helloPayload.mac.port)
                    it.write(control(PlinkEventType.ReconnectReverse, reversePayload), IO_TIMEOUT_MILLIS) {
                        requireCurrent(attemptToken)
                        binding.validateCurrent()
                    }
                    requireControl(
                        message(it.read(IO_TIMEOUT_MILLIS, ReconnectPayloadPolicy.maxEncryptedJsonBytes)),
                        PlinkEventType.ReconnectReverseProof,
                        reversePayload
                    )
                    requireCurrent(attemptToken)

                    try {
                        endpointStore.commit(
                            localID = localDeviceId,
                            peerID = peerDeviceId,
                            sessionID = sessionId,
                            endpoint = helloPayload.mac.toString(),
                            proofID = helloPayload.messageId,
                            sessionKey = ownedSessionKey,
                            attemptToken = attemptToken,
                            lifecycleOwner = lifecycleOwner,
                            pairIsCurrent = { !closed && isCurrentPair() }
                        )
                    } catch (_: Exception) {
                        fail(ReconnectFailureReason.STORAGE_ERROR)
                    }
                    check(prepareReplacement(attemptToken, binding)) { "Replacement preparation failed." }
                    it.write(control(PlinkEventType.ReconnectReady, reversePayload), IO_TIMEOUT_MILLIS) {
                        requireCurrent(attemptToken)
                        binding.validateCurrent()
                    }
                    requireControl(
                        message(it.read(IO_TIMEOUT_MILLIS, ReconnectPayloadPolicy.maxEncryptedJsonBytes)),
                        PlinkEventType.ReconnectCommit,
                        reversePayload
                    )
                    requireCurrent(attemptToken)
                    it.write(control(PlinkEventType.ReconnectDone, reversePayload), IO_TIMEOUT_MILLIS) {
                        requireCurrent(attemptToken)
                        binding.validateCurrent()
                    }
                    check(publishReplacement(attemptToken, binding)) { "Replacement publication failed." }
                }
                activeReverse = null
                successfulDiagnostics = ReconnectDiagnostics(
                    proofId = helloPayload.messageId,
                    c1 = tuple,
                    c2 = requireNotNull(lastReverseTuple),
                    ordinaryAdmissionInitiallyClosed = admissionInitiallyClosed
                )
                _state.value = ReconnectState.ConnectedInternetUnverified(addresses)
                completed = true
            }
        } catch (_: kotlinx.coroutines.TimeoutCancellationException) {
            _state.value = ReconnectState.Failed(ReconnectFailureReason.TIMEOUT_OR_INCOMPATIBLE_PEER, addresses)
        } catch (cancellation: CancellationException) {
            if (!closed) _state.value = ReconnectState.Cancelled(addresses)
            throw cancellation
        } catch (failure: ReconnectFailure) {
            _state.value = ReconnectState.Failed(failure.reason, addresses)
        } catch (_: java.net.SocketTimeoutException) {
            _state.value = ReconnectState.Failed(ReconnectFailureReason.TIMEOUT_OR_INCOMPATIBLE_PEER, addresses)
        } catch (_: SecurityException) {
            _state.value = ReconnectState.Failed(ReconnectFailureReason.UNAVAILABLE_NETWORK_OR_PERMISSION, addresses)
        } catch (_: Exception) {
            _state.value = ReconnectState.Failed(ReconnectFailureReason.AUTHENTICATION_FAILED, addresses)
        } finally {
            c1.close()
            activeReverse?.close()
            activeReverse = null
            if (completed) {
                lifecycleOwner.finish(attemptToken)
            } else {
                val invalidation = lifecycleOwner.invalidate(attemptToken, revokeAttempt)
                if (invalidation.cleanupRequired) revocationCleanupPending.set(true)
            }
            withContext(NonCancellable) { awaitPendingRevocation() }
            synchronized(this@ReconnectCoordinator) {
                if (!closed && activeHandshake === handshake && handshake.networkInvalidated) {
                    _state.value = ReconnectState.Failed(
                        ReconnectFailureReason.UNAVAILABLE_NETWORK_OR_PERMISSION,
                        addresses
                    )
                }
            }
        }
    }

    private fun control(type: String, payload: ReconnectPayload): PlinkEnvelope = ReconnectPayloadPolicy.envelope(
        type = type,
        sourceDeviceId = localDeviceId,
        targetDeviceId = peerDeviceId,
        payload = payload
    )

    private fun message(received: app.plink.android.transport.ReceivedPlinkMessage): PlinkEnvelope =
        when (val result = received.result) {
            is AuthenticatedFrameResult.Message -> result.envelope
            is AuthenticatedFrameResult.RejectedScreen -> error("Reconnect frame decoded as screen data.")
        }

    private fun requireControl(envelope: PlinkEnvelope, type: String, expected: ReconnectPayload) {
        require(envelope.type == type && envelope.sourceDeviceId == peerDeviceId && envelope.targetDeviceId == localDeviceId)
        require(ReconnectPayloadPolicy.payload(envelope) == expected)
    }

    private fun nonce(): String = ByteArray(32).also(SecureRandom()::nextBytes).let {
        Base64.getUrlEncoder().withoutPadding().encodeToString(it)
    }

    @Volatile private var lastReverseTuple: ObservedSocketTuple? = null

    private fun current(attemptToken: ReconnectAttemptToken): Boolean =
        !closed && lifecycleOwner.isCurrent(attemptToken) { isCurrentPair() }

    private fun requireCurrent(attemptToken: ReconnectAttemptToken) {
        check(current(attemptToken)) { "Reconnect attempt is stale." }
    }

    private fun fail(reason: ReconnectFailureReason): Nothing = throw ReconnectFailure(reason)

    override fun close() {
        val job = beginClose()
        if (job == null) clearSessionKey() else job.invokeOnCompletion { clearSessionKey() }
    }

    suspend fun closeAndAwait() {
        beginClose()?.cancelAndJoin()
        awaitPendingRevocation()
        clearSessionKey()
    }

    private fun beginClose(): Job? {
        val shouldInvalidate = synchronized(this) {
            if (closed) false else true.also { closed = true }
        }
        if (shouldInvalidate) {
            val invalidation = lifecycleOwner.close(revokeAttempt)
            if (invalidation.cleanupRequired) revocationCleanupPending.set(true)
        }
        return synchronized(this) {
            activeInbound?.close()
            activeReverse?.close()
            activeJob?.cancel()
            activeJob
        }
    }

    private suspend fun awaitPendingRevocation() {
        if (!revocationCleanupPending.getAndSet(false)) return
        try {
            awaitRevokedResources()
        } catch (cancellation: CancellationException) {
            revocationCleanupPending.set(true)
            throw cancellation
        }
    }

    @Synchronized
    private fun clearSessionKey() {
        ownedSessionKey.fill(0)
    }

    private class ReconnectFailure(val reason: ReconnectFailureReason) : Exception()

    private companion object {
        const val IO_TIMEOUT_MILLIS = 2_000
        const val PHONE_ATTEMPT_MILLIS = 10_000L
        const val HELLO_RATE_LIMIT_MILLIS = 2_000L
    }
}
