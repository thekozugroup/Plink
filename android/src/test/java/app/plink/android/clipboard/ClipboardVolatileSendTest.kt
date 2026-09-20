package app.plink.android.clipboard

import app.plink.android.protocol.PlinkEnvelope
import app.plink.android.protocol.PlinkEventType
import app.plink.android.services.EventOutbox
import app.plink.android.services.SerializedOutboundQueue
import app.plink.android.transport.OutboundPlinkSender
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class ClipboardVolatileSendTest {
    @Test fun cancellingDispatchedAutomaticClipboardClosesWriterBeforeCallerCompletes() = runTest {
        val entered = CompletableDeferred<Unit>()
        val releaseWrite = CompletableDeferred<Unit>()
        var closed = false
        var wrote = false
        val sent = mutableListOf<String>()
        val queue = SerializedOutboundQueue(sender = object : OutboundPlinkSender {
            override suspend fun send(envelope: PlinkEnvelope) {
                if (envelope.id == "cancelled") {
                    try {
                        entered.complete(Unit)
                        releaseWrite.await() // Connected socket waiting before its write.
                        wrote = true
                    } finally { closed = true }
                } else sent += envelope.id
            }
        }, scope = this)
        val caller = launch { queue.sendAwaitable(clipboard("cancelled")) }
        entered.await()
        caller.cancelAndJoin() // Same cancellation used for Off and a superseding clipboard copy.
        assertTrue(closed)
        releaseWrite.complete(Unit)
        val latest = launch { queue.sendAwaitable(clipboard("latest")) }
        advanceUntilIdle()
        latest.join()
        assertFalse(wrote)
        assertEquals(listOf("latest"), sent)
        assertTrue(queue.isRunning)
        queue.stop()
    }

    @Test fun clipboardDeadlineCancelsDispatchedWriterRatherThanOnlyItsWaiter() = runTest {
        val entered = CompletableDeferred<Unit>()
        val releaseWrite = CompletableDeferred<Unit>()
        var closed = false
        var wrote = false
        val queue = SerializedOutboundQueue(sender = object : OutboundPlinkSender {
            override suspend fun send(envelope: PlinkEnvelope) {
                try {
                    entered.complete(Unit)
                    releaseWrite.await()
                    wrote = true
                } finally { closed = true }
            }
        }, scope = this)
        val caller = launch { withTimeoutOrNull(750) { queue.sendAwaitable(clipboard("expires")) } }
        entered.await()
        advanceTimeBy(751)
        runCurrent()
        assertTrue(caller.isCompleted)
        assertTrue(closed)
        releaseWrite.complete(Unit)
        advanceUntilIdle()
        assertFalse(wrote)
        assertTrue(queue.isRunning)
        queue.stop()
    }

    @Test fun cancellingManualClipboardWaiterPreservesExistingOrdinaryDispatch() = runTest {
        val entered = CompletableDeferred<Unit>()
        val releaseWrite = CompletableDeferred<Unit>()
        var wrote = false
        val queue = SerializedOutboundQueue(sender = object : OutboundPlinkSender {
            override suspend fun send(envelope: PlinkEnvelope) {
                entered.complete(Unit)
                releaseWrite.await()
                wrote = true
            }
        }, scope = this)
        val caller = launch { queue.sendAwaitable(clipboard("manual", automatic = false)) }
        entered.await()
        caller.cancelAndJoin()
        releaseWrite.complete(Unit)
        advanceUntilIdle()
        assertTrue(wrote)
        assertTrue(queue.isRunning)
        queue.stop()
    }

    @Test fun expiredQueuedClipboardNeverPersistsOrDispatchesAfterConnectionUnblocks() = runTest {
        val predecessor = CompletableDeferred<Unit>()
        val sent = mutableListOf<String>()
        var stored = 0
        val outbox = object : EventOutbox {
            override fun store(envelope: PlinkEnvelope): Boolean { stored++; return true }
            override fun pending(): List<PlinkEnvelope> = emptyList()
            override fun remove(id: String) = Unit
            override fun removeTypes(types: Set<String>) = Unit
        }
        val queue = SerializedOutboundQueue(
            sender = object : OutboundPlinkSender {
                override suspend fun send(envelope: PlinkEnvelope) { sent += envelope.id }
            }, scope = this, outbox = outbox, awaitPredecessors = { predecessor.await() }
        )
        val message = PlinkEnvelope(id = "clip", type = PlinkEventType.ClipboardUpdated,
            sentAt = "2026-09-20T00:00:00Z", sourceDeviceId = "pixel", targetDeviceId = "mac",
            payload = buildJsonObject { put("text", "transient"); put("automatic", true) })
        val pending = launch {
            withTimeoutOrNull(750) {
                queue.sendAwaitable(message, stillValid = { testScheduler.currentTime < 750 })
            }
        }
        runCurrent()
        assertEquals(0, stored)
        advanceTimeBy(751)
        runCurrent()
        predecessor.complete(Unit)
        advanceUntilIdle()
        assertTrue(pending.isCompleted)
        assertTrue(sent.isEmpty())
        assertEquals(0, stored)
        queue.stop()
    }

    private fun clipboard(id: String, automatic: Boolean = true) = PlinkEnvelope(
        id = id, type = PlinkEventType.ClipboardUpdated, sentAt = "2026-09-20T00:00:00Z",
        sourceDeviceId = "pixel", targetDeviceId = "mac",
        payload = buildJsonObject { put("text", "transient"); if (automatic) put("automatic", true) }
    )
}
