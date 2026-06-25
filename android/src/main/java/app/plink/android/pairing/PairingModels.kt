package app.plink.android.pairing

import kotlinx.serialization.Serializable

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

sealed interface PairingStatus {
    data object Idle : PairingStatus
    data class ShowingCode(val offer: PairingOffer, val emoji: Pair<String, String>) : PairingStatus
    data class Paired(val device: PairedDevice) : PairingStatus
    data class Rejected(val reason: String) : PairingStatus
}
