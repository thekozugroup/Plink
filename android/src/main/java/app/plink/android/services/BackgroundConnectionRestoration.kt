package app.plink.android.services

import app.plink.android.SessionRestoreState
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.collect

/** Collected only while the activity is resumed; no start request survives collector cancellation. */
internal suspend fun observeBackgroundConnectionRestoration(
    restoreState: StateFlow<SessionRestoreState>,
    enabled: StateFlow<Boolean>,
    sessionStatus: StateFlow<SessionStatus>,
    runtime: StateFlow<BackgroundConnectionState>,
    isResumed: () -> Boolean,
    notificationsAllowed: () -> Boolean,
    start: () -> Unit
) {
    combine(restoreState, enabled, sessionStatus, runtime) { _, _, _, _ -> Unit }.collect {
        // Read live values, not the possibly queued combine snapshot. Do not suspend before start.
        if (!isResumed() || restoreState.value != SessionRestoreState.COMPLETE || !enabled.value) return@collect
        if (sessionStatus.value != SessionStatus.READY && sessionStatus.value != SessionStatus.AWAITING_RECONNECT) return@collect
        if (!notificationsAllowed()) return@collect
        when (runtime.value) {
            BackgroundConnectionState.Starting,
            BackgroundConnectionState.Running,
            BackgroundConnectionState.AwaitingReconnect -> return@collect
            else -> start()
        }
    }
}

/** Shared by explicit enable and restoration; only explicit enable may turn the preference on. */
internal fun startBackgroundConnectionService(
    setEnabled: (Boolean) -> Unit,
    setState: (BackgroundConnectionState) -> Unit,
    startService: () -> Unit
): BackgroundConnectionRequestResult {
    setState(BackgroundConnectionState.Starting)
    val message = try {
        startService()
        return BackgroundConnectionRequestResult.Started
    } catch (_: SecurityException) {
        "Plink lacks permission to run the background connection."
    } catch (_: RuntimeException) {
        "Android blocked the background connection start. Open Plink and try again."
    }
    setEnabled(false)
    setState(BackgroundConnectionState.Failed(message))
    return BackgroundConnectionRequestResult.Failed(message)
}
