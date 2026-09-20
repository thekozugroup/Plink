package app.plink.android.reconnect

import app.plink.android.protocol.PlinkEnvelope
import app.plink.android.protocol.PlinkEventType
import app.plink.android.services.DurableEventOutbox
import app.plink.android.services.EventOutbox
import app.plink.android.services.SharedOutboundBridge
import app.plink.android.transport.OutboundPlinkSender
import java.time.Instant
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class PreparedOrdinaryResourcesTest {
    @get:Rule val temporaryFolder = TemporaryFolder()

    @Test
    fun preparationCrossingDeadlineCannotPublishReadyOrSend() = blockedPreparation(cancel = false)

    @Test
    fun cancellationDoesNotWaitForPreparationAndCannotPublishReadyOrSend() = blockedPreparation(cancel = true)

    @Test
    fun preparedQueueStaysInactiveUntilValidPublicationThenReplaysPersistedEvent() = runBlocking {
        SharedOutboundBridge.configure(null)
        SharedOutboundBridge.awaitQuiescence()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val owner = ReconnectLifecycleOwner { 0L }
        val token = requireNotNull(owner.begin(10_000))
        val sent = CompletableDeferred<String>()
        val outbox = DurableEventOutbox(temporaryFolder.newFolder(), ByteArray(32) { 7 }, "mac")
        val probe = PlinkEnvelope(
            id = "valid-publication-probe", type = PlinkEventType.DeviceStatus,
            sentAt = Instant.now().toString(), sourceDeviceId = "phone", targetDeviceId = "mac",
            payload = buildJsonObject { put("batteryLevel", 53) }
        )
        assertTrue(outbox.store(probe))
        val prepared = PreparedOrdinaryResources.prepare(
            outbox = outbox, disabledTypes = emptySet(),
            sender = object : OutboundPlinkSender {
                override suspend fun send(envelope: PlinkEnvelope) { sent.complete(envelope.id) }
            },
            generation = 1, binding = null, attemptToken = token, scope = scope, isAllowed = { true }
        )
        try {
            assertFalse(prepared.admission.isAdmitted())
            assertFalse(SharedOutboundBridge.tryForward(probe))
            assertFalse(sent.isCompleted)
            assertTrue(prepared.publish(owner, token, { true }, Any()) {
                check(SharedOutboundBridge.installPrepared(prepared.outbound))
                prepared.admission.admit()
                true
            })
            prepared.outbound.retryPending()
            assertEquals(probe.id, withTimeout(5_000) { sent.await() })
        } finally {
            prepared.stop()
            prepared.awaitStopped()
            SharedOutboundBridge.configure(null)
            SharedOutboundBridge.awaitQuiescence()
            scope.cancel()
        }
    }

    private fun blockedPreparation(cancel: Boolean) = runBlocking {
        SharedOutboundBridge.configure(null)
        SharedOutboundBridge.awaitQuiescence()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val now = AtomicLong(0)
        val owner = ReconnectLifecycleOwner(now::get)
        val token = requireNotNull(owner.begin(10_000))
        now.set(9_900)
        val preparing = CountDownLatch(1)
        val release = CountDownLatch(1)
        val sends = AtomicInteger()
        val ready = AtomicBoolean()
        val resources = AtomicReference<PreparedOrdinaryResources?>()
        val durable = DurableEventOutbox(temporaryFolder.newFolder(), ByteArray(32) { 7 }, "mac")
        val probe = PlinkEnvelope(
            id = "preparation-probe", type = PlinkEventType.DeviceStatus,
            sentAt = Instant.now().toString(), sourceDeviceId = "phone", targetDeviceId = "mac",
            payload = buildJsonObject { put("batteryLevel", 53) }
        )
        assertTrue(durable.store(probe))
        val blockingOutbox = object : EventOutbox by durable {
            override fun removeTypes(types: Set<String>) {
                preparing.countDown()
                check(release.await(5, TimeUnit.SECONDS))
                // Production preparation still performs real encrypted outbox write/fsync after release.
                durable.removeTypes(types)
            }
        }
        val work = async(Dispatchers.IO) {
            val prepared = PreparedOrdinaryResources.prepare(
                outbox = blockingOutbox, disabledTypes = emptySet(),
                sender = object : OutboundPlinkSender {
                    override suspend fun send(envelope: PlinkEnvelope) { sends.incrementAndGet() }
                },
                generation = 1, binding = null, attemptToken = token, scope = scope, isAllowed = { true }
            )
            resources.set(prepared)
            try {
                assertFalse(prepared.admission.isAdmitted())
                assertFalse(prepared.outbound.trySend(probe))
                prepared.publish(owner, token, { true }, Any()) {
                    check(SharedOutboundBridge.installPrepared(prepared.outbound))
                    prepared.admission.admit()
                    ready.set(true)
                    true
                }
            } finally {
                prepared.stop()
                prepared.awaitStopped()
            }
        }
        try {
            assertTrue(preparing.await(5, TimeUnit.SECONDS))
            assertFalse(ready.get())
            assertFalse(SharedOutboundBridge.tryForward(probe))
            if (cancel) {
                // Must complete while removeTypes remains blocked; cancellation shares no disk lock.
                val invalidated = async(Dispatchers.Default) { owner.invalidate(token) { _, _ -> false } }
                assertTrue(withTimeout(1_000) { invalidated.await() }.invalidated)
            } else {
                now.set(10_200)
            }
            release.countDown()
            assertFalse(withTimeout(5_000) { work.await() })
            assertFalse(ready.get())
            assertEquals(0, sends.get())
            assertFalse(requireNotNull(resources.get()).admission.isAdmitted())
            assertFalse(requireNotNull(resources.get()).outbound.isRunning)
            assertFalse(SharedOutboundBridge.tryForward(probe))
        } finally {
            release.countDown()
            work.join()
            resources.get()?.stop()
            resources.get()?.awaitStopped()
            SharedOutboundBridge.configure(null)
            SharedOutboundBridge.awaitQuiescence()
            scope.cancel()
        }
    }
}
