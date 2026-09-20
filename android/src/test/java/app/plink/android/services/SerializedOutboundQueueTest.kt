package app.plink.android.services

import app.plink.android.protocol.PlinkEnvelope
import app.plink.android.protocol.PlinkEventType
import app.plink.android.transport.OutboundPlinkSender
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.Rule
import org.junit.rules.TemporaryFolder
import java.time.Instant
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

@OptIn(ExperimentalCoroutinesApi::class)
class SerializedOutboundQueueTest {
    @get:Rule val temporaryFolder = TemporaryFolder()

    @Test
    fun cancellingQueuedScreenControlDoesNotCancelOrdinaryWorker() = runTest {
        val predecessors = kotlinx.coroutines.CompletableDeferred<Unit>()
        val sender = RecordingSender()
        val queue = SerializedOutboundQueue(
            sender = sender,
            scope = this,
            awaitPredecessors = { predecessors.await() }
        )
        val control = queue.sendEphemeral(
            screenEnvelope("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1"),
            SerializedOutboundQueue.EphemeralKind.CONTROL
        ) { true }
        control.cancel()
        assertTrue(runCatching { control.await() }.isFailure)
        assertTrue(queue.trySend(envelope("ordinary")))

        predecessors.complete(Unit)
        advanceUntilIdle()

        assertEquals(listOf("ordinary"), sender.sent)
        assertTrue(queue.isRunning)
        queue.stop()
    }

    @Test
    fun queuedScreenControlExpiresWhilePredecessorBarrierIsBlocked() = runTest {
        val predecessors = kotlinx.coroutines.CompletableDeferred<Unit>()
        val sender = RecordingSender()
        val queue = SerializedOutboundQueue(
            sender = sender,
            scope = this,
            monotonicNanos = { testScheduler.currentTime * 1_000_000L },
            awaitPredecessors = { predecessors.await() }
        )
        val control = queue.sendEphemeral(
            screenEnvelope("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2"),
            SerializedOutboundQueue.EphemeralKind.CONTROL
        ) { true }

        runCurrent()
        advanceTimeBy(1_000)
        runCurrent()

        assertTrue(runCatching { control.await() }.isFailure)
        assertTrue(sender.sent.isEmpty())
        assertTrue(queue.trySend(envelope("ordinary-after-expiry")))
        predecessors.complete(Unit)
        advanceUntilIdle()
        assertEquals(listOf("ordinary-after-expiry"), sender.sent)
        queue.stop()
    }

    @Test
    fun screenTrafficNeverUsesOrdinaryQueueOrOutbox() = runTest {
        val stored = mutableListOf<String>()
        val outbox = object : EventOutbox {
            override fun store(envelope: PlinkEnvelope): Boolean = true.also { stored += envelope.id }
            override fun pending(): List<PlinkEnvelope> = emptyList()
            override fun remove(id: String) = Unit
            override fun removeTypes(types: Set<String>) = Unit
        }
        val sender = RecordingSender()
        val queue = SerializedOutboundQueue(sender, this, outbox = outbox)
        val screen = screenEnvelope("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3")

        assertFalse(queue.trySend(screen))
        assertTrue(runCatching { queue.sendAwaitable(screen) }.isFailure)
        val volatile = queue.sendEphemeral(
            screen,
            SerializedOutboundQueue.EphemeralKind.CONTROL
        ) { true }
        advanceUntilIdle()
        volatile.await()

        assertTrue(stored.isEmpty())
        assertEquals(listOf(screen.id), sender.sent)
        queue.stop()
    }

    @Test
    fun retryDropsPersistedScreenTrafficWithoutDispatch() = runTest {
        val screen = screenEnvelope("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa4")
        val removed = mutableListOf<String>()
        val outbox = object : EventOutbox {
            override fun store(envelope: PlinkEnvelope) = true
            override fun pending(): List<PlinkEnvelope> = listOf(screen)
            override fun remove(id: String) { removed += id }
            override fun removeTypes(types: Set<String>) = Unit
        }
        val sender = RecordingSender()
        val queue = SerializedOutboundQueue(sender, this, outbox = outbox)

        queue.retryPending()
        advanceUntilIdle()

        assertEquals(listOf(screen.id), removed)
        assertTrue(sender.sent.isEmpty())
        queue.stop()
    }

