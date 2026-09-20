import Foundation
import PlinkCore
import Testing

@Test func transcriptEndpointAndTupleAreBound() throws {
    let mac = PairingStateMachine()
    let phone = PairingStateMachine()
    let offer = mac.makeOffer(deviceId: "mac", deviceName: "Mac", endpoint: "host:1", targetDeviceId: "pixel")
    _ = phone.receive(offer, localEndpoint: "pixel:2")
    guard case .paired(let candidate) = try phone.confirm() else { Issue.record("pairing failed"); return }
    var confirmation = PairingConfirmation(deviceId: "pixel", deviceName: "Pixel", platform: "android", endpoint: "pixel:2", publicKey: phone.localPublicKeyBase64, targetDeviceId: "mac", offerNonce: offer.nonce, sessionId: candidate.sessionId)
    let original = mac.verificationCode(for: offer, confirmation: confirmation)
    confirmation.endpoint = "attacker:2"
    #expect(original != mac.verificationCode(for: offer, confirmation: confirmation))
    #expect(throws: PairingPayloadError.sessionMismatch) { _ = try mac.accept(confirmation, for: offer) }
    confirmation.endpoint = "pixel:2"
    confirmation.protocolVersion = 999
    #expect(throws: PairingPayloadError.invalidPayload) { _ = try mac.accept(confirmation, for: offer) }
    func transcript(_ a: String, _ b: String) -> String {
        PairingTranscript.canonical(sourceDeviceId: a, targetDeviceId: b, endpoint: "host:1", nonce: "nonce", sourcePublicKey: "key1", targetPublicKey: "key2", protocolVersion: 1)
    }
    #expect(transcript("mac|pixel", "other") != transcript("mac", "pixel|other"))
}

@Test func pairingNumericHighBitVectorMatchesAndroid() {
    #expect(PairingTranscript.verificationCode(transcript: "plink-pairing-v1|mac|pixel|127.0.0.1:45731|audit-0|key1|key2").numeric == "514649")
}
