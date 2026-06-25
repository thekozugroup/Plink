import CryptoKit
import Foundation

public struct PairingOffer: Codable, Equatable, Sendable {
    public var deviceId: String
    public var deviceName: String
    public var platform: String
    public var endpoint: String
    public var nonce: String
    public var protocolVersion: Int

    public init(
        deviceId: String,
        deviceName: String,
        platform: String,
        endpoint: String,
        nonce: String,
        protocolVersion: Int = 1
    ) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.platform = platform
        self.endpoint = endpoint
        self.nonce = nonce
        self.protocolVersion = protocolVersion
    }

    public var emojiCode: (String, String) {
        EmojiPairing.derive(sourceDeviceId: deviceId, targetDeviceId: "mac", nonce: nonce)
    }
}

public struct PairedDevice: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var platform: String
    public var endpoint: String
    public var sessionId: String
    public var trusted: Bool

    public init(id: String, name: String, platform: String, endpoint: String, sessionId: String, trusted: Bool) {
        self.id = id
        self.name = name
        self.platform = platform
        self.endpoint = endpoint
        self.sessionId = sessionId
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
}

public final class PairingStateMachine: @unchecked Sendable {
    private let lock = NSLock()
    private var current: PairingStatus = .idle

    public init() {}

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
        let device = PairedDevice(
            id: offer.deviceId,
            name: offer.deviceName,
            platform: offer.platform,
            endpoint: offer.endpoint,
            sessionId: Self.deriveSessionId(offer),
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

    private static func deriveSessionId(_ offer: PairingOffer) -> String {
        let input = "\(offer.deviceId)|\(offer.endpoint)|\(offer.nonce)|plink-v\(offer.protocolVersion)"
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(32).description
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
