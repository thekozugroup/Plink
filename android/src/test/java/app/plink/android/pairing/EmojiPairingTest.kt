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
}
