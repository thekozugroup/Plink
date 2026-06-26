import CryptoKit
import Foundation

public struct PairingOffer: Codable, Equatable, Sendable {
    public var deviceId: String
    public var deviceName: String
    public var platform: String
    public var endpoint: String
    public var nonce: String
    public var publicKey: String
    public var targetDeviceId: String
    public var protocolVersion: Int

    public init(
        deviceId: String,
        deviceName: String,
        platform: String,
        endpoint: String,
        nonce: String,
        publicKey: String,
        targetDeviceId: String = "mac-demo",
        protocolVersion: Int = 1
    ) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.platform = platform
        self.endpoint = endpoint
        self.nonce = nonce
        self.publicKey = publicKey
        self.targetDeviceId = targetDeviceId
        self.protocolVersion = protocolVersion
    }

    public var emojiCode: (String, String) {
        EmojiPairing.derive(sourceDeviceId: deviceId, targetDeviceId: targetDeviceId, nonce: nonce)
    }
}

public struct PairedDevice: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var platform: String
    public var endpoint: String
    public var sessionId: String
    public var peerPublicKey: String
    public var localPublicKey: String
    public var trusted: Bool

    public init(
        id: String,
        name: String,
        platform: String,
        endpoint: String,
        sessionId: String,
        peerPublicKey: String,
        localPublicKey: String,
        trusted: Bool
    ) {
        self.id = id
        self.name = name
        self.platform = platform
        self.endpoint = endpoint
        self.sessionId = sessionId
        self.peerPublicKey = peerPublicKey
        self.localPublicKey = localPublicKey
        self.trusted = trusted
    }
}

public struct PairingConfirmation: Codable, Equatable, Sendable {
    public var deviceId: String
    public var deviceName: String
    public var platform: String
    public var endpoint: String
    public var publicKey: String
    public var targetDeviceId: String
    public var offerNonce: String
    public var sessionId: String
    public var protocolVersion: Int

    public init(
        deviceId: String,
        deviceName: String,
        platform: String,
        endpoint: String,
        publicKey: String,
        targetDeviceId: String,
        offerNonce: String,
        sessionId: String,
        protocolVersion: Int = 1
    ) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.platform = platform
        self.endpoint = endpoint
        self.publicKey = publicKey
        self.targetDeviceId = targetDeviceId
        self.offerNonce = offerNonce
        self.sessionId = sessionId
        self.protocolVersion = protocolVersion
    }
}

public enum PairingPayloadError: Error, Equatable {
    case invalidPrefix
    case invalidPayload
    case staleOffer
    case wrongTarget
    case sessionMismatch
}

public enum PairingPayloadCodec {
    private static let prefix = "plink1:"

    public static func encodeOffer(_ offer: PairingOffer) throws -> String {
        try encode(offer)
    }

    public static func decodeOffer(_ payload: String) throws -> PairingOffer {
        try decode(payload)
    }

    public static func encodeConfirmation(_ confirmation: PairingConfirmation) throws -> String {
        try encode(confirmation)
    }

    public static func decodeConfirmation(_ payload: String) throws -> PairingConfirmation {
        try decode(payload)
    }

