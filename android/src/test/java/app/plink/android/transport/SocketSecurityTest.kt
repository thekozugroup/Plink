package app.plink.android.transport

import app.plink.android.protocol.PlinkEnvelope
import app.plink.android.protocol.PlinkEventType
import app.plink.android.security.*
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.io.DataOutputStream
import java.time.Clock
import java.time.Instant
import java.time.ZoneId
import java.time.ZoneOffset
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class SocketSecurityTest {
    @Test fun startReportsBindFailureBeforeSessionCanBecomeReady() {
        val port = port()
        val first = SecureSocketPlinkServer(port, EncryptedFrameCodec(key), InMemoryFrameStateStore())
        val second = SecureSocketPlinkServer(port, EncryptedFrameCodec(key), InMemoryFrameStateStore())
        try {
            first.start()
            first.start()
            assertTrue(runCatching { second.start() }.exceptionOrNull() is java.net.BindException)
            first.close()
            second.start()
            second.close()
            assertTrue(runCatching { second.start() }.isFailure)
        } finally { first.close(); second.close() }
    }

    private fun port() = ServerSocket(0).use { it.localPort }
    private val key = "socket-security-test".toByteArray()
    private fun envelope(now: Instant) = PlinkEnvelope(id="synthetic", type=PlinkEventType.ClipboardUpdated,
        sentAt=now.toString(), sourceDeviceId="mac", targetDeviceId="pixel",
        payload=buildJsonObject { put("text", "synthetic") })
    private suspend fun connect(port: Int): Socket {
        repeat(100) { try { return Socket("127.0.0.1", port) } catch (_: java.io.IOException) { delay(10) } }
        error("listener did not start")
    }
    private fun send(socket: Socket, now: Instant) {
        val frame = EncryptedFrameCodec(key).seal(envelope(now), 1, issuedAt=now)
        val json = Json { encodeDefaults = true }
        LengthPrefixedFrameCodec.write(DataOutputStream(socket.getOutputStream()), json.encodeToString(EncryptedPlinkFrame.serializer(), frame).toByteArray())
    }
    @Test fun cancellationClosesAcceptAndReleasesPort() = runBlocking {
        val port = port()
        val server = SecureSocketPlinkServer(port, EncryptedFrameCodec(key), InMemoryFrameStateStore())
        val waiting = launch(Dispatchers.IO) { server.receiveOnce() }
        delay(100)
        withTimeout(1_000) { waiting.cancelAndJoin() }
        server.close()
        ServerSocket().use { it.reuseAddress = true; it.bind(java.net.InetSocketAddress(port)) }
    }
    @Test fun closeUnblocksIncompleteFrameAndSuppressesDelivery() = runBlocking {
        val port = port()
        val server = SecureSocketPlinkServer(port, EncryptedFrameCodec(key), InMemoryFrameStateStore())
        val result = async(Dispatchers.IO) { runCatching { server.receiveOnce() } }
        connect(port).use { socket ->
            socket.getOutputStream().write(byteArrayOf(0))
            delay(50)
            server.close()
            assertTrue(withTimeout(1_000) { result.await() }.isFailure)
        }
        ServerSocket().use { it.reuseAddress = true; it.bind(java.net.InetSocketAddress(port)) }
    }
    @Test fun partialFrameExpiresAndListenerRemainsUsable() = runBlocking {
        val port = port()
        val server = SecureSocketPlinkServer(port, EncryptedFrameCodec(key), InMemoryFrameStateStore(), readTimeoutMillis=150)
        try {
            val first = async(Dispatchers.IO) { runCatching { server.receiveOnce() } }
            connect(port).use { socket ->
                socket.getOutputStream().write(byteArrayOf(0))
                assertTrue(withTimeout(1_000) { first.await() }.exceptionOrNull() is SocketTimeoutException)
            }
            val second = async(Dispatchers.IO) { server.receiveOnce() }
            val now = Instant.now()
            connect(port).use { send(it, now) }
            assertEquals("synthetic", withTimeout(1_000) { second.await() }.id)
        } finally { server.close() }
    }
    @Test fun freshnessIsSampledAfterFrameArrival() = runBlocking {
        val port = port()
        val clock = MutableClock(Instant.parse("2026-09-19T00:00:00Z"))
        val server = SecureSocketPlinkServer(port, EncryptedFrameCodec(key), InMemoryFrameStateStore(), clock=clock)
        try {
            val result = async(Dispatchers.IO) { server.receiveOnce() }
            connect(port).use { socket ->
                clock.value = clock.value.plusSeconds(3600)
                send(socket, clock.value)
            }
            assertEquals("synthetic", withTimeout(1_000) { result.await() }.id)
        } finally { server.close() }
    }
    private class MutableClock(@Volatile var value: Instant) : Clock() {
        override fun getZone(): ZoneId = ZoneOffset.UTC
        override fun withZone(zone: ZoneId): Clock = this
        override fun instant(): Instant = value
    }
}
