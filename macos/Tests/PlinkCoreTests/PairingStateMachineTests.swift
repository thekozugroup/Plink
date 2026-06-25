import PlinkCore
import Testing

@Test
func confirmCreatesTrustedDevice() throws {
    let machine = PairingStateMachine()
    _ = machine.receive(
        PairingOffer(
            deviceId: "pixel-1",
            deviceName: "Pixel",
            platform: "android",
            endpoint: "192.168.1.24:45731",
            nonce: "abc"
        )
    )

    let status = try machine.confirm()

    if case .paired(let device) = status {
        #expect(device.id == "pixel-1")
        #expect(device.trusted)
        #expect(device.sessionId.count == 32)
    } else {
        Issue.record("Expected paired status")
    }
}

@Test
func confirmWithoutOfferFailsClosed() {
    let machine = PairingStateMachine()

    #expect(throws: PairingError.noOfferToConfirm) {
        try machine.confirm()
    }
}
