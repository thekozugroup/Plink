package app.plink.android.pairing

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PairingStateMachineTest {
    @Test
    fun confirmCreatesTrustedDevice() {
        val machine = PairingStateMachine()
        machine.receiveOffer(
            PairingOffer(
                deviceId = "mac-1",
                deviceName = "MacBook Pro",
                platform = "macos",
                endpoint = "192.168.1.5:45731",
                nonce = "abc"
            )
        )

        val paired = machine.confirm()

        assertEquals("mac-1", paired.device.id)
        assertTrue(paired.device.trusted)
        assertEquals(32, paired.device.sessionId.length)
    }

    @Test(expected = IllegalStateException::class)
    fun confirmWithoutOfferFailsClosed() {
        PairingStateMachine().confirm()
    }
}
