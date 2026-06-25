package app.plink.android.permissions

data class PermissionState(
    val notificationListener: Boolean = false,
    val notificationRuntime: Boolean = false,
    val phoneState: Boolean = false,
    val smsRole: Boolean = false,
    val accessibilityClipboard: Boolean = false,
    val shizukuAvailable: Boolean = false
) {
    val canMirrorMessages: Boolean = notificationListener
    val canReplyToMessages: Boolean = notificationListener || smsRole
    val canMirrorCalls: Boolean = notificationListener || phoneState
    val canAutoSyncClipboard: Boolean = accessibilityClipboard
}

object ShizukuCapability {
    fun isAvailable(): Boolean = runCatching {
        Class.forName("rikka.shizuku.Shizuku")
    }.isSuccess
}

enum class PermissionAction {
    OpenNotificationListenerSettings,
    RequestPostNotifications,
    RequestPhoneState,
    OpenAccessibilitySettings,
    OpenDefaultSmsRole,
    CheckShizuku
}

data class PermissionOnboardingStep(
    val title: String,
    val summary: String,
    val action: PermissionAction,
    val completed: Boolean,
    val enabled: Boolean = true
)

object PermissionOnboarding {
    fun steps(state: PermissionState): List<PermissionOnboardingStep> = listOf(
        PermissionOnboardingStep(
            title = "Notification access",
            summary = "Mirrors calls and message notifications from your Pixel.",
            action = PermissionAction.OpenNotificationListenerSettings,
            completed = state.notificationListener
        ),
        PermissionOnboardingStep(
            title = "Pixel notifications",
            summary = "Allows Plink to explain pairing and background sync state.",
            action = PermissionAction.RequestPostNotifications,
            completed = state.notificationRuntime
        ),
        PermissionOnboardingStep(
            title = "Phone state",
            summary = "Improves call-state detection when call notifications are limited.",
            action = PermissionAction.RequestPhoneState,
            completed = state.phoneState
        ),
        PermissionOnboardingStep(
            title = "Clipboard automation",
            summary = "Optional. Manual share works without accessibility access.",
            action = PermissionAction.OpenAccessibilitySettings,
            completed = state.accessibilityClipboard
        ),
        PermissionOnboardingStep(
            title = "Direct SMS mode",
            summary = "Future default-SMS-app path. Not requested until that flow exists.",
            action = PermissionAction.OpenDefaultSmsRole,
            completed = state.smsRole,
            enabled = state.smsRole
        ),
        PermissionOnboardingStep(
            title = "Shizuku helper",
            summary = "Optional advanced helper for future privileged continuity features.",
            action = PermissionAction.CheckShizuku,
            completed = state.shizukuAvailable,
            enabled = state.shizukuAvailable
        )
    )
}
