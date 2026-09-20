package app.plink.android.pairing

import java.security.MessageDigest
import java.util.Base64
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/** A key preview never authorizes notification forwarding or persistence of trust. */
@Serializable
data class PairingConsent(
    val version: Int = 1,
    val stage: String,
    val confirmation: PairingConfirmation,
    val proof: String
) {
    fun verified(sessionKey: ByteArray): Boolean = runCatching {
        require(version == 1 && stage in setOf("preview", "confirmed") && sessionKey.size == 32)
        MessageDigest.isEqual(Base64.getDecoder().decode(proof), signature(stage, confirmation, sessionKey))
    }.getOrDefault(false)

    fun encode(): String = json.encodeToString(this).also { require(it.toByteArray().size <= 16_384) }

    companion object {
        private val json = Json { encodeDefaults = true; ignoreUnknownKeys = false }
        fun create(stage: String, confirmation: PairingConfirmation, sessionKey: ByteArray): PairingConsent {
            require(stage in setOf("preview", "confirmed") && sessionKey.size == 32)
            return PairingConsent(stage = stage, confirmation = confirmation, proof = Base64.getEncoder().encodeToString(signature(stage, confirmation, sessionKey)))
        }
        fun decode(payload: String): PairingConsent {
            require(payload.toByteArray().size <= 16_384 && payload.trimStart().startsWith("{"))
            return json.decodeFromString<PairingConsent>(payload).also {
                require(it.version == 1 && it.stage in setOf("preview", "confirmed"))
            }
        }
        private fun signature(stage: String, value: PairingConfirmation, key: ByteArray): ByteArray {
            val fields = listOf("plink-consent-v1", stage, value.deviceId, value.deviceName, value.platform,
                value.endpoint, value.publicKey, value.targetDeviceId, value.offerNonce, value.sessionId,
                value.protocolVersion.toString())
            val input = fields.joinToString("") { "${it.toByteArray(Charsets.UTF_8).size}:$it" }
            return Mac.getInstance("HmacSHA256").run {
                init(SecretKeySpec(key, "HmacSHA256"))
                doFinal(input.toByteArray(Charsets.UTF_8))
            }
        }
    }
}
