package app.plink.android.features

import android.content.SharedPreferences
import app.plink.android.permissions.PermissionState
import java.lang.reflect.Proxy
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FeaturePolicyTest {
    @Test
    fun screenPreviewIsAvailableOnlyOnAndroid14OrLater() {
        val enabled = FeatureToggleReader { true }
        val supported = FeaturePolicy.evaluate(PermissionState(), enabled, screenPreviewSupported = true)
        val unsupported = FeaturePolicy.evaluate(PermissionState(), enabled, screenPreviewSupported = false)
        assertTrue(supported.first { it.feature == ContinuityFeature.ScreenMirror }.available)
        assertFalse(unsupported.first { it.feature == ContinuityFeature.ScreenMirror }.available)
    }

    @Test
    fun savedScreenEnableCanActivateFeature() {
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

        assertTrue(settings.isEnabled(ContinuityFeature.ScreenMirror))
        assertTrue(settings.enabled.value.getValue(ContinuityFeature.ScreenMirror))
        assertTrue(FeaturePolicy.evaluate(PermissionState(), settings, screenPreviewSupported = true)
            .first { it.feature == ContinuityFeature.ScreenMirror }.enabled)
        assertTrue(preferences.getBoolean("feature_screenmirror", false))
        assertTrue(settings.isEnabled(ContinuityFeature.Files))
    }

    @Test
    fun screenOffPublishesStateAndNotifiesControllerListener() {
        val saved = mutableMapOf("feature_screenmirror" to true)
        val editor = Proxy.newProxyInstance(
            SharedPreferences.Editor::class.java.classLoader,
            arrayOf(SharedPreferences.Editor::class.java)
        ) { proxy, method, args ->
            when (method.name) {
                "putBoolean" -> { saved[args!![0] as String] = args[1] as Boolean; proxy }
                "apply" -> Unit
                else -> error("Unexpected preference edit: ${method.name}")
            }
        } as SharedPreferences.Editor
        val preferences = Proxy.newProxyInstance(
            SharedPreferences::class.java.classLoader,
            arrayOf(SharedPreferences::class.java)
        ) { _, method, args ->
            when (method.name) {
                "getBoolean" -> saved[args!![0] as String] ?: args[1]
                "edit" -> editor
                else -> error("Unexpected preference operation: ${method.name}")
            }
        } as SharedPreferences
        val settings = FeatureSettings(preferences)
        var disabledEvents = 0
        settings.addListener { feature, enabled ->
            if (feature == ContinuityFeature.ScreenMirror && !enabled) disabledEvents++
        }

        settings.setEnabled(ContinuityFeature.ScreenMirror, false)

        assertFalse(settings.isEnabled(ContinuityFeature.ScreenMirror))
        assertFalse(settings.enabled.value.getValue(ContinuityFeature.ScreenMirror))
        assertFalse(saved.getValue("feature_screenmirror"))
        assertTrue(disabledEvents == 1)
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
