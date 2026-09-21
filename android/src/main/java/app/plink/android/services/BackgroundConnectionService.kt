package app.plink.android.services

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import app.plink.android.PlinkApplication
import app.plink.android.R
import app.plink.android.SessionRestoreState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

sealed interface BackgroundConnectionState {
    data object Disabled : BackgroundConnectionState
    data object Starting : BackgroundConnectionState
    data object Running : BackgroundConnectionState
    data object AwaitingReconnect : BackgroundConnectionState
    data class RePairRequired(val message: String) : BackgroundConnectionState
    data class ActionRequired(val message: String) : BackgroundConnectionState
    data class Failed(val message: String) : BackgroundConnectionState
}

sealed interface BackgroundConnectionRequestResult {
    data object Started : BackgroundConnectionRequestResult
    data object Stopped : BackgroundConnectionRequestResult
    data class ActionRequired(val message: String) : BackgroundConnectionRequestResult
    data class Failed(val message: String) : BackgroundConnectionRequestResult
}

enum class BackgroundConnectionDecision {
    Start,
    ExplicitActionRequired,
    PairingRequired,
    NotificationPermissionRequired
}

object BackgroundConnectionPolicy {
    fun evaluate(
        explicitRequest: Boolean,
        paired: Boolean,
        notificationsAllowed: Boolean
    ): BackgroundConnectionDecision = when {
        !explicitRequest -> BackgroundConnectionDecision.ExplicitActionRequired
        !paired -> BackgroundConnectionDecision.PairingRequired
        !notificationsAllowed -> BackgroundConnectionDecision.NotificationPermissionRequired
        else -> BackgroundConnectionDecision.Start
    }
}

object BackgroundConnectionRuntime {
    private val _state = MutableStateFlow<BackgroundConnectionState>(BackgroundConnectionState.Disabled)
    val state: StateFlow<BackgroundConnectionState> = _state.asStateFlow()

    fun update(state: BackgroundConnectionState) {
        _state.value = state
    }
}

fun Context.notificationsAllowed(): Boolean {
    if (!getSystemService(NotificationManager::class.java).areNotificationsEnabled()) return false
    return Build.VERSION.SDK_INT < 33 || ContextCompat.checkSelfPermission(
        this,
        Manifest.permission.POST_NOTIFICATIONS
    ) == PackageManager.PERMISSION_GRANTED
}

