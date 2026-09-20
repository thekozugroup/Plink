package app.plink.android.clipboard

import android.app.AppOpsManager
import android.app.KeyguardManager
import android.content.ClipData
import android.content.ClipboardManager
import android.content.ComponentName
import android.content.Context
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.os.IBinder
import android.os.Build
import android.os.PersistableBundle
import android.os.Process
import android.os.SystemClock
import android.os.UserManager
import androidx.annotation.MainThread
import app.plink.android.features.FeatureSettings
import app.plink.android.protocol.PlinkEnvelope
import app.plink.android.protocol.PlinkEventType
import app.plink.android.services.PlinkSessionController
import app.plink.android.services.SharedOutboundBridge
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import rikka.shizuku.Shizuku
import java.time.Instant
import java.util.UUID

data class ClipboardSyncState(
    val message: String = "Automatic clipboard sync is off.",
    val canSend: Boolean = false,
    val canReceive: Boolean = false,
    val needsPermission: Boolean = false
)

/** Captured session authority; it contains no pairing secrets. */
class ClipboardConnection(
    val generation: Long,
    val localDeviceId: String,
    val peerDeviceId: String,
    val isCurrent: () -> Boolean
)

class ClipboardSyncController(
    context: Context,
    private val settings: FeatureSettings,
    private val sessions: PlinkSessionController
) {
    private val context = context.applicationContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val keyguard = context.getSystemService(KeyguardManager::class.java)
    private val users = context.getSystemService(UserManager::class.java)
    private val clipboard = context.getSystemService(ClipboardManager::class.java)
    private val policy = ClipboardSyncPolicy()
    private val _state = MutableStateFlow(ClipboardSyncState())
    val state: StateFlow<ClipboardSyncState> = _state.asStateFlow()
    private val refresh = MutableStateFlow(0L)
    private var observer: Job? = null
    private var sendJob: Job? = null
    private var bound: ServiceConnection? = null
    private var reader: IClipboardReader? = null
    @Volatile private var helperDead = false
    private val args = Shizuku.UserServiceArgs(ComponentName(context, ShizukuClipboardService::class.java))
        .daemon(false).processNameSuffix("clipboard").tag("plink-clipboard").version(1)
    private val binderReceived = Shizuku.OnBinderReceivedListener { refresh() }
    private val binderDead = Shizuku.OnBinderDeadListener {
        invalidate()
        _state.value = ClipboardSyncState("Shizuku stopped. Open Shizuku to restart it.")
        refresh()
    }
    private val permissionResult = Shizuku.OnRequestPermissionResultListener { code, _ ->
        if (code == PERMISSION_REQUEST) {
            invalidate()
            refresh()
        }
    }

    fun start() {
        if (observer != null) return
        Shizuku.addBinderReceivedListenerSticky(binderReceived)
        Shizuku.addBinderDeadListener(binderDead)
        Shizuku.addRequestPermissionResultListener(permissionResult)
        observer = scope.launch {
            combine(settings.clipboardSyncEnabled, sessions.status, refresh) { enabled, _, _ -> enabled }
                .collectLatest { enabled ->
                    invalidate()
                    if (!enabled) {
                        _state.value = ClipboardSyncState()
                        return@collectLatest
                    }
                    try { monitor() } finally { invalidate() }
                }
        }
    }

    @MainThread fun setEnabled(enabled: Boolean) {
        if (enabled && (!Shizuku.pingBinder() || !permissionGranted())) {
            _state.value = ClipboardSyncState("Start Shizuku and explicitly allow Plink before enabling automatic sync.",
                needsPermission = Shizuku.pingBinder())
            return
        }
        // Synchronous invalidation ensures Off cannot leave a pending read or send authorized.
        invalidate()
        settings.setClipboardSyncEnabled(enabled)
        refresh()
    }

    fun refresh() { refresh.value += 1 }

    /** UI-only setup action: no automatic permission request, install, or server startup. */
    fun requestShizukuPermission() {
        if (!Shizuku.pingBinder()) {
            _state.value = ClipboardSyncState("Open Shizuku and start it, then return to Plink.")
            return
        }
        try {
            if (Shizuku.checkSelfPermission() != PackageManager.PERMISSION_GRANTED) {
                Shizuku.requestPermission(PERMISSION_REQUEST)
            } else refresh()
        } catch (_: RuntimeException) {
            _state.value = ClipboardSyncState("Shizuku authorization is unavailable. Open Shizuku to review access.")
        }
    }

    fun stop() {
        observer?.cancel()
        observer = null
        invalidate()
        Shizuku.removeBinderReceivedListener(binderReceived)
        Shizuku.removeBinderDeadListener(binderDead)
        Shizuku.removeRequestPermissionResultListener(permissionResult)
        scope.cancel()
    }

    private suspend fun monitor() {
        while (scope.isActive && settings.clipboardSyncEnabled.value) {
            val connection = sessions.clipboardConnection()
            val problem = when {
                connection == null -> "Clipboard sync is waiting for your Mac."
                Process.myUid() / 100_000 != 0 -> "Clipboard sync supports only the Pixel personal profile."
                !unlockedForegroundUser() -> "Unlock the Pixel personal profile to sync clipboard text."
                !Shizuku.pingBinder() -> "Open Shizuku and start it to send copied text from Pixel."
                !permissionGranted() -> "Allow Plink in Shizuku to send copied text from Pixel."
                runCatching { Shizuku.getUid() != 2000 }.getOrDefault(true) ->
                    "Clipboard sync requires Shizuku running as shell."
                else -> null
            }
            if (problem != null) {
                invalidate()
                _state.value = ClipboardSyncState(problem,
                    canReceive = connection != null && unlockedForegroundUser(),
                    needsPermission = Shizuku.pingBinder() && !permissionGranted())
                delay(POLL_MILLIS)
                continue
            }
            val live = requireNotNull(connection)
            val epoch = ClipboardSyncPolicy.Epoch(live.generation, settings.clipboardSyncRevision)
            policy.begin(epoch)
            try {
                val service = reader ?: bindReader()
                if (!valid(live, epoch)) { delay(POLL_MILLIS); continue }
                val capture = policy.capture() ?: continue
                val result = withContext(Dispatchers.IO) {
                    // Recheck immediately before the Binder call, not only before scheduling IO.
                    check(valid(live, epoch) && policy.isCurrent(capture))
                    service.readClipboard()
                }
                if (!valid(live, epoch) || !policy.isCurrent(capture)) { delay(POLL_MILLIS); continue }
                check(result.getString(ShizukuClipboardService.STATUS) == ShizukuClipboardService.OK)
                val text = policy.observe(capture, result.getString(ShizukuClipboardService.TEXT),
                    result.getLong(ShizukuClipboardService.TIMESTAMP),
                    result.getBoolean(ShizukuClipboardService.SENSITIVE),
                    result.getString(ShizukuClipboardService.ORIGIN))
                _state.value = ClipboardSyncState("Automatic clipboard sync is active while Pixel is unlocked.",
                    canSend = true, canReceive = true)
                if (!settings.backgroundConnectionEnabled.value) {
                    _state.value = _state.value.copy(message = "Clipboard sync is active. Enable Background connection to keep Plink connected when closed.")
                }
                if (text != null) policy.capture()?.let { sendLatest(text, live, it) }
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (_: Exception) {
                invalidate()
                _state.value = ClipboardSyncState("Shizuku clipboard access failed. Reopen Plink after reviewing Shizuku.",
                    canReceive = live.isCurrent() && unlockedForegroundUser())
                // Do not repeatedly create privileged processes after an unsupported API or denied read.
                return
            }
            delay(POLL_MILLIS)
        }
    }

    private fun permissionGranted(): Boolean = runCatching {
        Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED &&
            Shizuku.checkRemotePermission("android.permission.READ_CLIPBOARD_IN_BACKGROUND") == PackageManager.PERMISSION_GRANTED
    }.getOrDefault(false)

    private fun unlockedForegroundUser(): Boolean = runCatching {
        Process.myUid() / 100_000 == 0 && Build.VERSION.SDK_INT >= 31 &&
            users.isUserForeground && users.isUserUnlocked && !keyguard.isDeviceLocked
    }.getOrDefault(false)

    private fun valid(connection: ClipboardConnection, epoch: ClipboardSyncPolicy.Epoch): Boolean =
        settings.clipboardSyncEnabled.value && settings.clipboardSyncRevision == epoch.enableRevision &&
            connection.isCurrent() && unlockedForegroundUser() && !helperDead &&
            Shizuku.pingBinder() && permissionGranted()

    private suspend fun bindReader(): IClipboardReader {
        val ready = CompletableDeferred<IClipboardReader>()
        helperDead = false
        val connection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName, service: IBinder) {
                if (bound !== this) return
                val api = IClipboardReader.Stub.asInterface(service)
                reader = api
                ready.complete(api)
            }
            override fun onServiceDisconnected(name: ComponentName) {
                if (bound !== this) return
                helperDead = true
                reader = null
                policy.clear()
                sendJob?.cancel()
                ready.completeExceptionally(IllegalStateException("Clipboard helper stopped."))
                refresh()
            }
        }
        bound = connection
        Shizuku.bindUserService(args, connection)
        return withTimeoutOrNull(5_000) { ready.await() }
            ?: error("Clipboard helper did not connect.")
    }

    private fun invalidate() {
        policy.clear()
        sendJob?.cancel()
        sendJob = null
        val previousReader = reader
        reader = null
        val connection = bound
        bound = null
        if (connection != null) {
            val removed = runCatching { Shizuku.unbindUserService(args, connection, true) }.isSuccess
            // The server may already be dead or authorization revoked. Stop our own helper directly.
            if (!removed) runCatching { previousReader?.destroy() }
        }
    }

    private fun sendLatest(text: String, connection: ClipboardConnection, capture: ClipboardSyncPolicy.Capture) {
        sendJob?.cancel()
        sendJob = scope.launch {
            val deadline = SystemClock.elapsedRealtime() + 750
            val message = PlinkEnvelope(
                id = "clip_${UUID.randomUUID()}", type = PlinkEventType.ClipboardUpdated,
                sentAt = Instant.now().toString(), sourceDeviceId = connection.localDeviceId,
                targetDeviceId = connection.peerDeviceId, payload = buildJsonObject {
                    put("text", text)
                    put("localOnly", false)
                    put("automatic", true)
                }
            )
            try {
                withTimeout(750) {
                    SharedOutboundBridge.sendAwaitable(message, stillValid = {
                        SystemClock.elapsedRealtime() < deadline &&
                            valid(connection, capture.epoch) && policy.isCurrent(capture)
                    })
                }
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (_: Exception) {
                // Volatile best effort: never save, retry, or log clipboard content.
            }
        }
    }

    /** Called on Main under the current inbound admission. Manual handoffs use another path. */
    @MainThread fun applyRemote(command: PlinkEnvelope, generation: Long, enableRevision: Long) {
        // The caller holds this generation's admission lock. Do not reacquire session locks here.
        check(settings.clipboardSyncEnabled.value && settings.clipboardSyncRevision == enableRevision)
        check(unlockedForegroundUser())
        check(command.payload["automatic"]?.jsonPrimitive?.booleanOrNull == true)
        check(command.payload["localOnly"]?.jsonPrimitive?.booleanOrNull != true)
        check(command.payload["sensitive"]?.jsonPrimitive?.booleanOrNull != true)
        val text = checkNotNull(command.payload["text"]?.jsonPrimitive?.contentOrNull)
        check(ClipboardSyncPolicy.acceptable(text))
        val ops = context.getSystemService(AppOpsManager::class.java)
        @Suppress("DEPRECATION")
        check(ops.checkOpNoThrow("android:write_clipboard", Process.myUid(), context.packageName) == AppOpsManager.MODE_ALLOWED)
        val clip = ClipData.newPlainText("Plink", text)
        clip.description.extras = PersistableBundle().apply {
            putString(ShizukuClipboardService.ORIGIN, command.id)
        }
        clipboard.setPrimaryClip(clip)
        policy.remoteApplied(ClipboardSyncPolicy.Epoch(generation, enableRevision), text, command.id)
        sendJob?.cancel()
    }

    companion object {
        private const val POLL_MILLIS = 1_000L
        private const val PERMISSION_REQUEST = 7312
    }
}
