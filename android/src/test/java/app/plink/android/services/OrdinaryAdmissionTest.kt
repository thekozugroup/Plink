package app.plink.android.services

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class OrdinaryAdmissionTest {
    @Test
    fun revokedLeaseClosesAcceptedOrdinarySocketButNotReleasedControlSocket() {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val admission = OrdinaryAdmissionLease(7, binding = null, attemptToken = null, scope = scope)
        val ordinaryClosed = AtomicBoolean(false)
        val controlClosed = AtomicBoolean(false)
        val ordinary = java.io.Closeable { ordinaryClosed.set(true) }
        val control = java.io.Closeable { controlClosed.set(true) }
        try {
            assertTrue(admission.trackAcceptedSocket(ordinary))
            assertTrue(admission.trackAcceptedSocket(control))
            admission.releaseAcceptedSocket(control)

            admission.revoke()

            assertTrue(ordinaryClosed.get())
            assertFalse(controlClosed.get())
            assertFalse(admission.trackAcceptedSocket(java.io.Closeable {}))
        } finally {
            scope.cancel()
        }
    }

    @Test
    fun revocationCancelsQueuedOrdinaryWorkAndDrainWaitsForRunningOwner() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val admission = OrdinaryAdmissionLease(7, binding = null, attemptToken = null, scope = scope)
        val running = CountDownLatch(1)
        val release = CountDownLatch(1)
        val queuedAction = AtomicBoolean(false)
        try {
            assertTrue(admission.dispatch.submit {
                running.countDown()
                check(release.await(5, TimeUnit.SECONDS))
            })
            assertTrue(running.await(5, TimeUnit.SECONDS))
            assertTrue(admission.dispatch.submit { queuedAction.set(true) })

            admission.revoke()
            val drained = async(Dispatchers.Default) { admission.dispatch.awaitStopped() }
            delay(50)
            assertFalse(drained.isCompleted)
            assertFalse(admission.isAdmitted())

            release.countDown()
            withTimeout(5_000) { drained.await() }
            assertFalse(queuedAction.get())
        } finally {
            release.countDown()
            scope.cancel()
        }
    }
}
