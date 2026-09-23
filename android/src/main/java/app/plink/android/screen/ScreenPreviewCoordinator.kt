package app.plink.android.screen

import android.app.Activity
import android.app.KeyguardManager
import android.content.Context
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.PowerManager
import app.plink.android.protocol.PlinkEnvelope
import app.plink.android.protocol.PlinkEventType
import app.plink.android.protocol.ScreenPreviewPayloadPolicy
import app.plink.android.security.AuthenticatedScreenRejection
import app.plink.android.security.AuthenticatedFrameResult
import app.plink.android.services.OutboundRequestRejectedException
import app.plink.android.services.SerializedOutboundQueue
import app.plink.android.services.SharedOutboundBridge
import java.time.Instant
import java.util.Base64
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.launch
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

enum class ScreenPreviewPhase {
    UNAVAILABLE, IDLE, AWAITING_CONSENT, STARTING, CAPTURING, STOPPING, ERROR
}

data class ScreenPreviewUiState(
    val phase: ScreenPreviewPhase,
    val requestId: String? = null,
    val streamId: String? = null,
    val peerName: String? = null,
    val message: String? = null
) {
    fun isCapturing(): Boolean = phase == ScreenPreviewPhase.CAPTURING

    fun isStopped(): Boolean = phase == ScreenPreviewPhase.IDLE ||
        phase == ScreenPreviewPhase.UNAVAILABLE || phase == ScreenPreviewPhase.ERROR
}

enum class ScreenStopReason(val wireValue: String) {
    USER("user"),
    DISABLED("disabled"),
    LOCKED("locked"),
    HIDDEN("hidden"),
    DISCONNECTED("disconnected"),
    TIMEOUT("timeout"),
    CONSENT_REVOKED("consent_revoked"),
    CAPTURE_ERROR("capture_error"),
    PROTOCOL_ERROR("protocol_error")
}

/** Opaque single-use identity bound to one trusted request and session generation. */
class ScreenConsentAttempt internal constructor(internal val token: String)

data class ScreenConsentLaunch internal constructor(
    val attempt: ScreenConsentAttempt,
    val intent: Intent
)

data class ScreenPreviewSession(
    val localDeviceId: String,
    val peerDeviceId: String,
    val peerName: String,
    val generation: Long
)

fun interface ScreenProjectionStarter {
    fun start(ticket: ScreenProjectionStartTicket, resultCode: Int, consentData: Intent): Boolean
}