    private static func encode<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        return prefix + data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decode<T: Decodable>(_ payload: String) throws -> T {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(prefix) else { throw PairingPayloadError.invalidPrefix }
        var encoded = String(trimmed.dropFirst(prefix.count))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while encoded.count % 4 != 0 {
            encoded.append("=")
        }
        guard let data = Data(base64Encoded: encoded) else {
            throw PairingPayloadError.invalidPayload
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

public enum PairingStatus: Equatable, Sendable {
    case idle
    case showingCode(PairingOffer, String, String, PairingVerificationCode)
    case paired(PairedDevice)
    case rejected(String)
}

public enum PairingError: Error, Equatable {
    case noOfferToConfirm
    case invalidPublicKey
}

public final class PairingStateMachine: @unchecked Sendable {
    private let lock = NSLock()
    private var current: PairingStatus = .idle
    private let localPrivateKey: P256.KeyAgreement.PrivateKey
    public private(set) var lastSessionKey: SymmetricKey?

    public init(localPrivateKey: P256.KeyAgreement.PrivateKey = P256.KeyAgreement.PrivateKey()) {
        self.localPrivateKey = localPrivateKey
    }

    public var status: PairingStatus {
        lock.withLock { current }
    }

    public func makeOffer(
        deviceId: String,
        deviceName: String,
        platform: String = "macos",
        endpoint: String,
        targetDeviceId: String = "pixel-pending",
        nonce: String = UUID().uuidString
    ) -> PairingOffer {
        PairingOffer(
            deviceId: deviceId,
            deviceName: deviceName,
            platform: platform,
            endpoint: endpoint,
            nonce: nonce,
            publicKey: localPublicKeyBase64,
            targetDeviceId: targetDeviceId
        )
    }

    public func receive(_ offer: PairingOffer) -> PairingStatus {
        let code = offer.emojiCode
        let next = PairingStatus.showingCode(
            offer,
            code.0,
            code.1,
            PairingTranscript.verificationCode(transcript: pairingTranscript(offer))
        )
        lock.withLock { current = next }
        return next
    }

    public func confirm() throws -> PairingStatus {
        let offer: PairingOffer? = lock.withLock {
            if case .showingCode(let offer, _, _, _) = current { return offer }
            return nil
        }
        guard let offer else { throw PairingError.noOfferToConfirm }
        let session = try Self.deriveSession(
            offer,
            localPrivateKey: localPrivateKey
        )
        lastSessionKey = session.key
        let device = PairedDevice(
            id: offer.deviceId,
            name: offer.deviceName,
            platform: offer.platform,
            endpoint: offer.endpoint,
            sessionId: session.sessionId,
            peerPublicKey: offer.publicKey,
            localPublicKey: localPublicKeyBase64,
            trusted: true
        )
        let next = PairingStatus.paired(device)
        lock.withLock { current = next }
        return next
    }

    public func verificationCode(for offer: PairingOffer, confirmation: PairingConfirmation) -> PairingVerificationCode {
        PairingTranscript.verificationCode(
            transcript: PairingTranscript.canonical(
                sourceDeviceId: offer.deviceId,
                targetDeviceId: confirmation.deviceId,
                endpoint: offer.endpoint,
                nonce: offer.nonce,
                sourcePublicKey: offer.publicKey,
                targetPublicKey: confirmation.publicKey,
                protocolVersion: offer.protocolVersion
            )
        )
    }

    public func accept(_ confirmation: PairingConfirmation, for offer: PairingOffer) throws -> PairingStatus {
        guard confirmation.offerNonce == offer.nonce else { throw PairingPayloadError.staleOffer }
        guard confirmation.targetDeviceId == offer.deviceId else { throw PairingPayloadError.wrongTarget }
        let session = try Self.deriveSession(
            peerPublicKey: confirmation.publicKey,
            sourceDeviceId: offer.deviceId,
            targetDeviceId: confirmation.deviceId,
            endpoint: offer.endpoint,
            nonce: offer.nonce,
            sourcePublicKey: offer.publicKey,
            targetPublicKey: confirmation.publicKey,
            protocolVersion: offer.protocolVersion,
            localPrivateKey: localPrivateKey
        )
        guard session.sessionId == confirmation.sessionId else { throw PairingPayloadError.sessionMismatch }
        lastSessionKey = session.key
        let device = PairedDevice(
            id: confirmation.deviceId,
            name: confirmation.deviceName,
            platform: confirmation.platform,
            endpoint: confirmation.endpoint,
            sessionId: session.sessionId,
            peerPublicKey: confirmation.publicKey,
            localPublicKey: localPublicKeyBase64,
            trusted: true
        )
        let next = PairingStatus.paired(device)
        lock.withLock { current = next }
        return next
    }

    public func reject(_ reason: String) -> PairingStatus {
        let next = PairingStatus.rejected(reason)
        lock.withLock { current = next }
        return next
    }

    public var localPublicKeyBase64: String {
        localPrivateKey.publicKey.derRepresentation.base64EncodedString()
    }

    private func pairingTranscript(_ offer: PairingOffer) -> String {
        PairingTranscript.canonical(
            sourceDeviceId: offer.deviceId,
            targetDeviceId: offer.targetDeviceId,
            endpoint: offer.endpoint,
            nonce: offer.nonce,
            sourcePublicKey: offer.publicKey,
            targetPublicKey: localPublicKeyBase64,
            protocolVersion: offer.protocolVersion
        )
    }

    private static func deriveSession(
        _ offer: PairingOffer,
        localPrivateKey: P256.KeyAgreement.PrivateKey
    ) throws -> (sessionId: String, key: SymmetricKey) {
        try deriveSession(
            peerPublicKey: offer.publicKey,
            sourceDeviceId: offer.deviceId,
            targetDeviceId: offer.targetDeviceId,
            endpoint: offer.endpoint,
            nonce: offer.nonce,
            sourcePublicKey: offer.publicKey,
            targetPublicKey: localPrivateKey.publicKey.derRepresentation.base64EncodedString(),
            protocolVersion: offer.protocolVersion,
            localPrivateKey: localPrivateKey
        )
    }

    private static func deriveSession(
        peerPublicKey: String,
        sourceDeviceId: String,
        targetDeviceId: String,
        endpoint: String,
        nonce: String,
        sourcePublicKey: String,
        targetPublicKey: String,
        protocolVersion: Int,
        localPrivateKey: P256.KeyAgreement.PrivateKey
    ) throws -> (sessionId: String, key: SymmetricKey) {
        guard !peerPublicKey.isEmpty else { throw PairingError.invalidPublicKey }
        let peerKey = try P256.KeyAgreement.PublicKey(derRepresentation: Data(base64Encoded: peerPublicKey) ?? Data())
        let sharedSecret = try localPrivateKey.sharedSecretFromKeyAgreement(with: peerKey)
        let transcript = PairingTranscript.canonical(
            sourceDeviceId: sourceDeviceId,
            targetDeviceId: targetDeviceId,
            endpoint: endpoint,
            nonce: nonce,
            sourcePublicKey: sourcePublicKey,
            targetPublicKey: targetPublicKey,
            protocolVersion: protocolVersion
        )
        let key = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(SHA256.hash(data: Data(nonce.utf8))),
            sharedInfo: Data("plink-session-v1|\(transcript)".utf8),
            outputByteCount: 32
        )
        let keyBytes = key.withUnsafeBytes { Data($0) }
        let sessionId = SHA256.hash(data: keyBytes)
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(32)
            .description
        return (sessionId, key)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
