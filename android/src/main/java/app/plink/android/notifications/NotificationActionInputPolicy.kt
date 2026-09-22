package app.plink.android.notifications

/** Public PendingIntent mutability inspection is unavailable before Android 31. */
object NotificationActionInputPolicy {
    fun reason(sdkInt: Int, textInput: Boolean, isImmutable: () -> Boolean): String? = when {
        !textInput -> null
        sdkInt < 31 -> "unsupported_input"
        isImmutable() -> "immutable_input"
        else -> null
    }
}
