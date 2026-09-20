package app.plink.android.continuity

import app.plink.android.protocol.FileTransferPayloadPolicy
import app.plink.android.protocol.PlinkEnvelope
import app.plink.android.protocol.PlinkEventType
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import kotlinx.serialization.json.put
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.file.Files
import java.security.MessageDigest
import java.util.Base64
import java.util.UUID

class FileTransferCoordinatorTest {
    private val fixtures = mutableListOf<Fixture>()

    @After
    fun cleanupFixtures() {
        val failures = mutableListOf<Throwable>()
        fixtures.forEach { fixture ->
            runCatching { fixture.coordinator.close() }.exceptionOrNull()?.let(failures::add)
            fixture.scope.cancel()
            if (!fixture.processRoot.deleteRecursively() && fixture.processRoot.exists()) {
                failures += AssertionError("Could not delete test transfer root: ${fixture.processRoot}")
            }
        }
        fixtures.clear()
        failures.firstOrNull()?.let { failure ->
            failures.drop(1).forEach(failure::addSuppressed)
            throw failure
        }
    }

    @Test
    fun outgoingBoundaryFilesWaitForAcceptanceAndSendByteIdentically() = runBlocking {
        for (size in listOf(0, 1, 32_768, 32_769, FileTransferPayloadPolicy.maxFileBytes)) {
            val bytes = ByteArray(size) { (it % 251).toByte() }
            val fixture = fixture(bytes)

            assertEquals(FileOfferStartResult.Offered, fixture.coordinator.offerOutgoing(
                OutgoingFileSource("source", "sample.bin", "application/octet-stream")
            ))
            val offer = fixture.sent.single()
            assertEquals(PlinkEventType.FileOffer, offer.type)
            assertEquals(size.toLong(), offer.payload.getValue("sizeBytes").jsonPrimitive.long)
            assertEquals(sha256(bytes), offer.payload.getValue("sha256").jsonPrimitive.content)
            assertFalse(fixture.sent.any { it.type == PlinkEventType.FileChunk })

            fixture.coordinator.handle(event(PlinkEventType.FileAccept, offer.transferId()), generation = 7)
            val received = ByteArrayOutputStream()
            var consumed = 1
            while (true) {
                val next = fixture.sent.drop(consumed).firstOrNull() ?: break
                consumed = fixture.sent.indexOf(next) + 1
                when (next.type) {
                    PlinkEventType.FileChunk -> {
                        received.write(Base64.getDecoder().decode(next.payload.getValue("data").jsonPrimitive.content))
                        fixture.coordinator.handle(event(
                            PlinkEventType.FileProgress,
                            offer.transferId(),
                            "nextIndex" to JsonPrimitive(next.payload.getValue("index").jsonPrimitive.int + 1)
                        ), generation = 7)
                    }
                    PlinkEventType.FileComplete -> break
                }
            }

            assertArrayEquals(bytes, received.toByteArray())
            assertEquals(PlinkEventType.FileComplete, fixture.sent.last().type)
            fixture.coordinator.handle(event(
                PlinkEventType.FileResult,
                offer.transferId(),
                "status" to JsonPrimitive("saved")
            ), generation = 7)
            assertTrue(fixture.coordinator.state.value is FileTransferState.Saved)
            assertTrue(fixture.processRoot.walkTopDown().none { it.isFile })
        }
    }

    @Test
    fun capPlusOneIsRejectedBeforeOfferAndRemoved() = runBlocking {
        val fixture = fixture(ByteArray(FileTransferPayloadPolicy.maxFileBytes + 1))

        assertEquals(FileOfferStartResult.TooLarge, fixture.coordinator.offerOutgoing(
            OutgoingFileSource("source", "large.bin", "application/octet-stream")
        ))

        assertTrue(fixture.sent.isEmpty())
        assertTrue(fixture.processRoot.walkTopDown().none { it.isFile })
    }

