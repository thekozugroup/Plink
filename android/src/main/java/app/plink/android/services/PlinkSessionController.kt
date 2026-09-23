package app.plink.android.services

import android.content.Context
import android.content.Intent
import android.os.SystemClock
import app.plink.android.continuity.ContinuityEnvelopeFactory
import app.plink.android.continuity.ContinuityEvent
import app.plink.android.continuity.AndroidFileTransferEnvironment
import app.plink.android.continuity.FileOfferStartResult
import app.plink.android.continuity.FileTransferCoordinator
import app.plink.android.continuity.FileTransferState
import app.plink.android.continuity.IncomingFileDestination
import app.plink.android.continuity.IncomingFileOffer
import app.plink.android.continuity.OutgoingFileSource
import app.plink.android.features.ContinuityFeature
import app.plink.android.features.FeatureSettings
import app.plink.android.PlinkApplication
import app.plink.android.clipboard.ClipboardConnection
import app.plink.android.protocol.PlinkEnvelope
import app.plink.android.notifications.RemoteInputReplyExecutor
import app.plink.android.notifications.ReplyDispatchLock
import app.plink.android.pairing.PairedDevice
import app.plink.android.protocol.PlinkEventType
import app.plink.android.protocol.FileTransferPayloadPolicy
import app.plink.android.protocol.ScreenPreviewPayloadPolicy
import app.plink.android.screen.ScreenConsentAttempt
import app.plink.android.screen.ScreenPreviewCoordinator
import app.plink.android.screen.ScreenPreviewSession
import app.plink.android.protocol.ReconnectPayloadPolicy
import app.plink.android.reconnect.ReconnectBindingResolver
import app.plink.android.reconnect.ReconnectAttemptToken
import app.plink.android.reconnect.ReconnectCoordinator
import app.plink.android.reconnect.ReconnectDiscovery
import app.plink.android.reconnect.ReconnectEndpointStore
import app.plink.android.reconnect.ReconnectLiveBinding
import app.plink.android.reconnect.ReconnectLifecycleOwner
import app.plink.android.reconnect.PreparedOrdinaryResources
import app.plink.android.reconnect.ReconnectNetworkResolver
import app.plink.android.reconnect.ReconnectState
import app.plink.android.security.AuthenticatedFrameResult
import app.plink.android.security.EncryptedFrameCodec
import app.plink.android.security.FileFrameStateStore
import app.plink.android.security.ReplayWindow
import app.plink.android.transport.SecureSocketPlinkClient
import app.plink.android.transport.SecureSocketPlinkServer
import app.plink.android.transport.PairTransmitGate
import app.plink.android.transport.SecureSocketPlinkExchange
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.collect
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.jsonPrimitive
import java.io.File
import java.util.concurrent.atomic.AtomicLong
import java.util.UUID

enum class SessionStatus { DISCONNECTED, AWAITING_RECONNECT, REPAIR_REQUIRED, READY }

private class PairSessionLifetime(
    val generation: Long,
    val session: ActivePlinkSession,
    val codec: EncryptedFrameCodec,
    val transmitGate: PairTransmitGate,
    val server: SecureSocketPlinkServer,
    val lifecycleOwner: ReconnectLifecycleOwner,
    val reconnect: ReconnectCoordinator,
    val discovery: ReconnectDiscovery,
    val resolver: ReconnectNetworkResolver,
    val admissionLock: Any = Any(),
    var admission: OrdinaryAdmissionLease? = null,
    var retiringDispatch: OrdinaryDispatchOwner? = null,
    var preparedResources: PreparedOrdinaryResources? = null,
    var retiringPrepared: PreparedOrdinaryResources? = null,
    var preparedBinding: ReconnectLiveBinding? = null,
    var preparedAttemptToken: ReconnectAttemptToken? = null,
    var suspendedAttemptToken: ReconnectAttemptToken? = null,
    var publishedAttemptToken: ReconnectAttemptToken? = null,
    var liveBinding: ReconnectLiveBinding? = null,
    var ordinaryActivationPending: Boolean = true,
    var stopping: Boolean = false,
    var addressesJob: Job? = null,
    var stateJob: Job? = null
)

