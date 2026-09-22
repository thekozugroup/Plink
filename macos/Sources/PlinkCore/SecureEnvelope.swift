import CryptoKit
import Foundation
import Security

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

public struct EncryptedPlinkFrame: Codable, Equatable, Sendable {
    public var version: Int
    public var sequence: Int64
    public var nonce: String
    public var issuedAt: Date
    public var sourceDeviceId: String
    public var targetDeviceId: String
    public var cipherText: String
    public var signature: String
    var decodedIssuedAtLexeme: String?

    public init(
        version: Int = 1,
        sequence: Int64,
        nonce: String,
        issuedAt: Date,
        sourceDeviceId: String,
        targetDeviceId: String,
        cipherText: String,
        signature: String
    ) {
        self.version = version
        self.sequence = sequence
        self.nonce = nonce
        self.issuedAt = issuedAt
        self.sourceDeviceId = sourceDeviceId
        self.targetDeviceId = targetDeviceId
        self.cipherText = cipherText
        self.signature = signature
        self.decodedIssuedAtLexeme = nil
    }

    private enum CodingKeys: String, CodingKey {
        case version, sequence, nonce, issuedAt, sourceDeviceId, targetDeviceId, cipherText, signature
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        sequence = try values.decode(Int64.self, forKey: .sequence)
        nonce = try values.decode(String.self, forKey: .nonce)
        issuedAt = try values.decode(Date.self, forKey: .issuedAt)
        decodedIssuedAtLexeme = try values.decode(String.self, forKey: .issuedAt)
        sourceDeviceId = try values.decode(String.self, forKey: .sourceDeviceId)
        targetDeviceId = try values.decode(String.self, forKey: .targetDeviceId)
        cipherText = try values.decode(String.self, forKey: .cipherText)
        signature = try values.decode(String.self, forKey: .signature)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version)
        try values.encode(sequence, forKey: .sequence)
        try values.encode(nonce, forKey: .nonce)
        try values.encode(issuedAt, forKey: .issuedAt)
        try values.encode(sourceDeviceId, forKey: .sourceDeviceId)
        try values.encode(targetDeviceId, forKey: .targetDeviceId)
        try values.encode(cipherText, forKey: .cipherText)
        try values.encode(signature, forKey: .signature)
    }

    public static func == (lhs: EncryptedPlinkFrame, rhs: EncryptedPlinkFrame) -> Bool {
        lhs.version == rhs.version && lhs.sequence == rhs.sequence && lhs.nonce == rhs.nonce &&
            lhs.issuedAt == rhs.issuedAt && lhs.sourceDeviceId == rhs.sourceDeviceId &&
            lhs.targetDeviceId == rhs.targetDeviceId && lhs.cipherText == rhs.cipherText &&
            lhs.signature == rhs.signature
    }
}