    @Test
    fun incomingTransferWritesOnlyAfterPickerConsentAndSavesSelectedDestination() = runBlocking {
        val bytes = ByteArray(32_769) { (it % 127).toByte() }
        val fixture = fixture()
        val transferId = UUID.randomUUID().toString()
        fixture.coordinator.handle(offer(transferId, "remote.bin", bytes), generation = 7)
        val handle = fixture.environment.offers.single().first

        assertTrue(fixture.environment.outputs.isEmpty())
        assertTrue(fixture.coordinator.acceptIncoming(
            handle,
            IncomingFileDestination("picked-document", newlyCreated = false)
        ))
        assertEquals(PlinkEventType.FileAccept, fixture.sent.last().type)

        bytes.asList().chunked(FileTransferPayloadPolicy.chunkBytes).forEachIndexed { index, chunk ->
            fixture.coordinator.handle(event(
                PlinkEventType.FileChunk,
                transferId,
                "index" to JsonPrimitive(index),
                "data" to JsonPrimitive(Base64.getEncoder().encodeToString(chunk.toByteArray()))
            ), generation = 7)
            assertEquals(index + 1, fixture.sent.last().payload.getValue("nextIndex").jsonPrimitive.int)
        }
        fixture.coordinator.handle(event(PlinkEventType.FileComplete, transferId), generation = 7)

        assertArrayEquals(bytes, fixture.environment.outputs.getValue("picked-document").toByteArray())
        assertEquals("saved", fixture.sent.last().payload.getValue("status").jsonPrimitive.content)
        assertTrue(fixture.coordinator.state.value is FileTransferState.Saved)
        assertTrue(fixture.processRoot.walkTopDown().none { it.isFile })
    }

    @Test
    fun chunkBeforeConsentFailsWithoutWritingDestination() = runBlocking {
        val bytes = byteArrayOf(1)
        val fixture = fixture()
        val transferId = UUID.randomUUID().toString()
        fixture.coordinator.handle(offer(transferId, "remote.bin", bytes), generation = 7)

        fixture.coordinator.handle(event(
            PlinkEventType.FileChunk,
            transferId,
            "index" to JsonPrimitive(0),
            "data" to JsonPrimitive(Base64.getEncoder().encodeToString(bytes))
        ), generation = 7)

        assertTrue(fixture.environment.outputs.isEmpty())
        assertEquals("invalid", fixture.sent.last().payload.getValue("code").jsonPrimitive.content)
        assertTrue(fixture.coordinator.state.value is FileTransferState.Failed)
        assertTrue(fixture.processRoot.walkTopDown().none { it.isFile })
    }

    @Test
    fun digestMismatchAndExportFailureNeverReportSaved() = runBlocking {
        val bytes = byteArrayOf(1, 2, 3)
        val fixture = fixture()
        val transferId = UUID.randomUUID().toString()
        fixture.coordinator.handle(offer(transferId, "remote.bin", bytes, sha = "0".repeat(64)), generation = 7)
        val handle = fixture.environment.offers.single().first
        fixture.coordinator.acceptIncoming(handle, IncomingFileDestination("picked", newlyCreated = false))
        fixture.coordinator.handle(event(
            PlinkEventType.FileChunk,
            transferId,
            "index" to JsonPrimitive(0),
            "data" to JsonPrimitive(Base64.getEncoder().encodeToString(bytes))
        ), generation = 7)
        fixture.coordinator.handle(event(PlinkEventType.FileComplete, transferId), generation = 7)

        assertEquals("invalid", fixture.sent.last().payload.getValue("code").jsonPrimitive.content)
        assertFalse(fixture.sent.any { it.type == PlinkEventType.FileResult && it.payload["status"]?.jsonPrimitive?.content == "saved" })

        val exportFailure = fixture(failExport = true)
        val secondId = UUID.randomUUID().toString()
        exportFailure.coordinator.handle(offer(secondId, "safe.bin", bytes), generation = 7)
        val secondHandle = exportFailure.environment.offers.single().first
        exportFailure.coordinator.acceptIncoming(secondHandle, IncomingFileDestination("user-selected-only", newlyCreated = false))
        exportFailure.coordinator.handle(event(
            PlinkEventType.FileChunk,
            secondId,
            "index" to JsonPrimitive(0),
            "data" to JsonPrimitive(Base64.getEncoder().encodeToString(bytes))
        ), generation = 7)
        exportFailure.coordinator.handle(event(PlinkEventType.FileComplete, secondId), generation = 7)

        assertEquals("storage", exportFailure.sent.last().payload.getValue("code").jsonPrimitive.content)
        assertEquals(listOf("user-selected-only"), exportFailure.environment.openedDestinations)
        assertTrue(exportFailure.environment.deletedDestinations.isEmpty())
    }

