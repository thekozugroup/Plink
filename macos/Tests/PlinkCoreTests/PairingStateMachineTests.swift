import PlinkCore
import Testing
import CryptoKit

@Test
func confirmCreatesTrustedDevice() throws {
    let pixelKey = P256.KeyAgreement.PrivateKey()
    let machine = PairingStateMachine()
    _ = machine.receive(
        PairingOffer(
            deviceId: "pixel-1",
            deviceName: "Pixel",
            platform: "android",
            endpoint: "192.168.1.24:45731",
            nonce: "abc",
            publicKey: pixelKey.publicKey.derRepresentation.base64EncodedString()
        )
    )

    let status = try machine.confirm()

    if case .paired(let device) = status {
        #expect(device.id == "pixel-1")
        #expect(device.trusted)
        #expect(device.sessionId.count == 32)
        #expect(device.peerPublicKey == pixelKey.publicKey.derRepresentation.base64EncodedString())
        #expect(device.localPublicKey.isEmpty == false)
    } else {
        Issue.record("Expected paired status")
    }
}

@Test
func receiveShowsKeyBoundVerificationCode() throws {
    let pixelKey = P256.KeyAgreement.PrivateKey()
    let machine = PairingStateMachine()
    let status = machine.receive(
        PairingOffer(
            deviceId: "pixel-1",
            deviceName: "Pixel",
            platform: "android",
            endpoint: "192.168.1.24:45731",
            nonce: "abc",
            publicKey: pixelKey.publicKey.derRepresentation.base64EncodedString()
        )
    )

    if case .showingCode(_, _, _, let verificationCode) = status {
        #expect(verificationCode.emoji.count == 4)
        #expect(verificationCode.numeric.count == 6)
    } else {
        Issue.record("Expected showing code status")
    }
}

@Test
func confirmWithoutOfferFailsClosed() {
    let machine = PairingStateMachine()

    #expect(throws: PairingError.noOfferToConfirm) {
        try machine.confirm()
    }
}

@Test
func confirmRejectsMissingPublicKey() throws {
    let machine = PairingStateMachine()
    _ = machine.receive(
        PairingOffer(
            deviceId: "pixel-1",
            deviceName: "Pixel",
            platform: "android",
            endpoint: "192.168.1.24:45731",
            nonce: "abc",
            publicKey: ""
        )
    )

    #expect(throws: PairingError.invalidPublicKey) {
        try machine.confirm()
    }
}
