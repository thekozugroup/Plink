package app.plink.android.services

import org.junit.Assert.assertEquals
import org.junit.Test

class BackgroundConnectionPolicyTest {
    @Test
    fun enableRequiresExplicitRequestPairingAndNotifications() {
        assertEquals(
            BackgroundConnectionDecision.ExplicitActionRequired,
            BackgroundConnectionPolicy.evaluate(explicitRequest = false, paired = true, notificationsAllowed = true)
        )
        assertEquals(
            BackgroundConnectionDecision.PairingRequired,
            BackgroundConnectionPolicy.evaluate(explicitRequest = true, paired = false, notificationsAllowed = true)
        )
        assertEquals(
            BackgroundConnectionDecision.NotificationPermissionRequired,
            BackgroundConnectionPolicy.evaluate(explicitRequest = true, paired = true, notificationsAllowed = false)
        )
        assertEquals(
            BackgroundConnectionDecision.Start,
            BackgroundConnectionPolicy.evaluate(explicitRequest = true, paired = true, notificationsAllowed = true)
        )
    }
}
