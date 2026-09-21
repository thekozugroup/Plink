package app.plink.android.security

import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

class DurableFrameStateTest {
    @Test fun oneConditionalFrameRetainsExistingWindowBoundary() {
        val within = InMemoryFrameStateStore()
        within.accept("pair", 4096, "ordinary-highest")
        within.accept("pair", 1, "delayed-ordinary")
        val advanced = InMemoryFrameStateStore()
        advanced.accept("pair", 4096, "ordinary-highest")
        advanced.accept("pair", 4097, "conditional-hello")
        assertThrows(IllegalArgumentException::class.java) {
            advanced.accept("pair", 1, "delayed-ordinary")
        }
        advanced.accept("pair", 2, "still-in-window")
        assertThrows(IllegalArgumentException::class.java) {
            advanced.accept("pair", 2, "still-in-window")
        }
    }

    @Test fun survivesRecreationAndAcceptsReordering() {
        val directory = Files.createTempDirectory("plink-state-test").toFile()
        try {
            val first = FileFrameStateStore(directory)
            assertEquals(1L, first.reserveSequence("peer-a"))
            assertEquals(2L, FileFrameStateStore(directory).reserveSequence("peer-a"))
            first.accept("peer-a", 2, "two")
            FileFrameStateStore(directory).accept("peer-a", 1, "one")
            assertThrows(IllegalArgumentException::class.java) {
                FileFrameStateStore(directory).accept("peer-a", 1, "one")
            }
            first.accept("peer-b", 1, "one")
        } finally { directory.deleteRecursively() }
    }
    @Test fun corruptStateFailsClosed() {
        val directory = Files.createTempDirectory("plink-state-test").toFile()
        try {
            val store = FileFrameStateStore(directory)
            store.reserveSequence("peer")
            directory.listFiles()!!.first { it.extension == "json" }.writeText("broken")
            assertThrows(Exception::class.java) { store.reserveSequence("peer") }
        } finally { directory.deleteRecursively() }
    }
    @Test fun parallelReservationsAcrossStoreInstancesAreUnique() {
        val directory = Files.createTempDirectory("plink-state-test").toFile()
        val pool = java.util.concurrent.Executors.newFixedThreadPool(4)
        try {
            val futures = (1..32).map { pool.submit<Long> { FileFrameStateStore(directory).reserveSequence("peer") } }
            assertEquals((1L..32L).toSet(), futures.map { it.get() }.toSet())
        } finally { pool.shutdownNow(); directory.deleteRecursively() }
    }
    @Test fun authenticatedOpenPersistsReplayBeforeReturn() {
        val directory = Files.createTempDirectory("plink-state-test").toFile()
        try {
            val now = java.time.Instant.parse("2026-09-19T00:00:00Z")
            val codec = EncryptedFrameCodec("synthetic".toByteArray())
            val envelope = app.plink.android.protocol.PlinkEnvelope(id="test", type="clipboard.updated", sentAt=now.toString(),
                sourceDeviceId="pixel", targetDeviceId="mac", payload=kotlinx.serialization.json.JsonObject(mapOf("text" to kotlinx.serialization.json.JsonPrimitive("synthetic"))))
            val frame = codec.seal(envelope, 1, issuedAt=now)
            assertThrows(IllegalArgumentException::class.java) {
                codec.open(frame.copy(signature="invalid"), now=now, stateStore=FileFrameStateStore(directory))
            }
            assertEquals(envelope, codec.open(frame, now=now, stateStore=FileFrameStateStore(directory)))
            assertThrows(IllegalArgumentException::class.java) {
                codec.open(frame, now=now, stateStore=FileFrameStateStore(directory))
            }
            assertNotEquals(codec.stateScope("a|b", "c"), codec.stateScope("a", "b|c"))
            assertNotEquals(codec.stateScope("a", "b"), codec.stateScope("b", "a"))
            assertNotEquals(codec.stateScope("a", "b"), EncryptedFrameCodec("other".toByteArray()).stateScope("a", "b"))
        } finally { directory.deleteRecursively() }
    }
    @Test fun replayIsRejectedAfterWindowEviction() {
        val state = InMemoryFrameStateStore()
        state.accept("test", 1, "one")
        state.accept("test", 4097, "new")
        assertThrows(IllegalArgumentException::class.java) { state.accept("test", 1, "one") }
        state.accept("test", 4096, "reordered")
        assertThrows(IllegalArgumentException::class.java) { state.accept("test", 4096, "reordered") }
    }

    @Test fun persistenceFailurePreventsAuthenticatedDispatch() {
        val now = java.time.Instant.now()
        val codec = EncryptedFrameCodec("synthetic".toByteArray())
        val envelope = app.plink.android.protocol.PlinkEnvelope(id="test", type="clipboard.updated", sentAt=now.toString(),
            sourceDeviceId="pixel", targetDeviceId="mac", payload=kotlinx.serialization.json.JsonObject(mapOf("text" to kotlinx.serialization.json.JsonPrimitive("synthetic"))))
        val frame = codec.seal(envelope, 1, issuedAt=now)
        val failing = object : FrameStateStore {
            override fun reserveSequence(scope: String): Long = throw java.io.IOException("disk unavailable")
            override fun accept(scope: String, sequence: Long, nonce: String): Unit = throw java.io.IOException("disk unavailable")
        }
        assertThrows(java.io.IOException::class.java) { codec.open(frame, now=now, stateStore=failing) }
    }

}