    @Test
    fun busyWrongPeerGenerationFeatureOffAndTimeoutAreBounded() = runBlocking {
        var enabled = true
        var now = 0L
        val fixture = fixture(filesEnabled = { enabled }, monotonicMillis = { now })
        val firstId = UUID.randomUUID().toString()
        fixture.coordinator.handle(offer(firstId, "first.bin", byteArrayOf(1)), generation = 7)
        val firstHandle = fixture.environment.offers.single().first
        val secondId = UUID.randomUUID().toString()
        fixture.coordinator.handle(offer(secondId, "second.bin", byteArrayOf(2)), generation = 7)
        assertEquals("busy", fixture.sent.last().payload.getValue("code").jsonPrimitive.content)
        assertEquals("first.bin", fixture.coordinator.pendingIncoming(firstHandle)?.name)

        fixture.coordinator.handle(offer(UUID.randomUUID().toString(), "wrong.bin", byteArrayOf(3)).copy(
            sourceDeviceId = "other"
        ), generation = 7)
        fixture.coordinator.handle(offer(UUID.randomUUID().toString(), "old.bin", byteArrayOf(4)), generation = 6)
        assertEquals(1, fixture.environment.offers.size)

        enabled = false
        fixture.coordinator.featureDisabled()
        assertNull(fixture.coordinator.pendingIncoming(firstHandle))
        assertTrue(fixture.environment.dismissed.contains(firstHandle))
        assertEquals("cancelled", fixture.sent.last().payload.getValue("reason").jsonPrimitive.content)

        enabled = true
        val timeoutId = UUID.randomUUID().toString()
        fixture.coordinator.handle(offer(timeoutId, "timeout.bin", byteArrayOf(5)), generation = 7)
        now = 60_000
        fixture.coordinator.checkTimeouts()
        assertEquals("timeout", fixture.sent.last().payload.getValue("code").jsonPrimitive.content)
        assertTrue(fixture.processRoot.walkTopDown().none { it.isFile })
    }

    @Test
    fun sessionReplacementRevokesOldHandleAndRemovesStaging() = runBlocking {
        val fixture = fixture()
        val transferId = UUID.randomUUID().toString()
        fixture.coordinator.handle(offer(transferId, "old.bin", byteArrayOf(1)), generation = 7)
        val oldHandle = fixture.environment.offers.single().first

        fixture.coordinator.activateSession("pixel", "new-mac", generation = 8)

        assertNull(fixture.coordinator.pendingIncoming(oldHandle))
        assertFalse(fixture.coordinator.acceptIncoming(
            oldHandle,
            IncomingFileDestination("late-document", newlyCreated = true)
        ))
        assertTrue(fixture.environment.outputs.isEmpty())
        assertTrue(fixture.processRoot.walkTopDown().none { it.isFile })
    }

    @Test
    fun outgoingErrorResultTerminatesBeforeAcceptance() = runBlocking {
        val fixture = fixture(byteArrayOf(1))
        fixture.coordinator.offerOutgoing(OutgoingFileSource("source", "sample.bin", "application/octet-stream"))
        val transferId = fixture.sent.single().transferId()

        fixture.coordinator.handle(event(
            PlinkEventType.FileResult,
            transferId,
            "status" to JsonPrimitive("error"),
            "code" to JsonPrimitive("receive_unavailable")
        ), generation = 7)

        assertEquals("receive_unavailable", (fixture.coordinator.state.value as FileTransferState.Failed).reason)
        assertTrue(fixture.processRoot.walkTopDown().none { it.isFile })
    }

    @Test
    fun acceptanceResetsInactivityClock() = runBlocking {
        var now = 0L
        val fixture = fixture(monotonicMillis = { now })
        val transferId = UUID.randomUUID().toString()
        fixture.coordinator.handle(offer(transferId, "remote.bin", byteArrayOf(1)), generation = 7)
        val handle = fixture.environment.offers.single().first
        now = 45_000

        assertTrue(fixture.coordinator.acceptIncoming(handle, IncomingFileDestination("picked", false)))
        now = 74_999
        fixture.coordinator.checkTimeouts()

        assertTrue(fixture.coordinator.state.value is FileTransferState.Transferring)
    }

