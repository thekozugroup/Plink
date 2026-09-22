package app.plink.android.notifications

import android.app.KeyguardManager
import android.app.Notification
import android.app.PendingIntent
import android.app.RemoteInput
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.Process
import android.os.UserHandle
import app.plink.android.protocol.NotificationActionsPolicy

/** Only original framework PendingIntents and their exact one RemoteInput are retained. */
object AndroidNotificationActions {
    fun isUserUnlocked(context: Context, user: UserHandle): Boolean? = runCatching {
        // Public KeyguardManager checks this process's user. Never substitute it for another profile.
        if (user != Process.myUserHandle()) null
        else context.getSystemService(KeyguardManager::class.java)?.let { !it.isDeviceLocked }
    }.getOrNull()

    fun describe(context: Context, action: Notification.Action, user: UserHandle,
                 unlocked: (UserHandle) -> Boolean? = { isUserUnlocked(context, it) }): NotificationActionSpec {
        val label = action.title?.toString().orEmpty()
        val auth = Build.VERSION.SDK_INT >= 31 && action.isAuthenticationRequired
        val inputs = action.remoteInputs.orEmpty()
        val data = action.dataOnlyRemoteInputs.orEmpty()
        val reason = when {
            !NotificationActionsPolicy.validLabel(label) -> "invalid_label"
            action.actionIntent == null -> "missing_intent"
            data.isNotEmpty() || inputs.any { it.isDataOnly } -> "data_input"
            inputs.size > 1 -> "multiple_inputs"
            inputs.size == 1 && !inputs[0].allowFreeFormInput -> "choice_input"
            inputs.size == 1 && inputs[0].resultKey.isNullOrBlank() -> "unsupported_input"
            else -> NotificationActionInputPolicy.reason(Build.VERSION.SDK_INT, inputs.size == 1) {
                if (Build.VERSION.SDK_INT >= 31) action.actionIntent.isImmutable else true
            }
        }
        val kind = if (reason != null) "phone" else if (inputs.isEmpty()) "invoke" else "text"
        return NotificationActionSpec(
            label = if (reason == "invalid_label") "Use your phone" else label,
            kind = kind, authenticationRequired = auth,
            inputLabel = if (kind == "text") inputs.single().label?.toString()?.takeIf(NotificationActionsPolicy::validLabel) else null,
            destructive = Build.VERSION.SDK_INT >= 28 && action.semanticAction == Notification.Action.SEMANTIC_ACTION_DELETE,
            reason = reason,
            unlocked = { unlocked(action.actionIntent?.creatorUserHandle ?: user) },
            execute = { text ->
                try {
                    when (kind) {
                        "invoke" -> action.actionIntent.send()
                        "text" -> {
                            val intent = Intent()
                            val results = Bundle().apply { putCharSequence(inputs.single().resultKey, requireNotNull(text)) }
                            RemoteInput.addResultsToIntent(inputs, intent, results)
                            if (Build.VERSION.SDK_INT >= 28) RemoteInput.setResultsSource(intent, RemoteInput.SOURCE_FREE_FORM_INPUT)
                            action.actionIntent.send(context, 0, intent)
                        }
                        else -> throw NotificationActionFailure("unsupported_input")
                    }
                } catch (_: PendingIntent.CanceledException) { throw NotificationActionFailure("action_canceled") }
            }
        )
    }
}
