package app.plink.android.debug

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Settings
import android.util.Log
import app.plink.android.pairing.PairedDevice
import app.plink.android.protocol.PlinkEnvelope
import app.plink.android.protocol.PlinkEventType
import app.plink.android.security.EncryptedFrameCodec
import app.plink.android.security.PlinkTime
import app.plink.android.storage.KeystorePairingSecretStore
import app.plink.android.storage.KeystorePairingStore
import app.plink.android.transport.SecureSocketPlinkClient
import java.time.Instant
import java.util.Base64
import java.util.UUID
import java.net.Socket
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

class DebugPairingReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val pending = goAsync()
        CoroutineScope(Dispatchers.IO).launch {
            runCatching {
                when (intent.action) {
                    ACTION_SEED_PAIRING -> seedPairing(context, intent)
                    ACTION_SEND_CLIPBOARD -> sendClipboard(context, intent)
                    ACTION_SEND_RAW -> sendRaw(intent)
                    else -> Log.w(TAG, "Unknown debug action: ${intent.action}")
                }
            }.onFailure { error ->
                Log.e(TAG, "Debug pairing action failed", error)
            }
            pending.finish()
        }
    }

    private suspend fun seedPairing(context: Context, intent: Intent) {
        val sessionId = intent.requiredString(EXTRA_SESSION_ID)
        val sessionKey = Base64.getDecoder().decode(intent.requiredString(EXTRA_SESSION_KEY_BASE64))
        val pairedDevice = PairedDevice(
            id = intent.getStringExtra(EXTRA_PAIRED_DEVICE_ID) ?: DEFAULT_MAC_DEVICE_ID,
            name = intent.getStringExtra(EXTRA_PAIRED_DEVICE_NAME) ?: "Mac",
            platform = "macos",
            endpoint = intent.requiredString(EXTRA_ENDPOINT),
            sessionId = sessionId,
            peerPublicKey = intent.getStringExtra(EXTRA_PEER_PUBLIC_KEY) ?: "debug-mac-public-key",
            localPublicKey = intent.getStringExtra(EXTRA_LOCAL_PUBLIC_KEY) ?: "debug-pixel-public-key",
            trusted = true
        )
        KeystorePairingStore(context).save(pairedDevice)
        KeystorePairingSecretStore(context).save(sessionKey, sessionId)
        Log.i(TAG, "Seeded debug pairing for ${pairedDevice.id} at ${pairedDevice.endpoint}")
    }

    private suspend fun sendClipboard(context: Context, intent: Intent) {
        val store = KeystorePairingStore(context)
        val device = store.all().firstOrNull()
            ?: error("No paired debug device is stored.")
        val sessionKey = KeystorePairingSecretStore(context).load(device.sessionId)
            ?: error("No session key is stored for ${device.sessionId}.")
        val (host, port) = parseEndpoint(device.endpoint)
        val text = intent.getStringExtra(EXTRA_TEXT) ?: "Plink debug clipboard ${Instant.now()}"
        val localDeviceId = intent.getStringExtra(EXTRA_LOCAL_DEVICE_ID) ?: context.localDeviceId()
        val envelope = PlinkEnvelope(
            id = "debug_${UUID.randomUUID()}",
            type = PlinkEventType.ClipboardUpdated,
            sentAt = PlinkTime.canonicalTimestamp(Instant.now()),
            sourceDeviceId = localDeviceId,
            targetDeviceId = device.id,
            payload = JsonObject(mapOf("text" to JsonPrimitive(text)))
        )
        Log.i(TAG, "Sending debug clipboard event to ${device.id} via ${device.endpoint}")
        SecureSocketPlinkClient(
            host = host,
            port = port,
            codec = EncryptedFrameCodec(sessionKey)
        ).send(envelope)
        Log.i(TAG, "Sent debug clipboard event to ${device.id} via ${device.endpoint}")
    }

    private fun sendRaw(intent: Intent) {
        val endpoint = intent.requiredString(EXTRA_ENDPOINT)
        val (host, port) = parseEndpoint(endpoint)
        val text = intent.getStringExtra(EXTRA_TEXT) ?: "plink-raw"
        Log.i(TAG, "Sending raw debug bytes to $endpoint")
        Socket(host, port).use { socket ->
            socket.getOutputStream().write(text.toByteArray(Charsets.UTF_8))
            socket.getOutputStream().flush()
        }
        Log.i(TAG, "Sent raw debug bytes to $endpoint")
    }

    private fun Intent.requiredString(key: String): String =
        getStringExtra(key)?.takeIf { it.isNotBlank() } ?: error("$key is required.")

    private fun Context.localDeviceId(): String {
        val androidId = Settings.Secure.getString(contentResolver, Settings.Secure.ANDROID_ID).orEmpty()
        return "pixel-${androidId.ifBlank { "local" }}"
    }

    private fun parseEndpoint(endpoint: String): Pair<String, Int> {
        val separator = endpoint.lastIndexOf(':')
        require(separator > 0 && separator < endpoint.lastIndex) { "Endpoint must be host:port." }
        return endpoint.substring(0, separator) to endpoint.substring(separator + 1).toInt()
    }

    companion object {
        private const val TAG = "PlinkDebugPairing"
        private const val DEFAULT_MAC_DEVICE_ID = "mac-demo"
        private const val ACTION_SEED_PAIRING = "app.plink.android.debug.SEED_PAIRING"
        private const val ACTION_SEND_CLIPBOARD = "app.plink.android.debug.SEND_CLIPBOARD"
        private const val ACTION_SEND_RAW = "app.plink.android.debug.SEND_RAW"
        private const val EXTRA_SESSION_ID = "session_id"
        private const val EXTRA_SESSION_KEY_BASE64 = "session_key_base64"
        private const val EXTRA_ENDPOINT = "endpoint"
        private const val EXTRA_PAIRED_DEVICE_ID = "paired_device_id"
        private const val EXTRA_PAIRED_DEVICE_NAME = "paired_device_name"
        private const val EXTRA_PEER_PUBLIC_KEY = "peer_public_key"
        private const val EXTRA_LOCAL_PUBLIC_KEY = "local_public_key"
        private const val EXTRA_LOCAL_DEVICE_ID = "local_device_id"
        private const val EXTRA_TEXT = "text"
    }
}
