package app.plink.android.companion

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import app.plink.android.services.OrdinaryAdmissionLease
import org.junit.Assert.*
import org.junit.Test

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class CompanionSetupCoordinatorTest {
    private val old = CompanionPeer(CompanionIdentity("mac", "key-1", "10:20:30:40:50:60"), "My Mac")
    private val replacement = CompanionPeer(CompanionIdentity("mac", "key-2", "10:20:30:40:50:60"), "My Mac")

    private class FakeEnvironment : CompanionEnvironment<String> {
        override var supported = true
        var peers = CompanionPairings(null, emptySet())
        var saved = CompanionRegistrations()
        val owned = linkedMapOf<Int, CompanionAssociation>()
        val removed = mutableListOf<Int>()
        val callbacks = mutableListOf<CompanionEnvironment.Callback<String>>()
        var cleanupFails = false
        var writesFail = false
        var failWriteNumber: Int? = null
        var writes = 0
        var notificationFails = false
        var associationQueryFails = false
        var notificationRequests = 0
        var beforeMain: (suspend () -> Unit)? = null
        override suspend fun pairings() = peers
        override fun readRegistrations() = saved
        override fun writeRegistrations(value: CompanionRegistrations) {
            writes++
            check(!writesFail && writes != failWriteNumber)
            saved = value
        }
        override fun associations(): List<CompanionAssociation> {
            check(!associationQueryFails)
            return owned.values.toList()
        }
        override fun disassociate(id: Int) {
            check(!cleanupFails)
            removed += id
            owned.remove(id)
        }
        val requestedAddresses = mutableListOf<String>()
        override fun associate(bluetoothAddress: String, callback: CompanionEnvironment.Callback<String>) {
            requestedAddresses += bluetoothAddress
            callbacks += callback
        }
        override fun requestNotificationAccess() {
            notificationRequests++
            check(!notificationFails)
        }
        override suspend fun onMain(action: () -> Unit) {
            beforeMain?.invoke()
            action()
        }
        fun select(peer: CompanionPeer?) {
            peers = CompanionPairings(peer, setOfNotNull(peer?.identity))
            saved = saved.copy(metadata = peer?.identity)
        }
        fun create(id: Int, index: Int = callbacks.lastIndex) {
            owned[id] = CompanionAssociation(id, requestedAddresses[index])
            callbacks[index].created(id)
        }
        fun register(peer: CompanionPeer, id: Int = 1) {
            select(peer)
            saved = CompanionRegistrations(CompanionRegistration(id, peer.identity), metadata = peer.identity)
            owned[id] = CompanionAssociation(id, peer.identity.bluetoothAddress)
        }
    }

    @Test fun defaultsAreSafe() {
        assertEquals(CompanionSetupState(false, false, false, false, null), CompanionSetupState())
    }

    @Test fun setupRequiresSupportedTrustedSelectionAndSuppressesDuplicates() = runTest {
        val env = FakeEnvironment().apply { select(old) }
        val controller = CompanionSetupCoordinator(env, this)
        val owner = Any()
        var launched = 0
        controller.setUp(owner) { launched++ }
        controller.setUp(owner) { launched++ }
        runCurrent()
        assertEquals(1, env.callbacks.size)
        assertEquals(listOf(old.identity.bluetoothAddress), env.requestedAddresses)
        assertTrue(controller.state.value.busy)
        env.callbacks.single().pending("consent")
        runCurrent()
        assertEquals(1, launched)
        env.create(1)
        runCurrent()
        assertTrue(controller.state.value.registered)
        assertFalse(controller.state.value.busy)
        assertEquals(old.identity, env.saved.registration?.identity)
        controller.setUp(owner) { launched++ }
        runCurrent()
        assertEquals(1, env.callbacks.size)
    }

    @Test fun sameNameKeyReplacementRejectsLateConsentResult() = runTest {
        val env = FakeEnvironment().apply { select(old) }
        val controller = CompanionSetupCoordinator(env, this)
        controller.setUp(Any()) { fail("Stale consent must not launch") }
        runCurrent()
        env.select(replacement)
        env.callbacks.single().pending("consent")
        env.create(8)
        runCurrent()
        assertEquals(listOf(8), env.removed)
        assertNull(env.saved.registration)
        assertFalse(controller.state.value.registered)
    }

    @Test fun selectionChangeWithSameNameDoesNotReuseRegistration() = runTest {
        val env = FakeEnvironment().apply { register(old) }
        val controller = CompanionSetupCoordinator(env, this)
        val other = CompanionPeer(CompanionIdentity("other-mac", old.identity.peerPublicKey), old.name)
        env.peers = CompanionPairings(other, setOf(old.identity, other.identity))
        controller.refresh()
        runCurrent()
        assertFalse(controller.state.value.registered)
        assertTrue(env.removed.isEmpty())
    }

    @Test fun cancelDisposesResultAndOldOwnerCannotCancelNewAttempt() = runTest {
        val env = FakeEnvironment().apply { select(old) }
        val controller = CompanionSetupCoordinator(env, this)
        val oldOwner = Any()
        val newOwner = Any()
        var launched = 0
        controller.setUp(oldOwner) { fail("Old owner") }
        runCurrent()
        controller.cancelSetup(oldOwner)
        controller.setUp(newOwner) { launched++ }
        controller.cancelSetup(oldOwner)
        runCurrent()
        env.create(3, 0)
        env.callbacks[1].pending("new")
        runCurrent()
        assertEquals(listOf(3), env.removed)
        assertEquals(1, launched)
        assertTrue(controller.state.value.busy)
        env.create(4, 1)
        runCurrent()
        assertEquals(4, env.saved.registration?.associationId)
    }

    @Test fun cancellationBeforeQueuedMainLaunchPreventsOldActivityUse() = runTest {
        val env = FakeEnvironment().apply { select(old) }
        val controller = CompanionSetupCoordinator(env, this)
        val owner = Any()
        controller.setUp(owner) { fail("Destroyed activity") }
        runCurrent()
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        env.beforeMain = { entered.complete(Unit); release.await() }
        env.callbacks.single().pending("consent")
        runCurrent()
        assertTrue(entered.isCompleted)
        controller.cancelSetup(owner)
        release.complete(Unit)
        runCurrent()
        env.beforeMain = null
        env.create(9)
        runCurrent()
        assertEquals(listOf(9), env.removed)
    }

    @Test fun externalRemovalAndKeyReplacementInvalidateMapping() = runTest {
        val env = FakeEnvironment().apply { register(old) }
        val controller = CompanionSetupCoordinator(env, this)
        env.owned.clear()
        controller.refresh()
        runCurrent()
        assertNull(env.saved.registration)
        assertFalse(controller.state.value.registered)
        env.register(old, 2)
        env.select(replacement)
        controller.refresh()
        runCurrent()
        assertEquals(listOf(2), env.removed)
        assertNull(env.saved.registration)
    }

    @Test fun cleanupFailurePersistsRetryAndRemovalNeverChangesPairing() = runTest {
        val env = FakeEnvironment().apply { register(old); cleanupFails = true }
        val controller = CompanionSetupCoordinator(env, this)
        controller.removeRegistration()
        runCurrent()
        assertEquals(old, env.peers.selected)
        assertNull(env.saved.registration)
        assertEquals(setOf(1), env.saved.cleanupIds)
        assertNotNull(controller.state.value.message)
        assertFalse(controller.state.value.registered)
        env.cleanupFails = false
        controller.refresh()
        runCurrent()
        assertEquals(listOf(1), env.removed)
        assertTrue(env.saved.cleanupIds.isEmpty())
        assertNull(controller.state.value.message)
    }

    @Test fun unknownAssociationsAreNeverSweptIncludingMatchingAddress() = runTest {
        val env = FakeEnvironment().apply {
            select(old)
            owned[1] = CompanionAssociation(1, old.identity.bluetoothAddress)
            owned[2] = CompanionAssociation(2, null)
        }
        val controller = CompanionSetupCoordinator(env, this)
        controller.refresh()
        runCurrent()
        assertTrue(env.removed.isEmpty())
        controller.setUp(Any()) {}
        runCurrent()
        env.owned[3] = CompanionAssociation(3, old.identity.bluetoothAddress)
        controller.refresh()
        runCurrent()
        assertTrue(3 in env.owned)
        env.callbacks.single().created(3)
        runCurrent()
        assertEquals(3, env.saved.registration?.associationId)
        assertTrue(2 in env.owned)
        assertTrue(1 in env.owned)
    }

    @Test fun journaledAssociationSurvivesFailedMappingWriteAndIsCleanedAfterRestart() = runTest {
        val env = FakeEnvironment().apply { select(old) }
        val controller = CompanionSetupCoordinator(env, this)
        controller.setUp(Any()) {}
        runCurrent()
        env.failWriteNumber = env.writes + 2
        env.create(7)
        runCurrent()
        assertEquals(setOf(7), env.saved.cleanupIds)
        assertNull(env.saved.registration)
        env.failWriteNumber = null
        CompanionSetupCoordinator(env, this).refresh()
        runCurrent()
        assertEquals(listOf(7), env.removed)
        assertTrue(env.saved.cleanupIds.isEmpty())
    }

    @Test fun missingAddressBlocksSetupButLeavesPairingAndSettingsAvailable() = runTest {
        val env = FakeEnvironment().apply { select(old); saved = saved.copy(metadata = null) }
        val controller = CompanionSetupCoordinator(env, this)
        controller.setUp(Any()) { fail("Address unavailable") }
        runCurrent()
        assertTrue(controller.state.value.paired)
        assertFalse(controller.state.value.busy)
        assertEquals("Connect to your Mac to finish setup", controller.state.value.message)
        assertTrue(env.callbacks.isEmpty())
    }

    @Test fun metadataRequiresCurrentSelectedIdentityAndRejectsStaleAdmission() = runTest {
        val env = FakeEnvironment().apply { select(old); saved = saved.copy(metadata = null) }
        val controller = CompanionSetupCoordinator(env, this)
        controller.receiveMetadata("other", "key-1", old.identity.bluetoothAddress) { it(); true }
        controller.receiveMetadata("mac", "wrong-key", old.identity.bluetoothAddress) { it(); true }
        controller.receiveMetadata("mac", "key-1", old.identity.bluetoothAddress) { false }
        assertNull(env.saved.metadata)
        controller.receiveMetadata("mac", "key-1", old.identity.bluetoothAddress) { it(); true }
        assertEquals(old.identity, env.saved.metadata)
    }

    @Test fun changedAddressInvalidatesRegistrationAndPendingConsent() = runTest {
        val env = FakeEnvironment().apply { register(old) }
        val controller = CompanionSetupCoordinator(env, this)
        val address = "20:30:40:50:60:70"
        controller.receiveMetadata("mac", "key-1", address) { it(); true }
        assertEquals(listOf(1), env.removed)
        assertNull(env.saved.registration)
        controller.setUp(Any()) { fail("Old address consent") }
        runCurrent()
        controller.receiveMetadata("mac", "key-1", "30:40:50:60:70:80") { it(); true }
        env.callbacks.single().pending("consent")
        env.create(2)
        runCurrent()
        assertEquals(listOf(1, 2), env.removed)
        assertFalse(controller.state.value.registered)
    }

    @Test fun callbackForWrongAddressIsRejectedAndKnownIdCleaned() = runTest {
        val env = FakeEnvironment().apply { select(old) }
        val controller = CompanionSetupCoordinator(env, this)
        controller.setUp(Any()) {}
        runCurrent()
        env.owned[3] = CompanionAssociation(3, "20:30:40:50:60:70")
        env.callbacks.single().created(3)
        runCurrent()
        assertEquals(listOf(3), env.removed)
        assertNull(env.saved.registration)
    }

    @Test fun metadataAdmissionIsRecheckedAfterWaitingForPairingTransaction() = runTest {
        val env = FakeEnvironment().apply { select(old); saved = saved.copy(metadata = null) }
        val controller = CompanionSetupCoordinator(env, this)
        val release = CompletableDeferred<Unit>()
        val transaction = launch { controller.withPairingTransaction { release.await() } }
        runCurrent()
        var admitted = true
        val receive = launch {
            controller.receiveMetadata("mac", "key-1", old.identity.bluetoothAddress) {
                if (admitted) { it(); true } else false
            }
        }
        runCurrent()
        assertNull(env.saved.metadata)
        admitted = false
        release.complete(Unit)
        transaction.join()
        receive.join()
        assertNull(env.saved.metadata)
    }

    @Test fun revocationImmediatelyBeforeGuardedCommitDoesNotWriteOrRemoveRegistration() = runTest {
        val env = FakeEnvironment().apply { register(old) }
        val controller = CompanionSetupCoordinator(env, this)
        val admission = OrdinaryAdmissionLease(1, null, null, this)
        val before = env.saved
        val writes = env.writes
        controller.receiveMetadata("mac", "key-1", "20:30:40:50:60:70") { persist ->
            admission.revoke()
            admission.runIfAdmitted(persist)
        }
        runCurrent()
        assertEquals(writes, env.writes)
        assertEquals(before, env.saved)
        assertTrue(env.removed.isEmpty())
        assertTrue(1 in env.owned)
        admission.dispatch.awaitStopped()
    }

    @Test fun unavailableAddressPreservesKnownMetadataAndRegistrationForSameKey() = runTest {
        val env = FakeEnvironment().apply { register(old) }
        val controller = CompanionSetupCoordinator(env, this)
        controller.refresh()
        runCurrent()
        val before = env.saved
        val writes = env.writes
        controller.receiveMetadata("mac", "key-1", "") { it(); true }
        assertEquals(before, env.saved)
        assertEquals(writes, env.writes)
        assertTrue(controller.state.value.registered)
        assertTrue(env.removed.isEmpty())
    }

    @Test fun replacementKeyCannotInheritKnownAddressFromUnavailableMetadata() = runTest {
        val env = FakeEnvironment().apply {
            register(old)
            peers = CompanionPairings(replacement, setOf(replacement.identity))
        }
        val controller = CompanionSetupCoordinator(env, this)
        controller.receiveMetadata("mac", "key-2", "") { it(); true }
        assertEquals(CompanionIdentity("mac", "key-2", ""), env.saved.metadata)
        assertNull(env.saved.registration)
        assertEquals(listOf(1), env.removed)
        controller.setUp(Any()) { fail("Replacement key has no authenticated address") }
        runCurrent()
        assertTrue(env.callbacks.isEmpty())
        assertTrue(controller.state.value.paired)
        assertEquals("Connect to your Mac to finish setup", controller.state.value.message)
    }

    @Test fun revokedOrdinaryDispatchCanBeJoinedWhileCompanionMutexIsHeld() = runTest {
        val env = FakeEnvironment().apply { register(old) }
        val controller = CompanionSetupCoordinator(env, this)
        val admission = OrdinaryAdmissionLease(1, null, null, this)
        val release = CompletableDeferred<Unit>()
        val entered = CompletableDeferred<Unit>()
        val transaction = launch { controller.withPairingTransaction { release.await() } }
        runCurrent()
        val before = env.saved
        assertTrue(admission.dispatch.submit {
            entered.complete(Unit)
            controller.receiveMetadata("mac", "key-1", "20:30:40:50:60:70") {
                admission.runIfAdmitted(it)
            }
        })
        entered.await()
        runCurrent()
        try {
            admission.revoke()
            withTimeout(1_000) { admission.dispatch.awaitStopped() }
            assertFalse(release.isCompleted)
            assertTrue(transaction.isActive)
            assertEquals(before, env.saved)
            assertTrue(env.removed.isEmpty())
        } finally {
            release.complete(Unit)
            transaction.join()
        }
    }

    @Test fun failedMappingWriteRecoversOrphanOnNextRefresh() = runTest {
        val env = FakeEnvironment().apply { select(old) }
        val controller = CompanionSetupCoordinator(env, this)
        controller.setUp(Any()) {}
        runCurrent()
        env.writesFail = true
        env.create(7)
        runCurrent()
        assertFalse(controller.state.value.registered)
        assertNotNull(controller.state.value.message)
        env.writesFail = false
        controller.refresh()
        runCurrent()
        assertEquals(listOf(7), env.removed)
        assertNull(env.saved.registration)
    }

    @Test fun staleCallbackFailureDoesNotCancelNewAttempt() = runTest {
        val env = FakeEnvironment().apply { select(old) }
        val controller = CompanionSetupCoordinator(env, this)
        val owner = Any()
        controller.setUp(owner) {}
        runCurrent()
        controller.cancelSetup(owner)
        controller.setUp(Any()) {}
        runCurrent()
        env.writesFail = true
        env.create(7, 0)
        runCurrent()
        assertTrue(controller.state.value.busy)
        env.writesFail = false
        env.create(8, 1)
        runCurrent()
        assertTrue(controller.state.value.registered)
        assertEquals(8, env.saved.registration?.associationId)
        assertEquals(listOf(7), env.removed)
    }

    @Test fun notificationAccessFallsBackForUnsupportedUnpairedUnregisteredAndDenied() = runTest {
        for (mode in 0..3) {
            val env = FakeEnvironment().apply {
                if (mode == 0) supported = false
                if (mode >= 2) select(old)
                if (mode == 3) { register(old); notificationFails = true }
            }
            val controller = CompanionSetupCoordinator(env, this)
            var settings = 0
            controller.requestNotificationAccess(Any()) { settings++ }
            runCurrent()
            assertEquals("mode=$mode", 1, settings)
            assertEquals(if (mode == 3) 1 else 0, env.notificationRequests)
        }
    }

    @Test fun validNotificationAccessUsesSystemPromptAndCancelledOwnerNeverOpensSettings() = runTest {
        val env = FakeEnvironment().apply { register(old) }
        val controller = CompanionSetupCoordinator(env, this)
        controller.requestNotificationAccess(Any()) { fail("Registered native request") }
        runCurrent()
        assertEquals(1, env.notificationRequests)
        env.notificationFails = true
        val owner = Any()
        val release = CompletableDeferred<Unit>()
        env.beforeMain = { release.await() }
        controller.requestNotificationAccess(owner) { fail("Destroyed activity") }
        runCurrent()
        controller.cancelSetup(owner)
        release.complete(Unit)
        runCurrent()
        assertEquals(1, env.notificationRequests)
    }

    @Test fun notificationSettingsStillOpenWhenCompanionServiceQueryFails() = runTest {
        val env = FakeEnvironment().apply { register(old); associationQueryFails = true }
        val controller = CompanionSetupCoordinator(env, this)
        var opened = 0
        controller.requestNotificationAccess(Any()) { opened++ }
        runCurrent()
        assertEquals(1, opened)
        assertEquals(0, env.notificationRequests)
        assertFalse(controller.state.value.registered)
        assertEquals(old.identity, env.saved.registration?.identity)
        assertTrue(env.removed.isEmpty())
    }

    @Test fun pairingTransactionPreventsTransientRollbackStateFromDeletingRegistration() = runTest {
        val env = FakeEnvironment().apply { register(old) }
        val controller = CompanionSetupCoordinator(env, this)
        val release = CompletableDeferred<Unit>()
        val transaction = launch {
            controller.withPairingTransaction {
                env.select(replacement)
                release.await()
                env.select(old)
            }
        }
        runCurrent()
        controller.refresh()
        runCurrent()
        assertTrue(env.removed.isEmpty())
        release.complete(Unit)
        transaction.join()
        runCurrent()
        assertTrue(env.removed.isEmpty())
        assertTrue(controller.state.value.registered)
    }

    @Test fun pairingTransactionPropagatesOriginalExceptionAndDoesNotRefresh() = runTest {
        val env = FakeEnvironment().apply { register(old) }
        val controller = CompanionSetupCoordinator(env, this)
        val error = IllegalStateException("rollback incomplete")
        try {
            controller.withPairingTransaction { env.select(replacement); throw error }
            fail("Must propagate")
        } catch (caught: IllegalStateException) {
            assertSame(error, caught)
        }
        assertEquals(old.identity, env.saved.registration?.identity)
        assertTrue(env.removed.isEmpty())
        controller.withPairingTransaction { env.select(old) }
        controller.refresh()
        runCurrent()
        assertTrue(controller.state.value.registered)
    }
}
