package app.plink.android.services

import app.plink.android.SessionRestoreState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class BackgroundConnectionRestorationTest {
    @Test
    fun lateRestoreCompletionStartsOnceWithoutChangingSavedOptIn() = runTest {
        val fixture = Fixture()
        fixture.observe(backgroundScope)
        runCurrent()
        assertEquals(0, fixture.starts)

        fixture.restore.value = SessionRestoreState.COMPLETE
        runCurrent()
        assertEquals(1, fixture.starts)
        assertEquals(BackgroundConnectionState.Starting, fixture.runtime.value)
        assertTrue(fixture.enabled.value)
        assertEquals(emptyList<Boolean>(), fixture.preferenceWrites)
    }

    @Test
    fun backgroundCancelsObservationAndResumeRechecksCompletedRestore() = runTest {
        val fixture = Fixture()
        val observation = fixture.observe(backgroundScope)
        runCurrent()
        fixture.resumed = false
        observation.cancel()
        fixture.restore.value = SessionRestoreState.COMPLETE
        runCurrent()
        assertEquals(0, fixture.starts)

        fixture.resumed = true
        fixture.observe(backgroundScope)
        runCurrent()
        assertEquals(1, fixture.starts)
    }

    @Test
    fun queuedCompletionRechecksResumedEvenBeforeCollectorCancellation() = runTest {
        val fixture = Fixture()
        fixture.observe(backgroundScope)
        runCurrent()
        fixture.restore.value = SessionRestoreState.COMPLETE
        fixture.resumed = false
        runCurrent()
        assertEquals(0, fixture.starts)
    }

    @Test
    fun offBeforeQueuedRestoreCompletionPreventsStart() = runTest {
        val fixture = Fixture()
        fixture.observe(backgroundScope)
        runCurrent()
        fixture.restore.value = SessionRestoreState.COMPLETE
        fixture.enabled.value = false
        runCurrent()
        assertEquals(0, fixture.starts)
        assertFalse(fixture.enabled.value)
    }

    @Test
    fun notificationStopPreventsRestartAcrossResume() = runTest {
        val fixture = Fixture()
        fixture.runtime.value = BackgroundConnectionState.Starting
        val observation = fixture.observe(backgroundScope)
        runCurrent()
        // BackgroundConnectionService.ACTION_STOP clears opt-in before publishing Disabled.
        fixture.enabled.value = false
        fixture.runtime.value = BackgroundConnectionState.Disabled
        fixture.restore.value = SessionRestoreState.COMPLETE
        runCurrent()
        observation.cancel()
        fixture.observe(backgroundScope)
        runCurrent()
        assertEquals(0, fixture.starts)
        assertFalse(fixture.enabled.value)
    }

    @Test
    fun activeRuntimeStatesAndRepeatedResumeDoNotDuplicateStarts() = runTest {
        val fixture = Fixture()
        fixture.restore.value = SessionRestoreState.COMPLETE
        val observation = fixture.observe(backgroundScope)
        runCurrent()
        assertEquals(1, fixture.starts)
        observation.cancel()
        fixture.observe(backgroundScope)
        runCurrent()
        for (state in listOf(BackgroundConnectionState.Running, BackgroundConnectionState.AwaitingReconnect)) {
            fixture.runtime.value = state
            runCurrent()
        }
        fixture.status.value = SessionStatus.READY
        runCurrent()
        assertEquals(1, fixture.starts)
    }

    @Test
    fun deniedNotificationsAndMissingPairingBlockStart() = runTest {
        val fixture = Fixture()
        fixture.restore.value = SessionRestoreState.COMPLETE
        fixture.notifications = false
        fixture.observe(backgroundScope)
        runCurrent()
        assertEquals(0, fixture.starts)
        fixture.notifications = true
        for (status in listOf(SessionStatus.DISCONNECTED, SessionStatus.REPAIR_REQUIRED)) {
            fixture.status.value = status
            runCurrent()
            assertEquals(0, fixture.starts)
        }
        fixture.status.value = SessionStatus.READY
        runCurrent()
        assertEquals(1, fixture.starts)
    }

    @Test
    fun startFailuresDisableOptInAndDoNotRetryOnResume() = runTest {
        for (failure in listOf(SecurityException(), IllegalStateException())) {
            val fixture = Fixture()
            fixture.failure = failure
            fixture.restore.value = SessionRestoreState.COMPLETE
            val observation = fixture.observe(backgroundScope)
            runCurrent()
            assertEquals(1, fixture.starts)
            assertFalse(fixture.enabled.value)
            assertEquals(listOf(false), fixture.preferenceWrites)
            val expectedMessage = if (failure is SecurityException) {
                "Plink lacks permission to run the background connection."
            } else {
                "Android blocked the background connection start. Open Plink and try again."
            }
            assertEquals(BackgroundConnectionState.Failed(expectedMessage), fixture.runtime.value)
            assertEquals(BackgroundConnectionRequestResult.Failed(expectedMessage), fixture.result)
            observation.cancel()
            val resumedObservation = fixture.observe(backgroundScope)
            runCurrent()
            assertEquals(1, fixture.starts)
            resumedObservation.cancel()
        }
    }

    private class Fixture {
        val restore = MutableStateFlow(SessionRestoreState.RESTORING)
        val enabled = MutableStateFlow(true)
        val status = MutableStateFlow(SessionStatus.AWAITING_RECONNECT)
        val runtime = MutableStateFlow<BackgroundConnectionState>(BackgroundConnectionState.Disabled)
        var resumed = true
        var notifications = true
        var starts = 0
        var failure: RuntimeException? = null
        var result: BackgroundConnectionRequestResult? = null
        val preferenceWrites = mutableListOf<Boolean>()

        fun observe(scope: CoroutineScope) = scope.launch {
            observeBackgroundConnectionRestoration(
                restore, enabled, status, runtime,
                isResumed = { resumed },
                notificationsAllowed = { notifications },
                start = {
                    result = startBackgroundConnectionService(
                        setEnabled = { preferenceWrites += it; enabled.value = it },
                        setState = { runtime.value = it },
                        startService = { starts++; failure?.let { throw it } }
                    )
                }
            )
        }
    }
}
