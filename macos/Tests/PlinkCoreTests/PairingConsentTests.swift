import CryptoKit
import Foundation
import Testing
@testable import PlinkCore

@Test func pairingConsentProofBindsBothIdentitiesEndpointAndStage() throws {
    let key = Data(repeating: 7, count: 32)
    let confirmation = PairingConfirmation(deviceId: "pixel", deviceName: "Pixel", platform: "android", endpoint: "192.0.2.1:45731", publicKey: "public-key", targetDeviceId: "mac", offerNonce: "nonce", sessionId: "session")
    let consent = try PairingConsent.make(stage: .confirmed, confirmation: confirmation, sessionKey: key)
    #expect(try consent.verified(using: key))
    #expect(consent.proof == "a+Tpx8+kdzT+yXTEKnSa7sYr09S1Qq3mh+RQIlDuQIk=")
    let decoded = try PairingConsent.decode(consent.encode())
    #expect(decoded == consent)
    var changed = consent
    changed.confirmation.endpoint = "192.0.2.2:45731"
    #expect(try !changed.verified(using: key))
    changed = consent
    changed.stage = .preview
    #expect(try !changed.verified(using: key))
    #expect(try !consent.verified(using: Data(repeating: 8, count: 32)))
}

@Test func pairingConsentRejectsLegacyUnconfirmedPayload() throws {
    let legacy = PairingConfirmation(deviceId: "pixel", deviceName: "Pixel", platform: "android", endpoint: "192.0.2.1:45731", publicKey: "key", targetDeviceId: "mac", offerNonce: "nonce", sessionId: "session")
    #expect(throws: (any Error).self) { try PairingConsent.decode(PairingPayloadCodec.encodeConfirmation(legacy)) }
}

@Test func pairingConsentFieldsHaveUnambiguousBoundaries() throws {
    let a = PairingConfirmation(deviceId: "a|b", deviceName: "Pixel", platform: "android", endpoint: "host:1", publicKey: "key", targetDeviceId: "c", offerNonce: "n", sessionId: "s")
    var b = a
    b.deviceId = "a"
    b.targetDeviceId = "b|c"
    #expect(PairingConsent.signingInput(stage: .confirmed, confirmation: a) != PairingConsent.signingInput(stage: .confirmed, confirmation: b))
}
