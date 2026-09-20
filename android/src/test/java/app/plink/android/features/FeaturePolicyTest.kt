package app.plink.android.features

import app.plink.android.permissions.PermissionState
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FeaturePolicyTest {
    @Test
    fun screenPreviewRequiresAndroid14AndRemainsOptIn() {
        val supported = FeaturePolicy.evaluate(PermissionState(), screenPreviewSupported = true)
            .first { it.feature == ContinuityFeature.ScreenMirror }
        assertTrue(supported.available)
        assertFalse(supported.enabled)
        val older = FeaturePolicy.evaluate(PermissionState(), FeatureToggleReader { true }, screenPreviewSupported = false)
            .first { it.feature == ContinuityFeature.ScreenMirror }
        assertFalse(older.available)
        assertTrue(older.enabled)
    }

    @Test
    fun callsUnavailableWithPhoneStateOnly() {
        val features = FeaturePolicy.evaluate(PermissionState(phoneState = true))
        val calls = features.first { it.feature == ContinuityFeature.Calls }

        assertFalse(calls.available)
    }

    @Test
    fun directSmsUnavailableWithoutSmsRole() {
        val features = FeaturePolicy.evaluate(PermissionState(notificationListener = true))
        val sms = features.first { it.feature == ContinuityFeature.Sms }

        assertFalse(sms.available)
    }

    @Test
    fun persistedToggleControlsEnabledStateWithoutClaimingAvailability() {
        val settings = FeatureToggleReader { feature -> feature != ContinuityFeature.Messages }
        val features = FeaturePolicy.evaluate(
            PermissionState(notificationListener = true),
            settings
        )

        val messages = features.first { it.feature == ContinuityFeature.Messages }
        assertFalse(messages.enabled)
        assertTrue(messages.available)
    }

    @Test
    fun implementedFilesRemainAvailableWhenEnabled() {
        val settings = FeatureToggleReader { true }
        val features = FeaturePolicy.evaluate(PermissionState(), settings)

        assertFalse(features.first { it.feature == ContinuityFeature.Media }.available)
        assertTrue(features.first { it.feature == ContinuityFeature.Files }.available)
        assertTrue(features.first { it.feature == ContinuityFeature.Web }.available)
    }
}
