package app.plink.android

import android.os.Bundle
import app.plink.android.protocol.PlinkEnvelope
import app.plink.android.protocol.PlinkEventType
import app.plink.android.protocol.ReconnectEndpoint
import app.plink.android.protocol.ReconnectProtocolTestHooks
import app.plink.android.reconnect.ReconnectBindingResolver
import app.plink.android.reconnect.ReconnectCoordinator
import app.plink.android.reconnect.ReconnectEndpointStore
import app.plink.android.reconnect.ReconnectInterfaceSnapshot
import app.plink.android.reconnect.ReconnectLiveBinding
import app.plink.android.reconnect.ReconnectState
import app.plink.android.security.EncryptedFrameCodec
import app.plink.android.security.FileFrameStateStore
import app.plink.android.security.FrameStateStore
import app.plink.android.security.ReplayWindow
import app.plink.android.services.OrdinaryAdmissionLease
import app.plink.android.transport.PairTransmitGate
import app.plink.android.transport.SecureSocketPlinkClient
import app.plink.android.transport.SecureSocketPlinkServer
import app.plink.android.transport.SocketChannelBinding
import java.io.File
import java.net.InetSocketAddress
import java.nio.channels.SocketChannel
import java.security.MessageDigest
import java.time.Instant
import java.util.Base64
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