    @Test
    fun ephemeralKindMatchesControlAndPullResponseTypes() = runTest {
        val sender = RecordingSender()
        val queue = SerializedOutboundQueue(sender, this)
        val idle = screenEnvelope(
            id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa5",
            type = PlinkEventType.ScreenIdle
        )

        val idleHandle = queue.sendEphemeral(
            idle,
            SerializedOutboundQueue.EphemeralKind.DATA
        ) { true }
        assertTrue(runCatching {
            queue.sendEphemeral(
                screenEnvelope("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa6"),
                SerializedOutboundQueue.EphemeralKind.DATA
            ) { true }
        }.isFailure)
        advanceUntilIdle()
        idleHandle.await()

        val frame = screenEnvelope(
            id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa7",
            type = PlinkEventType.ScreenFrame
        )
        val frameHandle = queue.sendEphemeral(
            frame,
            SerializedOutboundQueue.EphemeralKind.DATA
        ) { true }
        advanceUntilIdle()
        frameHandle.await()

        assertEquals(listOf(idle.id, frame.id), sender.sent)
        queue.stop()
    }

    @Test
    fun awaitableSendCompletesOnlyAfterTransportSend() = runTest {
        val gate = kotlinx.coroutines.CompletableDeferred<Unit>()
        val sender = object : OutboundPlinkSender {
            override suspend fun send(envelope: PlinkEnvelope) { gate.await() }
        }
        val queue = SerializedOutboundQueue(sender, this, capacity = 2)

        val result = async { queue.sendAwaitable(envelope("file")) }
        runCurrent()
        assertFalse(result.isCompleted)
        gate.complete(Unit)
        advanceUntilIdle()

        assertTrue(result.isCompleted)
        queue.stop()
    }

    @Test
    fun cancellingQueuedAwaitableSendPreventsLaterDispatch() = runTest {
        val firstStarted = kotlinx.coroutines.CompletableDeferred<Unit>()
        val releaseFirst = kotlinx.coroutines.CompletableDeferred<Unit>()
        val attempted = mutableListOf<String>()
        val sender = object : OutboundPlinkSender {
            override suspend fun send(envelope: PlinkEnvelope) {
                attempted += envelope.id
                if (envelope.id == "first") {
                    firstStarted.complete(Unit)
                    releaseFirst.await()
                }
            }
        }
        val queue = SerializedOutboundQueue(sender, this, capacity = 2)
        val first = launch { queue.sendAwaitable(envelope("first")) }
        firstStarted.await()
        val cancelled = launch { queue.sendAwaitable(envelope("cancelled")) }
        runCurrent()
        cancelled.cancelAndJoin()
        releaseFirst.complete(Unit)
        advanceUntilIdle()

        assertEquals(listOf("first"), attempted)
        first.join()
        queue.stop()
    }

    @Test
    fun purgeFailsQueuedAwaitableSendBeforeDispatch() = runTest {
        val firstStarted = kotlinx.coroutines.CompletableDeferred<Unit>()
        val releaseFirst = kotlinx.coroutines.CompletableDeferred<Unit>()
        val attempted = mutableListOf<String>()
        val sender = object : OutboundPlinkSender {
            override suspend fun send(envelope: PlinkEnvelope) {
                attempted += envelope.id
                if (envelope.id == "first") {
                    firstStarted.complete(Unit)
                    releaseFirst.await()
                }
            }
        }
        val queue = SerializedOutboundQueue(sender, this, capacity = 2)
        val first = launch { queue.sendAwaitable(envelope("first")) }
        firstStarted.await()
        val revoked = async { runCatching { queue.sendAwaitable(envelope("file", PlinkEventType.FileChunk)) } }
        runCurrent()
        queue.purge(setOf(PlinkEventType.FileChunk))
        releaseFirst.complete(Unit)
        advanceUntilIdle()

        assertTrue(revoked.await().isFailure)
        assertEquals(listOf("first"), attempted)
        first.join()
        queue.stop()
    }

