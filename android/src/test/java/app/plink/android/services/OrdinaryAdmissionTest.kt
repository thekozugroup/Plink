package app.plink.android.services

import app.plink.android.reconnect.ReconnectLifecycleOwner
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
import org.junit.Assert.assertNull
import org.junit.Assert.assertEquals
import org.junit.Test

class OrdinaryAdmissionTest {
    @Test
    fun conditionalClaimSerializesWithOrdinaryPublicationAndStop() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val owner = ReconnectLifecycleOwner { 1_000L }
        val admissionLock = Any()
        val admission = OrdinaryAdmissionLease(9, null, null, scope, initiallyAdmitted = false)
        val publicationLocked = CountDownLatch(1)
        val releasePublication = CountDownLatch(1)
        val claimStarted = CountDownLatch(1)
        var claimChecks = 0
        try {
            val publication = async(Dispatchers.Default) {
                synchronized(admissionLock) {
                    publicationLocked.countDown()
                    check(releasePublication.await(5, TimeUnit.SECONDS))
                    admission.admit()
                }
            }
            assertTrue(publicationLocked.await(5, TimeUnit.SECONDS))
            val claim = async(Dispatchers.Default) {
                claimStarted.countDown()
                owner.beginConditional(10_000, admissionLock) {
                    claimChecks++
                    !admission.isAdmitted()
                }
            }
            assertTrue(claimStarted.await(5, TimeUnit.SECONDS))
            releasePublication.countDown()
            withTimeout(5_000) { publication.await() }
            assertNull(withTimeout(5_000) { claim.await() })
            assertTrue(admission.isAdmitted())
            assertEquals(1, claimChecks)
            owner.close { _, _ -> false }
            admission.revoke()
            assertNull(owner.beginConditional(10_000, admissionLock) { error("Stopped owner checked eligibility") })
        } finally {
            releasePublication.countDown()
            admission.revoke()
            admission.dispatch.awaitStopped()
            scope.cancel()
        }
    }

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
