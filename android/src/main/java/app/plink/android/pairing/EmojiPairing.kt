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

    fun derive(sourceDeviceId: String, targetDeviceId: String, nonce: String): Pair<String, String> {
        val input = "$sourceDeviceId|$targetDeviceId|$nonce"
        val digest = MessageDigest.getInstance("SHA-256").digest(input.toByteArray())
        val first = emoji[digest[0].toUByte().toInt() % emoji.size].second
        val second = emoji[digest[1].toUByte().toInt() % emoji.size].second
        return first to second
    }

    fun labels(sourceDeviceId: String, targetDeviceId: String, nonce: String): Pair<String, String> {
        val input = "$sourceDeviceId|$targetDeviceId|$nonce"
        val digest = MessageDigest.getInstance("SHA-256").digest(input.toByteArray())
        val first = emoji[digest[0].toUByte().toInt() % emoji.size].first
        val second = emoji[digest[1].toUByte().toInt() % emoji.size].first
        return first to second
    }
}
