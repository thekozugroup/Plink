package app.plink.android.features

import app.plink.android.permissions.PermissionState
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FeaturePolicyTest {
    @Test
    fun callsAvailableWithPhoneStateOnly() {
        val features = FeaturePolicy.evaluate(PermissionState(phoneState = true))
        val calls = features.first { it.feature == ContinuityFeature.Calls }

        assertTrue(calls.available)
    }

    @Test
    fun directSmsUnavailableWithoutSmsRole() {
        val features = FeaturePolicy.evaluate(PermissionState(notificationListener = true))
        val sms = features.first { it.feature == ContinuityFeature.Sms }

        assertFalse(sms.available)
    }
}