    @Test
    fun transferGuardRejectsLateEnqueueAndQueuedDispatchEvenAfterFeatureReenabled() = runTest {
        val firstStarted = kotlinx.coroutines.CompletableDeferred<Unit>()
        val releaseFirst = kotlinx.coroutines.CompletableDeferred<Unit>()
        val sent = mutableListOf<String>()
        val sender = object : OutboundPlinkSender {
            override suspend fun send(envelope: PlinkEnvelope) {
                sent += envelope.id
                if (envelope.id == "first") { firstStarted.complete(Unit); releaseFirst.await() }
            }
        }
        val queue = SerializedOutboundQueue(sender, this, capacity = 4)
        val first = launch { queue.sendAwaitable(envelope("first")) }
        firstStarted.await()
        var valid = true
        val queued = async { runCatching {
            queue.sendAwaitable(envelope("queued", PlinkEventType.FileChunk), stillValid = { valid })
        } }
        runCurrent()
        valid = false
        // Simulate a feature disabled/re-enabled before the old producer enqueues.
        // Its attempt token remains invalid even when current policy permits Files.
        val late = runCatching {
            queue.sendAwaitable(envelope("late", PlinkEventType.FileChunk), stillValid = { valid })
        }
        assertTrue(late.isFailure)
        releaseFirst.complete(Unit)
        advanceUntilIdle()
        assertTrue(queued.await().isFailure)
        assertEquals(listOf("first"), sent)
        first.join()
        queue.stop()
    }

    @Test
    fun ownedTerminalCleanupCanFollowFilePurge() = runTest {
        val sender = RecordingSender()
        val queue = SerializedOutboundQueue(sender, this, capacity = 2, isAllowed = { false })
        queue.purge(setOf(PlinkEventType.FileCancel))

        queue.sendAwaitable(envelope("cancel", PlinkEventType.FileCancel), allowRevoked = true)
        advanceUntilIdle()

        assertEquals(listOf("cancel"), sender.sent)
        queue.stop()
    }

    @Test
    fun sendsInOrderAndContinuesAfterOneSendFails() = runTest {
        val sender = RecordingSender(failId = "two")
        val queue = SerializedOutboundQueue(
            sender = sender,
            scope = this,
            capacity = 4
        )

        assertTrue(queue.trySend(envelope("one")))
        assertTrue(queue.trySend(envelope("two")))
        assertTrue(queue.trySend(envelope("three")))
        advanceUntilIdle()

        assertEquals(listOf("one", "two", "three"), sender.attempts)
        assertEquals(listOf("one", "three"), sender.sent)
        queue.stop()
    }

    @Test
    fun rejectsWorkBeyondConfiguredCapacity() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val queue = SerializedOutboundQueue(
            sender = RecordingSender(),
            scope = CoroutineScope(dispatcher),
            capacity = 2
        )

