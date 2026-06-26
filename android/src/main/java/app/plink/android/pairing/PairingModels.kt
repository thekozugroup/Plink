package app.plink.android.pairing

import java.util.Base64
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

@Serializable
data class PairingOffer(
    val deviceId: String,
    val deviceName: String,
    val platform: String,
    val endpoint: String,
    val nonce: String,
    val publicKey: String,
    val targetDeviceId: String = "mac-demo",
    val protocolVersion: Int = 1
) {
    val emojiCode: Pair<String, String>
        get() = EmojiPairing.derive(deviceId, targetDeviceId, nonce)
}

@Serializable
data class PairedDevice(
    val id: String,
    val name: String,
    val platform: String,
    val endpoint: String,
    val sessionId: String,
    val peerPublicKey: String,
    val localPublicKey: String,
    val trusted: Boolean
)

@Serializable
data class PairingConfirmation(
    val deviceId: String,
    val deviceName: String,
    val platform: String,
    val endpoint: String,
    val publicKey: String,
    val targetDeviceId: String,
    val offerNonce: String,
    val sessionId: String,
    val protocolVersion: Int = 1
)

object PairingPayloadCodec {
    private const val PREFIX = "plink1:"
    private val json = Json { encodeDefaults = true; ignoreUnknownKeys = true }

    fun encodeOffer(offer: PairingOffer): String = encode(offer)

    fun decodeOffer(payload: String): PairingOffer = decode(payload)

    fun encodeConfirmation(confirmation: PairingConfirmation): String = encode(confirmation)

    fun decodeConfirmation(payload: String): PairingConfirmation = decode(payload)

    private inline fun <reified T> encode(value: T): String {
        val bytes = json.encodeToString(value).toByteArray(Charsets.UTF_8)
        return PREFIX + Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)
    }

    private inline fun <reified T> decode(payload: String): T {
        val normalized = payload.trim()
        require(normalized.startsWith(PREFIX)) { "Pairing payload must start with $PREFIX." }
        val bytes = Base64.getUrlDecoder().decode(normalized.removePrefix(PREFIX))
        return json.decodeFromString(bytes.decodeToString())
    }
}

sealed interface PairingStatus {
    data object Idle : PairingStatus
    data class ShowingCode(
        val offer: PairingOffer,
        val emoji: Pair<String, String>,
        val verificationCode: PairingVerificationCode
    ) : PairingStatus
    data class Paired(val device: PairedDevice) : PairingStatus
    data class Rejected(val reason: String) : PairingStatus
}
