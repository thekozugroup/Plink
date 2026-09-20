package app.plink.android.transport

import app.plink.android.protocol.PlinkEnvelope
import app.plink.android.protocol.PlinkEventType
import app.plink.android.security.*
import app.plink.android.services.OrdinaryAdmissionLease
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.io.DataOutputStream
import java.time.Clock
import java.time.Instant
import java.time.ZoneId
import java.time.ZoneOffset
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
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
    private fun send(socket: Socket, now: Instant, sequence: Long = 1) {
        LengthPrefixedFrameCodec.write(DataOutputStream(socket.getOutputStream()), frameBytes(now, sequence))
    }
    private fun frameBytes(now: Instant, sequence: Long = 1): ByteArray {
        val frame = EncryptedFrameCodec(key).seal(envelope(now), sequence, issuedAt=now)
        val json = Json { encodeDefaults = true }
        return json.encodeToString(EncryptedPlinkFrame.serializer(), frame).toByteArray()
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
    @Test fun frameReadUsesOneDeadlineAcrossPrefixAndBody() = runBlocking {
        val port = port()
        val server = SecureSocketPlinkServer(port, EncryptedFrameCodec(key), InMemoryFrameStateStore())
        try {
            server.start()
            val accepted = async(Dispatchers.IO) { server.acceptExchange() }
            connect(port).use { socket ->
                val exchange = accepted.await()
                exchange.use {
                    val result = async(Dispatchers.IO) { runCatching { exchange.read(180) } }
                    val payload = frameBytes(Instant.now())
                    delay(120)
                    DataOutputStream(socket.getOutputStream()).apply {
                        writeInt(payload.size)
                        flush()
                    }
                    delay(120)
                    runCatching { socket.getOutputStream().write(payload) }
                    assertTrue(withTimeout(1_000) { result.await() }.exceptionOrNull() is SocketTimeoutException)
                }
            }
        } finally { server.close() }
    }
    @Test fun knownReconnectReadRejectsOversizedPrefixBeforeBody() = runBlocking {
        val port = port()
        val server = SecureSocketPlinkServer(port, EncryptedFrameCodec(key), InMemoryFrameStateStore())
        try {
            server.start()
            val accepted = async(Dispatchers.IO) { server.acceptExchange() }
            connect(port).use { socket ->
                val exchange = accepted.await()
                exchange.use {
                    val result = async(Dispatchers.IO) {
                        runCatching { exchange.read(1_000, maxWireBytes = 4_096) }
                    }
                    DataOutputStream(socket.getOutputStream()).apply {
                        writeInt(4_097)
                        flush()
                    }
                    assertTrue(withTimeout(1_000) { result.await() }.isFailure)
                }
            }
        } finally { server.close() }
    }

    @Test fun nonblockingAcceptAndLeaseCaptureSerializeWithGenerationReplacement() = runBlocking {
        val port = port()
        val server = SecureSocketPlinkServer(port, EncryptedFrameCodec(key), InMemoryFrameStateStore())
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val generationLock = Any()
        val oldLease = OrdinaryAdmissionLease(1, null, null, scope)
        val newLease = OrdinaryAdmissionLease(2, null, null, scope)
        var current = oldLease
        val acceptedBeforeCapture = CountDownLatch(1)
        val releaseCapture = CountDownLatch(1)
        val replacing = CountDownLatch(1)
        try {
            server.start()
            val accepting = async(Dispatchers.IO) {
                server.acceptExchange(generationLock) { exchange ->
                    acceptedBeforeCapture.countDown()
                    check(releaseCapture.await(5, TimeUnit.SECONDS))
                    current.also { check(it.trackAcceptedSocket(exchange)) }
                }
            }
            connect(port).use { socket ->
                send(socket, Instant.now())
                assertTrue(acceptedBeforeCapture.await(5, TimeUnit.SECONDS))
                val replacement = async(Dispatchers.Default) {
                    replacing.countDown()
                    synchronized(generationLock) {
                        oldLease.revoke()
                        current = newLease
                    }
                }
                assertTrue(replacing.await(5, TimeUnit.SECONDS))
                delay(50)
                assertFalse(replacement.isCompleted)
                releaseCapture.countDown()
                val captured = withTimeout(5_000) { accepting.await() }
                withTimeout(5_000) { replacement.await() }
                assertSame(oldLease, captured.admission)
                assertFalse(captured.admission.isAdmitted())
                assertFalse(captured.admission.dispatch.submit { fail("Old socket ran in the replacement generation") })
                assertTrue(runCatching { captured.exchange.read(500) }.isFailure)
                assertEquals(0, server.activeExchangeCount)
            }
        } finally {
            releaseCapture.countDown()
            server.close()
            oldLease.revoke()
            newLease.revoke()
            oldLease.dispatch.awaitStopped()
            newLease.dispatch.awaitStopped()
            scope.cancel()
        }
    }

    @Test fun pollingAcrossPublicationCapturesFirstNewSocketAndClosedAdmissionStillAcceptsControl() = runBlocking {
        val port = port()
        val server = SecureSocketPlinkServer(port, EncryptedFrameCodec(key), InMemoryFrameStateStore())
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val generationLock = Any()
        val nextLease = OrdinaryAdmissionLease(2, null, null, scope)
        var current: OrdinaryAdmissionLease? = null
        try {
            server.start()
            val controlAccept = async(Dispatchers.IO) {
                server.acceptExchange(generationLock) { current }
            }
            connect(port).use { socket ->
                val captured = withTimeout(1_000) { controlAccept.await() }
                assertNull(captured.admission)
                captured.exchange.use {
                    send(socket, Instant.now())
                    assertTrue(it.read(1_000).result is AuthenticatedFrameResult.Message)
                }
            }
            val nextAccept = async(Dispatchers.IO) {
                server.acceptExchange(generationLock) { exchange ->
                    current?.also { check(it.trackAcceptedSocket(exchange)) }
                }
            }
            delay(50) // No socket yet: generation publication must not be blocked by polling.
            withTimeout(1_000) {
                withContext(Dispatchers.Default) { synchronized(generationLock) { current = nextLease } }
            }
            connect(port).use { socket ->
                val captured = withTimeout(1_000) { nextAccept.await() }
                assertSame(nextLease, captured.admission)
                assertTrue(requireNotNull(captured.admission).isAdmitted())
                captured.exchange.use {
                    send(socket, Instant.now(), sequence = 2)
                    assertTrue(it.read(1_000).result is AuthenticatedFrameResult.Message)
                }
            }
        } finally {
            server.close()
            nextLease.revoke()
            nextLease.dispatch.awaitStopped()
            scope.cancel()
        }
    }
    private class MutableClock(@Volatile var value: Instant) : Clock() {
        override fun getZone(): ZoneId = ZoneOffset.UTC
        override fun withZone(zone: ZoneId): Clock = this
        override fun instant(): Instant = value
    }
}
