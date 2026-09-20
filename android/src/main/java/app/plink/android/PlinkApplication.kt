package app.plink.android

import android.app.Application
import android.provider.Settings
import app.plink.android.services.PlinkSessionController
import app.plink.android.services.BackgroundConnectionDecision
import app.plink.android.services.BackgroundConnectionPolicy
import app.plink.android.services.BackgroundConnectionRequestResult
import app.plink.android.services.BackgroundConnectionRuntime
import app.plink.android.services.BackgroundConnectionService
import app.plink.android.services.BackgroundConnectionState
import app.plink.android.services.SessionStatus
import app.plink.android.services.ActivePlinkSession
import app.plink.android.services.notificationsAllowed
import android.content.Intent
import androidx.core.content.ContextCompat
import app.plink.android.features.FeatureSettings
import app.plink.android.storage.KeystorePairingSecretStore
import app.plink.android.storage.KeystorePairingStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.concurrent.atomic.AtomicLong

enum class SessionRestoreState { RESTORING, COMPLETE }

class PlinkApplication : Application() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val restoreLock = Any()
    private val restoreGeneration = AtomicLong()
    private val _sessionRestoreState = MutableStateFlow(SessionRestoreState.COMPLETE)
    val sessionRestoreState: StateFlow<SessionRestoreState> = _sessionRestoreState.asStateFlow()
    lateinit var sessionController: PlinkSessionController
        private set
    lateinit var featureSettings: FeatureSettings
        private set
    val backgroundConnectionState: StateFlow<BackgroundConnectionState>
        get() = BackgroundConnectionRuntime.state

    override fun onCreate() {
        super.onCreate()
        featureSettings = FeatureSettings(this)
        sessionController = PlinkSessionController(this, featureSettings, scope)
        restoreSavedSession()
    }

    fun requestBackgroundConnection(enabled: Boolean): BackgroundConnectionRequestResult {
        if (!enabled) {
            featureSettings.setBackgroundConnectionEnabled(false)
            stopService(Intent(this, BackgroundConnectionService::class.java))
            BackgroundConnectionRuntime.update(BackgroundConnectionState.Disabled)
            return BackgroundConnectionRequestResult.Stopped
        }
        return when (BackgroundConnectionPolicy.evaluate(
            explicitRequest = true,
            paired = sessionController.status.value == SessionStatus.READY,
            notificationsAllowed = notificationsAllowed()
        )) {
            BackgroundConnectionDecision.PairingRequired -> actionRequired("Pair with a Mac first.")
            BackgroundConnectionDecision.NotificationPermissionRequired -> actionRequired(
                "Enable Plink notifications to keep the connection active."
            )
            BackgroundConnectionDecision.ExplicitActionRequired -> actionRequired(
                "Enable background connection from Plink settings."
            )
            BackgroundConnectionDecision.Start -> {
                featureSettings.setBackgroundConnectionEnabled(true)
                BackgroundConnectionRuntime.update(BackgroundConnectionState.Starting)
                try {
                    ContextCompat.startForegroundService(this, Intent(this, BackgroundConnectionService::class.java))
                    BackgroundConnectionRequestResult.Started
                } catch (_: SecurityException) {
                    startFailed("Plink lacks permission to run the background connection.")
                } catch (_: RuntimeException) {
                    startFailed("Android blocked the background connection start. Open Plink and try again.")
                }
            }
        }
    }

    private fun actionRequired(message: String): BackgroundConnectionRequestResult.ActionRequired {
        featureSettings.setBackgroundConnectionEnabled(false)
        BackgroundConnectionRuntime.update(BackgroundConnectionState.ActionRequired(message))
        return BackgroundConnectionRequestResult.ActionRequired(message)
    }

    private fun startFailed(message: String): BackgroundConnectionRequestResult.Failed {
        featureSettings.setBackgroundConnectionEnabled(false)
        BackgroundConnectionRuntime.update(BackgroundConnectionState.Failed(message))
        return BackgroundConnectionRequestResult.Failed(message)
    }

    private fun restoreSavedSession() {
        val generation = synchronized(restoreLock) {
            restoreGeneration.incrementAndGet().also {
                _sessionRestoreState.value = SessionRestoreState.RESTORING
            }
        }
        scope.launch {
            try {
                val store = KeystorePairingStore(this@PlinkApplication)
                val secretStore = KeystorePairingSecretStore(this@PlinkApplication)
                val devices = store.all()
                val selectedId = store.activeDeviceId()
                if (selectedId == null) {
                    if (devices.isNotEmpty()) {
                        mutateIfRestoreCurrent(generation) {
                            featureSettings.setBackgroundConnectionEnabled(false)
                            sessionController.markRepairRequired()
                            BackgroundConnectionRuntime.update(
                                BackgroundConnectionState.RePairRequired("Re-pair with a Mac before reconnecting.")
                            )
                        }
                    }
                    return@launch
                }
                val device = devices.singleOrNull { it.id == selectedId } ?: run {
                    mutateIfRestoreCurrent(generation) {
                        featureSettings.setBackgroundConnectionEnabled(false)
                        BackgroundConnectionRuntime.update(
                            BackgroundConnectionState.ActionRequired("Select an available paired Mac before reconnecting.")
                        )
                    }
                    return@launch
                }
                if (!device.trusted || device.securityVersion != CURRENT_SECURITY_VERSION) {
                    mutateIfRestoreCurrent(generation) {
                        featureSettings.setBackgroundConnectionEnabled(false)
                        sessionController.markRepairRequired()
                        BackgroundConnectionRuntime.update(
                            BackgroundConnectionState.RePairRequired("Re-pair with this Mac before reconnecting.")
                        )
                    }
                    return@launch
                }
                val sessionKey = secretStore.load(device.sessionId) ?: return@launch
                mutateIfRestoreCurrent(generation) {
                    sessionController.restoreIfDisconnected(
                        localDeviceId = localDeviceId(),
                        pairedDevice = device,
                        sessionKey = sessionKey
                    )
                }
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (_: Exception) {
                mutateIfRestoreCurrent(generation) {
                    sessionController.stop()
                    featureSettings.setBackgroundConnectionEnabled(false)
                    BackgroundConnectionRuntime.update(
                        BackgroundConnectionState.Failed("Plink could not restore the saved connection. Open Plink and try again.")
                    )
                }
            } finally {
                mutateIfRestoreCurrent(generation) {
                    _sessionRestoreState.value = SessionRestoreState.COMPLETE
                }
            }
        }
    }

    fun invalidateSavedSessionRestore() {
        synchronized(restoreLock) {
            restoreGeneration.incrementAndGet()
            _sessionRestoreState.value = SessionRestoreState.COMPLETE
        }
    }

    fun invalidateSavedSessionRestoreAndSnapshot(): ActivePlinkSession? = synchronized(restoreLock) {
        restoreGeneration.incrementAndGet()
        _sessionRestoreState.value = SessionRestoreState.COMPLETE
        sessionController.snapshot()
    }

    private fun mutateIfRestoreCurrent(generation: Long, mutation: () -> Unit): Boolean =
        synchronized(restoreLock) {
            if (restoreGeneration.get() != generation) return@synchronized false
            mutation()
            true
        }

    private fun localDeviceId(): String {
        val androidId = Settings.Secure.getString(contentResolver, Settings.Secure.ANDROID_ID).orEmpty()
        return "pixel-${androidId.ifBlank { "local" }}"
    }

    private companion object {
        const val CURRENT_SECURITY_VERSION = 2
    }
}
