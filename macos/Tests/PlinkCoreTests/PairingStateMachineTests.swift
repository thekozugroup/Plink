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
func manualPairingPayloadRoundTripsOffer() throws {
    let machine = PairingStateMachine()
    let offer = machine.makeOffer(
        deviceId: "mac-1",
        deviceName: "Mac",
        endpoint: "192.168.1.5:45731",
        targetDeviceId: "pixel-1",
        nonce: "abc"
    )

    let decoded = try PairingPayloadCodec.decodeOffer(PairingPayloadCodec.encodeOffer(offer))

    #expect(decoded == offer)
}

@Test
func acceptsManualPairingConfirmation() throws {
    let mac = PairingStateMachine()
    let pixel = PairingStateMachine()
    let offer = mac.makeOffer(
        deviceId: "mac-1",
        deviceName: "Mac",
        endpoint: "192.168.1.5:45731",
        targetDeviceId: "pixel-1",
        nonce: "abc"
    )
    let pixelStatus = pixel.receive(offer)
    let pixelPaired = try pixel.confirm()
    guard
        case .showingCode(_, _, _, let pixelCode) = pixelStatus,
        case .paired(let pairedMac) = pixelPaired
    else {
        Issue.record("Expected Pixel-side pairing states")
        return
    }
    let confirmation = PairingConfirmation(
        deviceId: "pixel-1",
        deviceName: "Pixel",
        platform: "android",
        endpoint: "192.168.1.20:45731",
        publicKey: pairedMac.localPublicKey,
        targetDeviceId: "mac-1",
        offerNonce: "abc",
        sessionId: pairedMac.sessionId
    )

    let macCode = mac.verificationCode(for: offer, confirmation: confirmation)
    let status = try mac.accept(confirmation, for: offer)

    #expect(macCode.numeric == pixelCode.numeric)
    #expect(macCode.emoji == pixelCode.emoji)
    if case .paired(let device) = status {
        #expect(device.id == "pixel-1")
        #expect(device.endpoint == "192.168.1.20:45731")
        #expect(device.sessionId == confirmation.sessionId)
    } else {
        Issue.record("Expected Mac to accept Pixel confirmation")
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