class ScreenPreviewCoordinator(
    context: Context,
    private val scope: CoroutineScope,
    private val monotonicMillis: () -> Long = { android.os.SystemClock.elapsedRealtime() },
    private val featureEnabled: () -> Boolean,
    private val currentSession: () -> ScreenPreviewSession?,
    private val sendEphemeral: (
        PlinkEnvelope,
        SerializedOutboundQueue.EphemeralKind,
        () -> Boolean
    ) -> SerializedOutboundQueue.EphemeralHandle = SharedOutboundBridge::sendEphemeral,
    private val projectionStarter: ScreenProjectionStarter = ScreenProjectionStarter { ticket, resultCode, data ->
        ScreenProjectionService.start(context.applicationContext, ticket, resultCode, data)
    },
    private val createConsentIntent: () -> Intent = {
        context.applicationContext.getSystemService(MediaProjectionManager::class.java).createScreenCaptureIntent()
    },
    private val platformSupported: () -> Boolean = { Build.VERSION.SDK_INT >= 34 },
    private val captureAllowed: () -> Boolean = {
        val app = context.applicationContext
        app.getSystemService(PowerManager::class.java).isInteractive &&
            !app.getSystemService(KeyguardManager::class.java).isKeyguardLocked
    }
) {
    /** Called only after transport authentication and ordinary admission. */
    fun dispatchAuthenticated(result: AuthenticatedFrameResult, sessionGeneration: Long): Boolean {
        when (result) {
            is AuthenticatedFrameResult.RejectedScreen ->
                handleAuthenticatedRejection(result.rejection, sessionGeneration)
            is AuthenticatedFrameResult.Message -> when (result.envelope.type) {
                PlinkEventType.ScreenRequest -> handleRequest(result.envelope, sessionGeneration)
                PlinkEventType.ScreenPull -> handlePull(result.envelope, sessionGeneration)
                PlinkEventType.ScreenStop -> handleRemoteStop(result.envelope, sessionGeneration)
                in ScreenPreviewPayloadPolicy.eventTypes ->
                    handleUnexpectedInbound(result.envelope, sessionGeneration)
                else -> return false
            }
        }
        return true
    }
    private data class Pending(
        val requestId: String,
        val session: ScreenPreviewSession,
        val expiresAt: Long,
        var attemptToken: String? = null
    )

    private data class Running(
        val requestId: String,
        val streamId: String,
        val session: ScreenPreviewSession,
        val ticket: ScreenProjectionStartTicket,
        val startupDeadline: Long,
        var projectionStartedAt: Long? = null,
        var firstFrameDeadline: Long? = null,
        var noPullDeadline: Long? = null,
        var lastAcceptedPullAt: Long? = null,
        var nextIndex: Int = 1,
        var encodeJob: Job? = null,
        var activeSend: SerializedOutboundQueue.EphemeralHandle? = null,
        var captureGeneration: Long = 0,
        var sentFirstFrame: Boolean = false,
        var consecutiveOversize: Int = 0
    )

    private enum class PullOutcome { FRAME, IDLE, FRAME_TOO_LARGE }

    private data class Termination(
        val cleanup: Pair<Long, List<Job>>,
        val session: ScreenPreviewSession,
        val requestId: String,
        val streamId: String?,
        val ticket: ScreenProjectionStartTicket?,
        val activeSend: SerializedOutboundQueue.EphemeralHandle?
    )

    private val applicationContext = context.applicationContext
    private val lock = Any()
    private val _state = MutableStateFlow(initialState())
    val state: StateFlow<ScreenPreviewUiState> = _state.asStateFlow()
    private var pending: Pending? = null
    private var running: Running? = null
    private var generation = 0L
    private var terminalGeneration = 0L
    private var terminalInProgress = false
    private var watchdog: Job? = null
    private val trackedJobs = mutableSetOf<Job>()
    private var rateSessionGeneration = Long.MIN_VALUE
    private var rateTokens = CONTROL_TOKEN_CAPACITY
    private var rateUpdatedAt = monotonicMillis()

    init {
        ScreenProjectionRuntime.attach(this)
    }

    fun handleRequest(envelope: PlinkEnvelope, sessionGeneration: Long) {
        val session = currentSession()?.takeIf { it.generation == sessionGeneration } ?: return
        val requestId = ScreenPreviewPayloadPolicy.requestId(envelope)
        val rejection = synchronized(lock) {
            if (!consumeControlLocked(sessionGeneration)) return
            when {
                !platformSupported() -> "unsupported"
                !featureEnabled() -> "disabled"
                terminalInProgress || pending != null || running != null -> "busy"
                !isCurrent(session) -> "not_ready"
                else -> {
                    generation++
                    pending = Pending(requestId, session, monotonicMillis() + CONSENT_TIMEOUT_MILLIS)
                    _state.value = ScreenPreviewUiState(
                        phase = ScreenPreviewPhase.AWAITING_CONSENT,
                        requestId = requestId,
                        peerName = session.peerName,
                        message = "Share your screen with ${session.peerName}?"
                    )
                    scheduleWatchdogLocked()
                    null
                }
            }
        }
        if (rejection == null) {
            sendControl(stateEnvelope(session, requestId, "needs_consent")) {
                synchronized(lock) { pending?.requestId == requestId && isCurrent(session) }
            }
        } else {
            sendControl(rejectedEnvelope(session, requestId, rejection)) { isCurrent(session) }
        }
    }

    fun beginConsent(requestId: String): ScreenConsentLaunch? = synchronized(lock) {
        val current = pending ?: return@synchronized null
        if (current.requestId != requestId || current.attemptToken != null ||
            monotonicMillis() >= current.expiresAt || !canCapture(current.session)) return@synchronized null
        val token = UUID.randomUUID().toString()
        current.attemptToken = token
        ScreenConsentLaunch(
            ScreenConsentAttempt(token),
            createConsentIntent()
        )
    }

    fun completeConsent(attempt: ScreenConsentAttempt, resultCode: Int, data: Intent?) {
        val current = synchronized(lock) {
            val candidate = pending ?: return@synchronized null
            if (candidate.attemptToken != attempt.token) return@synchronized null
            candidate.attemptToken = null
            candidate
        } ?: return
        when {
            resultCode != Activity.RESULT_OK || data == null -> {
                rejectPending(current, "denied")
                return
            }
            monotonicMillis() >= current.expiresAt -> {
                rejectPending(current, "timeout")
                return
            }
            !canCapture(current.session) -> {
                rejectPending(current, "not_ready")
                return
            }
        }

        val streamId = UUID.randomUUID().toString()
        val ticket = synchronized(lock) {
            if (pending !== current || monotonicMillis() >= current.expiresAt || !canCapture(current.session)) return@synchronized null
            pending = null
            generation++
            val now = monotonicMillis()
            val ticket = ScreenProjectionRuntime.registerStart(
                requestId = current.requestId,
                streamId = streamId,
                sessionGeneration = current.session.generation,
                ownerGeneration = generation
            )
            running = Running(
                requestId = current.requestId,
                streamId = streamId,
                session = current.session,
                ticket = ticket,
                startupDeadline = now + STREAM_TIMEOUT_MILLIS
            )
            _state.value = ScreenPreviewUiState(
                ScreenPreviewPhase.STARTING,
                current.requestId,
                streamId,
                current.session.peerName,
                "Starting screen preview…"
            )
            scheduleWatchdogLocked()
            ticket
        } ?: return
        val started = runCatching {
            projectionStarter.start(ticket, resultCode, data)
        }.getOrDefault(false)
        if (!started) {
            synchronized(lock) { running?.takeIf { it.requestId == current.requestId && it.streamId == streamId } }
                ?.let { terminateRunning(it, ScreenStopReason.CAPTURE_ERROR, true, "Screen capture could not start.") }
        }
    }

    fun handlePull(envelope: PlinkEnvelope, sessionGeneration: Long) {
        val requestId = ScreenPreviewPayloadPolicy.requestId(envelope)
        val streamId = ScreenPreviewPayloadPolicy.streamId(envelope) ?: return
        val index = ScreenPreviewPayloadPolicy.index(envelope)
        val job = synchronized(lock) {
            val current = running ?: return
            if (!consumeControlLocked(sessionGeneration)) return
            val now = monotonicMillis()
            val last = current.lastAcceptedPullAt
            if (current.session.generation != sessionGeneration || current.requestId != requestId ||
                current.streamId != streamId || current.projectionStartedAt == null ||
                current.nextIndex != index || current.encodeJob != null ||
                (last != null && now - last < ScreenPreviewPayloadPolicy.minimumPullIntervalMillis) ||
                !canCapture(current.session)) return
            if (leaseExpiredLocked(current, now)) {
                scope.launch { terminateRunning(current, ScreenStopReason.TIMEOUT, true) }
                return
            }
            current.lastAcceptedPullAt = now
            current.noPullDeadline = now + STREAM_TIMEOUT_MILLIS
            val captureGeneration = current.captureGeneration
            createTrackedJob {
                processPull(current, index, captureGeneration)
            }.also { current.encodeJob = it }
        }
        job.start()
    }

    fun handleRemoteStop(envelope: PlinkEnvelope, sessionGeneration: Long) {
        val requestId = ScreenPreviewPayloadPolicy.requestId(envelope)
        val streamId = ScreenPreviewPayloadPolicy.streamId(envelope)
        terminateMatching(ScreenStopReason.USER, notifyPeer = false) { waiting, active ->
            consumeControlLocked(sessionGeneration) &&
                (waiting?.let { it.session.generation == sessionGeneration && it.requestId == requestId } == true ||
                active?.let {
                    it.session.generation == sessionGeneration && it.requestId == requestId &&
                        (streamId == null || it.streamId == streamId)
                } == true)
        }
    }

    fun handleUnexpectedInbound(envelope: PlinkEnvelope, sessionGeneration: Long) {
        handleProtocolError(
            requestId = runCatching { ScreenPreviewPayloadPolicy.requestId(envelope) }.getOrNull(),
            streamId = runCatching { ScreenPreviewPayloadPolicy.streamId(envelope) }.getOrNull(),
            sessionGeneration = sessionGeneration
        )
    }

    fun handleAuthenticatedRejection(rejection: AuthenticatedScreenRejection, sessionGeneration: Long) {
        handleProtocolError(rejection.requestId, rejection.streamId, sessionGeneration)
    }

    private fun handleProtocolError(requestId: String?, streamId: String?, sessionGeneration: Long) {
        terminateMatching(ScreenStopReason.PROTOCOL_ERROR, notifyPeer = true) { waiting, active ->
            when {
                waiting != null && waiting.session.generation == sessionGeneration ->
                    requestId == null || (requestId == waiting.requestId && streamId == null)
                active != null && active.session.generation == sessionGeneration ->
                    (requestId == null || requestId == active.requestId) &&
                        (streamId == null || streamId == active.streamId)
                else -> false
            }
        }
    }

    internal fun ownsProjectionStart(ticket: ScreenProjectionStartTicket): Boolean = synchronized(lock) {
        running?.let {
            it.ticket === ticket && !leaseExpiredLocked(it, monotonicMillis()) && canCapture(it.session)
        } == true
    }

    internal fun projectionStartRejected(ticket: ScreenProjectionStartTicket) {
        synchronized(lock) { running?.takeIf { it.ticket === ticket } }
            ?.let { terminateRunning(it, ScreenStopReason.DISCONNECTED, notifyPeer = true) }
    }

    internal fun projectionStarted(
        ticket: ScreenProjectionStartTicket,
        captureGeneration: Long
    ): Boolean {
        val current = synchronized(lock) {
            running?.takeIf {
                it.ticket === ticket && monotonicMillis() < it.startupDeadline && canCapture(it.session)
            }?.also {
                val now = monotonicMillis()
                it.projectionStartedAt = now
                it.firstFrameDeadline = now + STREAM_TIMEOUT_MILLIS
                it.noPullDeadline = now + STREAM_TIMEOUT_MILLIS
                it.captureGeneration = captureGeneration
                _state.value = ScreenPreviewUiState(
                    ScreenPreviewPhase.CAPTURING,
                    it.requestId,
                    it.streamId,
                    it.session.peerName,
                    "Sharing screen with ${it.session.peerName}."
                )
                scheduleWatchdogLocked()
            } ?: return false
        }
        sendControl(startedEnvelope(current)) {
            synchronized(lock) { running === current && canCapture(current.session) }
        }
        return true
    }

    internal fun projectionResized(ticket: ScreenProjectionStartTicket, captureGeneration: Long) {
        val activeSend = synchronized(lock) {
            val current = running?.takeIf { it.ticket === ticket } ?: return
            if (captureGeneration <= current.captureGeneration) return
            current.captureGeneration = captureGeneration
            current.activeSend
        }
        activeSend?.cancel()
    }

    internal fun projectionStopped(ticket: ScreenProjectionStartTicket, reason: ScreenStopReason) {
        val current = synchronized(lock) { running?.takeIf { it.ticket === ticket } } ?: return
        terminateRunning(
                current,
                reason,
                notifyPeer = true,
                errorMessage = if (reason == ScreenStopReason.CAPTURE_ERROR) {
                    "Screen capture stopped unexpectedly."
                } else null
            )
    }

    fun sessionChanged() {
        synchronized(lock) { resetRateLimitLocked() }
        stop(ScreenStopReason.DISCONNECTED, notifyPeer = false)
    }
    fun featureDisabled() = stop(ScreenStopReason.DISABLED, notifyPeer = true)

    fun stop(
        reason: ScreenStopReason = ScreenStopReason.USER,
        notifyPeer: Boolean = true,
        errorMessage: String? = null
    ) {
        val termination = synchronized(lock) {
            takeTerminationLocked().also {
                if (it == null && !terminalInProgress) _state.value = when {
                    !platformSupported() -> unavailableState()
                    errorMessage == null -> idleState()
                    else -> ScreenPreviewUiState(ScreenPreviewPhase.ERROR, message = errorMessage)
                }
            }
        } ?: return
        finishSelectedTermination(termination, reason, notifyPeer, errorMessage)
    }

    suspend fun awaitQuiescence() {
        while (true) {
            ScreenProjectionRuntime.awaitQuiescence()
            val jobs = synchronized(lock) { trackedJobs.toList() }
            if (jobs.isNotEmpty()) jobs.joinAll()
            if (synchronized(lock) { trackedJobs.isEmpty() }) {
                ScreenProjectionRuntime.awaitQuiescence()
                return
            }
        }
    }

    private suspend fun processPull(current: Running, index: Int, captureGeneration: Long) {
        val job = currentCoroutineContext()[Job]
        var bitmap: android.graphics.Bitmap? = null
        try {
            if (synchronized(lock) { running !== current || leaseExpiredLocked(current, monotonicMillis()) }) {
                terminateRunning(current, ScreenStopReason.TIMEOUT, notifyPeer = true)
                return
            }
            val captured = ScreenProjectionRuntime.takeLatest(current.ticket)
            if (captured == null) {
                sendPullResponse(current, index, idleEnvelope(current, index, "no_new_frame"), PullOutcome.IDLE, null)
                return
            }
            bitmap = captured.bitmap
            val encoded = ScreenFrameEncoder.encode(captured.bitmap)
            if (captured.generation != captureGeneration ||
                !ScreenProjectionRuntime.isCaptureGenerationCurrent(current.ticket, captured.generation)
            ) {
                sendPullResponse(current, index, idleEnvelope(current, index, "no_new_frame"), PullOutcome.IDLE, null)
                return
            }
            when (encoded) {
                is ScreenFrameEncoding.Encoded -> sendPullResponse(
                    current, index, frameEnvelope(current, index, encoded), PullOutcome.FRAME, captured.generation
                )
                ScreenFrameEncoding.TooLarge -> sendPullResponse(
                    current,
                    index,
                    idleEnvelope(current, index, "frame_too_large"),
                    PullOutcome.FRAME_TOO_LARGE,
                    captured.generation
                )
            }
        } catch (cancellation: CancellationException) {
            throw cancellation
        } catch (_: Exception) {
            terminateRunning(
                current,
                ScreenStopReason.CAPTURE_ERROR,
                notifyPeer = false,
                errorMessage = "Screen preview connection failed."
            )
        } finally {
            bitmap?.recycle()
            synchronized(lock) {
                if (running === current && current.encodeJob === job) {
                    current.encodeJob = null
                }
            }
        }
    }

    private suspend fun sendPullResponse(
        current: Running,
        index: Int,
        initialEnvelope: PlinkEnvelope,
        initialOutcome: PullOutcome,
        requiredCaptureGeneration: Long?
    ) {
        var envelope = initialEnvelope
        var outcome = initialOutcome
        var requiredGeneration = requiredCaptureGeneration
        while (true) {
            try {
                sendResponseOnce(current, index, envelope, requiredGeneration)
                completePull(current, index, outcome)
                return
            } catch (cancellation: CancellationException) {
                currentCoroutineContext().ensureActive()
                if (requiredGeneration == null || !captureGenerationChanged(current, requiredGeneration)) {
                    throw cancellation
                }
            } catch (rejected: OutboundRequestRejectedException) {
                if (requiredGeneration == null || !captureGenerationChanged(current, requiredGeneration)) {
                    throw rejected
                }
            }
            envelope = idleEnvelope(current, index, "no_new_frame")
            outcome = PullOutcome.IDLE
            requiredGeneration = null
        }
    }

    private suspend fun sendResponseOnce(
        current: Running,
        index: Int,
        envelope: PlinkEnvelope,
        requiredCaptureGeneration: Long?
    ) {
        val valid = {
            synchronized(lock) { isResponseValidLocked(current, index, requiredCaptureGeneration) }
        }
        val handle = sendEphemeral(envelope, SerializedOutboundQueue.EphemeralKind.DATA, valid)
        val accepted = synchronized(lock) {
            if (isResponseValidLocked(current, index, requiredCaptureGeneration)) {
                current.activeSend = handle
                true
            } else false
        }
        if (!accepted) {
            handle.cancel()
            throw OutboundRequestRejectedException("Screen response was revoked.")
        }
        try {
            handle.await()
        } finally {
            handle.cancel()
            synchronized(lock) {
                if (current.activeSend === handle) current.activeSend = null
            }
        }
    }

    private fun completePull(current: Running, index: Int, outcome: PullOutcome) {
        val terminalReason = synchronized(lock) {
            if (running !== current || current.nextIndex != index) return
            if (leaseExpiredLocked(current, monotonicMillis())) {
                return@synchronized ScreenStopReason.TIMEOUT
            }
            when (outcome) {
                PullOutcome.FRAME -> {
                    current.sentFirstFrame = true
                    current.consecutiveOversize = 0
                }
                PullOutcome.IDLE -> current.consecutiveOversize = 0
                PullOutcome.FRAME_TOO_LARGE -> current.consecutiveOversize++
            }
            if (index == Int.MAX_VALUE) {
                ScreenStopReason.PROTOCOL_ERROR
            } else {
                current.nextIndex++
                if (current.consecutiveOversize >= MAX_CONSECUTIVE_OVERSIZE) {
                    ScreenStopReason.CAPTURE_ERROR
                } else null
            }
        }
        if (terminalReason != null) {
            terminateRunning(
                current,
                terminalReason,
                notifyPeer = true,
                errorMessage = if (terminalReason == ScreenStopReason.CAPTURE_ERROR) {
                    "Screen frames exceed the preview size limit."
                } else null
            )
        }
    }

    private fun captureGenerationChanged(current: Running, expected: Long): Boolean =
        synchronized(lock) { running === current && current.captureGeneration != expected } ||
            !ScreenProjectionRuntime.isCaptureGenerationCurrent(current.ticket, expected)

    private fun isResponseValidLocked(
        current: Running,
        index: Int,
        requiredCaptureGeneration: Long?
    ): Boolean = running === current && current.nextIndex == index && current.encodeJob != null &&
        !leaseExpiredLocked(current, monotonicMillis()) &&
        canCapture(current.session) &&
        (requiredCaptureGeneration == null ||
            (current.captureGeneration == requiredCaptureGeneration &&
                ScreenProjectionRuntime.isCaptureGenerationCurrent(current.ticket, requiredCaptureGeneration)))

    private fun sendControl(envelope: PlinkEnvelope, valid: () -> Boolean) {
        val handle = runCatching {
            sendEphemeral(envelope, SerializedOutboundQueue.EphemeralKind.CONTROL, valid)
        }.getOrNull() ?: return
        createTrackedJob {
            try { handle.await() } catch (_: Exception) { }
            finally { handle.cancel() }
        }.start()
    }

    private fun leaseExpiredLocked(current: Running, now: Long): Boolean =
        if (current.projectionStartedAt == null) now >= current.startupDeadline
        else (!current.sentFirstFrame && current.firstFrameDeadline?.let { now >= it } == true) ||
            current.noPullDeadline?.let { now >= it } == true

    private fun terminateRunning(
        current: Running, reason: ScreenStopReason, notifyPeer: Boolean, errorMessage: String? = null
    ) = terminateMatching(reason, notifyPeer, errorMessage) { _, active -> active === current }

    private fun terminateMatching(
        reason: ScreenStopReason,
        notifyPeer: Boolean,
        errorMessage: String? = null,
        matches: (Pending?, Running?) -> Boolean
    ) {
        val termination = synchronized(lock) {
            if (!matches(pending, running)) return
            takeTerminationLocked()
        } ?: return
        finishSelectedTermination(termination, reason, notifyPeer, errorMessage)
    }

    /** Caller holds lock: matching, phase selection and invalidation are one transition. */
    private fun takeTerminationLocked(): Termination? {
        val active = running
        val waiting = pending
        if (active == null && waiting == null) return null
        running = null
        pending = null
        waiting?.attemptToken = null
        return Termination(
            beginTerminationLocked(),
            active?.session ?: requireNotNull(waiting).session,
            active?.requestId ?: requireNotNull(waiting).requestId,
            active?.streamId,
            active?.ticket,
            active?.activeSend
        )
    }

    private fun finishSelectedTermination(
        termination: Termination, reason: ScreenStopReason, notifyPeer: Boolean, errorMessage: String?
    ) {
        termination.activeSend?.cancel()
        SharedOutboundBridge.purgeEphemeral(ScreenPreviewPayloadPolicy.eventTypes)
        termination.ticket?.let { ScreenProjectionRuntime.invalidate(it, reason) }
        finishTermination(termination.cleanup, termination.session, termination.requestId,
            termination.streamId, reason, notifyPeer, errorMessage, termination.ticket)
    }

    private fun beginTerminationLocked(): Pair<Long, List<Job>> {
        generation++
        terminalGeneration++
        terminalInProgress = true
        watchdog = null
        _state.value = ScreenPreviewUiState(ScreenPreviewPhase.STOPPING, message = "Stopping screen preview…")
        return terminalGeneration to trackedJobs.toList()
    }

    private fun finishTermination(
        cleanup: Pair<Long, List<Job>>, session: ScreenPreviewSession, requestId: String,
        streamId: String?, reason: ScreenStopReason, notifyPeer: Boolean, errorMessage: String?,
        ticket: ScreenProjectionStartTicket?
    ) {
        cleanup.second.forEach { it.cancel() }
        createTrackedJob {
            cleanup.second.joinAll()
            ticket?.completion?.await()
            synchronized(lock) {
                if (terminalGeneration == cleanup.first) {
                    terminalInProgress = false
                    _state.value = when {
                        !platformSupported() -> unavailableState()
                        errorMessage != null -> ScreenPreviewUiState(ScreenPreviewPhase.ERROR, message = errorMessage)
                        else -> idleState()
                    }
                }
            }
        }.start()
        if (notifyPeer) sendControl(stopEnvelope(session, requestId, streamId, reason)) {
            isCurrent(session) && synchronized(lock) { terminalGeneration == cleanup.first }
        }
    }

    private fun rejectPending(current: Pending, reason: String) {
        val oldWatchdog = synchronized(lock) {
            if (pending !== current) return
            pending = null
            generation++
            val job = watchdog
            watchdog = null
            _state.value = idleState(
                when (reason) {
                    "denied" -> "Screen sharing was not allowed."
                    "timeout" -> "The screen sharing request expired."
                    else -> null
                }
            )
            job
        }
        oldWatchdog?.cancel()
        sendControl(rejectedEnvelope(current.session, current.requestId, reason)) { isCurrent(current.session) }
    }

    private fun scheduleWatchdogLocked() {
        watchdog?.cancel()
        val generationSnapshot = generation
        val job = createTrackedJob {
            while (true) {
                delay(WATCHDOG_INTERVAL_MILLIS)
                val expired = synchronized(lock) {
                    if (generation != generationSnapshot) return@createTrackedJob
                    val now = monotonicMillis()
                    val waiting = pending
                    val active = running
                    waiting?.takeIf { now >= it.expiresAt } to
                        active?.takeIf { leaseExpiredLocked(it, now) }
                }
                if (expired.first != null || expired.second != null) {
                    expired.first?.let { rejectPending(it, "timeout") }
                    expired.second?.let { terminateRunning(it, ScreenStopReason.TIMEOUT, notifyPeer = true) }
                    return@createTrackedJob
                }
            }
        }
        watchdog = job
        job.start()
    }

    private fun createTrackedJob(block: suspend CoroutineScope.() -> Unit): Job {
        val job = scope.launch(start = CoroutineStart.LAZY, block = block)
        synchronized(lock) { trackedJobs += job }
        job.invokeOnCompletion { synchronized(lock) { trackedJobs -= job } }
        return job
    }

    private fun consumeControlLocked(sessionGeneration: Long): Boolean {
        val now = monotonicMillis()
        if (rateSessionGeneration != sessionGeneration) {
            rateSessionGeneration = sessionGeneration
            rateTokens = CONTROL_TOKEN_CAPACITY
            rateUpdatedAt = now
        } else {
            val elapsed = (now - rateUpdatedAt).coerceAtLeast(0L)
            rateTokens = minOf(
                CONTROL_TOKEN_CAPACITY,
                rateTokens + elapsed.toDouble() * CONTROL_TOKENS_PER_SECOND / 1_000.0
            )
            rateUpdatedAt = now
        }
        if (rateTokens < 1.0) return false
        rateTokens -= 1.0
        return true
    }

    private fun resetRateLimitLocked() {
        rateSessionGeneration = Long.MIN_VALUE
        rateTokens = CONTROL_TOKEN_CAPACITY
        rateUpdatedAt = monotonicMillis()
    }

    private fun canCapture(session: ScreenPreviewSession): Boolean = platformSupported() &&
        featureEnabled() && isCurrent(session) && captureAllowed()

    private fun isCurrent(session: ScreenPreviewSession): Boolean = currentSession() == session

    private fun initialState(): ScreenPreviewUiState =
        if (!platformSupported()) unavailableState() else idleState()

    private fun unavailableState() = ScreenPreviewUiState(
        ScreenPreviewPhase.UNAVAILABLE,
        message = "Screen preview requires Android 14 or later."
    )

    private fun idleState(message: String? = null) = ScreenPreviewUiState(ScreenPreviewPhase.IDLE, message = message)

    private fun envelope(session: ScreenPreviewSession, type: String, payload: kotlinx.serialization.json.JsonObject) =
        PlinkEnvelope(
            id = UUID.randomUUID().toString(),
            type = type,
            sentAt = app.plink.android.security.PlinkTime.canonicalTimestamp(Instant.now()),
            sourceDeviceId = session.localDeviceId,
            targetDeviceId = session.peerDeviceId,
            payload = payload
        )

    private fun stateEnvelope(session: ScreenPreviewSession, requestId: String, state: String) =
        envelope(session, PlinkEventType.ScreenState, buildJsonObject {
            put("v", 1); put("requestId", requestId); put("state", state)
        })

    private fun rejectedEnvelope(session: ScreenPreviewSession, requestId: String, reason: String) =
        envelope(session, PlinkEventType.ScreenState, buildJsonObject {
            put("v", 1); put("requestId", requestId); put("state", "rejected"); put("reason", reason)
        })

    private fun startedEnvelope(current: Running) =
        envelope(current.session, PlinkEventType.ScreenState, buildJsonObject {
            put("v", 1); put("requestId", current.requestId); put("state", "started")
            put("streamId", current.streamId); put("profile", ScreenPreviewPayloadPolicy.profile)
        })

    private fun idleEnvelope(current: Running, index: Int, reason: String) =
        envelope(current.session, PlinkEventType.ScreenIdle, buildJsonObject {
            put("v", 1); put("requestId", current.requestId); put("streamId", current.streamId)
            put("index", index); put("reason", reason)
        })

    private fun frameEnvelope(current: Running, index: Int, frame: ScreenFrameEncoding.Encoded) =
        envelope(current.session, PlinkEventType.ScreenFrame, buildJsonObject {
            put("v", 1); put("requestId", current.requestId); put("streamId", current.streamId)
            put("index", index); put("width", frame.width); put("height", frame.height)
            put("data", Base64.getEncoder().encodeToString(frame.jpeg))
        })

    private fun stopEnvelope(
        session: ScreenPreviewSession,
        requestId: String,
        streamId: String?,
        reason: ScreenStopReason
    ) = envelope(session, PlinkEventType.ScreenStop, buildJsonObject {
        put("v", 1); put("requestId", requestId); if (streamId != null) put("streamId", streamId)
        put("reason", reason.wireValue)
    })

    private companion object {
        const val CONSENT_TIMEOUT_MILLIS = 60_000L
        const val STREAM_TIMEOUT_MILLIS = 5_000L
        const val WATCHDOG_INTERVAL_MILLIS = 100L
        const val MAX_CONSECUTIVE_OVERSIZE = 3
        const val CONTROL_TOKENS_PER_SECOND = 8.0
        const val CONTROL_TOKEN_CAPACITY = 4.0
    }
}
