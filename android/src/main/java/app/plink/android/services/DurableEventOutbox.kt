package app.plink.android.services

import app.plink.android.protocol.PlinkEnvelope
import app.plink.android.protocol.PlinkEventType
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.io.File
import java.security.MessageDigest
import java.security.SecureRandom
import java.time.Clock
import java.time.Duration
import java.time.Instant
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

interface EventOutbox {
    fun store(envelope: PlinkEnvelope): Boolean
    fun pending(): List<PlinkEnvelope>
    fun remove(id: String)
    fun removeTypes(types: Set<String>)
}

class DurableEventOutbox(
    directory: File,
    sessionKey: ByteArray,
    pairedDeviceId: String,
    private val clock: Clock = Clock.systemUTC(),
    private val capacity: Int = 64,
    private val maxBytes: Int = 256 * 1024
) : EventOutbox {
    private val file = File(directory, "${digest(pairedDeviceId)}.outbox")
    private val key = MessageDigest.getInstance("SHA-256")
        .digest("plink-outbox".toByteArray() + sessionKey)
    private val json = Json { encodeDefaults = true; ignoreUnknownKeys = true }

    @Synchronized
    override fun store(envelope: PlinkEnvelope): Boolean {
        val sanitized = sanitize(envelope) ?: return false
        if (isExpired(sanitized)) return false
        val records = load().filterNot { it.coalesceKey != null && it.coalesceKey == coalesceKey(sanitized) }.toMutableList()
        records += OutboxRecord(sanitized, coalesceKey(sanitized))
        write(bounded(records.takeLast(capacity)))
        return true
    }

    @Synchronized
    override fun pending(): List<PlinkEnvelope> {
        val records = load().filterNot { isExpired(it.envelope) }
        write(records)
        return records.map { it.envelope }
    }

    @Synchronized
    override fun remove(id: String) {
        write(load().filterNot { it.envelope.id == id })
    }

    @Synchronized
    fun clear() {
        file.delete()
    }

    @Synchronized
    override fun removeTypes(types: Set<String>) {
        write(load().filterNot { it.envelope.type in types })
    }

    private fun sanitize(envelope: PlinkEnvelope): PlinkEnvelope? = when (envelope.type) {
        PlinkEventType.MessageReceived -> {
            val omitted = setOf("replyToken", "sourceAppIconPng")
            envelope.copy(
                requiresAck = false,
                payload = JsonObject(envelope.payload.filterKeys { it !in omitted } + ("canReply" to JsonPrimitive(false)))
            )
        }
        PlinkEventType.DeviceStatus, PlinkEventType.MediaState -> envelope.copy(requiresAck = false)
        else -> null
    }

    private fun coalesceKey(envelope: PlinkEnvelope): String? = when (envelope.type) {
        PlinkEventType.DeviceStatus -> PlinkEventType.DeviceStatus
        PlinkEventType.MediaState -> "${PlinkEventType.MediaState}:${envelope.payload["sessionId"]}"
        PlinkEventType.MessageReceived -> envelope.payload["notificationKey"]
            ?.toString()?.trim('"')?.let { "${PlinkEventType.MessageReceived}:$it" }
        else -> null
    }

    private fun isExpired(envelope: PlinkEnvelope): Boolean = runCatching {
        val age = Duration.between(Instant.parse(envelope.sentAt), Instant.now(clock))
        age.isNegative || age > MAX_REPLAY_AGE
    }.getOrDefault(true)

    private fun bounded(records: List<OutboxRecord>): List<OutboxRecord> {
        val kept = records.toMutableList()
        while (kept.isNotEmpty() && json.encodeToString(kept).toByteArray().size > maxBytes) {
            kept.removeAt(0)
        }
        return kept
    }

    private fun load(): List<OutboxRecord> {
        if (!file.exists()) return emptyList()
        return runCatching {
            val combined = Base64.getDecoder().decode(file.readText())
            require(combined.size > 12)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, combined, 0, 12))
            json.decodeFromString<List<OutboxRecord>>(cipher.doFinal(combined.copyOfRange(12, combined.size)).decodeToString())
        }.getOrElse {
            file.delete()
            emptyList()
        }
    }

    private fun write(records: List<OutboxRecord>) {
        if (records.isEmpty()) {
            file.delete()
            return
        }
        check(file.parentFile?.isDirectory == true || file.parentFile?.mkdirs() == true)
        val iv = ByteArray(12).also(SecureRandom()::nextBytes)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, iv))
        val encrypted = cipher.doFinal(json.encodeToString(records).toByteArray())
        val temporary = File.createTempFile(file.name, ".tmp", file.parentFile)
        try {
            temporary.outputStream().use { output ->
                output.write(Base64.getEncoder().encode(iv + encrypted))
                output.fd.sync()
            }
            if (!temporary.renameTo(file)) {
                temporary.copyTo(file, overwrite = true)
                temporary.delete()
            }
        } finally {
            temporary.delete()
        }
    }

    private fun digest(value: String): String = MessageDigest.getInstance("SHA-256")
        .digest(value.toByteArray()).joinToString("") { "%02x".format(it) }
}

@Serializable
private data class OutboxRecord(
    val envelope: PlinkEnvelope,
    val coalesceKey: String? = null
)

private val MAX_REPLAY_AGE: Duration = Duration.ofSeconds(120)
