package app.plink.android.pairing

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Test

class PairingMigrationTest {
    @Test fun legacyTrustDoesNotAcquireDurableTransportVersion() {
        val old = Json.decodeFromString<PairedDevice>("""{"id":"mac","name":"Mac","platform":"macos","endpoint":"localhost:45731","sessionId":"old","peerPublicKey":"peer","localPublicKey":"local","trusted":true}""")
        assertEquals(0, old.securityVersion)
        val current = old.copy(securityVersion = 2)
        assertEquals(2, Json.decodeFromString<PairedDevice>(Json.encodeToString(PairedDevice.serializer(), current)).securityVersion)
    }
}
