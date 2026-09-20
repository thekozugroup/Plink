package app.plink.android.screen

import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class ScreenProjectionLifecyclesTest {
    @Test
    fun revokedIssuedLaunchWaitsForDelayedDeliveryAndReleaseWithoutDeadline() = runTest {
        val lifecycles = ScreenProjectionLifecycles<Any>()
        val ticket = lifecycles.register("request", "stream", 1, 1)
        assertTrue(lifecycles.markLaunchIssued(ticket))
        assertNull(lifecycles.invalidate(ticket))
        val quiescence = async(start = CoroutineStart.UNDISPATCHED) { lifecycles.awaitQuiescence() }

        advanceTimeBy(60_000)
        assertFalse(ticket.completion.isCompleted)
        assertFalse(quiescence.isCompleted)
        assertEquals(1, lifecycles.outstandingCount)

        // Delivery acknowledges the revoked launch without authorizing native capture.
        val service = Any()
        assertSame(ticket, deliver(lifecycles, ticket, service))
        assertFalse(lifecycles.isCurrent(ticket, service))
        assertNull(lifecycles.currentOwner(ticket))
        advanceTimeBy(60_000)
        assertFalse(quiescence.isCompleted)

        // The service reports this only after startup/callback work and thread release finish.
        lifecycles.complete(ticket, service)
        quiescence.await()
        assertTrue(ticket.completion.isCompleted)
        assertEquals(0, lifecycles.outstandingCount)
    }

    @Test
    fun unissuedAndKnownFailedLaunchesRetireWithoutWaitingForImpossibleDelivery() = runTest {
        val lifecycles = ScreenProjectionLifecycles<Any>()
        val unissued = lifecycles.register("unissued", "stream", 1, 1)
        assertNull(lifecycles.invalidate(unissued))
        assertTrue(unissued.completion.isCompleted)
        assertFalse(lifecycles.markLaunchIssued(unissued))

        val failed = lifecycles.register("failed", "stream", 1, 2)
        assertTrue(lifecycles.markLaunchIssued(failed))
        lifecycles.invalidate(failed)
        assertFalse(failed.completion.isCompleted)
        assertNull(lifecycles.launchFailed(failed))
        assertTrue(failed.completion.isCompleted)
        assertEquals(0, lifecycles.outstandingCount)
        lifecycles.awaitQuiescence()
    }

    @Test
    fun claimedStartupStillRequiresItsExactOwnerToFinishRelease() = runTest {
        val lifecycles = ScreenProjectionLifecycles<Any>()
        val ticket = lifecycles.register("request", "stream", 4, 8)
        val service = Any()
        assertTrue(lifecycles.markLaunchIssued(ticket))
        assertFalse(lifecycles.markLaunchIssued(ticket))
        assertNull(lifecycles.claimDelivery(ticket.token, ticket.requestId, ticket.streamId, 3, 8, service))
        assertSame(ticket, deliver(lifecycles, ticket, service))
        assertNull(deliver(lifecycles, ticket, service))
        assertTrue(lifecycles.isCurrent(ticket, service))

        assertSame(service, lifecycles.invalidate(ticket))
        val quiescence = async(start = CoroutineStart.UNDISPATCHED) { lifecycles.awaitQuiescence() }
        lifecycles.complete(ticket, Any())
        assertFalse(ticket.completion.isCompleted)
        assertFalse(quiescence.isCompleted)

        // Even an error reported after delivery cannot stand in for native release.
        assertSame(service, lifecycles.launchFailed(ticket))
        assertFalse(ticket.completion.isCompleted)
        lifecycles.complete(ticket, service)
        quiescence.await()
        assertEquals(0, lifecycles.outstandingCount)
    }

    @Test
    fun completedRecordsRetireImmediatelyAndLateCompletionCannotRetireReplacement() = runTest {
        val lifecycles = ScreenProjectionLifecycles<Any>()
        val service = Any()
        var previous: ScreenProjectionStartTicket? = null
        repeat(100) { generation ->
            val ticket = lifecycles.register("request", "stream", 1, generation.toLong())
            assertTrue(lifecycles.markLaunchIssued(ticket))
            assertSame(ticket, deliver(lifecycles, ticket, service))
            previous?.let { lifecycles.complete(it, service) }
            assertFalse(ticket.completion.isCompleted)
            assertEquals(1, lifecycles.outstandingCount)
            assertTrue(lifecycles.stopping(ticket, service))
            lifecycles.complete(ticket, service)
            assertTrue(ticket.completion.isCompleted)
            assertEquals(0, lifecycles.outstandingCount)
            previous = ticket
        }
        // Retirement does not depend on a later caller invoking this barrier.
        lifecycles.awaitQuiescence()
    }

    private fun deliver(
        lifecycles: ScreenProjectionLifecycles<Any>, ticket: ScreenProjectionStartTicket, owner: Any
    ): ScreenProjectionStartTicket? = lifecycles.claimDelivery(
        ticket.token, ticket.requestId, ticket.streamId, ticket.sessionGeneration, ticket.ownerGeneration, owner
    )
}
