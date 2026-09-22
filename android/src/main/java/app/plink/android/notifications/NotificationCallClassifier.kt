package app.plink.android.notifications

import android.app.Notification

/** Framework metadata only; package names and translated action labels are not call authority. */
object NotificationCallClassifier {
    // String metadata avoids linking CallStyle (API31) on supported API26-30 devices.
    private const val CALL_STYLE = "android.app.Notification\$CallStyle"

    fun isCall(notification: Notification?): Boolean = notification != null &&
        isCall(notification.category) { key -> extra(notification, key) }

    internal fun isCall(category: String?, readExtra: (String) -> Any?): Boolean =
        category == Notification.CATEGORY_CALL ||
            (read(readExtra, "android.template") as? String) == CALL_STYLE ||
            callType(readExtra)?.let { it in 1..3 } == true

    internal fun callType(notification: Notification): Int? = callType { key -> extra(notification, key) }

    internal fun callType(readExtra: (String) -> Any?): Int? = read(readExtra, "android.callType") as? Int

    private fun read(readExtra: (String) -> Any?, key: String): Any? = try {
        readExtra(key)
    } catch (_: RuntimeException) {
        null
    }

    @Suppress("DEPRECATION")
    private fun extra(notification: Notification, key: String): Any? = notification.extras?.get(key)
}