class PlinkSessionController(
    private val context: Context,
    private val featureSettings: FeatureSettings,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
) {
    private var replyReceiverJob: Job? = null
    private val receiverJobs = mutableSetOf<Job>()
    private val stopMutex = Mutex()
    private var awaitingStop = false
    private var replyServer: SecureSocketPlinkServer? = null
    @Volatile private var pairLifetime: PairSessionLifetime? = null
    private val pairGeneration = AtomicLong()
    private val replacementMutex = Mutex()
    private val frameStateStore = FileFrameStateStore(File(context.filesDir, "transport-state"))
    @Volatile
    private var activeSession: ActivePlinkSession? = null
    @Volatile private var screenSession: ScreenPreviewSession? = null
    @Volatile
    private var outbox: EventOutbox? = null
    private val sessionGeneration = AtomicLong()
    private val _status = MutableStateFlow(SessionStatus.DISCONNECTED)
    val status: StateFlow<SessionStatus> = _status.asStateFlow()
    private val _reconnectState = MutableStateFlow<ReconnectState>(ReconnectState.Idle(emptyList()))
    val reconnectState: StateFlow<ReconnectState> = _reconnectState.asStateFlow()
    private val _reconnectAvailable = MutableStateFlow(false)
    val reconnectAvailable: StateFlow<Boolean> = _reconnectAvailable.asStateFlow()
    private val mediaCollector = MediaSessionCollector(context) { sendEvent(it) }
    private val batteryCollector = BatteryStatusCollector(context) { sendEvent(it) }
    private val fileTransferEnvironment = AndroidFileTransferEnvironment(context.applicationContext)
    val fileTransferCoordinator = FileTransferCoordinator(
        stagingBase = newFileTransferProcessRoot(context.cacheDir),
        scope = scope,
        environment = fileTransferEnvironment,
        filesEnabled = { featureSettings.isEnabled(ContinuityFeature.Files) },
        sendEnvelope = { envelope, allowRevoked, stillValid -> SharedOutboundBridge.sendAwaitable(envelope, allowRevoked, stillValid) }
    )
    val fileTransferState: StateFlow<FileTransferState> = fileTransferCoordinator.state
    private val screenPreviewCoordinator = ScreenPreviewCoordinator(
        context = context.applicationContext,
        scope = scope,
        featureEnabled = { featureSettings.isEnabled(ContinuityFeature.ScreenMirror) },
        currentSession = { screenSession }
    )
    val screenPreviewState = screenPreviewCoordinator.state

    fun beginScreenConsent(requestId: String) = screenPreviewCoordinator.beginConsent(requestId)
    fun completeScreenConsent(attempt: ScreenConsentAttempt, resultCode: Int, data: Intent?) =
        screenPreviewCoordinator.completeConsent(attempt, resultCode, data)
    fun stopScreenPreview() = screenPreviewCoordinator.stop()

    init {
        featureSettings.addListener { feature, enabled ->
            if (feature == ContinuityFeature.Messages) {
                SharedNotificationActions.registry.setFeatureEnabled(enabled)
                if (enabled) SharedNotificationActions.requestRefresh()
            }
            if (!enabled) {
                if (feature == ContinuityFeature.Messages) {
                    revokeReplyCapabilities()
                }
                if (feature == ContinuityFeature.Files) fileTransferCoordinator.featureDisabled()
                SharedOutboundBridge.purge(feature.eventTypes)
                if (feature == ContinuityFeature.ScreenMirror) screenPreviewCoordinator.featureDisabled()
            }
        }
        scope.launch {
            featureSettings.enabled.collectLatest { enabled ->
                if (activeSession == null) return@collectLatest
                if (enabled[ContinuityFeature.Messages] != true) {
                    revokeReplyCapabilities()
                }
                if (enabled[ContinuityFeature.Battery] == true) batteryCollector.start() else batteryCollector.stop()
                if (enabled[ContinuityFeature.Media] == true) mediaCollector.start() else mediaCollector.stop()
            }
        }
    }

    @Synchronized
    fun configure(
        localDeviceId: String,
        pairedDevice: PairedDevice,
        sessionKey: ByteArray,
        localReplyPort: Int = 45731
    ) {
        configurePair(localDeviceId, pairedDevice, sessionKey, localReplyPort, admitOrdinary = true)
    }

    @Synchronized
    fun restoreIfDisconnected(
        localDeviceId: String,
        pairedDevice: PairedDevice,
        sessionKey: ByteArray,
        localReplyPort: Int = 45731,
        canRestore: () -> Boolean = { true }
    ): Boolean {
        if (!canRestore() || _status.value != SessionStatus.DISCONNECTED || pairLifetime != null) return false
        configurePair(localDeviceId, pairedDevice, sessionKey, localReplyPort, admitOrdinary = false)
        return pairLifetime != null
    }

    suspend fun configureAndAwait(
        localDeviceId: String,
        pairedDevice: PairedDevice,
        sessionKey: ByteArray,
        localReplyPort: Int = 45731,
        admitOrdinary: Boolean = true
    ) {
        stopAndAwait()
        synchronized(this) {
            configurePair(localDeviceId, pairedDevice, sessionKey, localReplyPort, admitOrdinary)
        }
    }

    @Synchronized
    private fun configurePair(
        localDeviceId: String,
        pairedDevice: PairedDevice,
        sessionKey: ByteArray,
        localReplyPort: Int,
        admitOrdinary: Boolean
    ) {
        check(!awaitingStop) { "Session shutdown is still in progress." }
        if (!pairedDevice.trusted || pairedDevice.securityVersion != CURRENT_SECURITY_VERSION) {
            stop()
            _status.value = SessionStatus.REPAIR_REQUIRED
            return
        }
        stop()
        val ownedKey = sessionKey.copyOf()
        try {
            val session = ActivePlinkSession(localDeviceId, pairedDevice, ownedKey)
            val codec = EncryptedFrameCodec(ownedKey)
            val gate = PairTransmitGate(codec, frameStateStore)
            val server = SecureSocketPlinkServer(
                port = localReplyPort,
                codec = codec,
                stateStore = frameStateStore,
                replayWindow = ReplayWindow(),
                expectedSourceDeviceId = pairedDevice.id,
                expectedTargetDeviceId = localDeviceId,
                transmitGate = gate
            )
            val resolver = ReconnectNetworkResolver(context.applicationContext)
            val lifecycleOwner = ReconnectLifecycleOwner(SystemClock::elapsedRealtime)
            lateinit var lifetime: PairSessionLifetime
            val discovery = ReconnectDiscovery(context.applicationContext) {
                lifetime.reconnect.networkChanged()
                scope.launch { invalidateChangedBinding(lifetime) }
            }
            val coordinator = ReconnectCoordinator(
                localDeviceId = localDeviceId,
                peerDeviceId = pairedDevice.id,
                sessionId = pairedDevice.sessionId,
                sessionKey = ownedKey,
                codec = codec,
                frameStateStore = frameStateStore,
                transmitGate = gate,
                endpointStore = ReconnectEndpointStore(File(context.filesDir, "reconnect-endpoints")),
                bindingResolver = object : ReconnectBindingResolver {
                    override fun resolveInbound(
                        tuple: app.plink.android.transport.ObservedSocketTuple,
                        macListenerPort: Int
                    ): ReconnectLiveBinding? = resolver.resolveInboundLive(tuple, macListenerPort)
                },
                scope = scope,
                lifecycleOwner = lifecycleOwner,
                suspendOrdinaryAndAwait = { attempt -> suspendOrdinaryAndAwait(lifetime, attempt) },
                prepareReplacement = { attempt, binding -> prepareReplacement(lifetime, attempt, binding) },
                publishReplacement = { attempt, binding -> publishReplacement(lifetime, attempt, binding) },
                revokeAttempt = { attempt, _ -> revokeReconnectAttempt(lifetime, attempt) },
                awaitRevokedResources = { awaitOrdinaryQuiescence(lifetime) },
                ordinaryAdmissionOpen = { activeSession != null },
                isCurrentPair = { pairLifetime === lifetime },
                claimConditional = { timeout, binding ->
                    lifecycleOwner.beginConditional(timeout, lifetime.admissionLock) {
                        conditionalAdmissionEligible(lifetime) &&
                            runCatching { binding.validateCurrent() }.isSuccess
                    }
                },
                conditionalClaimCurrent = { attempt ->
                    synchronized(lifetime.admissionLock) {
                        conditionalAdmissionEligible(lifetime, attempt, allowPrepared = true)
                    }
                }
            )
            lifetime = PairSessionLifetime(
                generation = pairGeneration.incrementAndGet(),
                session = session,
                codec = codec,
                transmitGate = gate,
                server = server,
                lifecycleOwner = lifecycleOwner,
                reconnect = coordinator,
                discovery = discovery,
                resolver = resolver
            )
            server.start()
            pairLifetime = lifetime
            replyServer = server
            _reconnectAvailable.value = true
            startReplyReceiver(lifetime)
            lifetime.addressesJob = scope.launch {
                discovery.addresses.collect { values ->
                    coordinator.updateAddresses(values)
                }
            }
            lifetime.stateJob = scope.launch { coordinator.state.collect { _reconnectState.value = it } }
            runCatching { discovery.start(localDeviceId, localReplyPort) }
                .onFailure {
                    _reconnectState.value = ReconnectState.Failed(
                        app.plink.android.reconnect.ReconnectFailureReason.UNAVAILABLE_NETWORK_OR_PERMISSION,
                        discovery.addresses.value
                    )
                }
            if (admitOrdinary) activateOrdinary(lifetime, binding = null)
            else synchronized(lifetime.admissionLock) {
                _status.value = SessionStatus.AWAITING_RECONNECT
                lifetime.ordinaryActivationPending = false
            }
        } catch (failure: Exception) {
            ownedKey.fill(0)
            stop()
            throw failure
        }
    }

    @Synchronized
    fun stop() {
        pairLifetime?.let { lifetime ->
            synchronized(lifetime.admissionLock) {
                lifetime.stopping = true
                deactivateOrdinaryLocked(lifetime, SessionStatus.DISCONNECTED)
            }
        } ?: run {
            screenSession = null
            val generation = sessionGeneration.incrementAndGet()
            activeSession = null
            screenPreviewCoordinator.sessionChanged()
            setReplySession(generation, active = false)
            fileTransferCoordinator.deactivateSession()
        }
        pairLifetime?.let { lifetime ->
            lifetime.addressesJob?.cancel()
            lifetime.stateJob?.cancel()
            lifetime.discovery.close()
            lifetime.reconnect.close()
            lifetime.server.close()
            lifetime.session.sessionKey.fill(0)
        }
        pairLifetime = null
        replyServer?.close()
        replyServer = null
        replyReceiverJob?.cancel()
        replyReceiverJob = null
        batteryCollector.stop()
        mediaCollector.stop()
        SharedOutboundBridge.configure(null)
        SharedSessionState.clear()
        activeSession = null
        outbox = null
        _status.value = SessionStatus.DISCONNECTED
        _reconnectState.value = ReconnectState.Idle(emptyList())
        _reconnectAvailable.value = false
    }

    /** A barrier for callers that must remove owned state only after all writers stop. */
    suspend fun stopAndAwait() = stopMutex.withLock {
        val (receivers, lifetime) = synchronized(this) {
            awaitingStop = true
            val lifetime = pairLifetime
            stop()
            receiverJobs.toList() to lifetime
        }
        try {
            lifetime?.reconnect?.closeAndAwait()
            receivers.joinAll()
            if (lifetime != null) awaitOrdinaryQuiescence(lifetime)
            screenPreviewCoordinator.awaitQuiescence()
            fileTransferCoordinator.awaitQuiescence()
            SharedOutboundBridge.awaitQuiescence()
        } finally {
            synchronized(this) { awaitingStop = false }
        }
    }

    /** Called with admissionLock held, inside the lifecycle owner at claim/commit points. */
    private fun conditionalAdmissionEligible(
        lifetime: PairSessionLifetime,
        attempt: ReconnectAttemptToken? = null,
        allowPrepared: Boolean = false
    ): Boolean = pairLifetime === lifetime && !lifetime.stopping && !lifetime.ordinaryActivationPending &&
        (attempt == null || lifetime.lifecycleOwner.isCurrent(attempt) { pairLifetime === lifetime }) &&
        activeSession == null && lifetime.admission == null && lifetime.retiringDispatch == null &&
        lifetime.retiringPrepared == null && lifetime.suspendedAttemptToken == null &&
        (if (!allowPrepared || attempt == null || lifetime.preparedResources == null) {
            lifetime.preparedResources == null && lifetime.preparedAttemptToken == null && lifetime.preparedBinding == null
        } else lifetime.preparedAttemptToken == attempt)

    private suspend fun suspendOrdinaryAndAwait(
        lifetime: PairSessionLifetime,
        attemptToken: ReconnectAttemptToken
    ): Boolean =
        replacementMutex.withLock {
            if (attemptToken.conditional) {
                // The claimed session has nothing to retire. Never route a stale conditional Proof
                // through legacy deactivation, which could revoke an intervening ordinary session.
                return@withLock lifetime.lifecycleOwner.commit(attemptToken, { pairLifetime === lifetime }) {
                    synchronized(lifetime.admissionLock) { conditionalAdmissionEligible(lifetime, attemptToken) }
                } == true
            }
            val suspended = lifetime.lifecycleOwner.commit(attemptToken, { pairLifetime === lifetime }) {
                synchronized(lifetime.admissionLock) {
                    lifetime.preparedBinding = null
                    lifetime.preparedAttemptToken = null
                    lifetime.suspendedAttemptToken = attemptToken
                    deactivateOrdinaryLocked(lifetime, SessionStatus.AWAITING_RECONNECT)
                    true
                }
            } == true
            if (!suspended) return@withLock false
            awaitOrdinaryQuiescence(lifetime)
            val current = lifetime.lifecycleOwner.isCurrent(attemptToken) { pairLifetime === lifetime }
            if (current) synchronized(lifetime.admissionLock) {
                if (lifetime.suspendedAttemptToken == attemptToken) lifetime.suspendedAttemptToken = null
            }
            current
        }

    private suspend fun prepareReplacement(
        lifetime: PairSessionLifetime,
        attemptToken: ReconnectAttemptToken,
        binding: ReconnectLiveBinding
    ): Boolean = replacementMutex.withLock {
        if (!lifetime.lifecycleOwner.isCurrent(attemptToken) { pairLifetime === lifetime }) return@withLock false
        if (attemptToken.conditional && lifetime.lifecycleOwner.commit(attemptToken, { pairLifetime === lifetime }) {
            synchronized(lifetime.admissionLock) { conditionalAdmissionEligible(lifetime, attemptToken) }
        } != true) return@withLock false
        binding.validateCurrent()
        // All disk work happens while ordinary admission remains closed and cancellation is unblocked.
        val prepared = prepareOrdinary(lifetime, binding, attemptToken)
        var retained = false
        try {
            binding.validateCurrent()
            retained = lifetime.lifecycleOwner.commit(attemptToken, { pairLifetime === lifetime }) {
                synchronized(lifetime.admissionLock) {
                    if (attemptToken.conditional && !conditionalAdmissionEligible(lifetime, attemptToken)) return@synchronized false
                    if (activeSession != null || lifetime.admission != null || lifetime.retiringDispatch != null ||
                        lifetime.preparedResources != null || lifetime.retiringPrepared != null
                    ) return@synchronized false
                    lifetime.preparedResources = prepared
                    lifetime.preparedBinding = binding
                    lifetime.preparedAttemptToken = attemptToken
                    true
                }
            } == true
            retained
        } finally {
            if (!retained) {
                prepared.stop()
                withContext(NonCancellable) { prepared.awaitStopped() }
            }
        }
    }

    private suspend fun publishReplacement(
        lifetime: PairSessionLifetime,
        attemptToken: ReconnectAttemptToken,
        binding: ReconnectLiveBinding
    ): Boolean = replacementMutex.withLock {
        binding.validateCurrent()
        val prepared = synchronized(lifetime.admissionLock) { lifetime.preparedResources } ?: return@withLock false
        val published = prepared.publish(
            lifetime.lifecycleOwner, attemptToken, { pairLifetime === lifetime }, lifetime.admissionLock
        ) {
            synchronized(lifetime.admissionLock) {
                if (attemptToken.conditional && !conditionalAdmissionEligible(lifetime, attemptToken, allowPrepared = true)) return@synchronized false
                if (lifetime.preparedAttemptToken != attemptToken || lifetime.preparedBinding !== binding ||
                    lifetime.preparedResources !== prepared || activeSession != null || lifetime.admission != null ||
                    lifetime.retiringDispatch != null || lifetime.retiringPrepared != null
                ) return@synchronized false
                if (!installOrdinaryLocked(lifetime, prepared)) return@synchronized false
                lifetime.publishedAttemptToken = attemptToken
                lifetime.preparedResources = null
                lifetime.preparedBinding = null
                lifetime.preparedAttemptToken = null
                lifetime.liveBinding = binding
                true
            }
        }
        if (published) startOrdinaryWork(lifetime, prepared)
        published
    }

    /** Fresh pairing has already provided the proof for this live lifetime. */
    private fun activateOrdinary(lifetime: PairSessionLifetime, binding: ReconnectLiveBinding?) {
        val prepared = prepareOrdinary(lifetime, binding, attemptToken = null)
        synchronized(lifetime.admissionLock) {
            lifetime.preparedResources = prepared
            check(installOrdinaryLocked(lifetime, prepared))
            lifetime.preparedResources = null
            lifetime.ordinaryActivationPending = false
        }
        startOrdinaryWork(lifetime, prepared)
    }

    private fun prepareOrdinary(
        lifetime: PairSessionLifetime,
        binding: ReconnectLiveBinding?,
        attemptToken: ReconnectAttemptToken?
    ): PreparedOrdinaryResources {
        val session = lifetime.session
        val (host, port) = binding?.peer?.let { it.address to it.port }
            ?: parseEndpoint(session.pairedDevice.endpoint)
        return PreparedOrdinaryResources.prepare(
            outbox = DurableEventOutbox(
                directory = File(context.filesDir, "event-outbox"),
                sessionKey = session.sessionKey,
                pairedDeviceId = session.pairedDevice.id
            ),
            disabledTypes = ContinuityFeature.entries.filterNot(featureSettings::isEnabled)
                .flatMapTo(mutableSetOf()) { it.eventTypes },
            sender = SecureSocketPlinkClient(
                host = host,
                port = port,
                codec = lifetime.codec,
                stateStore = frameStateStore,
                binding = binding?.socketBinding,
                transmitGate = lifetime.transmitGate
            ),
            generation = sessionGeneration.incrementAndGet(),
            binding = binding,
            attemptToken = attemptToken,
            scope = scope,
            isAllowed = { envelope ->
                activeSession === session && pairLifetime === lifetime &&
                    envelope.sourceDeviceId == session.localDeviceId &&
                    envelope.targetDeviceId == session.pairedDevice.id &&
                    (ordinaryFeatureEnabled(envelope) ||
                        envelope.type == PlinkEventType.ScreenStop ||
                        (envelope.type == PlinkEventType.ScreenState &&
                            envelope.payload["state"]?.jsonPrimitive?.content == "rejected"))
            }
        )
    }

    /** Only installs prepared state. No fsync, replay, collector registration or platform call here. */
    private fun installOrdinaryLocked(lifetime: PairSessionLifetime, prepared: PreparedOrdinaryResources): Boolean {
        check(pairLifetime === lifetime && activeSession == null && lifetime.admission == null)
        if (!SharedOutboundBridge.installPrepared(prepared.outbound)) return false
        val session = lifetime.session
        val generation = prepared.admission.generation
        outbox = prepared.outbox
        SharedSessionState.configure(session)
        setReplySession(generation, active = true, session = session)
        fileTransferCoordinator.activateSession(session.localDeviceId, session.pairedDevice.id, generation)
        screenSession = ScreenPreviewSession(
            session.localDeviceId, session.pairedDevice.id, session.pairedDevice.name, generation
        )
        lifetime.admission = prepared.admission
        prepared.admission.admit()
        activeSession = session
        _status.value = SessionStatus.READY
        return true
    }

    private fun startOrdinaryWork(lifetime: PairSessionLifetime, prepared: PreparedOrdinaryResources) {
        val admission = prepared.admission
        // Generation-owned work is drained before a replacement. Registration may call the platform.
        admission.dispatch.submit {
            fun current() = pairLifetime === lifetime && admission.isAdmitted()
            try {
                if (current()) SharedNotificationActions.requestRefresh()
                if (current()) prepared.outbound.retryPending()
                if (current() && featureSettings.isEnabled(ContinuityFeature.Battery)) batteryCollector.start()
                if (current() && featureSettings.isEnabled(ContinuityFeature.Media)) mediaCollector.start()
            } finally {
                // A cancellation during platform registration must not leave collectors resurrected.
                if (!current()) {
                    batteryCollector.stop()
                    mediaCollector.stop()
                }
            }
        }
    }

    private fun deactivateOrdinaryLocked(lifetime: PairSessionLifetime, nextStatus: SessionStatus) {
        retirePreparedLocked(lifetime)
        lifetime.admission?.let { admission ->
            admission.revoke()
            lifetime.retiringDispatch = admission.dispatch
        }
        lifetime.admission = null
        screenSession = null
        val generation = sessionGeneration.incrementAndGet()
        activeSession = null
        screenPreviewCoordinator.sessionChanged()
        setReplySession(generation, active = false)
        fileTransferCoordinator.deactivateSession()
        batteryCollector.stop()
        mediaCollector.stop()
        SharedOutboundBridge.configure(null)
        SharedSessionState.clear()
        outbox = null
        _status.value = nextStatus
    }

    private suspend fun awaitOrdinaryQuiescence(lifetime: PairSessionLifetime) {
        val (dispatch, prepared) = synchronized(lifetime.admissionLock) {
            lifetime.retiringDispatch to lifetime.retiringPrepared
        }
        prepared?.awaitStopped()
        dispatch?.awaitStopped()
        screenPreviewCoordinator.awaitQuiescence()
        fileTransferCoordinator.awaitQuiescence()
        SharedOutboundBridge.awaitQuiescence()
        synchronized(lifetime.admissionLock) {
            if (lifetime.retiringDispatch === dispatch) lifetime.retiringDispatch = null
            if (lifetime.retiringPrepared === prepared) lifetime.retiringPrepared = null
        }
    }

    private fun retirePreparedLocked(lifetime: PairSessionLifetime) {
        lifetime.preparedResources?.let { prepared ->
            prepared.stop()
            check(lifetime.retiringPrepared == null || lifetime.retiringPrepared === prepared)
            lifetime.retiringPrepared = prepared
        }
        lifetime.preparedResources = null
        lifetime.preparedBinding = null
        lifetime.preparedAttemptToken = null
    }

    private fun revokeReconnectAttempt(
        lifetime: PairSessionLifetime,
        attemptToken: ReconnectAttemptToken
    ): Boolean = synchronized(lifetime.admissionLock) {
        var cleanupRequired = lifetime.suspendedAttemptToken == attemptToken
        if (lifetime.preparedAttemptToken == attemptToken) {
            retirePreparedLocked(lifetime)
            cleanupRequired = true
        }
        if (lifetime.suspendedAttemptToken == attemptToken) lifetime.suspendedAttemptToken = null
        val publishedHere = lifetime.admission?.attemptToken == attemptToken
        if (publishedHere && pairLifetime === lifetime) {
            deactivateOrdinaryLocked(lifetime, SessionStatus.AWAITING_RECONNECT)
            lifetime.liveBinding = null
            cleanupRequired = true
        }
        if (lifetime.publishedAttemptToken == attemptToken) lifetime.publishedAttemptToken = null
        cleanupRequired
    }

    private suspend fun invalidateChangedBinding(lifetime: PairSessionLifetime) {
        val binding = synchronized(lifetime.admissionLock) {
            if (pairLifetime !== lifetime) return
            lifetime.liveBinding
        } ?: return
        if (runCatching { binding.validateCurrent() }.isSuccess) return
        replacementMutex.withLock {
            synchronized(lifetime.admissionLock) {
                if (lifetime.liveBinding !== binding) return@withLock
                deactivateOrdinaryLocked(lifetime, SessionStatus.AWAITING_RECONNECT)
                lifetime.liveBinding = null
            }
            awaitOrdinaryQuiescence(lifetime)
        }
        lifetime.reconnect.liveBindingInvalidated()
    }

    fun sendEvent(event: ContinuityEvent): Boolean {
        val session = activeSession ?: return false
        if (!featureSettings.isEnabled(event.feature)) return false
        return SharedOutboundBridge.tryForward(
            ContinuityEnvelopeFactory.create(event, session.localDeviceId, session.pairedDevice.id)
        )
    }

    /** Snapshot only: clipboard owns no reconnect lifecycle and receives no session keys. */
    fun clipboardConnection(): ClipboardConnection? {
        val lifetime = pairLifetime ?: return null
        return synchronized(lifetime.admissionLock) {
            val session = activeSession ?: return@synchronized null
            val admission = lifetime.admission ?: return@synchronized null
            if (!admission.isAdmitted() || pairLifetime !== lifetime) return@synchronized null
            ClipboardConnection(admission.generation, session.localDeviceId, session.pairedDevice.id) {
                activeSession === session && pairLifetime === lifetime && admission.isAdmitted()
            }
        }
    }

    private fun ordinaryFeatureEnabled(envelope: PlinkEnvelope): Boolean =
        if (envelope.type == PlinkEventType.ClipboardUpdated &&
            envelope.payload["automatic"]?.jsonPrimitive?.booleanOrNull == true) {
            featureSettings.clipboardSyncEnabled.value
        } else envelope.type.feature?.let(featureSettings::isEnabled) != false

    private suspend fun executeClipboardOrWebHandoff(
        command: PlinkEnvelope,
        admission: OrdinaryAdmissionLease
    ): HandoffResult {
        val enableRevision = featureSettings.clipboardSyncRevision
        return withContext(Dispatchers.Main.immediate) {
            val automatic = command.type == PlinkEventType.ClipboardUpdated &&
                command.payload["automatic"]?.jsonPrimitive?.booleanOrNull == true
            if (automatic) {
                check(featureSettings.clipboardSyncEnabled.value) { "Automatic clipboard sync is off." }
                check(admission.runIfAdmitted {
                    (context.applicationContext as PlinkApplication).clipboardSync.applyRemote(
                        command, admission.generation, enableRevision
                    )
                }) { "Ordinary admission was revoked." }
                HandoffResult.Executed
            } else {
                val feature = if (command.type == PlinkEventType.WebOpen) ContinuityFeature.Web else ContinuityFeature.Clipboard
                check(featureSettings.isEnabled(feature)) { "$feature is disabled." }
                check(admission.runIfAdmitted { HandoffNotificationPublisher(context).publish(command) }) {
                    "Ordinary admission was revoked."
                }
                HandoffResult.AwaitingUser
            }
        }
    }

    fun sendEnvelope(envelope: app.plink.android.protocol.PlinkEnvelope): Boolean =
        activeSession != null && SharedOutboundBridge.tryForward(envelope)

    fun refreshMediaSessions() {
        if (activeSession != null && featureSettings.isEnabled(ContinuityFeature.Media)) {
            mediaCollector.start()
        }
    }

    fun retryPendingEvents() {
        SharedOutboundBridge.retryPending()
    }

    suspend fun offerSharedFile(source: OutgoingFileSource): FileOfferStartResult =
        fileTransferCoordinator.offerOutgoing(source)

    fun pendingIncomingFile(handle: String): IncomingFileOffer? = fileTransferCoordinator.pendingIncoming(handle)

    suspend fun acceptIncomingFile(handle: String, destination: IncomingFileDestination): Boolean =
        fileTransferCoordinator.acceptIncoming(handle, destination)

    suspend fun declineIncomingFile(handle: String): Boolean = fileTransferCoordinator.declineIncoming(handle)

    fun cancelFileTransfer() {
        scope.launch { fileTransferCoordinator.cancelActive() }
    }

    fun cancelReconnect() {
        pairLifetime?.reconnect?.cancel()
    }

    fun refreshReconnectAddresses() {
        val lifetime = pairLifetime ?: return
        runCatching { lifetime.discovery.refresh() }.onFailure {
            _reconnectState.value = ReconnectState.Failed(
                app.plink.android.reconnect.ReconnectFailureReason.UNAVAILABLE_NETWORK_OR_PERMISSION,
                emptyList()
            )
        }
    }

    @Synchronized
    fun markRepairRequired() {
        stop()
        _status.value = SessionStatus.REPAIR_REQUIRED
    }

    internal fun snapshot(): ActivePlinkSession? = pairLifetime?.session?.let {
        it.copy(sessionKey = it.copySessionKey())
    }

    private fun startReplyReceiver(lifetime: PairSessionLifetime) {
        val server = lifetime.server
        val localDeviceId = lifetime.session.localDeviceId
        val pairedDeviceId = lifetime.session.pairedDevice.id
        val previousJob = replyReceiverJob
        previousJob?.cancel()
        val executor = RemoteInputReplyExecutor(
            context = context.applicationContext,
            routes = SharedReplyRoutes.registry,
            actions = SharedReplyActions.registry,
            isAuthorized = { action, reply ->
                val session = activeSession
                SharedReplyDispatchAuthority.isCurrent(action.capabilityGeneration) &&
                    app.plink.android.permissions.AndroidPermissionReader.isNotificationListenerEnabled(context) &&
                    featureSettings.isEnabled(ContinuityFeature.Messages) &&
                    _status.value == SessionStatus.READY &&
                    sessionGeneration.get() == action.capabilityGeneration.sessionGeneration &&
                    session?.localDeviceId == localDeviceId &&
                    session.pairedDevice.id == pairedDeviceId &&
                    reply.route.pairedDeviceId == pairedDeviceId
            }
        )
        val receiverJob = scope.launch(start = CoroutineStart.LAZY) {
            previousJob?.join()
            try {
                while (isActive) {
                    var exchange: SecureSocketPlinkExchange? = null
                    var ordinaryLease: OrdinaryAdmissionLease? = null
                    var handedToReconnect = false
                    var receiveStage = "accept"
                    try {
                        val captured = server.acceptExchange(lifetime.admissionLock) { accepted ->
                            lifetime.admission?.also { admission ->
                                check(admission.trackAcceptedSocket(accepted)) { "Ordinary admission was revoked." }
                            }
                        }
                        val accepted = captured.exchange
                        ordinaryLease = captured.admission
                        exchange = accepted
                        receiveStage = "first_frame"
                        val received = accepted.read(5_000)
                        val firstEnvelope = (received.result as? AuthenticatedFrameResult.Message)?.envelope
                        if (firstEnvelope?.type == PlinkEventType.ReconnectHello) {
                            receiveStage = "hello_handoff"
                            ordinaryLease?.releaseAcceptedSocket(accepted)
                            handedToReconnect = lifetime.reconnect.receiveHello(accepted, firstEnvelope)
                            android.util.Log.i("PlinkReconnect", "stage=hello_handoff category=" +
                                (if (handedToReconnect) "accepted" else "not_admitted"))
                            continue
                        }
                        receiveStage = "ordinary_dispatch"
                        if (firstEnvelope?.type in ReconnectPayloadPolicy.eventTypes) continue
                        val admitted = ordinaryLease?.takeIf(OrdinaryAdmissionLease::isAdmitted) ?: continue
                        admitted.binding?.let { binding ->
                            binding.validateCurrent()
                            val tuple = accepted.tuple
                            require(tuple.localAddress == binding.interfaceSnapshot.localIPv4 &&
                                tuple.localPort == binding.listenerPort &&
                                tuple.remoteAddress == binding.peer.address) {
                                "Inbound socket left the proven reconnect interface."
                            }
                        }
                        admitted.dispatch.submit {
                            dispatchOrdinary(received.result, admitted, executor, localDeviceId, pairedDeviceId)
                        }
                    } catch (cancellation: CancellationException) {
                        throw cancellation
                    } catch (failure: Exception) {
                        if (receiveStage != "ordinary_dispatch") {
                            val category = when (failure) {
                                is java.net.SocketTimeoutException -> "timeout"
                                is java.io.EOFException -> "incomplete_frame"
                                is java.net.SocketException -> "socket"
                                is java.security.GeneralSecurityException -> "cryptographic_rejection"
                                is SecurityException -> "permission"
                                is java.io.IOException -> "io"
                                is IllegalArgumentException -> "validation_rejection"
                                is IllegalStateException -> "state_rejection"
                                else -> "other"
                            }
                            android.util.Log.w("PlinkReconnect", "stage=$receiveStage category=$category")
                        }
                        delay(500)
                    } finally {
                        exchange?.let { ordinaryLease?.releaseAcceptedSocket(it) }
                        if (!handedToReconnect) exchange?.close()
                    }
                }
            } finally {
                server.close()
            }
        }
        replyReceiverJob = receiverJob
        synchronized(this) { receiverJobs += receiverJob }
        receiverJob.invokeOnCompletion { synchronized(this) { receiverJobs -= receiverJob } }
        receiverJob.start()
    }

    private suspend fun dispatchOrdinary(
        result: AuthenticatedFrameResult,
        admission: OrdinaryAdmissionLease,
        executor: RemoteInputReplyExecutor,
        localDeviceId: String,
        pairedDeviceId: String
    ) {
        if (!admission.isAdmitted()) return
        if (screenPreviewCoordinator.dispatchAuthenticated(result, admission.generation)) return
        when (result) {
            is AuthenticatedFrameResult.RejectedScreen -> Unit
            is AuthenticatedFrameResult.Message -> {
                val envelope = result.envelope
                when (envelope.type) {
                    app.plink.android.protocol.NotificationActionsPolicy.Enable,
                    app.plink.android.protocol.NotificationActionsPolicy.Invoke ->
                        handleNotificationAction(envelope, admission, localDeviceId, pairedDeviceId)
                    in FileTransferPayloadPolicy.eventTypes ->
                        fileTransferCoordinator.handle(envelope, admission.generation)
                    else -> InboundCommandHandler(
                        localDeviceId = localDeviceId,
                        pairedDeviceId = pairedDeviceId,
                        executeReply = { command ->
                            withContext(Dispatchers.Main.immediate) {
                                check(ReplyDispatchLock.admitted(admission::runIfAdmitted) { executor.execute(command, localDeviceId) }) {
                                    "Ordinary admission was revoked."
                                }
                            }
                        },
                        executeMedia = { sessionId, command ->
                            check(featureSettings.isEnabled(ContinuityFeature.Media)) { "Media is disabled." }
                            check(admission.runIfAdmitted { mediaCollector.execute(sessionId, command) }) {
                                "Ordinary admission was revoked."
                            }
                        },
                        executeHandoff = { command ->
                            executeClipboardOrWebHandoff(command, admission)
                        },
                        isAdmitted = admission::isAdmitted,
                        send = { outcome ->
                            SharedOutboundBridge.sendAwaitable(outcome, stillValid = admission::isAdmitted)
                        }
                    ).handle(envelope)
                }
            }
        }
    }

    private suspend fun handleNotificationAction(
        command: PlinkEnvelope, admission: OrdinaryAdmissionLease, localDeviceId: String, peerDeviceId: String
    ) {
        if (command.sourceDeviceId != peerDeviceId || command.targetDeviceId != localDeviceId) return
        var outcome: PlinkEnvelope? = null
        withContext(Dispatchers.Main.immediate) {
            ReplyDispatchLock.admitted(admission::runIfAdmitted) {
                outcome = SharedNotificationActions.registry.handle(command, admission.generation) {
                    val session = activeSession
                    sessionGeneration.get() == admission.generation &&
                        session?.localDeviceId == localDeviceId && session.pairedDevice.id == peerDeviceId &&
                        (command.type == app.plink.android.protocol.NotificationActionsPolicy.Enable ||
                            (featureSettings.isEnabled(ContinuityFeature.Messages) &&
                                app.plink.android.permissions.AndroidPermissionReader.isNotificationListenerEnabled(context)))
                }
            }
        }
        val reply = outcome ?: return
        if (!admission.isAdmitted()) return
        SharedOutboundBridge.sendAwaitable(reply, stillValid = admission::isAdmitted)
        if (command.type == app.plink.android.protocol.NotificationActionsPolicy.Enable && reply.type == PlinkEventType.Ack) {
            ReplyDispatchLock.admitted(admission::runIfAdmitted) {
                if (SharedNotificationActions.registry.currentSession() == command.payload["actionsSession"]?.jsonPrimitive?.content) {
                    SharedNotificationActions.registry.state()?.let { SharedOutboundBridge.tryForward(it) }
                    SharedNotificationActions.requestRefresh(force = true)
                }
            }
        }
    }

    private fun parseEndpoint(endpoint: String): Pair<String, Int> {
        val separator = endpoint.lastIndexOf(':')
        require(separator > 0 && separator < endpoint.lastIndex) { "Paired endpoint must be host:port." }
        val host = endpoint.substring(0, separator)
        val port = endpoint.substring(separator + 1).toInt()
        require(port in 1..65535) { "Paired endpoint port is invalid." }
        return host to port
    }

    private fun revokeReplyCapabilities() {
        ReplyDispatchLock.serialized {
            SharedReplyRoutes.registry.clear()
            SharedReplyActions.registry.clear()
        }
    }

    private fun setReplySession(generation: Long, active: Boolean, session: ActivePlinkSession? = null) {
        ReplyDispatchLock.serialized {
            SharedReplyDispatchAuthority.sessionChanged(generation, active)
            if (active) {
                val current = requireNotNull(session)
                SharedNotificationActions.registry.beginSession(current.localDeviceId, current.pairedDevice.id, generation)
                SharedNotificationActions.registry.setFeatureEnabled(featureSettings.isEnabled(ContinuityFeature.Messages))
            } else SharedNotificationActions.registry.retireSession()
            SharedReplyRoutes.registry.clear()
            SharedReplyActions.registry.clear()
        }
    }

    private companion object {
        const val CURRENT_SECURITY_VERSION = 2
    }
}