public enum PayloadPolicyError: Error, Equatable {
    case unsupportedVersion
    case missingDeviceId
    case envelopeTooLarge
    case unsafeURL
    case invalidSignature
    case malformedFrame
    case replayDetected
    case staleFrame
    case deviceMismatch
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
        try FileTransferPayloadPolicy.validate(envelope)
        try ScreenPreviewPayloadPolicy.validate(envelope)
        try NotificationActionPolicy.validate(envelope)
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
        switch envelope.type {
        case .callRinging:
            try requireString(envelope.payload, key: "callerName", maxLength: 200)
            try requireString(envelope.payload, key: "callerHandle", maxLength: 200)
        case .messageReceived:
            try requireString(envelope.payload, key: "sender", maxLength: 200)
            try requireString(envelope.payload, key: "preview", maxLength: 4_000)
            if envelope.payload["canReply"]?.boolValue == true && !NotificationActionPolicy.hasExtension(envelope.payload) {
                try requireString(envelope.payload, key: "packageName", maxLength: 300)
                try requireString(envelope.payload, key: "notificationKey", maxLength: 500)
                try requireString(envelope.payload, key: "replyToken", maxLength: 200)
            }
        case .messageReply:
            try requireString(envelope.payload, key: "sourceEnvelopeId", maxLength: 200)
            try requireString(envelope.payload, key: "packageName", maxLength: 300)
            try requireString(envelope.payload, key: "notificationKey", maxLength: 500)
            try requireString(envelope.payload, key: "replyToken", maxLength: 200)
            try requireString(envelope.payload, key: "text", maxLength: 4_000)
        case .clipboardUpdated:
            try requireString(envelope.payload, key: "text", maxLength: 64 * 1024)
        default:
            break
        }
    }

    public static func redact(_ envelope: PlinkEnvelope) -> PlinkEnvelope {
        let sensitiveKeys: Set<String> = ["preview", "text", "callerHandle", "body", "message", "clipboard", "data", "name", "replyToken", "actionToken", "sourceEnvelopeId", "packageName", "notificationKey", "sourceAppName"]
        var payload = envelope.payload
        for key in payload.keys where sensitiveKeys.contains(key) || NotificationActionPolicy.isReserved(key) {
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

    private static func requireString(_ payload: [String: PayloadValue], key: String, maxLength: Int) throws {
        guard let value = payload[key]?.stringValue, !value.isEmpty else {
            throw PayloadPolicyError.missingDeviceId
        }
        // Android String.length counts UTF-16 code units, not grapheme clusters.
        guard value.utf16.count <= maxLength else {
            throw PayloadPolicyError.envelopeTooLarge
        }
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

public final class ReplayProtector: @unchecked Sendable {
    private let lock = NSLock()
    private let maxClockSkew: TimeInterval
    private let state = InMemoryFrameStateStore()

    public init(maxClockSkew: TimeInterval = 300) {
        self.maxClockSkew = maxClockSkew
    }

    public func accept(_ frame: EncryptedPlinkFrame, now: Date = .now) throws {
        try lock.withLock {
            guard abs(now.timeIntervalSince(frame.issuedAt)) <= maxClockSkew else {
                throw PayloadPolicyError.staleFrame
            }
            try state.accept(scope: "replay", sequence: frame.sequence, nonce: frame.nonce)
        }
    }
}

public struct EncryptedFrameCodec: Sendable {
    private let aesKey: SymmetricKey
    private let hmacKey: SymmetricKey
    private let keyScope: String
    private let makeIV: @Sendable () throws -> Data

    public init(sessionKey: Data) {
        self.init(sessionKey: sessionKey, randomIV: { try Self.randomIV() })
    }

    internal init(sessionKey: Data, randomIV: @escaping @Sendable () throws -> Data) {
        self.keyScope = Data(SHA256.hash(data: sessionKey)).base64EncodedString()
        self.aesKey = SymmetricKey(data: SHA256.hash(data: sessionKey))
        self.hmacKey = SymmetricKey(data: SHA256.hash(data: Data("plink-frame-hmac".utf8) + sessionKey))
        self.makeIV = randomIV
    }

    public func stateScope(sourceDeviceId: String, targetDeviceId: String) -> String {
        [keyScope, sourceDeviceId, targetDeviceId].map { "\($0.utf8.count):\($0)" }.joined()
    }

    public func seal(
        _ envelope: PlinkEnvelope,
        sequence: Int64,
        nonce: String = UUID().uuidString,
        issuedAt: Date = .now,
        iv: Data? = nil
    ) throws -> EncryptedPlinkFrame {
        try PayloadPolicy.validate(envelope)
        let authenticatedData = aad(
            version: 1,
            sequence: sequence,
            nonce: nonce,
            issuedAt: issuedAt,
            sourceDeviceId: envelope.sourceDeviceId,
            targetDeviceId: envelope.targetDeviceId
        )
        let sealed = try AES.GCM.seal(
            try CanonicalJSON.encode(envelope),
            using: aesKey,
            nonce: AES.GCM.Nonce(data: try iv ?? makeIV()),
            authenticating: authenticatedData
        )
        guard let combined = sealed.combined else { throw PayloadPolicyError.malformedFrame }
        var frame = EncryptedPlinkFrame(
            sequence: sequence,
            nonce: nonce,
            issuedAt: issuedAt,
            sourceDeviceId: envelope.sourceDeviceId,
            targetDeviceId: envelope.targetDeviceId,
            cipherText: combined.base64EncodedString(),
            signature: ""
        )
        frame.signature = signature(for: frame)
        return frame
    }

    public func open(
        _ frame: EncryptedPlinkFrame,
        replayProtector: ReplayProtector? = nil,
        now: Date = .now,
        expectedSourceDeviceId: String? = nil,
        expectedTargetDeviceId: String? = nil,
        stateStore: (any FrameStateStoring)? = nil,
        wireBytes: Int? = nil,
        rawFrameData: Data? = nil,
        reconnectValidation: ReconnectValidationPolicy = .production
    ) throws -> PlinkEnvelope {
        guard frame.version == 1 else { throw PayloadPolicyError.unsupportedVersion }
        if let expectedSourceDeviceId, frame.sourceDeviceId != expectedSourceDeviceId {
            throw PayloadPolicyError.deviceMismatch
        }
        if let expectedTargetDeviceId, frame.targetDeviceId != expectedTargetDeviceId {
            throw PayloadPolicyError.deviceMismatch
        }
        var unsigned = frame
        unsigned.signature = ""
        guard let signatureBytes = Data(base64Encoded: frame.signature),
              HMAC<SHA256>.isValidAuthenticationCode(signatureBytes, authenticating: Data(signingInput(unsigned).utf8), using: hmacKey)
        else { throw PayloadPolicyError.invalidSignature }
        guard let combined = Data(base64Encoded: frame.cipherText) else {
            throw PayloadPolicyError.malformedFrame
        }
        let sealed = try AES.GCM.SealedBox(combined: combined)
        let data = try AES.GCM.open(sealed, using: aesKey, authenticating: aad(frame))
        let decoded = Result { try PlinkEnvelope.decode(data, reconnectValidation: reconnectValidation) }
        guard let envelope = try? decoded.get() else {
            if let rejection = ScreenPreviewPayloadPolicy.rejection(
                fromAuthenticatedPlaintext: data,
                sourceDeviceID: frame.sourceDeviceId,
                targetDeviceID: frame.targetDeviceId
            ) {
                try acceptAuthenticatedFrame(
                    frame,
                    replayProtector: replayProtector,
                    stateStore: stateStore,
                    now: now
                )
                throw rejection
            }
            return try decoded.get()
        }
        guard envelope.sourceDeviceId == frame.sourceDeviceId, envelope.targetDeviceId == frame.targetDeviceId else {
            throw PayloadPolicyError.deviceMismatch
        }
        if let expectedSourceDeviceId, envelope.sourceDeviceId != expectedSourceDeviceId {
            throw PayloadPolicyError.deviceMismatch
        }
        if let expectedTargetDeviceId, envelope.targetDeviceId != expectedTargetDeviceId {
            throw PayloadPolicyError.deviceMismatch
        }
        if ScreenPreviewPayloadPolicy.eventTypes.contains(envelope.type) {
            try acceptAuthenticatedFrame(frame, replayProtector: replayProtector, stateStore: stateStore, now: now)
            do {
                guard wireBytes.map({ $0 <= ScreenPreviewProtocol.maxScreenWireBytes }) ?? true else {
                    throw PayloadPolicyError.envelopeTooLarge
                }
                try PayloadPolicy.validate(envelope)
            } catch {
                if let rejection = ScreenPreviewPayloadPolicy.rejection(
                    fromAuthenticatedPlaintext: data,
                    sourceDeviceID: frame.sourceDeviceId,
                    targetDeviceID: frame.targetDeviceId
                ) {
                    throw rejection
                }
                throw error
            }
        } else {
            if ReconnectPayloadPolicy.eventTypes.contains(envelope.type) {
                try ReconnectPayloadPolicy.validateEncryptedFrame(
                    issuedAt: frame.issuedAt,
                    decodedIssuedAtLexeme: frame.decodedIssuedAtLexeme,
                    rawJSON: rawFrameData
                )
            }
            try ReconnectPayloadPolicy.validate(
                envelope,
                validation: reconnectValidation,
                plaintextBytes: data.count,
                encryptedBytes: wireBytes
            )
            try PayloadPolicy.validate(envelope)
            try acceptAuthenticatedFrame(frame, replayProtector: replayProtector, stateStore: stateStore, now: now)
        }
        return envelope
    }

    private func acceptAuthenticatedFrame(
        _ frame: EncryptedPlinkFrame,
        replayProtector: ReplayProtector?,
        stateStore: (any FrameStateStoring)?,
        now: Date
    ) throws {
        guard abs(now.timeIntervalSince(frame.issuedAt)) <= 300 else { throw PayloadPolicyError.staleFrame }
        try replayProtector?.accept(frame, now: now)
        try stateStore?.accept(
            scope: stateScope(sourceDeviceId: frame.sourceDeviceId, targetDeviceId: frame.targetDeviceId),
            sequence: frame.sequence,
            nonce: frame.nonce
        )
    }

    private func signature(for frame: EncryptedPlinkFrame) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(signingInput(frame).utf8), using: hmacKey)
        return Data(mac).base64EncodedString()
    }

    private func signingInput(_ frame: EncryptedPlinkFrame) -> String {
        [
            "\(frame.version)",
            "\(frame.sequence)",
            frame.nonce,
            ISO8601DateFormatter().string(from: frame.issuedAt),
            frame.sourceDeviceId,
            frame.targetDeviceId,
            frame.cipherText
        ].joined(separator: "\n")
    }

    private func aad(_ frame: EncryptedPlinkFrame) -> Data {
        aad(
            version: frame.version,
            sequence: frame.sequence,
            nonce: frame.nonce,
            issuedAt: frame.issuedAt,
            sourceDeviceId: frame.sourceDeviceId,
            targetDeviceId: frame.targetDeviceId
        )
    }

    private func aad(
        version: Int,
        sequence: Int64,
        nonce: String,
        issuedAt: Date,
        sourceDeviceId: String,
        targetDeviceId: String
    ) -> Data {
        [
            "\(version)",
            "\(sequence)",
            nonce,
            ISO8601DateFormatter().string(from: issuedAt),
            sourceDeviceId,
            targetDeviceId
        ].joined(separator: "\n").data(using: .utf8) ?? Data()
    }

    public static func randomIV() throws -> Data {
        try randomIV { count, buffer in SecRandomCopyBytes(kSecRandomDefault, count, buffer) }
    }

    internal static func randomIV(using fill: (Int, UnsafeMutableRawPointer) -> OSStatus) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 12)
        let status = bytes.withUnsafeMutableBytes { buffer in fill(buffer.count, buffer.baseAddress!) }
        guard status == errSecSuccess else { throw SecureRandomError.unavailable(status) }
        return Data(bytes)
    }
}

public enum SecureRandomError: Error, Equatable, Sendable {
    case unavailable(OSStatus)
}

enum CanonicalJSON {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        try PlinkJSON.encoder(sortedKeys: true).encode(value)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
