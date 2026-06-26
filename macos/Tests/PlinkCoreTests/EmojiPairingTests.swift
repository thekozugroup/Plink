import PlinkCore
import Testing

@Test
func deriveIsStable() {
    let first = EmojiPairing.derive(sourceDeviceId: "pixel", targetDeviceId: "mac", nonce: "nonce")
    let second = EmojiPairing.derive(sourceDeviceId: "pixel", targetDeviceId: "mac", nonce: "nonce")

    #expect(first.0 == second.0)
    #expect(first.1 == second.1)
}

@Test
func deriveChangesWithNonce() {
    let first = EmojiPairing.derive(sourceDeviceId: "pixel", targetDeviceId: "mac", nonce: "nonce-1")
    let second = EmojiPairing.derive(sourceDeviceId: "pixel", targetDeviceId: "mac", nonce: "nonce-2")

    #expect(first.0 != second.0 || first.1 != second.1)
}

@Test
func demoPairingCodeMatchesSharedFixture() {
    let code = EmojiPairing.derive(sourceDeviceId: "pixel-demo", targetDeviceId: "mac-demo", nonce: "demo-nonce")

    #expect(code.0 == "⚡")
    #expect(code.1 == "🔑")
}

@Test
func strongVerificationBindsPublicKeys() {
    let first = PairingTranscript.verificationCode(
        transcript: PairingTranscript.canonical(
            sourceDeviceId: "pixel",
            targetDeviceId: "mac",
            endpoint: "host:1",
            nonce: "nonce",
            sourcePublicKey: "pixel-key-a",
            targetPublicKey: "mac-key",
            protocolVersion: 1
        )
    )
    let second = PairingTranscript.verificationCode(
        transcript: PairingTranscript.canonical(
            sourceDeviceId: "pixel",
            targetDeviceId: "mac",
            endpoint: "host:1",
            nonce: "nonce",
            sourcePublicKey: "pixel-key-b",
            targetPublicKey: "mac-key",
            protocolVersion: 1
        )
    )

    #expect(first.emoji.count == 4)
    #expect(first.numeric.count == 6)
    #expect(first != second)
}