        assertTrue(queue.trySend(envelope("one")))
        assertTrue(queue.trySend(envelope("two")))
        assertFalse(queue.trySend(envelope("three")))
        queue.stop()
    }

    @Test
    fun cancellationStopsWorkerInsteadOfBeingSwallowed() = runTest {
        val sender = object : OutboundPlinkSender {
            var attempts = 0

            override suspend fun send(envelope: PlinkEnvelope) {
                attempts += 1
                throw CancellationException("stop")
            }
        }
        val queue = SerializedOutboundQueue(sender, this, capacity = 2)

        assertTrue(queue.trySend(envelope("one")))
        advanceUntilIdle()
        assertFalse(queue.isRunning)
        assertEquals(1, sender.attempts)
        queue.stop()
    }

    @Test
    fun purgeSuppressesQueuedTypeAndPersistenceFailureDoesNotKillWorker() = runTest {
        val sender = RecordingSender()
        val dispatcher = StandardTestDispatcher(testScheduler)
        val invalidDirectory = temporaryFolder.newFile("plink-outbox-parent.tmp")
        val outbox = DurableEventOutbox(invalidDirectory, byteArrayOf(1, 2, 3), "mac")
        val queue = SerializedOutboundQueue(sender, CoroutineScope(dispatcher), capacity = 4, outbox = outbox)

        assertTrue(queue.trySend(envelope("device", PlinkEventType.DeviceStatus, Instant.now().toString())))
        queue.purge(setOf(PlinkEventType.DeviceStatus))
        assertTrue(queue.trySend(envelope("ack", sentAt = Instant.now().toString())))
        advanceUntilIdle()

        assertEquals(listOf("ack"), sender.sent)
        assertTrue(queue.isRunning)
        queue.stop()
    }

    @Test
    fun revokeDuringPendingReadCannotRelabelOrSendRevokedEvent() = runTest {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val removed = AtomicBoolean(false)
        val revoked = envelope("revoked", PlinkEventType.MessageReceived, Instant.now().toString())
        val outbox = object : EventOutbox {
            override fun store(envelope: PlinkEnvelope) = true
            override fun pending(): List<PlinkEnvelope> {
                entered.countDown()
                check(release.await(5, TimeUnit.SECONDS))
                return listOf(revoked)
            }
            override fun remove(id: String) = Unit
            override fun removeTypes(types: Set<String>) { removed.set(true) }
        }
        var allowed = true
        val sender = RecordingSender()
        val queue = SerializedOutboundQueue(sender, this, outbox = outbox, isAllowed = { allowed })
        val retry = Thread(queue::retryPending).apply { start() }
        assertTrue(entered.await(5, TimeUnit.SECONDS))
        allowed = false
        val purge = Thread { queue.purge(setOf(PlinkEventType.MessageReceived)) }.apply { start() }
        release.countDown()
        retry.join(5_000)
        purge.join(5_000)
        advanceUntilIdle()

        assertTrue(removed.get())
        assertTrue(sender.sent.isEmpty())
        queue.stop()
    }

    @Test
    fun laterSuccessfulTrafficRetriesPersistedFailure() = runTest {
        val directory = temporaryFolder.newFolder("plink-retry")
        val outbox = DurableEventOutbox(directory, byteArrayOf(3, 2, 1), "mac")
        var online = false
        val attempts = mutableListOf<String>()
        val sender = object : OutboundPlinkSender {
            override suspend fun send(envelope: PlinkEnvelope) {
                attempts += envelope.id
                if (!online) error("offline")
            }
        }
        val queue = SerializedOutboundQueue(sender, this, outbox = outbox)
        assertTrue(queue.trySend(envelope("missed", PlinkEventType.MessageReceived, Instant.now().toString())))
        runCurrent()
        online = true
        assertTrue(queue.trySend(envelope("fresh", PlinkEventType.MessageReceived, Instant.now().toString())))
        runCurrent()
        advanceTimeBy(5_000)
        advanceUntilIdle()

        assertTrue(attempts.containsAll(listOf("missed", "fresh")))
        assertTrue(attempts.count { it == "missed" } >= 2)
        assertTrue(outbox.pending().isEmpty())
        queue.stop()
    }

    @Test
    fun bridgePublishesNewQueueBeforeRetryReadsPending() {
        SharedOutboundBridge.configure(null)
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val sent = CountDownLatch(1)
        val outbox = object : EventOutbox {
            override fun store(envelope: PlinkEnvelope) = false
            override fun pending(): List<PlinkEnvelope> {
                entered.countDown()
                check(release.await(5, TimeUnit.SECONDS))
                return emptyList()
            }
            override fun remove(id: String) = Unit
            override fun removeTypes(types: Set<String>) = Unit
        }
        val configure = Thread {
            SharedOutboundBridge.configure(
                sender = object : OutboundPlinkSender {
                    override suspend fun send(envelope: PlinkEnvelope) { sent.countDown() }
                },
                outbox = outbox
            )
        }.apply { start() }
        assertTrue(entered.await(5, TimeUnit.SECONDS))
        val forwarded = AtomicBoolean(false)
        val forward = Thread {
            forwarded.set(SharedOutboundBridge.tryForward(envelope("live", sentAt = Instant.now().toString())))
        }.apply { start() }
        release.countDown()
        configure.join(5_000)
        forward.join(5_000)

        assertTrue(forwarded.get())
        assertTrue(sent.await(5, TimeUnit.SECONDS))
        SharedOutboundBridge.configure(null)
    }

    @Test
    fun cancelledDrainWaiterDoesNotForgetRunningRetiredQueue() = runBlocking {
        SharedOutboundBridge.configure(null)
        val removalEntered = CountDownLatch(1)
        val releaseRemoval = CountDownLatch(1)
        val replacementSent = CountDownLatch(1)
        val outbox = object : EventOutbox {
            override fun store(envelope: PlinkEnvelope) = true
            override fun pending(): List<PlinkEnvelope> = emptyList()
            override fun remove(id: String) {
                removalEntered.countDown()
                check(releaseRemoval.await(5, TimeUnit.SECONDS))
            }
            override fun removeTypes(types: Set<String>) = Unit
        }
        try {
            SharedOutboundBridge.configure(
                sender = object : OutboundPlinkSender {
                    override suspend fun send(envelope: PlinkEnvelope) = Unit
                },
                outbox = outbox
            )
            assertTrue(SharedOutboundBridge.tryForward(envelope("retired")))
            assertTrue(removalEntered.await(5, TimeUnit.SECONDS))
            SharedOutboundBridge.configure(null)

            val cancelledWaiter = launch(Dispatchers.IO) { SharedOutboundBridge.awaitQuiescence() }
            delay(50)
            cancelledWaiter.cancelAndJoin()

            SharedOutboundBridge.configure(sender = object : OutboundPlinkSender {
                override suspend fun send(envelope: PlinkEnvelope) {
                    replacementSent.countDown()
                }
            })
            assertTrue(SharedOutboundBridge.tryForward(envelope("replacement")))
            assertFalse(replacementSent.await(200, TimeUnit.MILLISECONDS))

            releaseRemoval.countDown()
            assertTrue(replacementSent.await(5, TimeUnit.SECONDS))
            SharedOutboundBridge.configure(null)
            withTimeout(5_000) { SharedOutboundBridge.awaitQuiescence() }
        } finally {
            releaseRemoval.countDown()
            SharedOutboundBridge.configure(null)
        }
    }

    private fun envelope(
        id: String,
        type: String = PlinkEventType.Ack,
        sentAt: String = "2026-09-19T00:00:00Z"
    ) = PlinkEnvelope(
        id = id,
        type = type,
        sentAt = sentAt,
        sourceDeviceId = "pixel",
        targetDeviceId = "mac",
        payload = buildJsonObject {}
    )

    private fun screenEnvelope(
        id: String,
        type: String = PlinkEventType.ScreenState
    ) = PlinkEnvelope(
        id = id,
        type = type,
        sentAt = "2026-09-20T00:00:00Z",
        sourceDeviceId = "pixel",
        targetDeviceId = "mac",
        payload = buildJsonObject {
            put("v", 1)
            put("requestId", "11111111-1111-4111-8111-111111111111")
            when (type) {
                PlinkEventType.ScreenIdle -> {
                    put("streamId", "22222222-2222-4222-8222-222222222222")
                    put("index", 1)
                    put("reason", "no_new_frame")
                }
                PlinkEventType.ScreenFrame -> {
                    put("streamId", "22222222-2222-4222-8222-222222222222")
                    put("index", 1)
                    put("width", 1)
                    put("height", 1)
                    put("data", "queue-test")
                }
                else -> put("state", "needs_consent")
            }
        }
    )

    private class RecordingSender(private val failId: String? = null) : OutboundPlinkSender {
        val attempts = mutableListOf<String>()
        val sent = mutableListOf<String>()

        override suspend fun send(envelope: PlinkEnvelope) {
            attempts += envelope.id
            if (envelope.id == failId) error("network failure")
            sent += envelope.id
        }
    }
}
