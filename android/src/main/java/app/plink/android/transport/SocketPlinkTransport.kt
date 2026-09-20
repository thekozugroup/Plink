package app.plink.android.transport

import app.plink.android.protocol.PlinkEnvelope
import app.plink.android.security.EncryptedFrameCodec
import app.plink.android.security.EncryptedPlinkFrame
import app.plink.android.security.FrameStateStore
import app.plink.android.security.ReplayWindow
import java.io.Closeable
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.EOFException
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.time.Clock
import java.time.Instant
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json

interface OutboundPlinkSender {
    suspend fun send(envelope: PlinkEnvelope)
}

object LengthPrefixedFrameCodec {
    const val maxFrameBytes = 128 * 1024
    fun write(output: DataOutputStream, payload: ByteArray) {
        require(payload.size in 1..maxFrameBytes) { "Frame size is invalid." }
        output.writeInt(payload.size)
        output.write(payload)
        output.flush()
    }
    fun read(input: DataInputStream): ByteArray {
        val size = input.readInt()
        require(size in 1..maxFrameBytes) { "Frame size is invalid." }
        return ByteArray(size).also { input.readFully(it) }
    }
}

class SecureSocketPlinkClient(
    private val host: String,
    private val port: Int,
    private val codec: EncryptedFrameCodec,
    private val stateStore: FrameStateStore,
    private val json: Json = Json { encodeDefaults = true; ignoreUnknownKeys = true }
) : OutboundPlinkSender {
    override suspend fun send(envelope: PlinkEnvelope) = withContext(Dispatchers.IO) {
        val sequence = stateStore.reserveSequence(codec.stateScope(envelope.sourceDeviceId, envelope.targetDeviceId))
        val frame = codec.seal(envelope, sequence = sequence)
        val payload = json.encodeToString(EncryptedPlinkFrame.serializer(), frame).toByteArray(Charsets.UTF_8)
        sendLengthPrefixedFrame(host, port, payload)
    }
}

/** Bounds connect AND write, and releases the channel when the coroutine is cancelled. */
suspend fun sendLengthPrefixedFrame(host: String, port: Int, payload: ByteArray, timeoutMillis: Int = 5_000) = withContext(Dispatchers.IO) {
    require(port in 1..65535 && timeoutMillis > 0)
    require(payload.size in 1..LengthPrefixedFrameCodec.maxFrameBytes)
    // A nonblocking channel bounds both connection and writes; SO_TIMEOUT only bounds reads.
    java.nio.channels.SocketChannel.open().use { channel ->
        channel.configureBlocking(false)
        channel.connect(InetSocketAddress(host, port))
        val buffer = java.nio.ByteBuffer.allocate(payload.size + 4).putInt(payload.size).put(payload)
        buffer.flip()
        val deadline = System.nanoTime() + timeoutMillis.toLong() * 1_000_000
        while (!channel.finishConnect()) {
            currentCoroutineContext().ensureActive()
            if (System.nanoTime() >= deadline) throw SocketTimeoutException("Connect timed out.")
            kotlinx.coroutines.delay(10)
        }
        while (buffer.hasRemaining()) {
            currentCoroutineContext().ensureActive()
            if (System.nanoTime() >= deadline) throw SocketTimeoutException("Write timed out.")
            if (channel.write(buffer) == 0) kotlinx.coroutines.delay(10)
        }
    }
}

/** One owner per session. close() is terminal and unblocks accept/read. */
class SecureSocketPlinkServer(
    private val port: Int,
    private val codec: EncryptedFrameCodec,
    private val stateStore: FrameStateStore,
    private val expectedSourceDeviceId: String? = null,
    private val expectedTargetDeviceId: String? = null,
    private val readTimeoutMillis: Int = 5_000,
    private val clock: Clock = Clock.systemUTC(),
    private val replayWindow: ReplayWindow? = null,
    private val json: Json = Json { ignoreUnknownKeys = true }
) : Closeable {
    init { require(port in 1..65535 && readTimeoutMillis > 0) }
    private val lock = Any()
    private var closed = false
    private var listener: ServerSocket? = null
    private var client: Socket? = null
    private var receiving = false

    /** A successful return means the listening port is owned by this session. */
    fun start() = synchronized(lock) {
        check(!closed) { "Receiver is closed." }
        boundListener()
        Unit
    }

    /** Caller holds lock. Failed binds never publish a listener. */
    private fun boundListener(): ServerSocket = listener ?: ServerSocket().also {
        try {
            it.reuseAddress = true
            it.soTimeout = 200
            it.bind(InetSocketAddress(port))
            listener = it
        } catch (error: Exception) { it.close(); throw error }
    }

    suspend fun receiveOnce(): PlinkEnvelope = withContext(Dispatchers.IO) {
        val coroutine = currentCoroutineContext()
        coroutine.ensureActive()
        val server = synchronized(lock) {
            check(!closed) { "Receiver is closed." }
            check(!receiving) { "Only one receive may run at a time." }
            val existing = boundListener()
            receiving = true
            existing
        }
        try {
            var accepted: Socket? = null
            while (accepted == null) {
                coroutine.ensureActive()
                accepted = try { server.accept() } catch (_: SocketTimeoutException) { null }
            }
            accepted.use { socket ->
                synchronized(lock) {
                    check(!closed) { "Receiver is closed." }
                    client = socket
                }
                val deadline = System.nanoTime() + readTimeoutMillis.toLong() * 1_000_000
                val input = socket.getInputStream()
                fun readExact(size: Int): ByteArray {
                    val result = ByteArray(size)
                    var offset = 0
                    while (offset < size) {
                        coroutine.ensureActive()
                        val remaining = (deadline - System.nanoTime()) / 1_000_000
                        if (remaining <= 0) throw SocketTimeoutException("Frame deadline exceeded.")
                        socket.soTimeout = minOf(200L, remaining).toInt().coerceAtLeast(1)
                        val count = try { input.read(result, offset, size - offset) }
                            catch (_: SocketTimeoutException) { continue }
                        if (count < 0) throw EOFException("Incomplete frame.")
                        offset += count
                    }
                    return result
                }
                val size = java.nio.ByteBuffer.wrap(readExact(4)).int
                require(size in 1..LengthPrefixedFrameCodec.maxFrameBytes) { "Frame size is invalid." }
                val frame = json.decodeFromString(EncryptedPlinkFrame.serializer(), readExact(size).decodeToString())
                coroutine.ensureActive()
                synchronized(lock) {
                    check(!closed) { "Receiver is closed." }
                    codec.open(frame, replayWindow, Instant.now(clock), expectedSourceDeviceId,
                        expectedTargetDeviceId, stateStore)
                }
            }
        } finally {
            synchronized(lock) { client = null; receiving = false }
            if (coroutine[kotlinx.coroutines.Job]?.isActive == false) close()
        }
    }

    override fun close() = synchronized(lock) {
        closed = true
        client?.close()
        listener?.close()
        client = null
        listener = null
    }
}
