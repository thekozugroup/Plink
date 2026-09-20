package app.plink.android.transport

import app.plink.android.protocol.PlinkEnvelope
import app.plink.android.protocol.ReconnectPayloadPolicy
import app.plink.android.security.AuthenticatedFrameResult
import app.plink.android.security.EncryptedFrameCodec
import app.plink.android.security.EncryptedPlinkFrame
import app.plink.android.security.FrameStateStore
import app.plink.android.security.ReplayWindow
import java.io.Closeable
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.EOFException
import java.net.Inet4Address
import java.net.InetSocketAddress
import java.net.SocketTimeoutException
import java.nio.ByteBuffer
import java.nio.channels.ServerSocketChannel
import java.nio.channels.SocketChannel
import java.time.Clock
import java.time.Instant
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json

interface OutboundPlinkSender {
    suspend fun send(envelope: PlinkEnvelope)

    suspend fun send(envelope: PlinkEnvelope, timeoutMillis: Int) {
        send(envelope)
    }
}

data class ReceivedPlinkMessage(
    val result: AuthenticatedFrameResult,
    val wireBytes: Int
)

data class ObservedSocketTuple(
    val localAddress: String,
    val localPort: Int,
    val remoteAddress: String,
    val remotePort: Int
)

/** Production implementations bind a public platform Network and exact local address before connect. */
interface SocketChannelBinding {
    fun bindBeforeConnect(channel: SocketChannel)
    fun validateConnected(channel: SocketChannel)
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

/** One instance belongs to one immutable pair lifetime and serializes every encrypted write. */
class PairTransmitGate(
    private val codec: EncryptedFrameCodec,
    private val stateStore: FrameStateStore,
    private val json: Json = Json { encodeDefaults = true; ignoreUnknownKeys = true }
) {
    private val mutex = Mutex()

    suspend fun write(
        envelope: PlinkEnvelope,
        validate: () -> Unit = {},
        writer: suspend (ByteArray) -> Unit
    ) = mutex.withLock {
        currentCoroutineContext().ensureActive()
        validate()
        val sequence = stateStore.reserveSequence(codec.stateScope(envelope.sourceDeviceId, envelope.targetDeviceId))
        val frame = codec.seal(envelope, sequence = sequence)
        val payload = json.encodeToString(EncryptedPlinkFrame.serializer(), frame).toByteArray(Charsets.UTF_8)
        if (envelope.type in ReconnectPayloadPolicy.eventTypes) {
            require(payload.size <= ReconnectPayloadPolicy.maxEncryptedJsonBytes) {
                "Reconnect encrypted JSON exceeds ${ReconnectPayloadPolicy.maxEncryptedJsonBytes} bytes."
            }
        }
        writer(payload)
    }
}

class SecureSocketPlinkClient(
    private val host: String,
    private val port: Int,
    codec: EncryptedFrameCodec,
    stateStore: FrameStateStore,
    private val binding: SocketChannelBinding? = null,
    transmitGate: PairTransmitGate? = null,
    json: Json = Json { encodeDefaults = true; ignoreUnknownKeys = true }
) : OutboundPlinkSender {
    private val gate = transmitGate ?: PairTransmitGate(codec, stateStore, json)

    override suspend fun send(envelope: PlinkEnvelope) = send(envelope, 5_000)

    override suspend fun send(envelope: PlinkEnvelope, timeoutMillis: Int) = withContext(Dispatchers.IO) {
        openConnectedChannel(host, port, timeoutMillis, binding).use { channel ->
            gate.write(envelope, validate = { binding?.validateConnected(channel) }) { payload ->
                writeLengthPrefixedFrame(channel, payload, timeoutMillis)
            }
        }
    }
}

/** Bounds connect and write. Binding runs before connect and is revalidated before sequence reservation. */
suspend fun sendLengthPrefixedFrame(
    host: String,
    port: Int,
    payload: ByteArray,
    timeoutMillis: Int = 5_000,
    binding: SocketChannelBinding? = null
) = withContext(Dispatchers.IO) {
    openConnectedChannel(host, port, timeoutMillis, binding).use { channel ->
        binding?.validateConnected(channel)
        writeLengthPrefixedFrame(channel, payload, timeoutMillis)
    }
}

suspend fun openConnectedChannel(
    host: String,
    port: Int,
    timeoutMillis: Int,
    binding: SocketChannelBinding? = null
): SocketChannel {
    require(port in 1..65535 && timeoutMillis > 0)
    val channel = SocketChannel.open()
    try {
        channel.configureBlocking(false)
        binding?.bindBeforeConnect(channel)
        channel.connect(InetSocketAddress(host, port))
        val deadline = deadline(timeoutMillis)
        while (!channel.finishConnect()) {
            currentCoroutineContext().ensureActive()
            requireBefore(deadline, "Connect timed out.")
            delay(10)
        }
        binding?.validateConnected(channel)
        return channel
    } catch (error: Throwable) {
        channel.close()
        throw error
    }
}

suspend fun writeLengthPrefixedFrame(channel: SocketChannel, payload: ByteArray, timeoutMillis: Int) {
    require(payload.size in 1..LengthPrefixedFrameCodec.maxFrameBytes && timeoutMillis > 0)
    val buffer = ByteBuffer.allocate(payload.size + 4).putInt(payload.size).put(payload).also { it.flip() }
    val deadline = deadline(timeoutMillis)
    while (buffer.hasRemaining()) {
        currentCoroutineContext().ensureActive()
        requireBefore(deadline, "Write timed out.")
        if (channel.write(buffer) == 0) delay(10)
    }
}

/** A connected socket whose reads and writes remain owned by one reconnect phase. */
class SecureSocketPlinkExchange(
    private val channel: SocketChannel,
    private val codec: EncryptedFrameCodec,
    private val stateStore: FrameStateStore,
    private val transmitGate: PairTransmitGate,
    private val expectedSourceDeviceId: String?,
    private val expectedTargetDeviceId: String?,
    private val clock: Clock,
    private val replayWindow: ReplayWindow?,
    private val json: Json,
    private val onClose: (SecureSocketPlinkExchange) -> Unit = {}
) : Closeable {
    private val readMutex = Mutex()
    @Volatile private var closed = false

    val tuple: ObservedSocketTuple
        get() {
            val local = channel.localAddress as InetSocketAddress
            val remote = channel.remoteAddress as InetSocketAddress
            val localAddress = local.address as? Inet4Address ?: error("Local socket is not IPv4.")
            val remoteAddress = remote.address as? Inet4Address ?: error("Remote socket is not IPv4.")
            val localHost = localAddress.hostAddress ?: error("Local socket address is unavailable.")
            val remoteHost = remoteAddress.hostAddress ?: error("Remote socket address is unavailable.")
            return ObservedSocketTuple(localHost, local.port, remoteHost, remote.port)
        }

    suspend fun read(
        timeoutMillis: Int,
        maxWireBytes: Int = LengthPrefixedFrameCodec.maxFrameBytes
    ): ReceivedPlinkMessage = readMutex.withLock {
        check(!closed) { "Exchange is closed." }
        require(timeoutMillis > 0 && maxWireBytes in 1..LengthPrefixedFrameCodec.maxFrameBytes)
        val frameDeadline = deadline(timeoutMillis)
        val sizeBytes = readExact(channel, 4, frameDeadline)
        val size = ByteBuffer.wrap(sizeBytes).int
        require(size in 1..maxWireBytes) { "Frame size is invalid." }
        val raw = readExact(channel, size, frameDeadline)
        val frame = json.decodeFromString(EncryptedPlinkFrame.serializer(), PlinkEnvelope.decodeUtf8(raw))
        val result = codec.openAuthenticated(
            frame = frame,
            replayWindow = replayWindow,
            now = Instant.now(clock),
            expectedSourceDeviceId = expectedSourceDeviceId,
            expectedTargetDeviceId = expectedTargetDeviceId,
            stateStore = stateStore,
            wireBytes = size
        )
        ReceivedPlinkMessage(result, size)
    }

    suspend fun write(envelope: PlinkEnvelope, timeoutMillis: Int, validate: () -> Unit = {}) {
        check(!closed) { "Exchange is closed." }
        transmitGate.write(envelope, validate = {
            check(!closed && channel.isConnected) { "Exchange is closed." }
            validate()
        }) { payload -> writeLengthPrefixedFrame(channel, payload, timeoutMillis) }
    }

    override fun close() {
        if (closed) return
        closed = true
        runCatching { channel.close() }
        onClose(this)
    }
}

suspend fun openSecureSocketPlinkExchange(
    host: String,
    port: Int,
    codec: EncryptedFrameCodec,
    stateStore: FrameStateStore,
    transmitGate: PairTransmitGate,
    expectedSourceDeviceId: String?,
    expectedTargetDeviceId: String?,
    timeoutMillis: Int,
    binding: SocketChannelBinding
): SecureSocketPlinkExchange {
    val channel = openConnectedChannel(host, port, timeoutMillis, binding)
    return SecureSocketPlinkExchange(
        channel = channel,
        codec = codec,
        stateStore = stateStore,
        transmitGate = transmitGate,
        expectedSourceDeviceId = expectedSourceDeviceId,
        expectedTargetDeviceId = expectedTargetDeviceId,
        clock = Clock.systemUTC(),
        replayWindow = null,
        json = Json { ignoreUnknownKeys = true }
    )
}

/** The lease captured in the same transaction as the nonblocking socket accept. */
internal data class AcceptedSecureExchange<T>(val exchange: SecureSocketPlinkExchange, val admission: T)

/** One owner per pair lifetime. close() is terminal and unblocks accept/read. */
class SecureSocketPlinkServer(
    private val port: Int,
    private val codec: EncryptedFrameCodec,
    private val stateStore: FrameStateStore,
    private val expectedSourceDeviceId: String? = null,
    private val expectedTargetDeviceId: String? = null,
    private val readTimeoutMillis: Int = 5_000,
    private val clock: Clock = Clock.systemUTC(),
    private val replayWindow: ReplayWindow? = null,
    private val json: Json = Json { ignoreUnknownKeys = true },
    private val transmitGate: PairTransmitGate = PairTransmitGate(codec, stateStore)
) : Closeable {
    init { require(port in 1..65535 && readTimeoutMillis > 0) }

    private val lock = Any()
    private var closed = false
    private var listener: ServerSocketChannel? = null
    private val exchanges = mutableSetOf<SecureSocketPlinkExchange>()

    val isClosed: Boolean get() = synchronized(lock) { closed }
    val activeExchangeCount: Int get() = synchronized(lock) { exchanges.size }

    fun start() = synchronized(lock) {
        check(!closed) { "Receiver is closed." }
        boundListener()
        Unit
    }

    val localPort: Int
        get() = synchronized(lock) { (boundListener().localAddress as InetSocketAddress).port }

    private fun boundListener(): ServerSocketChannel = listener ?: ServerSocketChannel.open().also { channel ->
        try {
            channel.configureBlocking(false)
            channel.setOption(java.net.StandardSocketOptions.SO_REUSEADDR, true)
            channel.bind(InetSocketAddress(port))
            listener = channel
        } catch (error: Exception) {
            channel.close()
            throw error
        }
    }

    suspend fun acceptExchange(): SecureSocketPlinkExchange = acceptExchange(lock) { Unit }.exchange

    internal suspend fun <T> acceptExchange(
        admissionLock: Any,
        captureAdmission: (SecureSocketPlinkExchange) -> T
    ): AcceptedSecureExchange<T> = withContext(Dispatchers.IO) {
        val server = synchronized(lock) {
            check(!closed) { "Receiver is closed." }
            boundListener()
        }
        var accepted: AcceptedSecureExchange<T>? = null
        while (accepted == null) {
            currentCoroutineContext().ensureActive()
            accepted = synchronized(admissionLock) {
                // accept() is nonblocking. Polling and frame reads never hold the generation lock.
                val exchange = synchronized(lock) accept@{
                    check(!closed) { "Receiver is closed." }
                    val channel = server.accept() ?: return@accept null
                    try {
                        channel.configureBlocking(false)
                        SecureSocketPlinkExchange(
                            channel = channel,
                            codec = codec,
                            stateStore = stateStore,
                            transmitGate = transmitGate,
                            expectedSourceDeviceId = expectedSourceDeviceId,
                            expectedTargetDeviceId = expectedTargetDeviceId,
                            clock = clock,
                            replayWindow = replayWindow,
                            json = json,
                            onClose = { synchronized(lock) { exchanges -= it } }
                        ).also { exchanges += it }
                    } catch (failure: Exception) {
                        channel.close()
                        throw failure
                    }
                }
                exchange?.let {
                    try {
                        AcceptedSecureExchange(it, captureAdmission(it))
                    } catch (failure: Exception) {
                        it.close()
                        throw failure
                    }
                }
            }
            if (accepted == null) delay(10)
        }
        accepted
    }

    suspend fun receiveOnce(): PlinkEnvelope = when (val message = receiveAuthenticated().result) {
        is AuthenticatedFrameResult.Message -> message.envelope
        is AuthenticatedFrameResult.RejectedScreen -> throw IllegalArgumentException("Invalid screen message.")
    }

    suspend fun receiveAuthenticated(): ReceivedPlinkMessage = acceptExchange().use { exchange ->
        exchange.read(readTimeoutMillis)
    }

    override fun close() {
        val owned = synchronized(lock) {
            if (closed) return
            closed = true
            val result = exchanges.toList()
            exchanges.clear()
            listener?.close()
            listener = null
            result
        }
        owned.forEach(SecureSocketPlinkExchange::close)
    }
}

private suspend fun readExact(channel: SocketChannel, size: Int, deadline: Long): ByteArray {
    require(size > 0)
    val bytes = ByteBuffer.allocate(size)
    while (bytes.hasRemaining()) {
        currentCoroutineContext().ensureActive()
        requireBefore(deadline, "Frame deadline exceeded.")
        when (channel.read(bytes)) {
            -1 -> throw EOFException("Incomplete frame.")
            0 -> delay(10)
        }
    }
    return bytes.array()
}

private fun deadline(timeoutMillis: Int): Long = System.nanoTime() + timeoutMillis.toLong() * 1_000_000L

private fun requireBefore(deadline: Long, message: String) {
    if (System.nanoTime() >= deadline) throw SocketTimeoutException(message)
}
