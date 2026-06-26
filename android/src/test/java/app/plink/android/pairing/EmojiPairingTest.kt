package app.plink.android.pairing

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

class EmojiPairingTest {
    @Test
    fun deriveIsStable() {
        assertEquals(
            EmojiPairing.derive("pixel", "mac", "nonce"),
            EmojiPairing.derive("pixel", "mac", "nonce")
        )
    }

    @Test
    fun deriveChangesWhenNonceChanges() {
        assertNotEquals(
            EmojiPairing.derive("pixel", "mac", "nonce-1"),
            EmojiPairing.derive("pixel", "mac", "nonce-2")
        )
    }

    @Test
    fun demoPairingCodeMatchesSharedFixture() {
        assertEquals("⚡" to "🔑", EmojiPairing.derive("pixel-demo", "mac-demo", "demo-nonce"))
    }

    @Test
    fun strongVerificationBindsPublicKeys() {
        val first = PairingTranscript.verificationCode(
            PairingTranscript.canonical("pixel", "mac", "host:1", "nonce", "pixel-key-a", "mac-key", 1)
        )
        val second = PairingTranscript.verificationCode(
            PairingTranscript.canonical("pixel", "mac", "host:1", "nonce", "pixel-key-b", "mac-key", 1)
        )

        assertEquals(4, first.emoji.size)
        assertEquals(6, first.numeric.length)
        assertNotEquals(first, second)
    }
}
