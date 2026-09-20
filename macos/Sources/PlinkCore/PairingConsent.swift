import CryptoKit
import Foundation

/// A preview exchanges keys; only a confirmed message records the phone user's consent.
public struct PairingConsent: Codable, Equatable, Sendable {
    public enum Stage: String, Codable, Sendable { case preview, confirmed }
    public var version: Int = 1
    public var stage: Stage
    public var confirmation: PairingConfirmation
    public var proof: String

    public static func signingInput(stage: Stage, confirmation: PairingConfirmation) -> Data {
        let fields = ["plink-consent-v1", stage.rawValue, confirmation.deviceId, confirmation.deviceName,
                      confirmation.platform, confirmation.endpoint, confirmation.publicKey,
                      confirmation.targetDeviceId, confirmation.offerNonce, confirmation.sessionId,
                      String(confirmation.protocolVersion)]
        return Data(fields.map { "\($0.utf8.count):\($0)" }.joined().utf8)
    }

    public static func make(stage: Stage, confirmation: PairingConfirmation, sessionKey: Data) throws -> Self {
        guard sessionKey.count == 32 else { throw PairingPayloadError.invalidPayload }
        let code = HMAC<SHA256>.authenticationCode(for: signingInput(stage: stage, confirmation: confirmation), using: SymmetricKey(data: sessionKey))
        return Self(stage: stage, confirmation: confirmation, proof: Data(code).base64EncodedString())
    }

    public func verified(using sessionKey: Data) throws -> Bool {
        guard version == 1, sessionKey.count == 32, let signature = Data(base64Encoded: proof) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(signature, authenticating: Self.signingInput(stage: stage, confirmation: confirmation), using: SymmetricKey(data: sessionKey))
    }

    public func encode() throws -> String {
        let data = try JSONEncoder().encode(self)
        guard data.count <= 16_384 else { throw PairingPayloadError.invalidPayload }
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode(_ payload: String) throws -> Self {
        guard payload.utf8.count <= 16_384 else { throw PairingPayloadError.invalidPayload }
        let value = try JSONDecoder().decode(Self.self, from: Data(payload.utf8))
        guard value.version == 1 else { throw PairingPayloadError.invalidPayload }
        return value
    }
}
