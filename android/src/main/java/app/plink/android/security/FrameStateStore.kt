package app.plink.android.security

import java.io.File
import java.io.RandomAccessFile
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.nio.channels.FileChannel
import java.nio.file.StandardOpenOption
import java.security.MessageDigest
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

interface FrameStateStore {
    fun reserveSequence(scope: String): Long
    fun accept(scope: String, sequence: Long, nonce: String)
}

@Serializable
private data class FrameState(
    var sent: Long = 0,
    var highest: Long = 0,
    val received: MutableMap<Long, String> = linkedMapOf()
) {
    fun accept(sequence: Long, nonce: String) {
        require(sequence > 0 && nonce.isNotEmpty() && sequence > highest - 4096 &&
            !received.containsKey(sequence) && !received.containsValue(nonce)) { "Frame replay detected." }
        highest = maxOf(highest, sequence)
        received[sequence] = nonce
        received.keys.removeAll { it <= highest - 4096 }
    }
}

/** Keep this app-private directory for as long as the corresponding pairing key exists. */
class FileFrameStateStore(private val directory: File) : FrameStateStore {
    companion object { private val processLock = Any() }
    override fun reserveSequence(scope: String): Long = update(scope) {
        check(it.sent < Long.MAX_VALUE) { "Send sequence exhausted." }
        ++it.sent
    }
    override fun accept(scope: String, sequence: Long, nonce: String) = update(scope) {
        it.accept(sequence, nonce)
    }
    private fun <T> update(scope: String, body: (FrameState) -> T): T = synchronized(processLock) {
        check(directory.isDirectory || directory.mkdirs()) { "Cannot create transport state directory." }
        val name = MessageDigest.getInstance("SHA-256").digest(scope.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
        RandomAccessFile(File(directory, "$name.lock"), "rw").use { lockFile ->
            lockFile.channel.lock().use {
                val file = File(directory, "$name.json")
                val state = if (file.exists()) Json.decodeFromString<FrameState>(file.readText()) else FrameState()
                val result = body(state)
                val temporary = File.createTempFile("$name-", ".tmp", directory)
                try {
                    temporary.outputStream().use { output ->
                        output.write(Json.encodeToString(state).toByteArray(Charsets.UTF_8))
                        output.fd.sync()
                    }
                    Files.move(temporary.toPath(), file.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
                    FileChannel.open(directory.toPath(), StandardOpenOption.READ).use { it.force(true) }
                } finally { temporary.delete() }
                result
            }
        }
    }
}

class InMemoryFrameStateStore : FrameStateStore {
    private val states = mutableMapOf<String, FrameState>()
    @Synchronized override fun reserveSequence(scope: String): Long {
        val state = states.getOrPut(scope) { FrameState() }
        check(state.sent < Long.MAX_VALUE)
        return ++state.sent
    }
    @Synchronized override fun accept(scope: String, sequence: Long, nonce: String) {
        states.getOrPut(scope) { FrameState() }.accept(sequence, nonce)
    }
}
