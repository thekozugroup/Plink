package app.plink.android.pairing

import app.plink.android.protocol.PlinkEnvelope
import app.plink.android.protocol.PlinkEventType
import app.plink.android.security.EncryptedFrameCodec
import app.plink.android.security.InMemoryFrameStateStore
import app.plink.android.services.ActivePlinkSession
import app.plink.android.storage.InMemoryPairingSecretStore
import app.plink.android.storage.InMemoryPairingStore
import app.plink.android.storage.PairingSecretStore
import app.plink.android.storage.PairingStore
import java.time.Instant
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.*
import org.junit.Test

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class PairingCoordinatorTest {
    private class Connection : PairingCoordinator.Connection {
        val incoming = Channel<ByteArray>(Channel.UNLIMITED)
        val sent = mutableListOf<PairingConsent>()
        var sendBlock: (suspend () -> Unit)? = null
        var closed = false
        override suspend fun send(endpoint: String, payload: ByteArray) {
            sent += PairingConsent.decode(payload.decodeToString())
            sendBlock?.invoke()
        }
        override suspend fun receive(): ByteArray = incoming.receive()
        override fun close() { closed = true; incoming.close() }
    }

    private class Fixture(scope: TestScope) {
        val backingStore = InMemoryPairingStore()
        val backingSecrets = InMemoryPairingSecretStore()
        var afterSecretSave: (suspend () -> Unit)? = null
        var afterDeviceSave: (suspend () -> Unit)? = null
        val store = object : PairingStore by backingStore {
            override suspend fun save(device: PairedDevice) {
                backingStore.save(device)
                afterDeviceSave?.invoke()
            }
        }
        val secrets = object : PairingSecretStore by backingSecrets {
            override suspend fun save(sessionKey: ByteArray, sessionId: String) {
                backingSecrets.save(sessionKey, sessionId)
                afterSecretSave?.invoke()
            }
        }
        val oldDevice = PairedDevice("mac", "Old Mac", "macos", "old:45732", "old-session", "peer", "local", true, securityVersion = 2)
        val oldKey = ByteArray(32) { 9 }
        var active: ActivePlinkSession? = ActivePlinkSession("pixel", oldDevice, oldKey.copyOf())
        val snapshots = mutableListOf<ActivePlinkSession>()
        val prepared = mutableListOf<PairingCoordinator.Prepared>()
        val connections = mutableListOf<Connection>()
        var nextConnection = Connection()
        var bindFails = false
        var activationFails = false
        var afterConfigure: (() -> Unit)? = null
        var failedActivationKey: ByteArray? = null
        var configuredPort = 45731
        var elapsed = 0L
        var stops = 0
        val restoredAdmissions = mutableListOf<Boolean>()
        var offer = PairingOffer("mac", "Mac", "macos", "mac:45732", "nonce", PairingCrypto.generateKeyPair().publicKeyBase64, "pixel")
        val coordinator = PairingCoordinator(PairingCoordinator.Environment(
            store, secrets, InMemoryFrameStateStore(),
            prepare = { incoming, endpoint ->
                val machine = PairingStateMachine()
                val code = machine.receiveOffer(incoming, endpoint).verificationCode
                val (candidate, confirmation) = machine.previewWithResponse("pixel", "Pixel", endpoint)
                PairingCoordinator.Prepared(incoming, confirmation, candidate, machine.lastSessionKey!!, code).also { prepared += it }
            },
            snapshot = { active?.let { it.copy(sessionKey = it.copySessionKey()).also(snapshots::add) } },
            stop = { stops++; active = null },
            configure = { session, port ->
                require(session.pairedDevice.trusted && session.pairedDevice.securityVersion == 2)
                active = session.copy(sessionKey = session.copySessionKey())
                configuredPort = port
                afterConfigure?.invoke()
                if (activationFails) {
                    activationFails = false
                    failedActivationKey = session.sessionKey
                    error("activation failed after publication")
                }
            },
            connect = {
                if (bindFails) error("bind failed")
                nextConnection.also { connections += it; nextConnection = Connection() }
            },
            now = { elapsed },
            restore = { session, port, admitted ->
                restoredAdmissions += admitted
                active = session.copy(sessionKey = session.copySessionKey())
                configuredPort = port
            }
        ), StandardTestDispatcher(scope.testScheduler))

        suspend fun seed() {
            backingStore.save(oldDevice)
            backingStore.setActiveDeviceId(oldDevice.id)
            backingSecrets.save(oldKey, oldDevice.sessionId)
        }
        fun select(port: Int = 45731) { coordinator.select(offer, "pixel:$port") }
        fun final(index: Int = prepared.lastIndex): ByteArray {
            val p = prepared[index]
            val envelope = PlinkEnvelope(id = "final", type = PlinkEventType.PairingConfirm,
                sentAt = Instant.now().toString(), sourceDeviceId = p.offer.deviceId, targetDeviceId = "pixel",
                payload = buildJsonObject {
                    put("sessionId", p.candidate.sessionId); put("offerNonce", p.offer.nonce); put("status", "confirmed")
                })
            return Json.encodeToString(EncryptedFrameCodec(p.key).seal(envelope, 1)).toByteArray()
        }
        fun approve() { connections.last().incoming.trySend(final()).getOrThrow() }
        fun assertRestored() {
            assertEquals(oldDevice, active?.pairedDevice)
            assertArrayEquals(oldKey, active?.sessionKey)
            assertTrue(prepared.all { p -> p.key.all { it == 0.toByte() } })
            assertTrue(snapshots.all { s -> s.sessionKey.all { it == 0.toByte() } })
        }
    }

    @Test fun cancellationBeforeFinalRestoresPreviousSessionAndWipesAttempt() = runTest {
        val f = Fixture(this); f.seed(); f.select(); runCurrent()
        val staleFinal = f.final()
        f.coordinator.confirm(); runCurrent()
        f.coordinator.cancelAttempt(); runCurrent()
        f.assertRestored()
        assertTrue(f.connections.single().closed)
        assertEquals(listOf(f.oldDevice), f.backingStore.all())
        assertNull(f.backingSecrets.load(f.prepared.single().candidate.sessionId))
        assertTrue(f.connections.single().incoming.trySend(staleFinal).isFailure)
        f.coordinator.close(); runCurrent()
    }

    @Test fun stoppedReadyPairRestoresListenerOnlyAfterReplacementCancellation() = runTest {
        val f = Fixture(this)
        f.seed()
        f.select()
        runCurrent()
        f.coordinator.cancelAttempt()
        runCurrent()

        f.assertRestored()
        assertEquals(listOf(false), f.restoredAdmissions)
        f.coordinator.close()
        runCurrent()
    }

    @Test fun bindFailureRestoresPriorSessionAndWipesUnpublishedKey() = runTest {
        val f = Fixture(this); f.seed(); f.bindFails = true
        f.select(); runCurrent()
        f.assertRestored()
        assertFalse(f.coordinator.state.value.paired)
        assertEquals(listOf(f.oldDevice), f.backingStore.all())
        f.coordinator.close(); runCurrent()
    }

    @Test fun successRequiresBothGatesAndCompletedConfirmedSendThenReleasesKeys() = runTest {
        val f = Fixture(this); f.seed(); f.select(49123); runCurrent()
        val p = f.prepared.single(); val expected = p.key.copyOf()
        f.approve(); runCurrent()
        assertEquals(listOf(f.oldDevice), f.backingStore.all())
        assertNull(f.active)
        val sent = CompletableDeferred<Unit>()
        f.connections.single().sendBlock = { sent.await() }
        f.coordinator.confirm(); runCurrent()
        assertNull(f.backingSecrets.load(p.candidate.sessionId))
        sent.complete(Unit); runCurrent()
        assertTrue(f.coordinator.state.value.paired)
        assertEquals(2, f.active?.pairedDevice?.securityVersion)
        assertEquals(49123, f.configuredPort)
        assertArrayEquals(expected, f.active?.sessionKey)
        assertArrayEquals(expected, f.backingSecrets.load(p.candidate.sessionId))
        assertTrue(p.key.all { it == 0.toByte() })
        assertTrue(f.snapshots.single().sessionKey.all { it == 0.toByte() })
        f.coordinator.close(); runCurrent()
        assertArrayEquals(expected, f.active?.sessionKey)
    }

    @Test fun cancellationDuringCommitWaitsAndDoesNotWipeKeyBeingSaved() = runTest {
        val f = Fixture(this); f.seed(); f.select(); runCurrent()
        val expected = f.prepared.single().key.copyOf()
        val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        f.afterSecretSave = { entered.complete(Unit); release.await() }
        f.coordinator.confirm(); runCurrent(); f.approve(); runCurrent()
        assertTrue(entered.isCompleted)
        f.coordinator.cancelAttempt(); f.coordinator.close(); runCurrent()
        assertArrayEquals(expected, f.prepared.single().key)
        release.complete(Unit); runCurrent()
        assertArrayEquals(expected, f.active?.sessionKey)
        assertArrayEquals(expected, f.backingSecrets.load(f.prepared.single().candidate.sessionId))
        assertTrue(f.prepared.single().key.all { it == 0.toByte() })
    }

    @Test fun secretDeviceAndActivationFailuresRollbackEvenAfterWrite() = runTest {
        for (failure in listOf("secret", "device", "activation")) {
            val f = Fixture(this); f.seed(); f.select(); runCurrent()
            when (failure) {
                "secret" -> f.afterSecretSave = { f.afterSecretSave = null; error("secret failed after write") }
                "device" -> f.afterDeviceSave = { f.afterDeviceSave = null; error("device failed after write") }
                "activation" -> f.activationFails = true
            }
            f.coordinator.confirm(); runCurrent(); f.approve(); runCurrent()
            f.assertRestored()
            assertEquals(failure, listOf(f.oldDevice), f.backingStore.all())
            assertNull(failure, f.backingSecrets.load(f.prepared.single().candidate.sessionId))
            assertArrayEquals(f.oldKey, f.backingSecrets.load(f.oldDevice.sessionId))
            assertEquals("mac", f.backingStore.activeDeviceId())
            assertFalse(f.coordinator.state.value.paired)
            f.failedActivationKey?.let { assertTrue(it.all { b -> b == 0.toByte() }) }
            f.coordinator.close(); runCurrent()
        }
    }

    @Test fun rollbackPreservesExistingSecretAtCandidateSessionId() = runTest {
        val f = Fixture(this); f.seed(); f.select(); runCurrent()
        val id = f.prepared.single().candidate.sessionId
        val prior = ByteArray(32) { 42 }; f.backingSecrets.save(prior, id)
        f.activationFails = true
        f.coordinator.confirm(); runCurrent(); f.approve(); runCurrent()
        assertArrayEquals(prior, f.backingSecrets.load(id))
        assertEquals(listOf(f.oldDevice), f.backingStore.all())
        f.assertRestored()
        f.coordinator.close(); runCurrent()
    }

    @Test fun lateFailureFromCancelledAttemptCannotCancelReplacement() = runTest {
        val f = Fixture(this); f.seed()
        val release = CompletableDeferred<Unit>()
        f.nextConnection.sendBlock = { withContext(NonCancellable) { release.await(); error("late failure") } }
        f.select(); runCurrent()
        f.coordinator.cancelAttempt(); f.select(); runCurrent()
        assertTrue(f.coordinator.state.value.canConfirm)
        val newer = f.prepared.last()
        release.complete(Unit); runCurrent()
        assertTrue(f.coordinator.state.value.canConfirm)
        assertFalse(newer.key.all { it == 0.toByte() })
        assertFalse(f.connections.last().closed)
        f.coordinator.close(); runCurrent(); f.assertRestored()
    }

    @Test fun expiryUsesInjectedElapsedTimeAndRestoresPriorSession() = runTest {
        val f = Fixture(this); f.seed(); f.select(); runCurrent()
        f.elapsed = 120_000
        f.coordinator.confirm(); runCurrent()
        f.assertRestored()
        assertFalse(f.coordinator.state.value.canConfirm)
        assertEquals(1, f.connections.single().sent.size)
        f.coordinator.close(); runCurrent()
    }

    @Test fun queuedSelectionAndCancellationCannotLeaveStalePreparationActive() = runTest {
        val f = Fixture(this); f.seed()
        f.select(); f.coordinator.cancelAttempt(); runCurrent()
        f.assertRestored()
        assertFalse(f.coordinator.state.value.canConfirm)
        assertTrue(f.connections.single().closed)
        f.coordinator.close(); runCurrent()
    }

    @Test fun queuedCancellationAtEachCommitStepCannotPartiallyAbortCommit() = runTest {
        for (boundary in listOf("secret", "device", "configure")) {
            val f = Fixture(this); f.seed(); f.select(); runCurrent()
            val expected = f.prepared.single().key.copyOf()
            val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
            val block: suspend () -> Unit = { entered.complete(Unit); release.await() }
            when (boundary) {
                "secret" -> f.afterSecretSave = block
                "device" -> f.afterDeviceSave = block
                "configure" -> f.afterConfigure = {
                    f.coordinator.cancelAttempt()
                    assertArrayEquals(expected, f.prepared.single().key)
                }
            }
            f.coordinator.confirm(); runCurrent(); f.approve(); runCurrent()
            if (boundary != "configure") {
                assertTrue(entered.isCompleted)
                f.coordinator.cancelAttempt(); runCurrent()
                assertArrayEquals(expected, f.prepared.single().key)
                release.complete(Unit); runCurrent()
            }
            assertArrayEquals(expected, f.active?.sessionKey)
            assertArrayEquals(expected, f.backingSecrets.load(f.prepared.single().candidate.sessionId))
            assertTrue(f.prepared.single().key.all { it == 0.toByte() })
            f.coordinator.close(); runCurrent()
        }
    }

    @Test fun timerExpiresIdleAttemptWithoutAnotherNetworkMessage() = runTest {
        val f = Fixture(this); f.seed(); f.select(); runCurrent()
        f.elapsed = 120_000
        advanceTimeBy(120_000); runCurrent()
        f.assertRestored()
        assertTrue(f.coordinator.state.value.message.contains("timed out"))
        f.coordinator.close(); runCurrent()
    }

    @Test fun rollbackFailureIsReportedAndPreventsAnotherReplacement() = runTest {
        val f = Fixture(this); f.seed(); f.select(); runCurrent()
        f.afterDeviceSave = { error("device write and rollback both fail") }
        f.coordinator.confirm(); runCurrent(); f.approve(); runCurrent()
        assertTrue(f.coordinator.state.value.message.contains("recovery was incomplete"))
        f.coordinator.cancelAttempt(); f.select(); runCurrent()
        assertEquals(1, f.prepared.size)
        assertTrue(f.coordinator.state.value.message.contains("recovery was incomplete"))
        assertTrue(f.prepared.single().key.all { it == 0.toByte() })
        f.coordinator.close(); runCurrent()
    }

    @Test fun failedFirstPairingLeavesNoTrustOrActiveSession() = runTest {
        val f = Fixture(this); f.active = null; f.select(); runCurrent()
        f.activationFails = true
        f.coordinator.confirm(); runCurrent(); f.approve(); runCurrent()
        assertNull(f.active)
        assertTrue(f.backingStore.all().isEmpty())
        assertNull(f.backingSecrets.load(f.prepared.single().candidate.sessionId))
        assertTrue(f.prepared.single().key.all { it == 0.toByte() })
        f.coordinator.close(); runCurrent()
    }

    @Test fun legacyRecordsSurviveRollbackWithoutBecomingActive() = runTest {
        val f = Fixture(this); f.active = null
        val legacy = f.oldDevice.copy(securityVersion = 0)
        f.backingStore.save(legacy); f.backingSecrets.save(f.oldKey, legacy.sessionId)
        f.select(); runCurrent()
        f.activationFails = true
        f.coordinator.confirm(); runCurrent(); f.approve(); runCurrent()
        assertNull(f.active)
        assertEquals(listOf(legacy), f.backingStore.all())
        assertArrayEquals(f.oldKey, f.backingSecrets.load(legacy.sessionId))
        assertNull(f.backingSecrets.load(f.prepared.single().candidate.sessionId))
        f.coordinator.close(); runCurrent()
    }

    @Test fun failedReplacementRestoresLastSuccessfulSessionAndReplyPort() = runTest {
        val f = Fixture(this); f.seed(); f.select(49123); runCurrent()
        f.coordinator.confirm(); runCurrent(); f.approve(); runCurrent()
        val successful = f.active!!
        val key = successful.copySessionKey()
        f.select(); runCurrent()
        f.coordinator.cancelAttempt(); runCurrent()
        assertEquals(successful.pairedDevice, f.active?.pairedDevice)
        assertArrayEquals(key, f.active?.sessionKey)
        assertEquals(49123, f.configuredPort)
        assertTrue(f.prepared.all { it.key.all { b -> b == 0.toByte() } })
        f.coordinator.close(); runCurrent()
    }

    @Test fun pairingDifferentMacSelectsNewActiveDeviceAndPreservesBothRecords() = runTest {
        val f = Fixture(this); f.seed()
        f.offer = f.offer.copy(
            deviceId = "mac-b",
            deviceName = "Mac B",
            nonce = "nonce-b",
            publicKey = PairingCrypto.generateKeyPair().publicKeyBase64
        )
        f.select(); runCurrent()
        f.coordinator.confirm(); runCurrent(); f.approve(); runCurrent()

        assertEquals("mac-b", f.backingStore.activeDeviceId())
        assertEquals(setOf("mac", "mac-b"), f.backingStore.all().map { it.id }.toSet())
        assertEquals("mac-b", f.active?.pairedDevice?.id)
        f.coordinator.close(); runCurrent()
    }

    @Test fun failedDifferentMacPairingRetainsPreviousActiveDevice() = runTest {
        val f = Fixture(this); f.seed()
        f.offer = f.offer.copy(
            deviceId = "mac-b",
            deviceName = "Mac B",
            nonce = "nonce-b",
            publicKey = PairingCrypto.generateKeyPair().publicKeyBase64
        )
        f.activationFails = true
        f.select(); runCurrent()
        f.coordinator.confirm(); runCurrent(); f.approve(); runCurrent()

        assertEquals("mac", f.backingStore.activeDeviceId())
        assertEquals(listOf(f.oldDevice), f.backingStore.all())
        f.assertRestored()
        f.coordinator.close(); runCurrent()
    }
}
