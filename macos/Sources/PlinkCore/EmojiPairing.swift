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

    public static func symbols(for digest: [UInt8], count: Int) -> [String] {
        (0..<count).map { index in emoji[Int(digest[index]) % emoji.count].symbol }
    }

    public static func labels(for digest: [UInt8], count: Int) -> [String] {
        (0..<count).map { index in emoji[Int(digest[index]) % emoji.count].label }
    }

    public static func derive(sourceDeviceId: String, targetDeviceId: String, nonce: String) -> (String, String) {
        let input = "\(sourceDeviceId)|\(targetDeviceId)|\(nonce)"
        let digest = SHA256.hash(data: Data(input.utf8))
        let bytes = Array(digest)
        let symbols = symbols(for: bytes, count: 2)
        return (symbols[0], symbols[1])
    }

    public static func labels(sourceDeviceId: String, targetDeviceId: String, nonce: String) -> (String, String) {
        let input = "\(sourceDeviceId)|\(targetDeviceId)|\(nonce)"
        let digest = SHA256.hash(data: Data(input.utf8))
        let bytes = Array(digest)
        let labels = labels(for: bytes, count: 2)
        return (labels[0], labels[1])
    }
}

public struct PairingVerificationCode: Equatable, Sendable {
    public var emoji: [String]
    public var labels: [String]
    public var numeric: String

    public init(emoji: [String], labels: [String], numeric: String) {
        self.emoji = emoji
        self.labels = labels
        self.numeric = numeric
    }
}

public enum PairingTranscript {
    public static func canonical(
        sourceDeviceId: String,
        targetDeviceId: String,
        endpoint: String,
        nonce: String,
        sourcePublicKey: String,
        targetPublicKey: String,
        protocolVersion: Int
    ) -> String {
        [
            "plink-pairing-v\(protocolVersion)",
            sourceDeviceId,
            targetDeviceId,
            endpoint,
            nonce,
            sourcePublicKey,
            targetPublicKey
        ].joined(separator: "|")
    }

    public static func verificationCode(transcript: String) -> PairingVerificationCode {
        let digest = Array(SHA256.hash(data: Data(transcript.utf8)))
        let emoji = EmojiPairing.symbols(for: digest, count: 4)
        let labels = EmojiPairing.labels(for: digest, count: 4)
        let numericValue = digest.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } % 1_000_000
        return PairingVerificationCode(
            emoji: emoji,
            labels: labels,
            numeric: String(format: "%06d", numericValue)
        )
    }
}
