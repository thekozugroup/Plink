package app.plink.android.pairing

import java.security.MessageDigest

object EmojiPairing {
    private val emoji = listOf(
        "sparkles",
        "key",
        "bolt",
        "leaf",
        "moon",
        "sun",
        "wave",
        "gem",
        "rocket",
        "lock",
        "bell",
        "cloud"
    )

    fun derive(sourceDeviceId: String, targetDeviceId: String, nonce: String): Pair<String, String> {
        val input = "$sourceDeviceId|$targetDeviceId|$nonce"
        val digest = MessageDigest.getInstance("SHA-256").digest(input.toByteArray())
        val first = emoji[digest[0].toUByte().toInt() % emoji.size]
        val second = emoji[digest[1].toUByte().toInt() % emoji.size]
        return first to second
    }
}
