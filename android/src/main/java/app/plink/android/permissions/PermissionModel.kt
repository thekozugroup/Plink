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
