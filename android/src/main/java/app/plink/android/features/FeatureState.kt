package app.plink.android.features

import app.plink.android.permissions.PermissionState

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

object FeaturePolicy {
    fun evaluate(permissionState: PermissionState): List<FeatureAvailability> = listOf(
        FeatureAvailability(
            ContinuityFeature.Calls,
            enabled = true,
            available = permissionState.canMirrorCalls,
            reason = if (permissionState.canMirrorCalls) null else "Enable notification listener or phone state."
        ),
        FeatureAvailability(
            ContinuityFeature.Messages,
            enabled = true,
            available = permissionState.canMirrorMessages,
            reason = if (permissionState.canMirrorMessages) null else "Enable notification listener."
        ),
        FeatureAvailability(
            ContinuityFeature.Clipboard,
            enabled = true,
            available = true,
            reason = if (permissionState.canAutoSyncClipboard) null else "Manual share works; auto sync needs accessibility."
        ),
        FeatureAvailability(ContinuityFeature.Files, enabled = true, available = true),
        FeatureAvailability(ContinuityFeature.Web, enabled = true, available = true),
        FeatureAvailability(ContinuityFeature.Battery, enabled = true, available = true),
        FeatureAvailability(ContinuityFeature.Media, enabled = true, available = permissionState.notificationListener),
        FeatureAvailability(
            ContinuityFeature.Sms,
            enabled = false,
            available = permissionState.smsRole,
            reason = if (permissionState.smsRole) null else "Future direct SMS mode requires default SMS role."
        ),
        FeatureAvailability(
            ContinuityFeature.ScreenMirror,
            enabled = false,
            available = permissionState.shizukuAvailable,
            reason = if (permissionState.shizukuAvailable) null else "Future scrcpy/Shizuku path."
        )
    )
}
