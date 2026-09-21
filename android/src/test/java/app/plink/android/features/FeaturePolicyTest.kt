package app.plink.android.features

import android.content.SharedPreferences
import app.plink.android.permissions.PermissionState
import java.lang.reflect.Proxy
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FeaturePolicyTest {
    @Test
    fun screenPreviewIsAbsentEvenWhenToggleReaderEnablesEverything() {
        val features = FeaturePolicy.evaluate(PermissionState(), FeatureToggleReader { true })
        assertFalse(features.any { it.feature == ContinuityFeature.ScreenMirror })
    }

    @Test
    fun savedScreenEnableCannotActivateFeatureOrRewriteHistoricalPreference() {
        val saved = mapOf("feature_screenmirror" to true, "feature_files" to true)
        val preferences = Proxy.newProxyInstance(
            SharedPreferences::class.java.classLoader,
            arrayOf(SharedPreferences::class.java)
        ) { _, method, args ->
            when (method.name) {
                "getBoolean" -> saved[args!![0] as String] ?: args[1]
                else -> error("Unexpected preference operation: ${method.name}")
            }
        } as SharedPreferences
        val settings = FeatureSettings(preferences)

        assertFalse(settings.isEnabled(ContinuityFeature.ScreenMirror))
        assertFalse(settings.enabled.value.getValue(ContinuityFeature.ScreenMirror))
        settings.setEnabled(ContinuityFeature.ScreenMirror, true)
        settings.setEnabled(ContinuityFeature.ScreenMirror, false)
        assertFalse(settings.isEnabled(ContinuityFeature.ScreenMirror))
        assertFalse(settings.enabled.value.getValue(ContinuityFeature.ScreenMirror))
        assertFalse(FeaturePolicy.evaluate(PermissionState(), settings)
            .any { it.feature == ContinuityFeature.ScreenMirror })
        assertTrue(preferences.getBoolean("feature_screenmirror", false))
        assertTrue(settings.isEnabled(ContinuityFeature.Files))
    }

    @Test
    fun callsUnavailableWithPhoneStateOnly() {
        val features = FeaturePolicy.evaluate(PermissionState(phoneState = true))
        val calls = features.first { it.feature == ContinuityFeature.Calls }

        assertFalse(calls.available)
    }

    @Test
    fun unimplementedDirectSmsIsAbsentFromFeatureChoices() {
        val features = FeaturePolicy.evaluate(PermissionState(notificationListener = true))
        assertFalse(features.any { it.feature == ContinuityFeature.Sms })
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
