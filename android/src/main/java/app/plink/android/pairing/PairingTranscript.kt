package app.plink.android.pairing

import java.security.MessageDigest

data class PairingVerificationCode(
    val emoji: List<String>,
    val labels: List<String>,
    val numeric: String
)

object PairingTranscript {
    fun canonical(
        sourceDeviceId: String,
        targetDeviceId: String,
        endpoint: String,
        nonce: String,
        sourcePublicKey: String,
        targetPublicKey: String,
        protocolVersion: Int
    ): String = listOf(
        "plink-pairing-v$protocolVersion",
        sourceDeviceId,
        targetDeviceId,
        endpoint,
        nonce,
        sourcePublicKey,
        targetPublicKey
    ).joinToString("|")

    fun verificationCode(transcript: String): PairingVerificationCode {
        val digest = MessageDigest.getInstance("SHA-256").digest(transcript.toByteArray(Charsets.UTF_8))
        val emoji = EmojiPairing.symbolsForDigest(digest, count = 4)
        val labels = EmojiPairing.labelsForDigest(digest, count = 4)
        val numeric = digest.take(4)
            .fold(0) { acc, byte -> (acc shl 8) or (byte.toInt() and 0xff) }
            .mod(1_000_000)
            .toString()
            .padStart(6, '0')
        return PairingVerificationCode(emoji = emoji, labels = labels, numeric = numeric)
    }
}
