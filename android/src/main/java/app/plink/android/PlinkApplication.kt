package app.plink.android

import android.app.Application
import android.provider.Settings
import app.plink.android.services.PlinkSessionController
import app.plink.android.storage.KeystorePairingSecretStore
import app.plink.android.storage.KeystorePairingStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

class PlinkApplication : Application() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private lateinit var sessionController: PlinkSessionController

    override fun onCreate() {
        super.onCreate()
        sessionController = PlinkSessionController(this, scope)
        restoreSavedSession()
    }

    private fun restoreSavedSession() {
        scope.launch {
            val store = KeystorePairingStore(this@PlinkApplication)
            val secretStore = KeystorePairingSecretStore(this@PlinkApplication)
            val device = store.all().firstOrNull() ?: return@launch
            val sessionKey = secretStore.load(device.sessionId) ?: return@launch
            sessionController.configure(
                localDeviceId = localDeviceId(),
                pairedDevice = device,
                sessionKey = sessionKey
            )
        }
    }

    private fun localDeviceId(): String {
        val androidId = Settings.Secure.getString(contentResolver, Settings.Secure.ANDROID_ID).orEmpty()
        return "pixel-${androidId.ifBlank { "local" }}"
    }
}
