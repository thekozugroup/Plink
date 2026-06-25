import CryptoKit
import Foundation

public struct SecurePlinkEnvelope: Codable, Equatable, Sendable {
    public var envelope: PlinkEnvelope
    public var sequence: Int64
    public var nonce: String
    public var issuedAt: Date
    public var signature: String

    public init(
        envelope: PlinkEnvelope,
        sequence: Int64,
        nonce: String,
        issuedAt: Date,
        signature: String
    ) {
        self.envelope = envelope
        self.sequence = sequence
        self.nonce = nonce
        self.issuedAt = issuedAt
        self.signature = signature
    }
}

public enum PayloadPolicyError: Error, Equatable {
    case unsupportedVersion
    case missingDeviceId
    case envelopeTooLarge
    case unsafeURL
}

public enum PayloadPolicy {
    public static let maxEnvelopeBytes = 64 * 1024
    private static let allowedURLSchemes: Set<String> = ["http", "https"]

    public static func validate(_ envelope: PlinkEnvelope) throws {
        guard envelope.version == 1 else { throw PayloadPolicyError.unsupportedVersion }
        guard !envelope.id.isEmpty, !envelope.sourceDeviceId.isEmpty, !envelope.targetDeviceId.isEmpty else {
            throw PayloadPolicyError.missingDeviceId
        }
        guard try CanonicalJSON.encode(envelope).count <= maxEnvelopeBytes else {
            throw PayloadPolicyError.envelopeTooLarge
        }
        if envelope.type == .webOpen {
            guard
                let rawURL = envelope.payload["url"]?.stringValue,
                let url = URL(string: rawURL),
                let scheme = url.scheme?.lowercased(),
                allowedURLSchemes.contains(scheme)
            else {
                throw PayloadPolicyError.unsafeURL
            }
        }
    }

    public static func redact(_ envelope: PlinkEnvelope) -> PlinkEnvelope {
        let sensitiveKeys: Set<String> = ["preview", "text", "callerHandle", "body", "message", "clipboard"]
        var payload = envelope.payload
        for key in sensitiveKeys where payload[key] != nil {
            payload[key] = .string("[redacted]")
        }
        var redacted = envelope
        redacted.payload = payload
        return redacted
    }

    public static func isAllowedURL(_ rawURL: String) -> Bool {
        guard
            let url = URL(string: rawURL),
            let scheme = url.scheme?.lowercased()
        else { return false }
        return allowedURLSchemes.contains(scheme)
    }
}

public struct SecureEnvelopeCodec: Sendable {
    private let key: SymmetricKey

    public init(sessionKey: Data) {
        self.key = SymmetricKey(data: SHA256.hash(data: sessionKey))
    }

    public func seal(
        _ envelope: PlinkEnvelope,
        sequence: Int64,
        nonce: String = UUID().uuidString,
        issuedAt: Date = .now
    ) throws -> SecurePlinkEnvelope {
        try PayloadPolicy.validate(envelope)
        let unsigned = SecurePlinkEnvelope(
            envelope: envelope,
            sequence: sequence,
            nonce: nonce,
            issuedAt: issuedAt,
            signature: ""
        )
        return SecurePlinkEnvelope(
            envelope: envelope,
            sequence: sequence,
            nonce: nonce,
            issuedAt: issuedAt,
            signature: try signature(for: unsigned)
        )
    }

    public func open(_ secureEnvelope: SecurePlinkEnvelope) throws -> PlinkEnvelope {
        let expected = try signature(for: SecurePlinkEnvelope(
            envelope: secureEnvelope.envelope,
            sequence: secureEnvelope.sequence,
            nonce: secureEnvelope.nonce,
            issuedAt: secureEnvelope.issuedAt,
            signature: ""
        ))
        guard expected == secureEnvelope.signature else {
            throw PayloadPolicyError.missingDeviceId
        }
        try PayloadPolicy.validate(secureEnvelope.envelope)
        return secureEnvelope.envelope
    }

    private func signature(for secureEnvelope: SecurePlinkEnvelope) throws -> String {
        let issuedAt = ISO8601DateFormatter().string(from: secureEnvelope.issuedAt)
        let envelopeJSON = String(data: try CanonicalJSON.encode(secureEnvelope.envelope), encoding: .utf8) ?? "{}"
        let input = "\(secureEnvelope.sequence)\n\(issuedAt)\n\(secureEnvelope.nonce)\n\(envelopeJSON)"
        let mac = HMAC<SHA256>.authenticationCode(for: Data(input.utf8), using: key)
        return Data(mac).base64EncodedString()
    }
}

enum CanonicalJSON {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
}
