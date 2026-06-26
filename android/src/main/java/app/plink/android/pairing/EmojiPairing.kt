package app.plink.android.pairing

import java.security.MessageDigest

object EmojiPairing {
    private val emoji = listOf(
        "sparkles" to "✨",
        "key" to "🔑",
        "bolt" to "⚡",
        "leaf" to "🍃",
        "moon" to "🌙",
        "sun" to "☀️",
        "wave" to "🌊",
        "gem" to "💎",
        "rocket" to "🚀",
        "lock" to "🔒",
        "bell" to "🔔",
        "cloud" to "☁️"
    )

    fun symbolsForDigest(digest: ByteArray, count: Int): List<String> =
        (0 until count).map { index -> emoji[digest[index].toUByte().toInt() % emoji.size].second }

    fun labelsForDigest(digest: ByteArray, count: Int): List<String> =
        (0 until count).map { index -> emoji[digest[index].toUByte().toInt() % emoji.size].first }

    fun derive(sourceDeviceId: String, targetDeviceId: String, nonce: String): Pair<String, String> {
        val input = "$sourceDeviceId|$targetDeviceId|$nonce"
        val digest = MessageDigest.getInstance("SHA-256").digest(input.toByteArray())
        val symbols = symbolsForDigest(digest, count = 2)
        return symbols[0] to symbols[1]
    }

    fun labels(sourceDeviceId: String, targetDeviceId: String, nonce: String): Pair<String, String> {
        val input = "$sourceDeviceId|$targetDeviceId|$nonce"
        val digest = MessageDigest.getInstance("SHA-256").digest(input.toByteArray())
        val labels = labelsForDigest(digest, count = 2)
        return labels[0] to labels[1]
    }
}
