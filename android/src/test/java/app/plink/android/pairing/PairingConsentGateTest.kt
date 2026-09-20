package app.plink.android.pairing

import org.junit.Assert.*
import org.junit.Test

class PairingConsentGateTest {
    @Test fun bothConfirmationsAreRequiredAndCanOnlyBeConsumedOnce() {
        val gate = PairingConsentGate(500)
        assertFalse(gate.consume(0))
        gate.confirmLocal(1)
        assertFalse(gate.consume(2))
        gate.confirmRemote(3)
        assertTrue(gate.consume(4))
        assertThrows(IllegalStateException::class.java) { gate.consume(5) }
    }
    @Test fun remoteConfirmationAloneCannotActivateTrust() {
        val gate = PairingConsentGate(500)
        gate.confirmRemote(1)
        assertFalse(gate.consume(2))
        gate.cancel()
        assertThrows(IllegalStateException::class.java) { gate.confirmLocal(3) }
    }
    @Test fun expiryPreventsActivation() {
        val gate = PairingConsentGate(500)
        gate.confirmLocal(1)
        assertThrows(IllegalStateException::class.java) { gate.confirmRemote(500) }
    }
    @Test fun observedExpiryCannotBeRevivedByClockRollback() {
        val gate = PairingConsentGate(500)
        assertThrows(IllegalStateException::class.java) { gate.checkLive(500) }
        assertThrows(IllegalStateException::class.java) { gate.confirmLocal(1) }
        assertThrows(IllegalStateException::class.java) { gate.confirmRemote(2) }
        assertThrows(IllegalStateException::class.java) { gate.consume(3) }
    }
}
