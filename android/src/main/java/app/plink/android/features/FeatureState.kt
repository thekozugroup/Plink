package app.plink.android.features

import android.content.Context
import android.content.SharedPreferences
import app.plink.android.permissions.PermissionState
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.concurrent.CopyOnWriteArrayList

enum class ContinuityFeature {
    Calls,
    Messages,
    Clipboard,
    Files,
    Web,
    Battery,
    Media,
    Sms,
    ScreenMirror
}

data class FeatureAvailability(
    val feature: ContinuityFeature,
    val enabled: Boolean,
    val available: Boolean,
    val reason: String? = null
)

fun interface FeatureToggleReader {
    fun isEnabled(feature: ContinuityFeature): Boolean
}

class FeatureSettings(
    context: Context,
    private val preferences: SharedPreferences = context.applicationContext.getSharedPreferences(
        "feature_settings",
        Context.MODE_PRIVATE
    )
) : FeatureToggleReader {
    private val _backgroundConnectionEnabled = MutableStateFlow(
        preferences.getBoolean(BACKGROUND_CONNECTION_KEY, false)
    )
    val backgroundConnectionEnabled: StateFlow<Boolean> = _backgroundConnectionEnabled.asStateFlow()
    private val _enabled = MutableStateFlow(readAll())
    private val listeners = CopyOnWriteArrayList<(ContinuityFeature, Boolean) -> Unit>()
    val enabled: StateFlow<Map<ContinuityFeature, Boolean>> = _enabled.asStateFlow()

    override fun isEnabled(feature: ContinuityFeature): Boolean =
        _enabled.value[feature] ?: defaultEnabled(feature)

    fun setEnabled(feature: ContinuityFeature, enabled: Boolean) {
        preferences.edit().putBoolean(feature.preferenceKey, enabled).apply()
        _enabled.value = _enabled.value + (feature to enabled)
        listeners.forEach { it(feature, enabled) }
    }

    fun addListener(listener: (ContinuityFeature, Boolean) -> Unit) {
        listeners += listener
    }

    fun setBackgroundConnectionEnabled(enabled: Boolean) {
        preferences.edit().putBoolean(BACKGROUND_CONNECTION_KEY, enabled).apply()
        _backgroundConnectionEnabled.value = enabled
    }

    private fun readAll(): Map<ContinuityFeature, Boolean> =
        ContinuityFeature.entries.associateWith { feature ->
            preferences.getBoolean(feature.preferenceKey, defaultEnabled(feature))
        }

    private fun defaultEnabled(feature: ContinuityFeature): Boolean = when (feature) {
        ContinuityFeature.Files, ContinuityFeature.Sms, ContinuityFeature.ScreenMirror -> false
        else -> true
    }

    private val ContinuityFeature.preferenceKey: String
        get() = "feature_${name.lowercase()}"

    companion object { private const val BACKGROUND_CONNECTION_KEY = "background_connection_enabled" }
}

object FeaturePolicy {
    fun evaluate(
        permissionState: PermissionState,
        settings: FeatureToggleReader = FeatureToggleReader { feature ->
            feature != ContinuityFeature.Files &&
                feature != ContinuityFeature.Sms &&
                feature != ContinuityFeature.ScreenMirror
        }
    ): List<FeatureAvailability> = listOf(
        FeatureAvailability(
            ContinuityFeature.Calls,
            enabled = settings.isEnabled(ContinuityFeature.Calls),
            available = permissionState.notificationListener,
            reason = if (permissionState.notificationListener) null else "Enable notification listener."
        ),
        FeatureAvailability(
            ContinuityFeature.Messages,
            enabled = settings.isEnabled(ContinuityFeature.Messages),
            available = permissionState.canMirrorMessages,
            reason = if (permissionState.canMirrorMessages) null else "Enable notification listener."
        ),
        FeatureAvailability(
            ContinuityFeature.Clipboard,
            enabled = settings.isEnabled(ContinuityFeature.Clipboard),
            available = true,
            reason = "Use Android share to send, or tap an incoming Plink notification."
        ),
        FeatureAvailability(
            ContinuityFeature.Files,
            enabled = settings.isEnabled(ContinuityFeature.Files),
            available = true,
            reason = if (permissionState.notificationRuntime) {
                "Use Android share to send. Incoming files require explicit notification and destination approval."
            } else {
                "Sending works; incoming files require Pixel notifications."
            }
        ),
        FeatureAvailability(
            ContinuityFeature.Web,
            enabled = settings.isEnabled(ContinuityFeature.Web),
            available = true,
            reason = if (permissionState.notificationRuntime) null else "Sending works; incoming links need Pixel notifications."
        ),
        FeatureAvailability(
            ContinuityFeature.Battery,
            enabled = settings.isEnabled(ContinuityFeature.Battery),
            available = true
        ),
        FeatureAvailability(
            ContinuityFeature.Media,
            enabled = settings.isEnabled(ContinuityFeature.Media),
            available = permissionState.notificationListener,
            reason = if (permissionState.notificationListener) null else "Enable notification listener."
        ),
        FeatureAvailability(
            ContinuityFeature.Sms,
            enabled = settings.isEnabled(ContinuityFeature.Sms),
            available = false,
            reason = "Direct SMS mode is not implemented."
        ),
        FeatureAvailability(
            ContinuityFeature.ScreenMirror,
            enabled = settings.isEnabled(ContinuityFeature.ScreenMirror),
            available = false,
            reason = "Screen mirroring is not implemented."
        )
    )
}