    @Test
    fun cancellationAfterCompleteIsOutcomeUnconfirmed() = runBlocking {
        val fixture = fixture()
        fixture.coordinator.offerOutgoing(OutgoingFileSource("source", "empty.bin", "application/octet-stream"))
        val transferId = fixture.sent.single().transferId()
        fixture.coordinator.handle(event(PlinkEventType.FileAccept, transferId), generation = 7)
        assertEquals(PlinkEventType.FileComplete, fixture.sent.last().type)

        fixture.coordinator.cancelActive()

        assertTrue(fixture.coordinator.state.value is FileTransferState.OutcomeUnconfirmed)
    }

    @Test
    fun featureOffThenOnWhileDestinationOpenIsBlockedWritesNoBytes() = runBlocking {
        var enabled = true
        val opened = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val fixture = fixture(
            filesEnabled = { enabled },
            environment = BlockingEnvironment(byteArrayOf(), opened, release)
        )
        val bytes = byteArrayOf(1, 2, 3)
        val transferId = UUID.randomUUID().toString()
        fixture.coordinator.handle(offer(transferId, "remote.bin", bytes), generation = 7)
        val handle = fixture.environment.offers.single().first
        fixture.coordinator.acceptIncoming(handle, IncomingFileDestination("picked", false))
        fixture.coordinator.handle(event(
            PlinkEventType.FileChunk,
            transferId,
            "index" to JsonPrimitive(0),
            "data" to JsonPrimitive(Base64.getEncoder().encodeToString(bytes))
        ), generation = 7)
        val complete = async {
            fixture.coordinator.handle(event(PlinkEventType.FileComplete, transferId), generation = 7)
        }
        opened.await()
        enabled = false
        fixture.coordinator.featureDisabled()
        enabled = true
        release.complete(Unit)
        complete.await()

        assertEquals(0, fixture.environment.outputs["picked"]?.size() ?: 0)
        assertFalse(fixture.sent.any { it.type == PlinkEventType.FileResult && it.payload["status"]?.jsonPrimitive?.content == "saved" })
    }

    @Test
    fun preparationReservesSlotAndRemainsRevokedAcrossFeatureToggleOrSessionChange() = runBlocking {
        for (replaceSession in listOf(false, true)) {
            var enabled = true
            val opened = CompletableDeferred<Unit>()
            val release = CompletableDeferred<Unit>()
            val environment = object : FakeEnvironment(byteArrayOf(1, 2, 3), false) {
                override fun openSource(token: String): ByteArrayInputStream {
                    opened.complete(Unit)
                    runBlocking { release.await() }
                    return super.openSource(token)
                }
            }
            val fixture = fixture(filesEnabled = { enabled }, environment = environment)
            val pending = async(Dispatchers.Default) {
                fixture.coordinator.offerOutgoing(OutgoingFileSource("source", "sample.bin", "application/octet-stream"))
            }
            try {
                kotlinx.coroutines.withTimeout(5_000) { opened.await() }
                assertEquals(FileOfferStartResult.Busy, fixture.coordinator.offerOutgoing(
                    OutgoingFileSource("source", "second.bin", "application/octet-stream")))
                fixture.coordinator.handle(offer(UUID.randomUUID().toString(), "incoming.bin", byteArrayOf()), 7)
                assertEquals("busy", fixture.sent.single().payload["code"]?.jsonPrimitive?.content)
                if (replaceSession) {
                    fixture.coordinator.activateSession("pixel", "other-mac", 8)
                } else {
                    enabled = false
                    fixture.coordinator.featureDisabled()
                    enabled = true
                }
                assertEquals(FileOfferStartResult.Busy, fixture.coordinator.offerOutgoing(
                    OutgoingFileSource("source", "late.bin", "application/octet-stream")))
            } finally { release.complete(Unit) }
            assertEquals(FileOfferStartResult.Failed, pending.await())
            assertFalse(fixture.sent.any { it.type == PlinkEventType.FileOffer })
            assertTrue(fixture.processRoot.walkTopDown().none { it.isFile })
        }
    }

    @Test
    fun aLateAcceptCannotRestartAnExpiredOffer() = runBlocking {
        var now = 0L
        val fixture = fixture(byteArrayOf(1), monotonicMillis = { now })
        fixture.coordinator.offerOutgoing(OutgoingFileSource("source", "sample.bin", "application/octet-stream"))
        val id = fixture.sent.single().transferId()
        now = 60_000
        fixture.coordinator.handle(event(PlinkEventType.FileAccept, id), 7)
        assertFalse(fixture.sent.any { it.type == PlinkEventType.FileChunk })
        assertEquals("timeout", (fixture.coordinator.state.value as FileTransferState.Failed).reason)
    }

