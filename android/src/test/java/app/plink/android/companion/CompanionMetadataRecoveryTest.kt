package app.plink.android.companion

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class CompanionMetadataRecoveryTest {
    private val peer = CompanionIdentity("mac", "key", "10:20:30:40:50:60")

    private class Environment(val peer: CompanionIdentity) : CompanionEnvironment<String> {
        override val supported = true
        var saved = CompanionRegistrations(metadata = peer)
        var readFailure: Exception? = null
        var writeFailure: Exception? = null
        var associationFailure: Exception? = null
        var callback: CompanionEnvironment.Callback<String>? = null
        val owned = mutableListOf<CompanionAssociation>()
        override suspend fun pairings() = CompanionPairings(CompanionPeer(peer, "Mac"), setOf(peer))
        override fun readRegistrations(): CompanionRegistrations {
            readFailure?.let { throw it }
            return saved
        }
        override fun writeRegistrations(value: CompanionRegistrations) {
            writeFailure?.let { throw it }
            saved = value
        }
        override fun associations(): List<CompanionAssociation> {
            associationFailure?.let { throw it }
            return owned.toList()
        }
        override fun disassociate(id: Int) { owned.removeAll { it.id == id } }
        override fun associate(bluetoothAddress: String, callback: CompanionEnvironment.Callback<String>) {
            this.callback = callback
        }
        override fun requestNotificationAccess() = Unit
        override suspend fun onMain(action: () -> Unit) = action()
    }

    @Test fun readFailureReportsRecoverableError() = runTest {
        val env = Environment(peer).apply { readFailure = IllegalStateException("storage") }
        val controller = CompanionSetupCoordinator(env, this)
        controller.receiveMetadata(peer.deviceId, peer.peerPublicKey, peer.bluetoothAddress) { it(); true }
        assertFalse(controller.state.value.registered)
        assertTrue(controller.state.value.message.orEmpty().contains("Reconnect"))
    }

    @Test fun writeFailureReportsErrorAndLaterDeliveryRecovers() = runTest {
        val env = Environment(peer).apply { writeFailure = IllegalStateException("storage") }
        val controller = CompanionSetupCoordinator(env, this)
        val nextAddress = "20:30:40:50:60:70"
        controller.receiveMetadata(peer.deviceId, peer.peerPublicKey, nextAddress) { it(); true }
        assertEquals(peer, env.saved.metadata)
        assertNotNull(controller.state.value.message)
        env.writeFailure = null
        controller.receiveMetadata(peer.deviceId, peer.peerPublicKey, nextAddress) { it(); true }
        assertEquals(peer.copy(bluetoothAddress = nextAddress), env.saved.metadata)
        assertNull(controller.state.value.message)
    }

    @Test fun revokedSessionCannotPublishStorageFailure() = runTest {
        val env = Environment(peer).apply { readFailure = IllegalStateException("storage") }
        val controller = CompanionSetupCoordinator(env, this)
        val before = controller.state.value
        controller.receiveMetadata(peer.deviceId, peer.peerPublicKey, peer.bluetoothAddress) { false }
        assertEquals(before, controller.state.value)
    }

    @Test fun savedMetadataSurvivesReconciliationFailure() = runTest {
        val env = Environment(peer).apply { associationFailure = IllegalStateException("association lookup") }
        val controller = CompanionSetupCoordinator(env, this)
        val nextAddress = "20:30:40:50:60:70"
        controller.receiveMetadata(peer.deviceId, peer.peerPublicKey, nextAddress) { it(); true }
        assertEquals(peer.copy(bluetoothAddress = nextAddress), env.saved.metadata)
        assertNotNull(controller.state.value.message)
        env.associationFailure = null
        controller.refresh()
        runCurrent()
        assertNull(controller.state.value.message)
    }

    @Test fun sessionRevokedAfterWriteFailureCannotPublishError() = runTest {
        val env = Environment(peer).apply { writeFailure = IllegalStateException("storage") }
        val controller = CompanionSetupCoordinator(env, this)
        val before = controller.state.value
        var commits = 0
        controller.receiveMetadata(peer.deviceId, peer.peerPublicKey, peer.bluetoothAddress) {
            commits++
            if (commits == 1) { it(); true } else false
        }
        assertEquals(2, commits)
        assertEquals(before, controller.state.value)
    }

    @Test fun unselectedPeerCannotPublishStorageFailure() = runTest {
        val env = Environment(peer).apply { readFailure = IllegalStateException("storage") }
        val controller = CompanionSetupCoordinator(env, this)
        val before = controller.state.value
        controller.receiveMetadata(peer.deviceId, "old-key", peer.bluetoothAddress) { it(); true }
        assertEquals(before, controller.state.value)
    }

    @Test fun metadataFailureDoesNotCancelConsentAttempt() = runTest {
        val env = Environment(peer)
        val controller = CompanionSetupCoordinator(env, this)
        controller.setUp(Any()) {}
        runCurrent()
        assertNotNull(env.callback)
        env.writeFailure = IllegalStateException("storage")
        controller.receiveMetadata(peer.deviceId, peer.peerPublicKey, peer.bluetoothAddress) { it(); true }
        assertTrue(controller.state.value.busy)
        env.writeFailure = null
        env.owned += CompanionAssociation(7, peer.bluetoothAddress)
        env.callback!!.created(7)
        runCurrent()
        assertTrue(controller.state.value.registered)
        assertFalse(controller.state.value.busy)
    }

    @Test fun cancellationPropagatesWithoutPublishingError() = runTest {
        val cancellation = CancellationException("session stopped")
        val env = Environment(peer).apply { writeFailure = cancellation }
        val controller = CompanionSetupCoordinator(env, this)
        try {
            controller.receiveMetadata(peer.deviceId, peer.peerPublicKey, peer.bluetoothAddress) { it(); true }
            fail("Cancellation must propagate")
        } catch (actual: CancellationException) {
            assertSame(cancellation, actual)
        }
        assertNull(controller.state.value.message)
    }

    @Test fun invalidAddressStillRejectsAtProtocolBoundary() = runTest {
        val env = Environment(peer)
        val controller = CompanionSetupCoordinator(env, this)
        try {
            controller.receiveMetadata(peer.deviceId, peer.peerPublicKey, "invalid") { it(); true }
            fail("Invalid address must be rejected")
        } catch (_: IllegalArgumentException) {
            assertEquals(peer, env.saved.metadata)
            assertNull(controller.state.value.message)
        }
    }
}
