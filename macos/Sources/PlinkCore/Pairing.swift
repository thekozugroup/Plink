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

public enum PairingStatus: Equatable, Sendable {
    case idle
    case showingCode(PairingOffer, String, String)
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

    public func receive(_ offer: PairingOffer) -> PairingStatus {
        let code = offer.emojiCode
        let next = PairingStatus.showingCode(offer, code.0, code.1)
        lock.withLock { current = next }
        return next
    }

    public func confirm() throws -> PairingStatus {
        let offer: PairingOffer? = lock.withLock {
            if case .showingCode(let offer, _, _) = current { return offer }
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

    public func reject(_ reason: String) -> PairingStatus {
        let next = PairingStatus.rejected(reason)
        lock.withLock { current = next }
        return next
    }

    public var localPublicKeyBase64: String {
        localPrivateKey.publicKey.derRepresentation.base64EncodedString()
    }

    private static func deriveSession(
        _ offer: PairingOffer,
        localPrivateKey: P256.KeyAgreement.PrivateKey
    ) throws -> (sessionId: String, key: SymmetricKey) {
        guard !offer.publicKey.isEmpty else { throw PairingError.invalidPublicKey }
        let peerKey = try P256.KeyAgreement.PublicKey(derRepresentation: Data(base64Encoded: offer.publicKey) ?? Data())
        let sharedSecret = try localPrivateKey.sharedSecretFromKeyAgreement(with: peerKey)
        let transcript = "\(offer.deviceId)|\(offer.targetDeviceId)|\(offer.endpoint)|plink-v\(offer.protocolVersion)"
        let key = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(SHA256.hash(data: Data(offer.nonce.utf8))),
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
