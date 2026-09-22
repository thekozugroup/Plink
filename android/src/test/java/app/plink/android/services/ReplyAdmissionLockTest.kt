package app.plink.android.services

import app.plink.android.notifications.ReplyDispatchLock
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ReplyAdmissionLockTest {
    @Test
    fun commandHelperAndPublicationCompleteWithReplyBeforeAdmission() {
        withLease { lease, workers ->
            val publicationEntered = CountDownLatch(1)
            val commandStarted = CountDownLatch(1)
            val operations = AtomicInteger()
            workers.start {
                ReplyDispatchLock.serialized {
                    publicationEntered.countDown()
                    await(commandStarted)
                    // Same reply -> admission read used by publication's outbound policy.
                    assertTrue(lease.isAdmitted())
                }
            }
            await(publicationEntered)
            workers.start {
                commandStarted.countDown()
                assertTrue(ReplyDispatchLock.admitted({ action ->
                    // Assert at gate entry: a lease-first mutation fails before taking the lease.
                    assertTrue(ReplyDispatchLock.heldByCurrentThread())
                    lease.runIfAdmitted(action)
                }) {
                    ReplyDispatchLock.serialized { operations.incrementAndGet() }
                })
            }
            workers.finish()
            assertEquals(1, operations.get())
        }
    }

    @Test
    fun revocationWinningPreventsSynchronousOperationEntry() {
        withLease { lease, _ ->
            lease.revoke()
            var entered = false
            assertFalse(ReplyDispatchLock.admitted(lease::runIfAdmitted) { entered = true })
            assertFalse(entered)
        }
    }

    @Test
    fun admittedOperationCompletesOnceAndRevocationBlocksLaterEntry() {
        withLease { lease, workers ->
            val operationEntered = CountDownLatch(1)
            val releaseOperation = CountDownLatch(1)
            val revokeStarted = CountDownLatch(1)
            val operations = AtomicInteger()
            try {
                workers.start {
                    assertTrue(ReplyDispatchLock.admitted(lease::runIfAdmitted) {
                        operations.incrementAndGet()
                        operationEntered.countDown()
                        await(releaseOperation)
                    })
                }
                await(operationEntered)
                workers.start {
                    revokeStarted.countDown()
                    lease.revoke()
                }
                await(revokeStarted)
                releaseOperation.countDown()
                workers.finish()
                assertFalse(ReplyDispatchLock.admitted(lease::runIfAdmitted) { operations.incrementAndGet() })
                assertEquals(1, operations.get())
            } finally {
                releaseOperation.countDown()
            }
        }
    }

    private fun withLease(block: (OrdinaryAdmissionLease, Workers) -> Unit) {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val lease = OrdinaryAdmissionLease(7, null, null, scope)
        val workers = Workers()
        try {
            block(lease, workers)
        } finally {
            try {
                workers.finish()
            } finally {
                scope.cancel()
            }
        }
    }

    private class Workers {
        private val failure = AtomicReference<Throwable?>(null)
        private val threads = mutableListOf<Thread>()

        fun start(block: () -> Unit) {
            threads += thread(isDaemon = true) {
                try { block() } catch (error: Throwable) { failure.compareAndSet(null, error) }
            }
        }

        fun finish() {
            threads.forEach { it.join(6_000); assertFalse("Worker did not finish", it.isAlive) }
            failure.get()?.let { throw AssertionError("Worker failed", it) }
        }
    }

    companion object {
        private fun await(latch: CountDownLatch) {
            assertTrue("Barrier timed out", latch.await(5, TimeUnit.SECONDS))
        }
    }
}
