package app.plink.android.reconnect

import app.plink.android.protocol.ReconnectEndpoint
import app.plink.android.protocol.ReconnectPayloadPolicy
import app.plink.android.security.EncryptedFrameCodec
import java.io.File
import java.nio.ByteBuffer
import java.nio.CharBuffer
import java.nio.channels.FileChannel
import java.nio.charset.CodingErrorAction
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import java.security.MessageDigest
import java.util.Base64
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

@Serializable
data class ReconnectEndpointRecord(
    val version: Int = 1,
    val localID: String,
    val peerID: String,
    val sessionID: String,
    val endpoint: String,
    val proofID: String,
    val tag: String
)

class ReconnectEndpointStore(
    private val directory: File,
    private val beforeRename: () -> Unit = {}
) {
    private val json = Json { encodeDefaults = true; ignoreUnknownKeys = false; prettyPrint = false }

    fun load(
        localID: String,
        peerID: String,
        sessionID: String,
        sessionKey: ByteArray
    ): ReconnectEndpointRecord? = synchronized(processLock) {
        validateIdentity(localID, "localID")
        validateIdentity(peerID, "peerID")
        val file = File(directory, fileName(sessionKey, localID, peerID))
        if (!file.isFile || file.length() !in 1..MAX_RECORD_BYTES.toLong()) return@synchronized null
        val record = runCatching {
            val raw = Charsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(file.readBytes()))
                .toString()
            json.decodeFromString<ReconnectEndpointRecord>(raw)
        }
            .getOrNull() ?: return@synchronized null
        if (record.version != 1 || record.localID != localID || record.peerID != peerID ||
            record.sessionID != sessionID || !validRecord(record)
        ) return@synchronized null
        val expected = authenticate(record.copy(tag = ""), sessionKey).tag
        if (!MessageDigest.isEqual(expected.toByteArray(Charsets.US_ASCII), record.tag.toByteArray(Charsets.US_ASCII))) {
            return@synchronized null
        }
        record
    }

    /** Atomic rename is the commit point. A failed durability check leaves admission closed. */
    internal fun commit(
        localID: String,
        peerID: String,
        sessionID: String,
        endpoint: String,
        proofID: String,
        sessionKey: ByteArray,
        attemptToken: ReconnectAttemptToken,
        lifecycleOwner: ReconnectLifecycleOwner,
        pairIsCurrent: () -> Boolean
    ): ReconnectEndpointRecord = synchronized(processLock) {
        val unsigned = ReconnectEndpointRecord(
            localID = localID,
            peerID = peerID,
            sessionID = sessionID,
            endpoint = endpoint,
            proofID = proofID,
            tag = ""
        )
        require(validRecord(unsigned)) { "Reconnect endpoint record is invalid." }
        val record = authenticate(unsigned, sessionKey)
        val encoded = json.encodeToString(record).toByteArray(Charsets.UTF_8)
        require(encoded.size <= MAX_RECORD_BYTES) { "Reconnect endpoint record is too large." }
        check(directory.isDirectory || directory.mkdirs()) { "Cannot create reconnect endpoint directory." }
        val file = File(directory, fileName(sessionKey, localID, peerID))
        val temporary = File.createTempFile(file.nameWithoutExtension + "-", ".tmp", directory)
        try {
            temporary.outputStream().use { output ->
                output.write(encoded)
                output.fd.sync()
            }
            beforeRename()
            checkNotNull(lifecycleOwner.commit(attemptToken, pairIsCurrent) {
                Files.move(
                    temporary.toPath(),
                    file.toPath(),
                    StandardCopyOption.ATOMIC_MOVE,
                    StandardCopyOption.REPLACE_EXISTING
                )
                record
            }) { "Reconnect publication was cancelled." }
            FileChannel.open(directory.toPath(), StandardOpenOption.READ).use { it.force(true) }
            record
        } finally {
            temporary.delete()
        }
    }

    companion object {
        private const val MAX_RECORD_BYTES = 2_048
        private val processLock = Any()
        private val keyLabel = "plink-reconnect-endpoint-v1".toByteArray(Charsets.UTF_8)

        internal fun signingInput(record: ReconnectEndpointRecord): ByteArray = listOf(
            record.version.toString(),
            record.localID,
            record.peerID,
            record.sessionID,
            record.endpoint,
            record.proofID
        ).joinToString("") { value ->
            "${strictUtf8(value).size}:$value"
        }.let(::strictUtf8)

        internal fun authenticate(record: ReconnectEndpointRecord, sessionKey: ByteArray): ReconnectEndpointRecord {
            val derivedKey = hmac(sessionKey, keyLabel)
            return try {
                record.copy(tag = Base64.getEncoder().encodeToString(hmac(derivedKey, signingInput(record))))
            } finally {
                derivedKey.fill(0)
            }
        }

        internal fun fileName(sessionKey: ByteArray, localID: String, peerID: String): String {
            validateIdentity(localID, "localID")
            validateIdentity(peerID, "peerID")
            val scope = EncryptedFrameCodec(sessionKey).stateScope(localID, peerID)
            return MessageDigest.getInstance("SHA-256").digest(scope.toByteArray(Charsets.UTF_8))
                .joinToString("") { "%02x".format(it) } + ".json"
        }

        private fun validRecord(record: ReconnectEndpointRecord): Boolean = runCatching {
            require(record.version == 1)
            validateIdentity(record.localID, "localID")
            validateIdentity(record.peerID, "peerID")
            require(strictUtf8(record.sessionID).size in 1..128)
            ReconnectPayloadPolicy.parseWireEndpoint(record.endpoint)
            val proof = Base64.getUrlDecoder().decode(record.proofID)
            require(record.proofID.length == 43 && proof.size == 32 &&
                Base64.getUrlEncoder().withoutPadding().encodeToString(proof) == record.proofID)
            if (record.tag.isNotEmpty()) require(Base64.getDecoder().decode(record.tag).size == 32)
        }.isSuccess

        private fun validateIdentity(value: String, field: String) {
            require(strictUtf8(value).size in 1..128) { "$field is invalid." }
        }

        private fun strictUtf8(value: String): ByteArray {
            val encoded = Charsets.UTF_8.newEncoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .encode(CharBuffer.wrap(value))
            return ByteArray(encoded.remaining()).also { encoded.get(it) }
        }

        private fun hmac(key: ByteArray, input: ByteArray): ByteArray = Mac.getInstance("HmacSHA256").run {
            init(SecretKeySpec(key, "HmacSHA256"))
            doFinal(input)
        }
    }
}