internal suspend fun checkReconnectRoundtrip(
    context: android.content.Context,
    arguments: Bundle,
    emit: (String) -> Unit
): String {
    val runId = canonicalUuid(requireNotNull(arguments.getString("reconnectRunId")))
    val phase = requireNotNull(arguments.getString("reconnectPhase")).also { require(it in setOf("A", "B", "B-restart")) }
    val macPort = requireNotNull(arguments.getString("macPort")).toInt().also { require(it in 1..65535) }
    val phonePort = requireNotNull(arguments.getString("replyPort")).toInt().also { require(it in 1..65535) }
    val expectedPorts = when (phase) {
        "A" -> 46_732 to 46_731
        "B", "B-restart" -> 46_742 to 46_741
        else -> error("Unsupported reconnect phase.")
    }
    require(macPort == expectedPorts.first && phonePort == expectedPorts.second) {
        "Reconnect phase ports do not match the frozen harness interface."
    }
    val key = Base64.getDecoder().decode(requireNotNull(arguments.getString("sessionKeyBase64")))
        .also { require(it.size == 32) }
    val root = File(context.filesDir, "plink-reconnect-tests").canonicalFile
    val runDirectory = File(root, runId).canonicalFile.also {
        check(it.parentFile == root)
        check(it.isDirectory || it.mkdirs())
    }
    val marker = File(runDirectory, ".owner")
    if (marker.exists()) check(marker.readText() == runId) else marker.writeText(runId)
    ReconnectProtocolTestHooks.endpointPortsOverride = emptySet()

    val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    val stateStore = RecordingFrameStateStore(FileFrameStateStore(File(runDirectory, "frames")))
    val endpointStore = ReconnectEndpointStore(File(runDirectory, "endpoints"))
    val codec = EncryptedFrameCodec(key)
    val gate = PairTransmitGate(codec, stateStore)
    val storedBefore = endpointStore.load(LOCAL_ID, PEER_ID, SESSION_ID, key)
    val hintBefore = storedBefore?.endpoint
    val priorProofFile = File(runDirectory, "previous-proof.sha256")
    if (phase == "A") check(!priorProofFile.exists())
    else check(priorProofFile.readText() == sha256(requireNotNull(storedBefore).proofID)) {
        "The previous proof did not survive store recreation."
    }
    val expectedHintBefore = when (phase) {
        "A" -> null
        "B" -> "127.0.0.1:46732"
        "B-restart" -> "127.0.0.1:46742"
        else -> error("Unsupported reconnect phase.")
    }
    check(hintBefore == expectedHintBefore) { "Durable endpoint hint did not match the prior phase." }
    val admissionLock = Any()
    var admission: OrdinaryAdmissionLease? = null
    var preparedAdmission: OrdinaryAdmissionLease? = null
    var retiringAdmission: OrdinaryAdmissionLease? = null
    suspend fun closeAdmissions() {
        val leases = synchronized(admissionLock) {
            listOfNotNull(admission, preparedAdmission, retiringAdmission).distinct().also {
                admission = null; preparedAdmission = null; retiringAdmission = null
                it.forEach(OrdinaryAdmissionLease::revoke)
            }
        }
        leases.forEach { it.dispatch.awaitStopped() }
    }
    val initialLease = OrdinaryAdmissionLease(0, null, null, scope, initiallyAdmitted = false)
    var closedProbeExecuted = false
    val admissionInitiallyClosed = !initialLease.isAdmitted() &&
        !initialLease.runIfAdmitted { closedProbeExecuted = true } && !closedProbeExecuted
    initialLease.revoke()
    initialLease.dispatch.awaitStopped()
    val bindingReady = CompletableDeferred<ReconnectLiveBinding>()
    val incoming = CompletableDeferred<PlinkEnvelope>()
    val ordinarySent = AtomicInteger()
    val ordinaryReceived = AtomicInteger()
    val bindingActive = AtomicBoolean(true)
    val server = SecureSocketPlinkServer(
        port = phonePort,
        codec = codec,
        stateStore = stateStore,
        expectedSourceDeviceId = PEER_ID,
        expectedTargetDeviceId = LOCAL_ID,
        replayWindow = ReplayWindow(),
        transmitGate = gate
    )
    lateinit var coordinator: ReconnectCoordinator
    val resolver = object : ReconnectBindingResolver {
        override fun resolveInbound(
            tuple: app.plink.android.transport.ObservedSocketTuple,
            macListenerPort: Int
        ): ReconnectLiveBinding {
            val peer = ReconnectEndpoint(tuple.remoteAddress, macListenerPort)
            val channelBinding = LoopbackSocketBinding(tuple.localAddress, peer, bindingActive)
            return object : ReconnectLiveBinding {
                override val interfaceSnapshot = ReconnectInterfaceSnapshot(
                    name = "test-loopback",
                    index = 1,
                    localIPv4 = tuple.localAddress,
                    prefixLength = 8,
                    up = true,
                    loopback = true,
                    pointToPoint = false,
                    broadcast = false,
                    vpn = false,
                    matchingAndroidNetwork = false
                )
                override val peer = peer
                override val listenerPort = tuple.localPort
                override val generation = System.nanoTime()
                override val socketBinding = channelBinding
                override fun validateCurrent() = check(bindingActive.get()) { "Injected binding was invalidated." }
            }
        }
    }
    val lifecycleOwner = app.plink.android.reconnect.ReconnectLifecycleOwner(android.os.SystemClock::elapsedRealtime)
    coordinator = ReconnectCoordinator(
        localDeviceId = LOCAL_ID,
        peerDeviceId = PEER_ID,
        sessionId = SESSION_ID,
        sessionKey = key,
        codec = codec,
        frameStateStore = stateStore,
        transmitGate = gate,
        endpointStore = endpointStore,
        bindingResolver = resolver,
        scope = scope,
        lifecycleOwner = lifecycleOwner,
        suspendOrdinaryAndAwait = {
            val old = synchronized(admissionLock) {
                admission.also { admission = null; it?.revoke() }
            }
            old?.dispatch?.awaitStopped()
            true
        },
        prepareReplacement = { token, binding ->
            binding.validateCurrent()
            synchronized(admissionLock) {
                check(admission == null && preparedAdmission == null)
                preparedAdmission = OrdinaryAdmissionLease(binding.generation, binding, token, scope,
                    initiallyAdmitted = false)
            }
            true
        },
        publishReplacement = { token, binding ->
            synchronized(admissionLock) {
                check(admission == null)
                val prepared = requireNotNull(preparedAdmission)
                check(prepared.attemptToken == token && prepared.binding === binding && !prepared.isAdmitted())
                prepared.admit()
                admission = prepared
                preparedAdmission = null
                bindingReady.complete(binding)
            }
            true
        },
        revokeAttempt = { _, published ->
            synchronized(admissionLock) {
                val old = if (published) admission.also { admission = null }
                    else preparedAdmission.also { preparedAdmission = null }
                old?.revoke()
                retiringAdmission = old
                old != null
            }
        },
        awaitRevokedResources = {
            val old = synchronized(admissionLock) { retiringAdmission }
            old?.dispatch?.awaitStopped()
            synchronized(admissionLock) { if (retiringAdmission === old) retiringAdmission = null }
        },
        ordinaryAdmissionOpen = { synchronized(admissionLock) { admission?.isAdmitted() == true } },
        isCurrentPair = { true }
    )

    var receiver: Job? = null
    var cleanupComplete = false
    try {
        server.start()
        emit("RECONNECT PHONE LISTENING")
        receiver = scope.launch {
            while (isActive) {
                var handed = false
                val captured = server.acceptExchange(admissionLock) { accepted ->
                    admission?.also { check(it.trackAcceptedSocket(accepted)) }
                }
                val exchange = captured.exchange
                val acceptedAdmission = captured.admission
                try {
                    val result = exchange.read(5_000).result
                    val envelope = (result as? app.plink.android.security.AuthenticatedFrameResult.Message)?.envelope
                        ?: continue
                    if (envelope.type == PlinkEventType.ReconnectHello) {
                        acceptedAdmission?.releaseAcceptedSocket(exchange)
                        handed = coordinator.receiveHello(exchange, envelope)
                    } else if (acceptedAdmission != null) {
                        acceptedAdmission.dispatch.submit {
                            acceptedAdmission.runIfAdmitted { incoming.complete(envelope) }
                        }
                    }
                } finally {
                    acceptedAdmission?.releaseAcceptedSocket(exchange)
                    if (!handed) exchange.close()
                }
            }
        }

        val terminal = withTimeout(20_000) {
            coordinator.state.first {
                it is ReconnectState.ConnectedInternetUnverified || it is ReconnectState.Failed || it is ReconnectState.Cancelled
            }
        }
        check(terminal is ReconnectState.ConnectedInternetUnverified) { "Reconnect did not complete: $terminal" }
        val binding = withTimeout(1_000) { bindingReady.await() }
        // The Mac opens admission after receiving done. Its authenticated probe
        // establishes that point before the phone replies; sending immediately
        // after writing done can legitimately arrive while Mac admission is closed.
        val received = withTimeout(10_000) { incoming.await() }
        check(received.type == PlinkEventType.DeviceStatus && received.sourceDeviceId == PEER_ID &&
            received.targetDeviceId == LOCAL_ID && !received.requiresAck &&
            received.payload == buildJsonObject { put("batteryLevel", 53) }
        ) { "Post-proof ordinary probe was invalid." }
        ordinaryReceived.incrementAndGet()
        val outgoing = PlinkEnvelope(
            id = UUID.randomUUID().toString(),
            type = PlinkEventType.DeviceStatus,
            sentAt = Instant.now().truncatedTo(java.time.temporal.ChronoUnit.SECONDS).toString(),
            sourceDeviceId = LOCAL_ID,
            targetDeviceId = PEER_ID,
            requiresAck = false,
            payload = buildJsonObject { put("batteryLevel", 53) }
        )
        SecureSocketPlinkClient(
            host = binding.peer.address,
            port = binding.peer.port,
            codec = codec,
            stateStore = stateStore,
            binding = binding.socketBinding,
            transmitGate = gate
        ).send(outgoing, 2_000)
        ordinarySent.incrementAndGet()

        val diagnostics = requireNotNull(coordinator.diagnostics())
        val storedAfter = requireNotNull(endpointStore.load(LOCAL_ID, PEER_ID, SESSION_ID, key))
        check(storedAfter.proofID == diagnostics.proofId) { "The fresh proof was not persisted." }
        val hintAfter = storedAfter.endpoint
        check(hintAfter == "127.0.0.1:$macPort") { "Committed endpoint hint did not match the proven peer." }
        check(diagnostics.c1.localAddress == "127.0.0.1" && diagnostics.c1.localPort == phonePort &&
            diagnostics.c1.remoteAddress == "127.0.0.1" && diagnostics.c1.remotePort > 0)
        check(diagnostics.c2.localAddress == "127.0.0.1" && diagnostics.c2.localPort > 0 &&
            diagnostics.c2.remoteAddress == "127.0.0.1" && diagnostics.c2.remotePort == macPort)
        coordinator.closeAndAwait()
        closeAdmissions()
        server.close()
        val receiverJob = receiver
        receiverJob.cancelAndJoin()
        receiver = null
        scope.cancel()
        cleanupComplete = coordinator.isClosed && !coordinator.hasActiveAttempt && server.isClosed &&
            server.activeExchangeCount == 0 && receiverJob.isCompleted && synchronized(admissionLock) {
                admission == null && preparedAdmission == null && retiringAdmission == null
            }
        val passed = ordinarySent.get() == 1 && ordinaryReceived.get() == 1 &&
            admissionInitiallyClosed && diagnostics.ordinaryAdmissionInitiallyClosed &&
            stateStore.highestReserved.get() > 0 && cleanupComplete
        check(passed)
        priorProofFile.writeText(sha256(diagnostics.proofId))
        val report = buildJsonObject {
            put("schemaVersion", 1)
            put("runId", runId)
            put("phase", phase)
            put("role", "phone")
            put("passed", passed)
            put("proofIdHash", sha256(diagnostics.proofId))
            if (hintBefore == null) put("hintBefore", kotlinx.serialization.json.JsonNull)
            else put("hintBefore", hintBefore)
            put("hintAfter", hintAfter)
            put("ordinarySent", ordinarySent.get())
            put("ordinaryReceived", ordinaryReceived.get())
            put("ordinaryAdmissionInitiallyClosed", admissionInitiallyClosed && diagnostics.ordinaryAdmissionInitiallyClosed)
            put("highestReservedSequence", stateStore.highestReserved.get())
            put("socketObservations", JsonArray(listOf(
                observation("C1", diagnostics.c1),
                observation("C2", diagnostics.c2)
            )))
            put("cleanupComplete", cleanupComplete)
        }
        return report.toString()
    } finally {
        withContext(NonCancellable) {
            bindingActive.set(false)
            try {
                coordinator.closeAndAwait()
                server.close()
                receiver?.cancelAndJoin()
                closeAdmissions()
            } finally {
                scope.cancel()
                key.fill(0)
                ReconnectProtocolTestHooks.endpointPortsOverride = null
            }
        }
    }
}

