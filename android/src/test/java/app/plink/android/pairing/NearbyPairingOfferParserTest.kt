package app.plink.android.pairing

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class NearbyPairingOfferParserTest {
    @Test
    fun parseCreatesPairingOfferFromBonjourAttributes() {
        val attributes = mapOf(
            "plink" to "1".bytes(),
            "deviceId" to "mac-1".bytes(),
            "deviceName" to "MacBook Pro".bytes(),
            "platform" to "macos".bytes(),
            "endpoint" to "192.168.50.41:45731".bytes(),
            "nonce" to "nonce-1".bytes(),
            "publicKey" to "public-key".bytes(),
            "targetDeviceId" to "pixel-pending".bytes(),
            "protocolVersion" to "1".bytes()
        )

        val discovered = NearbyPairingOfferParser.parse(
            serviceName = "Plink MacBook Pro",
            attributes = attributes,
            host = "192.168.50.41",
            port = 45731
        )

        requireNotNull(discovered)
        assertEquals("Plink MacBook Pro", discovered.serviceName)
        assertEquals("MacBook Pro", discovered.offer.deviceName)
        assertEquals("mac-1", discovered.offer.deviceId)
        assertEquals("192.168.50.41:45731", discovered.offer.endpoint)
        assertEquals("public-key", discovered.offer.publicKey)
    }

    @Test
    fun parseFallsBackToResolvedEndpoint() {
        val attributes = mapOf(
            "plink" to "1".bytes(),
            "deviceId" to "mac-1".bytes(),
            "deviceName" to "MacBook Pro".bytes(),
            "platform" to "macos".bytes(),
            "nonce" to "nonce-1".bytes(),
            "publicKey" to "public-key".bytes(),
            "targetDeviceId" to "pixel-pending".bytes(),
            "protocolVersion" to "1".bytes()
        )

        val discovered = NearbyPairingOfferParser.parse(
            serviceName = "Plink MacBook Pro",
            attributes = attributes,
            host = "192.168.50.41",
            port = 45731
        )

        assertEquals("192.168.50.41:45731", discovered?.offer?.endpoint)
    }

    @Test
    fun parseRejectsUnsupportedProtocol() {
        val attributes = mapOf(
            "plink" to "1".bytes(),
            "protocolVersion" to "2".bytes()
        )

        assertNull(
            NearbyPairingOfferParser.parse(
                serviceName = "Plink MacBook Pro",
                attributes = attributes,
                host = "192.168.50.41",
                port = 45731
            )
        )
    }

    private fun String.bytes(): ByteArray = toByteArray(Charsets.UTF_8)
}
