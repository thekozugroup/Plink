package app.plink.android.reconnect

import app.plink.android.protocol.*
import app.plink.android.security.*
import app.plink.android.transport.*
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.nio.channels.SocketChannel
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import java.io.File
import java.util.Base64
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class ReconnectTest {
    @get:Rule val temporaryFolder = TemporaryFolder()

    @Test
    fun conditionalClaimChecksAdmissionInsideOwnerAndAdmissionLocks() {
        val owner = ReconnectLifecycleOwner { 1_000L }
        val admissionLock = Any()
        var admitted = true
        assertNull(owner.beginConditional(10_000, admissionLock) { !admitted })
        admitted = false
        val first = requireNotNull(owner.beginConditional(10_000, admissionLock) {
            assertTrue(Thread.holdsLock(admissionLock))
            !admitted
        })
        assertTrue(first.conditional)
        assertNull(owner.beginConditional(10_000, admissionLock) { true })
        owner.invalidate(first) { _, _ -> false }
        admitted = true
        assertNull(owner.beginConditional(10_000, admissionLock) { !admitted })
        assertFalse(owner.publish(first, { true }) { error("Stale conditional claim published") })
        val legacy = requireNotNull(owner.begin(10_000))
        assertFalse(legacy.conditional)
        owner.close { _, _ -> false }
        assertNull(owner.beginConditional(10_000, admissionLock) { true })
    }

    @Test
    fun frozenNetworkCasesUseProductionCandidatePolicy() {
        val fixture = fixture("shared/protocol/v1/reconnect/network-cases.json")
        for (entry in fixture.getValue("cases").jsonArray) {
            val item = entry.jsonObject
            val network = item.getValue("interface").jsonObject
            val snapshot = ReconnectInterfaceSnapshot(
                name = network.text("name"),
                index = network.number("index"),
                localIPv4 = network.text("localIPv4"),
                prefixLength = network.number("prefixLength"),
                up = network.flag("up"),
                loopback = network.flag("loopback"),
                pointToPoint = network.flag("pointToPoint"),
                broadcast = network.flag("broadcast"),
                vpn = network.flag("vpn"),
                matchingAndroidNetwork = network.flag("matchingAndroidNetwork")
            )
            assertEquals(
                item.text("name"),
                item.getValue("expectedAndroid").jsonPrimitive.boolean,
                ReconnectCandidatePolicy.accepts(item.text("endpoint"), snapshot)
            )
        }
    }

    @Test
    fun frozenEndpointVectorsUseProductionAuthenticationAndFilename() {
        val fixture = fixture("shared/protocol/v1/reconnect/endpoint-store-vectors.json")
        for (entry in fixture.getValue("vectors").jsonArray) {
            val item = entry.jsonObject
            val source = item.getValue("record").jsonObject
            val key = Base64.getDecoder().decode(item.text("sessionKeyBase64"))
            val unsigned = ReconnectEndpointRecord(
                version = source.number("version"),
                localID = source.text("localID"),
                peerID = source.text("peerID"),
                sessionID = source.text("sessionID"),
                endpoint = source.text("endpoint"),
                proofID = source.text("proofID"),
                tag = ""
            )
            assertArrayEquals(
                item.text("name"),
                Base64.getDecoder().decode(item.text("signingInputBase64")),
                ReconnectEndpointStore.signingInput(unsigned)
            )
            assertEquals(
                item.text("name"),
                source.text("tag"),
                ReconnectEndpointStore.authenticate(unsigned, key).tag
            )
            assertEquals(
                item.text("name"),
                item.text("fileName"),
                ReconnectEndpointStore.fileName(key, unsigned.localID, unsigned.peerID)
            )
            key.fill(0)
        }
    }

    @Test
    fun cancellationBetweenStagingAndRenameLeavesNoEndpointHint() {
        val now = 1_000L
        val owner = ReconnectLifecycleOwner { now }
        val token = requireNotNull(owner.begin(10_000))
        val directory = temporaryFolder.newFolder("cancel-before-rename")
        val store = ReconnectEndpointStore(directory) {
            owner.invalidate(token) { _, _ -> false }
        }
        val key = ByteArray(32) { it.toByte() }
        val proof = Base64.getUrlEncoder().withoutPadding().encodeToString(ByteArray(32) { 7 })

        assertThrows(IllegalStateException::class.java) {
            store.commit(
                localID = "pixel",
                peerID = "mac",
                sessionID = "session",
                endpoint = "192.168.50.10:45731",
                proofID = proof,
                sessionKey = key,
                attemptToken = token,
                lifecycleOwner = owner,
                pairIsCurrent = { true }
            )
        }
        assertNull(store.load("pixel", "mac", "session", key))
        assertTrue(directory.listFiles().orEmpty().none { it.extension == "tmp" })
    }

    @Test
    fun cancelAfterDonePreventsPublicationAndOldTokenCannotReviveSameBinding() {
        val now = 2_000L
        val owner = ReconnectLifecycleOwner { now }
        val old = requireNotNull(owner.begin(10_000))
        var publications = 0

        owner.invalidate(old) { _, _ -> false }
        assertFalse(owner.publish(old, { true }) { publications += 1; true })

        val replacement = requireNotNull(owner.begin(10_000))
        val sameBinding = Any()
        var publishedBinding: Any? = null
        assertFalse(owner.publish(old, { true }) { publishedBinding = sameBinding; true })
        assertTrue(owner.publish(replacement, { true }) {
            publications += 1
            publishedBinding = sameBinding
            true
        })
        assertEquals(1, publications)
        assertTrue(publishedBinding === sameBinding)
    }

    @Test
    fun expiredAttemptCannotRenameOrPublish() {
        var now = 3_000L
        val owner = ReconnectLifecycleOwner { now }
        val token = requireNotNull(owner.begin(50))
        now += 50
        var operationRan = false

        assertNull(owner.commit(token, { true }) { operationRan = true })
        assertFalse(owner.publish(token, { true }) { operationRan = true; true })
        assertFalse(operationRan)
    }

    @Test
    fun conditionalResponderCompletesAllEightPhasesOnAuthenticatedExchanges() = runBlocking {
        val harness = ConditionalHarness()
        try {
            val c1 = harness.hello()
            c1.use {
                assertTrue(harness.handedOff)
                val challenge = harness.read(c1, PlinkEventType.ReconnectChallenge)
                assertEquals(2, challenge.version)
                assertEquals(1, harness.claims.get())
                assertEquals(0, harness.suspensions.get())
                c1.write(harness.control(PlinkEventType.ReconnectProof, challenge), 2_000)
                harness.macServer.acceptExchange().use { c2 ->
                    val reverse = harness.read(c2, PlinkEventType.ReconnectReverse)
                    assertEquals(challenge.messageId, reverse.messageId)
                    assertEquals(challenge.proof, reverse.proof)
                    c2.write(harness.control(PlinkEventType.ReconnectReverseProof, reverse), 2_000)
                    assertEquals(reverse, harness.read(c2, PlinkEventType.ReconnectReady))
                    c2.write(harness.control(PlinkEventType.ReconnectCommit, reverse), 2_000)
                    assertEquals(reverse, harness.read(c2, PlinkEventType.ReconnectDone))
                }
                withTimeout(5_000) {
                    harness.coordinator.state.first { it is ReconnectState.ConnectedInternetUnverified }
                }
                assertEquals(1, harness.suspensions.get())
                assertEquals(1, harness.publications.get())
                assertEquals(4, harness.phoneWrites.get())
                assertTrue(harness.admitted)
            }
        } finally { harness.close() }
    }

    @Test
    fun conditionalHealthyAndBusyHelloAreNormalNoOpsWithoutResponseReservation() = runBlocking {
        for (busy in listOf(false, true)) {
            val harness = ConditionalHarness()
            try {
                if (busy) requireNotNull(harness.owner.begin(10_000)) else harness.admitted = true
                val before = harness.coordinator.state.value
                harness.hello().close()
                assertFalse(harness.handedOff)
                assertEquals(before, harness.coordinator.state.value)
                assertEquals(0, harness.claims.get())
                assertEquals(0, harness.phoneWrites.get())
                assertEquals(0, harness.suspensions.get())
                assertEquals(0, harness.publications.get())
                assertEquals(!busy, harness.admitted)
            } finally { harness.close() }
        }
    }

    @Test
    fun conditionalOldProofCannotSuspendAdmissionInstalledAfterChallenge() = runBlocking {
        val harness = ConditionalHarness()
        try {
            harness.hello().use { c1 ->
                val challenge = harness.read(c1, PlinkEventType.ReconnectChallenge)
                // Challenge is the held boundary: peer has not sent Proof yet.
                harness.admitted = true
                c1.write(harness.control(PlinkEventType.ReconnectProof, challenge), 2_000)
                withTimeout(5_000) { harness.coordinator.state.first { it is ReconnectState.Failed } }
                assertEquals(0, harness.suspensions.get())
                assertEquals(0, harness.publications.get())
                assertTrue(harness.admitted)
            }
        } finally { harness.close() }
    }

    @Test
    fun conditionalTranscriptRejectsLegacyProofWithoutSuspending() = runBlocking {
        val harness = ConditionalHarness()
        try {
            harness.hello().use { c1 ->
                val challenge = harness.read(c1, PlinkEventType.ReconnectChallenge)
                c1.write(harness.control(PlinkEventType.ReconnectProof, challenge.copy(version = 1)), 2_000)
                withTimeout(5_000) { harness.coordinator.state.first { it is ReconnectState.Failed } }
                assertEquals(0, harness.suspensions.get())
                assertEquals(0, harness.publications.get())
            }
        } finally { harness.close() }
    }

    @Test
    fun conditionalCancellationAtHeldPreparationAndPublicationCannotPublish() = runBlocking {
        for (boundary in listOf("prepare", "publish")) {
            val harness = ConditionalHarness()
            val entered = CompletableDeferred<Unit>()
            val release = CompletableDeferred<Unit>()
            val hold: suspend () -> Unit = {
                withContext(NonCancellable) { entered.complete(Unit); release.await() }
            }
            if (boundary == "prepare") harness.beforePrepare = hold else harness.beforePublish = hold
            try {
                harness.hello().use { c1 ->
                    val challenge = harness.read(c1, PlinkEventType.ReconnectChallenge)
                    c1.write(harness.control(PlinkEventType.ReconnectProof, challenge), 2_000)
                    harness.macServer.acceptExchange().use { c2 ->
                        val reverse = harness.read(c2, PlinkEventType.ReconnectReverse)
                        c2.write(harness.control(PlinkEventType.ReconnectReverseProof, reverse), 2_000)
                        if (boundary == "publish") {
                            harness.read(c2, PlinkEventType.ReconnectReady)
                            c2.write(harness.control(PlinkEventType.ReconnectCommit, reverse), 2_000)
                            harness.read(c2, PlinkEventType.ReconnectDone)
                        }
                        withTimeout(5_000) { entered.await() }
                        val cancelling = async(start = CoroutineStart.UNDISPATCHED) { harness.coordinator.cancelAndAwait() }
                        assertFalse(cancelling.isCompleted) // The real attempt is held in cleanup/commit work.
                        harness.admitted = true // A newer generation must survive the released old continuation.
                        release.complete(Unit)
                        withTimeout(5_000) { cancelling.await() }
                        assertEquals(0, harness.publications.get())
                        assertTrue(harness.admitted)
                    }
                }
            } finally { release.complete(Unit); harness.close() }
        }
    }

    private inner class ConditionalHarness {
        private val key = ByteArray(32) { it.toByte() }
        private val codec = EncryptedFrameCodec(key)
        private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val owner = ReconnectLifecycleOwner { System.nanoTime() / 1_000_000 }
        private val admissionLock = Any()
        @Volatile var admitted = false
        var handedOff = false
        val claims = AtomicInteger()
        val suspensions = AtomicInteger()
        val publications = AtomicInteger()
        val phoneWrites = AtomicInteger()
        var beforePrepare: suspend () -> Unit = {}
        var beforePublish: suspend () -> Unit = {}
        private val phoneStore = object : FrameStateStore {
            private val delegate = InMemoryFrameStateStore()
            override fun reserveSequence(scope: String): Long {
                phoneWrites.incrementAndGet()
                return delegate.reserveSequence(scope)
            }
            override fun accept(scope: String, sequence: Long, nonce: String) = delegate.accept(scope, sequence, nonce)
        }
        private val macStore = InMemoryFrameStateStore()
        private val phoneGate = PairTransmitGate(codec, phoneStore)
        private val macGate = PairTransmitGate(codec, macStore)
        private val phonePort = ServerSocket(0).use { it.localPort }
        private val macPort = ServerSocket(0).use { it.localPort }
        private val phoneServer = SecureSocketPlinkServer(phonePort, codec, phoneStore,
            expectedSourceDeviceId = "mac", expectedTargetDeviceId = "phone", transmitGate = phoneGate)
        val macServer = SecureSocketPlinkServer(macPort, codec, macStore,
            expectedSourceDeviceId = "phone", expectedTargetDeviceId = "mac", transmitGate = macGate)
        private val socketBinding = object : SocketChannelBinding {
            override fun bindBeforeConnect(channel: SocketChannel) { channel.bind(InetSocketAddress("127.0.0.1", 0)) }
            override fun validateConnected(channel: SocketChannel) = Unit
        }
        private val binding = object : ReconnectLiveBinding {
            override val interfaceSnapshot = ReconnectInterfaceSnapshot("test", 1, "127.0.0.1", 24,
                true, false, false, true, false, true)
            override val peer = ReconnectEndpoint("127.0.0.1", macPort)
            override val listenerPort = phonePort
            override val generation = 1L
            override val socketBinding get() = this@ConditionalHarness.socketBinding
            override fun validateCurrent() = Unit
        }
        val coordinator = ReconnectCoordinator(
            localDeviceId = "phone", peerDeviceId = "mac", sessionId = "test-session", sessionKey = key,
            codec = codec, frameStateStore = phoneStore, transmitGate = phoneGate,
            endpointStore = ReconnectEndpointStore(temporaryFolder.newFolder()),
            bindingResolver = object : ReconnectBindingResolver {
                override fun resolveInbound(tuple: ObservedSocketTuple, macListenerPort: Int) = binding
            }, scope = scope, lifecycleOwner = owner,
            suspendOrdinaryAndAwait = { token -> owner.commit(token, { true }) {
                synchronized(admissionLock) {
                    if (admitted) false else { suspensions.incrementAndGet(); true }
                }
            } == true },
            prepareReplacement = { token, _ -> beforePrepare(); owner.isCurrent(token) { !admitted } },
            publishReplacement = { token, _ ->
                beforePublish()
                owner.publish(token, { !admitted }) { admitted = true; publications.incrementAndGet(); true }
            },
            revokeAttempt = { _, _ -> false }, awaitRevokedResources = {},
            ordinaryAdmissionOpen = { admitted }, isCurrentPair = { true },
            monotonicMillis = { System.nanoTime() / 1_000_000 },
            claimConditional = { timeout, _ -> owner.beginConditional(timeout, admissionLock) { !admitted }
                ?.also { claims.incrementAndGet() } }
        )
        init {
            ReconnectProtocolTestHooks.endpointPortsOverride = setOf(phonePort, macPort)
            phoneServer.start()
            macServer.start()
        }
        fun control(type: String, payload: ReconnectPayload) =
            ReconnectPayloadPolicy.envelope(type, "mac", "phone", payload)
        suspend fun hello(): SecureSocketPlinkExchange {
            val c1 = openSecureSocketPlinkExchange("127.0.0.1", phonePort, codec, macStore, macGate,
                "phone", "mac", 2_000, socketBinding)
            val payload = ReconnectPayload(Base64.getUrlEncoder().withoutPadding()
                .encodeToString(ByteArray(32) { 7 }), binding.peer,
                ReconnectEndpoint("127.0.0.1", phonePort), version = 2)
            c1.write(control(PlinkEventType.ReconnectHello, payload), 2_000)
            val accepted = phoneServer.acceptExchange()
            val envelope = (accepted.read(2_000).result as AuthenticatedFrameResult.Message).envelope
            handedOff = coordinator.receiveHello(accepted, envelope)
            if (!handedOff) accepted.close()
            return c1
        }
        suspend fun read(exchange: SecureSocketPlinkExchange, expected: String): ReconnectPayload {
            val message = (exchange.read(2_000).result as AuthenticatedFrameResult.Message).envelope
            assertEquals(expected, message.type)
            return ReconnectPayloadPolicy.payload(message)
        }
        suspend fun close() {
            coordinator.closeAndAwait()
            phoneServer.close()
            macServer.close()
            scope.cancel()
            ReconnectProtocolTestHooks.endpointPortsOverride = null
        }
    }

    private fun fixture(path: String) = Json.parseToJsonElement(
        generateSequence(File(requireNotNull(System.getProperty("user.dir")))) { it.parentFile }
            .map { File(it, path) }
            .first(File::isFile)
            .readText()
    ).jsonObject

    private fun kotlinx.serialization.json.JsonObject.text(key: String) = getValue(key).jsonPrimitive.content
    private fun kotlinx.serialization.json.JsonObject.number(key: String) = getValue(key).jsonPrimitive.int
    private fun kotlinx.serialization.json.JsonObject.flag(key: String) = getValue(key).jsonPrimitive.boolean
}
