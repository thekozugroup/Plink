package app.plink.android.permissions

import android.Manifest
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import androidx.core.content.ContextCompat
import app.plink.android.services.PlinkClipboardAccessibilityService
import app.plink.android.services.PlinkNotificationListenerService

object AndroidPermissionReader {
    fun read(context: Context): PermissionState = PermissionState(
        notificationListener = isNotificationListenerEnabled(context),
        notificationRuntime = hasRuntimeNotifications(context),
        phoneState = false,
        smsRole = false,
        accessibilityClipboard = isAccessibilityServiceEnabled(context),
        shizukuAvailable = ShizukuCapability.isAvailable()
    )

    fun settingsIntent(action: PermissionAction): Intent = when (action) {
        PermissionAction.OpenNotificationListenerSettings -> Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
        PermissionAction.RequestPostNotifications -> Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
        PermissionAction.RequestPhoneState -> Intent(Settings.ACTION_APPLICATION_SETTINGS)
        PermissionAction.OpenAccessibilitySettings -> Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
        PermissionAction.OpenDefaultSmsRole -> Intent(Settings.ACTION_MANAGE_DEFAULT_APPS_SETTINGS)
        PermissionAction.CheckShizuku -> Intent(Settings.ACTION_APPLICATION_SETTINGS)
    }.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

    private fun hasRuntimeNotifications(context: Context): Boolean =
        Build.VERSION.SDK_INT < 33 ||
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    private fun isNotificationListenerEnabled(context: Context): Boolean {
        val expected = ComponentName(context, PlinkNotificationListenerService::class.java).flattenToString()
        val enabled = Settings.Secure.getString(context.contentResolver, "enabled_notification_listeners").orEmpty()
        return enabled.split(':').any { it.equals(expected, ignoreCase = true) }
    }

    private fun isAccessibilityServiceEnabled(context: Context): Boolean {
        val expected = ComponentName(context, PlinkClipboardAccessibilityService::class.java).flattenToString()
        val enabled = Settings.Secure.getString(context.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES).orEmpty()
        return enabled.split(':').any { it.equals(expected, ignoreCase = true) }
    }
}
