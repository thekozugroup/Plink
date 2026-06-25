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