    private fun fixture(
        source: ByteArray = byteArrayOf(),
        failExport: Boolean = false,
        filesEnabled: () -> Boolean = { true },
        monotonicMillis: () -> Long = { 0L },
        environment: FakeEnvironment = FakeEnvironment(source, failExport)
    ): Fixture {
        val root = Files.createTempDirectory("plink-transfer-test").toFile()
        return try {
            val sent = mutableListOf<PlinkEnvelope>()
            val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
            val coordinator = FileTransferCoordinator(
                stagingBase = root,
                scope = scope,
                environment = environment,
                filesEnabled = filesEnabled,
                sendEnvelope = { envelope, _, stillValid -> check(stillValid()); sent += envelope },
                monotonicMillis = monotonicMillis,
                scheduleWatchdog = false
            )
            coordinator.activateSession("pixel", "mac", generation = 7)
            Fixture(coordinator, environment, sent, root, scope).also(fixtures::add)
        } catch (failure: Throwable) {
            root.deleteRecursively()
            throw failure
        }
    }

    private fun offer(id: String, name: String, bytes: ByteArray, sha: String = sha256(bytes)) = event(
        PlinkEventType.FileOffer,
        id,
        "name" to JsonPrimitive(name),
        "mimeType" to JsonPrimitive("application/octet-stream"),
        "sizeBytes" to JsonPrimitive(bytes.size),
        "sha256" to JsonPrimitive(sha),
        "chunkBytes" to JsonPrimitive(FileTransferPayloadPolicy.chunkBytes)
    )

    private fun event(type: String, transferId: String, vararg fields: Pair<String, JsonPrimitive>) = PlinkEnvelope(
        id = UUID.randomUUID().toString(),
        type = type,
        sentAt = "2026-09-19T00:00:00Z",
        sourceDeviceId = "mac",
        targetDeviceId = "pixel",
        payload = buildJsonObject {
            put("transferId", transferId)
            fields.forEach { (key, value) -> put(key, value) }
        }
    )

    private fun PlinkEnvelope.transferId(): String = payload.getValue("transferId").jsonPrimitive.content

    private fun sha256(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256")
        .digest(bytes).joinToString("") { "%02x".format(it) }

    private data class Fixture(
        val coordinator: FileTransferCoordinator,
        val environment: FakeEnvironment,
        val sent: MutableList<PlinkEnvelope>,
        val processRoot: File,
        val scope: CoroutineScope
    )

    private open class FakeEnvironment(source: ByteArray, private val failExport: Boolean) : FileTransferEnvironment {
        private val sources = mapOf("source" to source)
        val offers = mutableListOf<Pair<String, IncomingFileOffer>>()
        val dismissed = mutableListOf<String>()
        val outputs = mutableMapOf<String, ByteArrayOutputStream>()
        val openedDestinations = mutableListOf<String>()
        val deletedDestinations = mutableListOf<String>()

        override fun openSource(token: String) = ByteArrayInputStream(sources.getValue(token))

        override fun openDestination(token: String): ByteArrayOutputStream {
            openedDestinations += token
            if (failExport) error("provider failed")
            return outputs.getOrPut(token, ::ByteArrayOutputStream)
        }

        override fun showIncomingOffer(handle: String, offer: IncomingFileOffer): Boolean {
            offers += handle to offer
            return true
        }

        override fun dismissIncomingOffer(handle: String) {
            dismissed += handle
        }

        override fun deleteNewDestination(token: String): Boolean {
            deletedDestinations += token
            return true
        }

        override fun releaseDestination(token: String) = Unit
    }

    private class BlockingEnvironment(
        source: ByteArray,
        private val opened: CompletableDeferred<Unit>,
        private val release: CompletableDeferred<Unit>
    ) : FakeEnvironment(source, false) {
        override fun openDestination(token: String): ByteArrayOutputStream {
            val output = super.openDestination(token)
            opened.complete(Unit)
            kotlinx.coroutines.runBlocking { release.await() }
            return output
        }
    }
}
