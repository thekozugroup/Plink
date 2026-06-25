import CryptoKit
import Foundation

public enum EmojiPairing {
    private static let emoji: [(label: String, symbol: String)] = [
        ("sparkles", "✨"),
        ("key", "🔑"),
        ("bolt", "⚡"),
        ("leaf", "🍃"),
        ("moon", "🌙"),
        ("sun", "☀️"),
        ("wave", "🌊"),
        ("gem", "💎"),
        ("rocket", "🚀"),
        ("lock", "🔒"),
        ("bell", "🔔"),
        ("cloud", "☁️")
    ]

    public static func derive(sourceDeviceId: String, targetDeviceId: String, nonce: String) -> (String, String) {
        let input = "\(sourceDeviceId)|\(targetDeviceId)|\(nonce)"
        let digest = SHA256.hash(data: Data(input.utf8))
        let bytes = Array(digest)
        return (emoji[Int(bytes[0]) % emoji.count].symbol, emoji[Int(bytes[1]) % emoji.count].symbol)
    }

    public static func labels(sourceDeviceId: String, targetDeviceId: String, nonce: String) -> (String, String) {
        let input = "\(sourceDeviceId)|\(targetDeviceId)|\(nonce)"
        let digest = SHA256.hash(data: Data(input.utf8))
        let bytes = Array(digest)
        return (emoji[Int(bytes[0]) % emoji.count].label, emoji[Int(bytes[1]) % emoji.count].label)
    }
}
