package app.plink.android.services

import app.plink.android.pairing.PairedDevice
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SharedSessionStateTest {
    @Test
    fun snapshotReturnsActivePairedSession() {
        SharedSessionState.clear()
        SharedSessionState.configure(
            ActivePlinkSession(
                localDeviceId = "pixel",
                pairedDevice = pairedDevice(),
                sessionKey = byteArrayOf(1, 2, 3)
            )
        )

        val snapshot = SharedSessionState.snapshot()

        assertEquals("pixel", snapshot?.localDeviceId)
        assertEquals("mac", snapshot?.pairedDevice?.id)
        SharedSessionState.clear()
        assertNull(SharedSessionState.snapshot())
    }

    private fun pairedDevice(): PairedDevice = PairedDevice(
        id = "mac",
        name = "Mac",
        platform = "macos",
        endpoint = "127.0.0.1:45731",
        sessionId = "session",
        peerPublicKey = "peer",
        localPublicKey = "local",
        trusted = true
    )
}
