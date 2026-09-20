package app.plink.android

import android.content.Context
import android.os.Build
import app.plink.android.features.ContinuityFeature
import app.plink.android.pairing.PairedDevice
import app.plink.android.security.EncryptedFrameCodec
import app.plink.android.services.SessionStatus
import app.plink.android.screen.ScreenPreviewPhase
import app.plink.android.storage.KeystorePairingStore
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext
import java.io.File
import java.security.MessageDigest
import java.util.UUID

/** Owns only an ephemeral emulator session; never writes a saved pairing or key. */
internal class ScreenPreviewTestSession private constructor(
    val application: PlinkApplication,
    private val originalFeatures: Map<ContinuityFeature, Boolean>,
    private val originalPreferenceValues: Map<String, *>,
    private val ownedFiles: List<File>,
    private val absentDirectories: List<File>,
) {
    fun isCapturing(): Boolean = application.sessionController.screenPreviewState.value.phase == ScreenPreviewPhase.CAPTURING

    fun isStopped(): Boolean = application.sessionController.screenPreviewState.value.phase == ScreenPreviewPhase.IDLE

    fun requireNoCaptureError() {
        val state = application.sessionController.screenPreviewState.value
        check(state.phase != ScreenPreviewPhase.ERROR) { state.message ?: "Screen capture failed." }
    }

    suspend fun close() {
        // State files may only be removed after producers, sockets and capture
        // callbacks have actually stopped; a stop request alone is not a barrier.
        application.sessionController.stopAndAwait()
        originalFeatures.forEach { (feature, enabled) ->
            application.featureSettings.setEnabled(feature, enabled)
        }
        // Preserve absent preference keys as well as explicit Boolean values.
        val preferences = application.getSharedPreferences("feature_settings", Context.MODE_PRIVATE)
        val editor = preferences.edit()
        originalFeatures.keys.forEach { feature ->
            val key = "feature_${feature.name.lowercase()}"
            val previous = originalPreferenceValues[key]
            if (previous is Boolean) editor.putBoolean(key, previous) else editor.remove(key)
        }
        check(editor.commit()) { "Could not restore test feature preferences." }
        ownedFiles.forEach { file ->
            check(!file.exists() || file.delete()) { "Could not remove synthetic session state." }
        }
        absentDirectories.forEach { directory ->
            if (directory.exists() && directory.listFiles()?.isEmpty() == true) {
                check(directory.delete()) { "Could not remove empty synthetic state directory." }
            }
        }
    }

    companion object {
        const val PHONE_ID = "test-pixel"
        const val MAC_ID = "test-mac"

        suspend fun open(context: Context, key: ByteArray, macHost: String, macPort: Int, replyPort: Int): ScreenPreviewTestSession {
            check(Build.MODEL.startsWith("sdk_gphone") && Build.VERSION.SDK_INT >= 34) {
                "Screen capture integration is restricted to the owned API34+ emulator."
            }
            check(macHost == "10.0.2.2" && macPort in 1..65535 && replyPort in 1..65535)
            check(key.size == 32)
            val application = context.applicationContext as PlinkApplication
            check(application.sessionRestoreState.value == SessionRestoreState.COMPLETE)
            check(KeystorePairingStore(application).all().isEmpty()) { "Preserve existing saved pairings; use an isolated emulator." }
            check(application.sessionController.status.value == SessionStatus.DISCONNECTED)
            check(application.invalidateSavedSessionRestoreAndSnapshot() == null)
            val preferences = application.getSharedPreferences("feature_settings", Context.MODE_PRIVATE)
            val originalPreferenceValues = preferences.all.toMap()
            val originalFeatures = application.featureSettings.enabled.value.toMap()
            val codec = EncryptedFrameCodec(key)
            val stateFiles = listOf(PHONE_ID to MAC_ID, MAC_ID to PHONE_ID).flatMap { (source, target) ->
                val name = digest(codec.stateScope(source, target))
                listOf(File(application.filesDir, "transport-state/$name.json"), File(application.filesDir, "transport-state/$name.lock"))
            } + File(application.filesDir, "event-outbox/${digest(MAC_ID)}.outbox")
            check(stateFiles.none(File::exists)) { "Synthetic state already exists; refusing to overwrite it." }
            val absentDirectories = stateFiles.mapNotNull { it.parentFile }.distinct().filterNot(File::exists)
            val owner = ScreenPreviewTestSession(application, originalFeatures, originalPreferenceValues, stateFiles, absentDirectories)
            try {
                // Suppress unrelated collectors for this screen-only fixture.
                ContinuityFeature.entries.forEach {
                    application.featureSettings.setEnabled(it, it == ContinuityFeature.ScreenMirror)
                }
                application.sessionController.configure(
                    localDeviceId = PHONE_ID,
                    pairedDevice = PairedDevice(
                        id = MAC_ID, name = "Plink synthetic Mac", platform = "macos",
                        endpoint = "$macHost:$macPort", sessionId = UUID.randomUUID().toString(),
                        peerPublicKey = "synthetic-test-only", localPublicKey = "synthetic-test-only",
                        trusted = true, securityVersion = 2,
                    ),
                    sessionKey = key,
                    localReplyPort = replyPort,
                )
                check(application.sessionController.status.value == SessionStatus.READY)
                return owner
            } catch (failure: Throwable) {
                runCatching { withContext(NonCancellable) { owner.close() } }
                    .onFailure { failure.addSuppressed(it) }
                throw failure
            }
        }

        private fun digest(text: String): String = MessageDigest.getInstance("SHA-256")
            .digest(text.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }
    }
}
