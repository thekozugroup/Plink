package app.plink.android.pairing

import org.junit.Assert.*
import org.junit.Test

class PairingConsentTest {
    private val confirmation = PairingConfirmation("pixel", "Pixel", "android", "192.0.2.1:45731", "public-key", "mac", "nonce", "session")
    private val key = ByteArray(32) { 7 }

    @Test fun consentBindsStageEndpointAndKey() {
        val consent = PairingConsent.create("confirmed", confirmation, key)
        assertTrue(consent.verified(key))
        assertEquals(consent, PairingConsent.decode(consent.encode()))
        assertFalse(consent.copy(confirmation = confirmation.copy(endpoint = "192.0.2.2:45731")).verified(key))
        assertFalse(consent.copy(stage = "preview").verified(key))
        assertFalse(consent.verified(ByteArray(32) { 8 }))
    }

    @Test fun legacyConfirmationIsNotConsent() {
        assertThrows(IllegalArgumentException::class.java) {
            PairingConsent.decode(PairingPayloadCodec.encodeConfirmation(confirmation))
        }
    }

    @Test fun bothSidesUseSameCanonicalProof() {
        val consent = PairingConsent.create("confirmed", confirmation, key)
        assertEquals("a+Tpx8+kdzT+yXTEKnSa7sYr09S1Qq3mh+RQIlDuQIk=", consent.proof)
    }
}