private fun newFileTransferProcessRoot(cacheDirectory: File): File {
    val ownedRoot = File(cacheDirectory, "PlinkFileTransfer").also { it.mkdirs() }
    ownedRoot.listFiles()?.forEach { it.deleteRecursively() }
    return File(ownedRoot, UUID.randomUUID().toString()).also { check(it.mkdirs()) }
}

private val ContinuityEvent.feature: ContinuityFeature
    get() = when (type) {
        PlinkEventType.CallRinging, PlinkEventType.CallEnded -> ContinuityFeature.Calls
        PlinkEventType.MessageReceived, PlinkEventType.MessageReply -> ContinuityFeature.Messages
        PlinkEventType.ClipboardUpdated -> ContinuityFeature.Clipboard
        PlinkEventType.WebOpen -> ContinuityFeature.Web
        PlinkEventType.DeviceStatus -> ContinuityFeature.Battery
        PlinkEventType.MediaState, PlinkEventType.MediaCommand -> ContinuityFeature.Media
        else -> ContinuityFeature.Files
    }

private val String.feature: ContinuityFeature?
    get() = when (this) {
        PlinkEventType.CallRinging, PlinkEventType.CallEnded -> ContinuityFeature.Calls
        PlinkEventType.MessageReceived, PlinkEventType.MessageReply -> ContinuityFeature.Messages
        PlinkEventType.ClipboardUpdated -> ContinuityFeature.Clipboard
        PlinkEventType.WebOpen -> ContinuityFeature.Web
        PlinkEventType.DeviceStatus -> ContinuityFeature.Battery
        PlinkEventType.MediaState, PlinkEventType.MediaCommand -> ContinuityFeature.Media
        in FileTransferPayloadPolicy.eventTypes -> ContinuityFeature.Files
        in ScreenPreviewPayloadPolicy.eventTypes -> ContinuityFeature.ScreenMirror
        else -> null
    }

private val ContinuityFeature.eventTypes: Set<String>
    get() = when (this) {
        ContinuityFeature.Calls -> setOf(PlinkEventType.CallRinging, PlinkEventType.CallEnded)
        ContinuityFeature.Messages -> setOf(PlinkEventType.MessageReceived, PlinkEventType.MessageReply)
        ContinuityFeature.Clipboard -> setOf(PlinkEventType.ClipboardUpdated)
        ContinuityFeature.Web -> setOf(PlinkEventType.WebOpen)
        ContinuityFeature.Battery -> setOf(PlinkEventType.DeviceStatus)
        ContinuityFeature.Media -> setOf(PlinkEventType.MediaState, PlinkEventType.MediaCommand)
        ContinuityFeature.Files -> FileTransferPayloadPolicy.eventTypes
        ContinuityFeature.ScreenMirror -> ScreenPreviewPayloadPolicy.eventTypes
        else -> emptySet()
    }