internal fun cleanupReconnectRun(context: android.content.Context, arguments: Bundle) {
    val runId = canonicalUuid(requireNotNull(arguments.getString("reconnectRunId")))
    val root = File(context.filesDir, "plink-reconnect-tests").canonicalFile
    val runDirectory = File(root, runId).canonicalFile
    check(runDirectory.parentFile == root && File(runDirectory, ".owner").readText() == runId)
    check(runDirectory.deleteRecursively()) { "Reconnect test state cleanup failed." }
}

private class RecordingFrameStateStore(private val delegate: FrameStateStore) : FrameStateStore {
    val highestReserved = AtomicLong()
    override fun reserveSequence(scope: String): Long = delegate.reserveSequence(scope).also { sequence ->
        highestReserved.accumulateAndGet(sequence) { current, candidate -> maxOf(current, candidate) }
    }
    override fun accept(scope: String, sequence: Long, nonce: String) = delegate.accept(scope, sequence, nonce)
}

private class LoopbackSocketBinding(
    private val localHost: String,
    private val peer: ReconnectEndpoint,
    private val active: AtomicBoolean
) : SocketChannelBinding {
    override fun bindBeforeConnect(channel: SocketChannel) {
        check(active.get())
        channel.bind(InetSocketAddress(localHost, 0))
    }

    override fun validateConnected(channel: SocketChannel) {
        check(active.get())
        val local = channel.localAddress as InetSocketAddress
        val remote = channel.remoteAddress as InetSocketAddress
        check(local.address.hostAddress == localHost && remote.address.hostAddress == peer.address && remote.port == peer.port)
    }
}

private fun observation(channel: String, tuple: app.plink.android.transport.ObservedSocketTuple): JsonObject =
    buildJsonObject {
        put("channel", channel)
        put("localHost", tuple.localAddress)
        put("localPort", tuple.localPort)
        put("remoteHost", tuple.remoteAddress)
        put("remotePort", tuple.remotePort)
    }

private fun canonicalUuid(value: String): String {
    val parsed = UUID.fromString(value)
    require(parsed.toString() == value && parsed.version() == 4 && parsed.variant() == 2)
    return value
}

private fun sha256(value: String): String = MessageDigest.getInstance("SHA-256")
    .digest(value.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }

private const val LOCAL_ID = "test-pixel"
private const val PEER_ID = "test-mac"
private const val SESSION_ID = "00000000-0000-4000-8000-000000000001"
