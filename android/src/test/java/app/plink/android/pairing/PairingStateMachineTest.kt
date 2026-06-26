package app.plink.android.pairing

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class PairingStateMachineTest {
    @Test
    fun confirmCreatesTrustedDevice() {
        val macKey = PairingCrypto.generateKeyPair()
        val machine = PairingStateMachine()
        machine.receiveOffer(
            PairingOffer(
                deviceId = "mac-1",
                deviceName = "MacBook Pro",
                platform = "macos",
                endpoint = "192.168.1.5:45731",
                nonce = "abc",
                publicKey = macKey.publicKeyBase64,
                targetDeviceId = "pixel-1"
            )
        )

        val paired = machine.confirm()

        assertEquals("mac-1", paired.device.id)
        assertTrue(paired.device.trusted)
        assertEquals(32, paired.device.sessionId.length)
        assertEquals(macKey.publicKeyBase64, paired.device.peerPublicKey)
        assertTrue(paired.device.localPublicKey.isNotBlank())
        assertTrue(machine.lastSessionKey?.isNotEmpty() == true)
    }

    @Test
    fun receiveOfferShowsKeyBoundVerificationCode() {
        val macKey = PairingCrypto.generateKeyPair()
        val machine = PairingStateMachine()
        val showing = machine.receiveOffer(
            PairingOffer(
                deviceId = "mac-1",
                deviceName = "MacBook Pro",
                platform = "macos",
                endpoint = "192.168.1.5:45731",
                nonce = "abc",
                publicKey = macKey.publicKeyBase64,
                targetDeviceId = "pixel-1"
            )
        )

        assertEquals(4, showing.verificationCode.emoji.size)
        assertEquals(6, showing.verificationCode.numeric.length)
    }

    @Test
    fun pairingPayloadCodecRoundTripsOffer() {
        val offer = PairingOffer(
            deviceId = "mac-1",
            deviceName = "MacBook Pro",
            platform = "macos",
            endpoint = "192.168.1.5:45731",
            nonce = "abc",
            publicKey = PairingCrypto.generateKeyPair().publicKeyBase64,
            targetDeviceId = "pixel-1"
        )

        val decoded = PairingPayloadCodec.decodeOffer(PairingPayloadCodec.encodeOffer(offer))

        assertEquals(offer, decoded)
    }

    @Test
    fun confirmWithResponseBuildsMacImportPayload() {
        val macKey = PairingCrypto.generateKeyPair()
        val machine = PairingStateMachine()
        machine.receiveOffer(
            PairingOffer(
                deviceId = "mac-1",
                deviceName = "MacBook Pro",
                platform = "macos",
                endpoint = "192.168.1.5:45731",
                nonce = "abc",
                publicKey = macKey.publicKeyBase64,
                targetDeviceId = "pixel-1"
            )
        )

        val (paired, confirmation) = machine.confirmWithResponse(
            localDeviceId = "pixel-1",
            localDeviceName = "Pixel",
            localEndpoint = "192.168.1.20:45731"
        )
        val decoded = PairingPayloadCodec.decodeConfirmation(
            PairingPayloadCodec.encodeConfirmation(confirmation)
        )

        assertEquals("mac-1", paired.device.id)
        assertEquals("pixel-1", decoded.deviceId)
        assertEquals("mac-1", decoded.targetDeviceId)
        assertEquals("abc", decoded.offerNonce)
        assertEquals(paired.device.sessionId, decoded.sessionId)
        assertEquals(machine.localPublicKeyBase64, decoded.publicKey)
    }

    @Test(expected = IllegalStateException::class)
    fun confirmWithoutOfferFailsClosed() {
        PairingStateMachine().confirm()
    }

    @Test
    fun invalidOfferWithoutPublicKeyFailsClosed() {
        val machine = PairingStateMachine()
        machine.receiveOffer(
            PairingOffer(
                deviceId = "mac-1",
                deviceName = "MacBook Pro",
                platform = "macos",
                endpoint = "192.168.1.5:45731",
                nonce = "abc",
                publicKey = "",
                targetDeviceId = "pixel-1"
            )
        )

        assertThrows(IllegalArgumentException::class.java) {
            machine.confirm()
        }
    }
}
