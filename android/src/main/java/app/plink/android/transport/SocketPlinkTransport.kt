package app.plink.android.transport

import app.plink.android.protocol.PlinkEnvelope
import app.plink.android.security.EncryptedFrameCodec
import app.plink.android.security.EncryptedPlinkFrame
import app.plink.android.security.ReplayWindow
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.ServerSocket
import java.net.Socket
import java.time.Instant
import java.util.concurrent.atomic.AtomicLong

object LengthPrefixedFrameCodec {
    private const val maxFrameBytes = 128 * 1024

    fun write(output: DataOutputStream, payload: ByteArray) {
        require(payload.size in 1..maxFrameBytes) { "Frame size is invalid." }
        output.writeInt(payload.size)
        output.write(payload)
        output.flush()
    }

    fun read(input: DataInputStream): ByteArray {
        val size = input.readInt()
        require(size in 1..maxFrameBytes) { "Frame size is invalid." }
        val payload = ByteArray(size)
        input.readFully(payload)
        return payload
    }
}

class SecureSocketPlinkClient(
    private val host: String,
    private val port: Int,
    private val codec: EncryptedFrameCodec,
    private val json: Json = Json { encodeDefaults = true; ignoreUnknownKeys = true }
) {
    private val sequence = AtomicLong(0)

    suspend fun send(envelope: PlinkEnvelope) = withContext(Dispatchers.IO) {
        val frame = codec.seal(envelope, sequence = sequence.incrementAndGet())
        val payload = json.encodeToString(EncryptedPlinkFrame.serializer(), frame).toByteArray(Charsets.UTF_8)
        Socket(host, port).use { socket ->
            LengthPrefixedFrameCodec.write(DataOutputStream(socket.getOutputStream()), payload)
        }
    }
}

class SecureSocketPlinkServer(
    private val port: Int,
    private val codec: EncryptedFrameCodec,
    private val replayWindow: ReplayWindow = ReplayWindow(),
    private val json: Json = Json { ignoreUnknownKeys = true }
) {
    suspend fun receiveOnce(now: Instant = Instant.now()): PlinkEnvelope = withContext(Dispatchers.IO) {
        ServerSocket(port).use { server ->
            server.accept().use { socket ->
                val payload = LengthPrefixedFrameCodec.read(DataInputStream(socket.getInputStream()))
                val frame = json.decodeFromString(EncryptedPlinkFrame.serializer(), payload.decodeToString())
                codec.open(frame, replayWindow = replayWindow, now = now)
            }
        }
    }
}
