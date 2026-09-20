package app.plink.android.pairing

import org.junit.Assert.*
import org.junit.Test

class PairingSecurityTest {
    @Test fun numericCodeUsesUnsignedDigestPrefix() {
        assertEquals("514649", PairingTranscript.verificationCode("plink-pairing-v1|mac|pixel|127.0.0.1:45731|audit-0|key1|key2").numeric)
    }
    @Test fun previewDoesNotActivateTrustAndBindsEndpoint() {
        val machine = PairingStateMachine()
        val offer = PairingOffer("mac", "Mac", "macos", "host:123", "nonce", PairingCrypto.generateKeyPair().publicKeyBase64, "pixel")
        machine.receiveOffer(offer, localEndpoint = "pixel:456")
        val (candidate, confirmation) = machine.previewWithResponse("pixel", "Pixel", "pixel:456")
        assertFalse(candidate.trusted)
        assertTrue(machine.status is PairingStatus.ShowingCode)
        assertEquals(candidate.sessionId, confirmation.sessionId)
        assertThrows(IllegalArgumentException::class.java) {
            machine.previewWithResponse("pixel", "Pixel", "attacker:456")
        }
    }
    @Test fun transcriptIsUnambiguous() {
        fun transcript(a: String, b: String) = PairingTranscript.canonical(a,b,"host:1","nonce","key1","key2",1)
        assertNotEquals(transcript("mac|pixel", "other"), transcript("mac", "pixel|other"))
    }
}
