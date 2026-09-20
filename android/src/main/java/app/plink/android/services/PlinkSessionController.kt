package app.plink.android.services

import android.content.Context
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
import app.plink.android.notifications.RemoteInputReplyExecutor
import app.plink.android.pairing.PairedDevice
import app.plink.android.protocol.PlinkEventType
import app.plink.android.protocol.FileTransferPayloadPolicy
import app.plink.android.security.EncryptedFrameCodec
import app.plink.android.security.FileFrameStateStore
import app.plink.android.security.ReplayWindow
import app.plink.android.transport.SecureSocketPlinkClient
import app.plink.android.transport.SecureSocketPlinkServer
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import java.io.File
import java.util.concurrent.atomic.AtomicLong
import java.util.UUID

enum class SessionStatus { DISCONNECTED, REPAIR_REQUIRED, READY }

class PlinkSessionController(
    private val context: Context,
    private val featureSettings: FeatureSettings,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
) {
    private var replyReceiverJob: Job? = null
    private var replyServer: SecureSocketPlinkServer? = null
    private val frameStateStore = FileFrameStateStore(File(context.filesDir, "transport-state"))
    @Volatile
    private var activeSession: ActivePlinkSession? = null
    @Volatile
    private var outbox: DurableEventOutbox? = null
    private val sessionGeneration = AtomicLong()
    private val _status = MutableStateFlow(SessionStatus.DISCONNECTED)
    val status: StateFlow<SessionStatus> = _status.asStateFlow()
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

    init {
        featureSettings.addListener { feature, enabled ->
            if (!enabled) {
                if (feature == ContinuityFeature.Messages) {
                    SharedReplyRoutes.registry.clear()
                    SharedReplyActions.registry.clear()
                }
                if (feature == ContinuityFeature.Files) fileTransferCoordinator.featureDisabled()
                SharedOutboundBridge.purge(feature.eventTypes)
            }
        }
        scope.launch {
            featureSettings.enabled.collectLatest { enabled ->
                if (activeSession == null) return@collectLatest
                if (enabled[ContinuityFeature.Messages] != true) {
                    SharedReplyRoutes.registry.clear()
                    SharedReplyActions.registry.clear()
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
        if (!pairedDevice.trusted || pairedDevice.securityVersion != CURRENT_SECURITY_VERSION) {
            stop()
            _status.value = SessionStatus.REPAIR_REQUIRED
            return
        }
        stop()
        try {
            val session = ActivePlinkSession(
                localDeviceId = localDeviceId,
                pairedDevice = pairedDevice,
                sessionKey = sessionKey
            )
            val server = createReplyServer(localDeviceId, pairedDevice.id, sessionKey, localReplyPort)
            server.start()
            replyServer = server
            SharedReplyRoutes.registry.clear()
            SharedReplyActions.registry.clear()
            activeSession = session
            outbox = DurableEventOutbox(
                directory = File(context.filesDir, "event-outbox"),
                sessionKey = sessionKey,
                pairedDeviceId = pairedDevice.id
            )
            runCatching {
                outbox?.removeTypes(
                    ContinuityFeature.entries.filterNot(featureSettings::isEnabled)
                        .flatMapTo(mutableSetOf()) { it.eventTypes }
                )
            }
            SharedSessionState.configure(session)
            configureOutbound(pairedDevice, sessionKey)
            val generation = sessionGeneration.incrementAndGet()
            fileTransferCoordinator.activateSession(localDeviceId, pairedDevice.id, generation)
            startReplyReceiver(server, localDeviceId, pairedDevice.id, generation)
            _status.value = SessionStatus.READY
            if (featureSettings.isEnabled(ContinuityFeature.Battery)) batteryCollector.start()
            if (featureSettings.isEnabled(ContinuityFeature.Media)) mediaCollector.start()
        } catch (failure: Exception) {
            stop()
            throw failure
        }
    }

    @Synchronized
    fun restoreIfDisconnected(
        localDeviceId: String,
        pairedDevice: PairedDevice,
        sessionKey: ByteArray,
        localReplyPort: Int = 45731,
        canRestore: () -> Boolean = { true }
    ): Boolean {
        if (!canRestore() || _status.value != SessionStatus.DISCONNECTED || activeSession != null) return false
        configure(localDeviceId, pairedDevice, sessionKey, localReplyPort)
        return _status.value == SessionStatus.READY
    }

    @Synchronized
    fun stop() {
        sessionGeneration.incrementAndGet()
        fileTransferCoordinator.deactivateSession()
        replyServer?.close()
        replyServer = null
        replyReceiverJob?.cancel()
        replyReceiverJob = null
        batteryCollector.stop()
        mediaCollector.stop()
        SharedOutboundBridge.configure(null)
        SharedSessionState.clear()
        SharedReplyRoutes.registry.clear()
        SharedReplyActions.registry.clear()
        activeSession = null
        outbox = null
        _status.value = SessionStatus.DISCONNECTED
    }

    fun sendEvent(event: ContinuityEvent): Boolean {
        val session = activeSession ?: return false
        if (!featureSettings.isEnabled(event.feature)) return false
        return SharedOutboundBridge.tryForward(
            ContinuityEnvelopeFactory.create(event, session.localDeviceId, session.pairedDevice.id)
        )
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

    @Synchronized
    fun markRepairRequired() {
        stop()
        _status.value = SessionStatus.REPAIR_REQUIRED
    }

    internal fun snapshot(): ActivePlinkSession? = activeSession?.let {
        it.copy(sessionKey = it.copySessionKey())
    }

    private fun configureOutbound(pairedDevice: PairedDevice, sessionKey: ByteArray) {
        val (host, port) = parseEndpoint(pairedDevice.endpoint)
        SharedOutboundBridge.configure(
            SecureSocketPlinkClient(
                host = host,
                port = port,
                codec = EncryptedFrameCodec(sessionKey),
                stateStore = frameStateStore
            ),
            outbox = outbox,
            isAllowed = { envelope ->
                val session = activeSession
                session != null &&
                    envelope.targetDeviceId == session.pairedDevice.id &&
                    (envelope.type.feature?.let(featureSettings::isEnabled) != false)
            }
        )
    }

    private fun createReplyServer(
        localDeviceId: String,
        pairedDeviceId: String,
        sessionKey: ByteArray,
        localReplyPort: Int
    ): SecureSocketPlinkServer = SecureSocketPlinkServer(
        port = localReplyPort,
        codec = EncryptedFrameCodec(sessionKey),
        stateStore = frameStateStore,
        replayWindow = ReplayWindow(),
        expectedSourceDeviceId = pairedDeviceId,
        expectedTargetDeviceId = localDeviceId
    )

    private fun startReplyReceiver(
        server: SecureSocketPlinkServer,
        localDeviceId: String,
        pairedDeviceId: String,
        generation: Long
    ) {
        val previousJob = replyReceiverJob
        previousJob?.cancel()
        val executor = RemoteInputReplyExecutor(
            context = context.applicationContext,
            routes = SharedReplyRoutes.registry,
            actions = SharedReplyActions.registry
        )
        replyReceiverJob = scope.launch {
            previousJob?.join()
            val handler = InboundCommandHandler(
                localDeviceId = localDeviceId,
                pairedDeviceId = pairedDeviceId,
                executeReply = { envelope ->
                    require(featureSettings.isEnabled(ContinuityFeature.Messages)) { "Messages are disabled." }
                    executor.execute(envelope, localDeviceId)
                },
                executeMedia = { sessionId, command ->
                    require(featureSettings.isEnabled(ContinuityFeature.Media)) { "Media is disabled." }
                    mediaCollector.execute(sessionId, command)
                },
                executeHandoff = { envelope ->
                    val feature = if (envelope.type == PlinkEventType.WebOpen) {
                        ContinuityFeature.Web
                    } else {
                        ContinuityFeature.Clipboard
                    }
                    require(featureSettings.isEnabled(feature)) { "$feature is disabled." }
                    HandoffNotificationPublisher(context).publish(envelope)
                },
                send = { SharedOutboundBridge.tryForward(it) }
            )
            try {
                while (isActive) {
                    try {
                        server.receiveOnce().let { envelope ->
                            if (envelope.type in FileTransferPayloadPolicy.eventTypes) {
                                fileTransferCoordinator.handle(envelope, generation)
                            } else {
                                handler.handle(envelope)
                            }
                        }
                    } catch (cancellation: CancellationException) {
                        throw cancellation
                    } catch (_: Exception) {
                        delay(500)
                    }
                }
            } finally {
                server.close()
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
        else -> emptySet()
    }