class BackgroundConnectionService : Service() {
    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var statusJob: Job? = null
    override fun onCreate() {
        super.onCreate()
        createChannel()
        try {
            startForeground()
        } catch (_: SecurityException) {
            val app = applicationContext as PlinkApplication
            app.featureSettings.setBackgroundConnectionEnabled(false)
            BackgroundConnectionRuntime.update(
                BackgroundConnectionState.Failed("Plink could not show its background connection notification.")
            )
            stopSelf()
        } catch (_: IllegalStateException) {
            val app = applicationContext as PlinkApplication
            app.featureSettings.setBackgroundConnectionEnabled(false)
            BackgroundConnectionRuntime.update(
                BackgroundConnectionState.Failed("Android could not start the background connection.")
            )
            stopSelf()
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val app = applicationContext as PlinkApplication
        if (intent?.action == ACTION_STOP) {
            app.featureSettings.setBackgroundConnectionEnabled(false)
            stopConnection()
            return START_NOT_STICKY
        }
        if (!app.featureSettings.backgroundConnectionEnabled.value) {
            stopConnection()
            return START_NOT_STICKY
        }
        if (!applicationContext.notificationsAllowed()) {
            app.featureSettings.setBackgroundConnectionEnabled(false)
            BackgroundConnectionRuntime.update(
                BackgroundConnectionState.ActionRequired("Enable Plink notifications to keep the connection active.")
            )
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }
        if (app.sessionRestoreState.value == SessionRestoreState.RESTORING) {
            BackgroundConnectionRuntime.update(BackgroundConnectionState.Starting)
            serviceScope.launch {
                val restored = withTimeoutOrNull(RESTORE_WAIT_MILLIS) {
                    app.sessionRestoreState.first { it == SessionRestoreState.COMPLETE }
                }
                if (restored == null) {
                    BackgroundConnectionRuntime.update(
                        BackgroundConnectionState.ActionRequired("Open Plink to finish restoring the saved connection.")
                    )
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    stopSelf()
                } else {
                    activate(app)
                }
            }
            return START_STICKY
        }
        return activate(app)
    }

    private fun activate(app: PlinkApplication): Int {
        return when (app.sessionController.status.value) {
            SessionStatus.READY -> {
                app.sessionController.retryPendingEvents()
                BackgroundConnectionRuntime.update(BackgroundConnectionState.Running)
                updateNotification(awaitingReconnect = false)
                observeSessionStatus(app)
                START_STICKY
            }
            SessionStatus.AWAITING_RECONNECT -> {
                BackgroundConnectionRuntime.update(BackgroundConnectionState.AwaitingReconnect)
                updateNotification(awaitingReconnect = true)
                observeSessionStatus(app)
                START_STICKY
            }
            SessionStatus.DISCONNECTED, SessionStatus.REPAIR_REQUIRED -> {
                app.featureSettings.setBackgroundConnectionEnabled(false)
                BackgroundConnectionRuntime.update(
                    BackgroundConnectionState.ActionRequired("Pair with a Mac before enabling background connection.")
                )
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                START_NOT_STICKY
            }
        }
    }

    private fun observeSessionStatus(app: PlinkApplication) {
        if (statusJob?.isActive == true) return
        statusJob = serviceScope.launch {
            app.sessionController.status.collect { status ->
                if (!app.featureSettings.backgroundConnectionEnabled.value) return@collect
                when (status) {
                    SessionStatus.READY -> {
                        app.sessionController.retryPendingEvents()
                        BackgroundConnectionRuntime.update(BackgroundConnectionState.Running)
                        updateNotification(awaitingReconnect = false)
                    }
                    SessionStatus.AWAITING_RECONNECT -> {
                        BackgroundConnectionRuntime.update(BackgroundConnectionState.AwaitingReconnect)
                        updateNotification(awaitingReconnect = true)
                    }
                    SessionStatus.DISCONNECTED, SessionStatus.REPAIR_REQUIRED -> {
                        app.featureSettings.setBackgroundConnectionEnabled(false)
                        BackgroundConnectionRuntime.update(
                            BackgroundConnectionState.ActionRequired(
                                "Pair with a Mac before enabling background connection."
                            )
                        )
                        stopForeground(STOP_FOREGROUND_REMOVE)
                        stopSelf()
                    }
                }
            }
        }
    }

    override fun onDestroy() {
        serviceScope.cancel()
        if (BackgroundConnectionRuntime.state.value == BackgroundConnectionState.Running ||
            BackgroundConnectionRuntime.state.value == BackgroundConnectionState.AwaitingReconnect
        ) {
            BackgroundConnectionRuntime.update(BackgroundConnectionState.Disabled)
        }
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun startForeground() {
        val notification = notification(awaitingReconnect = false)
        ServiceCompat.startForeground(
            this,
            NOTIFICATION_ID,
            notification,
            if (Build.VERSION.SDK_INT >= 34) ServiceInfo.FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING else 0
        )
    }

    private fun updateNotification(awaitingReconnect: Boolean) {
        getSystemService(NotificationManager::class.java).notify(
            NOTIFICATION_ID,
            notification(awaitingReconnect)
        )
    }

    private fun notification(awaitingReconnect: Boolean): android.app.Notification {
        val stopIntent = Intent(this, BackgroundConnectionService::class.java).setAction(ACTION_STOP)
        val stopPendingIntent = PendingIntent.getService(
            this,
            0,
            stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_plink)
            .setContentTitle(if (awaitingReconnect) "Plink paired" else "Plink connection active")
            .setContentText(if (awaitingReconnect) {
                "Waiting for your paired Mac to reconnect"
            } else {
                "Keeping your phone available to your paired Mac"
            })
            .setOngoing(true)
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .addAction(0, "Stop", stopPendingIntent)
            .build()
    }

    private fun createChannel() {
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "Background connection", NotificationManager.IMPORTANCE_LOW)
        )
    }

    private fun stopConnection() {
        BackgroundConnectionRuntime.update(BackgroundConnectionState.Disabled)
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    companion object {
        const val ACTION_STOP = "app.plink.android.action.STOP_BACKGROUND_CONNECTION"
        private const val CHANNEL_ID = "background_connection"
        private const val NOTIFICATION_ID = 45731
        private const val RESTORE_WAIT_MILLIS = 5_000L
    }
}
