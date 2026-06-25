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
