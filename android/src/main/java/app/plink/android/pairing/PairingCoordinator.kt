package app.plink.android.pairing

import android.content.Context
import android.os.Build
import android.os.SystemClock
import android.provider.Settings
import app.plink.android.PlinkApplication
import app.plink.android.protocol.PlinkEventType
import app.plink.android.security.EncryptedFrameCodec
import app.plink.android.security.EncryptedPlinkFrame
import app.plink.android.security.FileFrameStateStore
import app.plink.android.security.FrameStateStore
import app.plink.android.security.ReplayWindow
import app.plink.android.services.SessionStatus
import app.plink.android.services.ActivePlinkSession
import app.plink.android.storage.KeystorePairingSecretStore
import app.plink.android.storage.KeystorePairingStore
import app.plink.android.storage.PairingSecretStore
import app.plink.android.storage.PairingStore
import app.plink.android.transport.LengthPrefixedFrameCodec
import java.io.DataOutputStream
import java.io.File
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.time.Instant
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonPrimitive

/** Lifecycle commands, including the complete trust transaction, have one serialized owner. */
class PairingCoordinator internal constructor(
    private val environment: Environment,
    dispatcher: CoroutineDispatcher = Dispatchers.IO
) {
    constructor(context: Context) : this(environment(context.applicationContext as PlinkApplication))

    data class State(val code: PairingVerificationCode? = null, val message: String = "Select your Mac to compare codes.", val canConfirm: Boolean = false, val paired: Boolean = false)

    internal data class Prepared(
        val offer: PairingOffer, val confirmation: PairingConfirmation, val candidate: PairedDevice,
        val key: ByteArray, val code: PairingVerificationCode
    )

    internal class Environment(
        val store: PairingStore,
        val secrets: PairingSecretStore,
        val frameState: FrameStateStore,
        val prepare: (PairingOffer, String) -> Prepared,
        val snapshot: () -> ActivePlinkSession?,
        val stop: () -> Unit,
        val configure: (ActivePlinkSession, Int) -> Unit,
        val connect: (Int) -> Connection,
        val now: () -> Long
    )

    /** Workers exchange bytes only; keys and trust decisions remain with the lifecycle owner. */
    internal interface Connection : AutoCloseable {
        suspend fun send(endpoint: String, payload: ByteArray)
        suspend fun receive(): ByteArray?
    }

    private class Attempt(val prepared: Prepared, deadline: Long, val port: Int) {
        val gate = PairingConsentGate(deadline)
        var previous: ActivePlinkSession? = null
        var previousPort = 45731
        var stoppedSession = false
        var connection: Connection? = null
        val jobs = mutableListOf<Job>()
        var confirmationSent = false
    }

    private val scope = CoroutineScope(SupervisorJob() + dispatcher)
    private val commands = Channel<suspend () -> Unit>(Channel.UNLIMITED)
    private val mutableState = MutableStateFlow(State())
    val state: StateFlow<State> = mutableState
    private var attempt: Attempt? = null
    private var activePort = 45731
    private var closed = false

    init {
        scope.launch {
            try {
                for (command in commands) command()
            } finally {
                withContext(NonCancellable) { reset(State()) }
                commands.cancel()
            }
        }
    }

    private fun enqueue(command: suspend () -> Unit) {
        commands.trySend { if (!closed) command() }
    }

    fun select(offer: PairingOffer, localEndpoint: String) = enqueue {
        if (!reset(State(message = "Exchanging keys with ${offer.deviceName}…"))) return@enqueue
        try {
            val port = localEndpoint.substringAfterLast(':').toInt()
            require(port in 1..65535)
            val deadline = environment.now() + 120_000
            val prepared = environment.prepare(offer, localEndpoint)
            // Publish ownership before any operation that can fail, including snapshot and bind.
            val current = Attempt(prepared, deadline, port)
            attempt = current
            current.previous = environment.snapshot()
            current.previousPort = activePort
            current.stoppedSession = true
            environment.stop()
            val connection = environment.connect(port)
            current.connection = connection
            current.jobs += scope.launch {
                delay((deadline - environment.now()).coerceAtLeast(0))
                enqueue { fail(current, "Pairing timed out. Compare fresh codes to try again.") }
            }
            send(current, "preview") {
                mutableState.value = State(prepared.code, "Compare this code on both devices. Confirm only if they match.", true)
            }
            current.jobs += scope.launch {
                try {
                    while (isActive) {
                        val raw = connection.receive() ?: continue
                        // At most one received frame can be queued, even from a hostile peer.
                        val processed = CompletableDeferred<Unit>()
                        commands.send {
                            try { if (attempt === current) receive(current, raw) }
                            finally { processed.complete(Unit) }
                        }
                        processed.await()
                    }
                } catch (error: CancellationException) { throw error }
                catch (_: Exception) {
                    enqueue { fail(current, "Pairing connection failed. Try again with fresh codes.") }
                }
            }
        } catch (_: Exception) {
            reset(State(message = "Could not exchange pairing codes. Keep both apps open and try again."))
        }
    }

    fun confirm() = enqueue {
        val current = attempt ?: return@enqueue
        if (!mutableState.value.canConfirm) return@enqueue
        try {
            current.gate.confirmLocal(environment.now())
            mutableState.value = State(current.prepared.code, "Waiting for confirmation on your Mac…")
            send(current, "confirmed") {
                current.confirmationSent = true
                commitIfReady(current)
            }
        } catch (_: Exception) {
            fail(current, "Confirmation failed. Try pairing again.")
        }
    }

    fun cancelAttempt() = enqueue { reset(State()) }

    /** Close is queued so it cannot interrupt a trust commit or its rollback. */
    fun close() = enqueue {
        reset(State())
        closed = true
        commands.close()
        scope.cancel()
    }

    private fun send(current: Attempt, stage: String, onSent: suspend () -> Unit) {
        current.gate.checkLive(environment.now())
        val prepared = current.prepared
        val payload = PairingConsent.create(stage, prepared.confirmation, prepared.key).encode().toByteArray(Charsets.UTF_8)
        val connection = checkNotNull(current.connection)
        current.jobs += scope.launch {
            try {
                connection.send(prepared.offer.endpoint, payload)
                enqueue {
                    if (attempt === current) {
                        try {
                            current.gate.checkLive(environment.now())
                            onSent()
                        } catch (_: Exception) { fail(current, "Pairing did not complete. Try again with fresh codes.") }
                    }
                }
            } catch (error: CancellationException) { throw error }
            catch (_: Exception) { enqueue { fail(current, "Could not send pairing confirmation. Try again.") } }
            finally { payload.fill(0) }
        }
    }

    private suspend fun receive(current: Attempt, raw: ByteArray) {
        val prepared = current.prepared
        val approved = runCatching {
            val frame = Json.decodeFromString<EncryptedPlinkFrame>(raw.decodeToString())
            val envelope = EncryptedFrameCodec(prepared.key).open(frame, ReplayWindow(), Instant.now(),
                prepared.offer.deviceId, prepared.confirmation.deviceId, environment.frameState)
            envelope.type == PlinkEventType.PairingConfirm &&
                envelope.payload["sessionId"]?.jsonPrimitive?.content == prepared.candidate.sessionId &&
                envelope.payload["offerNonce"]?.jsonPrimitive?.content == prepared.offer.nonce &&
                envelope.payload["status"]?.jsonPrimitive?.content == "confirmed"
        }.getOrDefault(false)
        if (!approved) return
        try {
            current.gate.confirmRemote(environment.now())
            commitIfReady(current)
        } catch (_: Exception) { fail(current, "Pairing did not complete. Try again with fresh codes.") }
    }

    private suspend fun commitIfReady(current: Attempt) {
        if (!current.confirmationSent || !current.gate.consume(environment.now())) return
        // Commit is the cancellation boundary. Later commands wait for success or full rollback.
        withContext(NonCancellable) {
            val prepared = current.prepared
            val trusted = prepared.candidate.copy(trusted = true)
            var oldDevice: PairedDevice? = null
            var oldSecret: ByteArray? = null
            var oldActiveDeviceId: String? = null
            var secretTouched = false
            var deviceTouched = false
            var activeDeviceTouched = false
            var failure: Throwable? = null
            try {
                stopNetwork(current)
                oldDevice = environment.store.all().firstOrNull { it.id == trusted.id }
                oldSecret = environment.secrets.load(trusted.sessionId)
                oldActiveDeviceId = environment.store.activeDeviceId()
                secretTouched = true
                environment.secrets.save(prepared.key, trusted.sessionId)
                deviceTouched = true
                environment.store.save(trusted)
                activeDeviceTouched = true
                environment.store.setActiveDeviceId(trusted.id)
                configure(ActivePlinkSession(prepared.confirmation.deviceId, trusted, prepared.key), current.port)
                activePort = current.port
                mutableState.value = State(message = "Paired with ${trusted.name}.", paired = true)
            } catch (error: Exception) {
                failure = error
                // A store may throw after applying a write; restore every potentially touched value.
                suspend fun undo(action: suspend () -> Unit) {
                    try { action() } catch (rollback: Exception) { error.addSuppressed(rollback) }
                }
                if (activeDeviceTouched) undo { environment.store.setActiveDeviceId(oldActiveDeviceId) }
                if (deviceTouched) undo {
                    oldDevice?.let { environment.store.save(it) } ?: environment.store.remove(trusted.id)
                }
                if (secretTouched) undo {
                    oldSecret?.let { environment.secrets.save(it, trusted.sessionId) }
                        ?: environment.secrets.remove(trusted.sessionId)
                }
                undo { restore(current) }
                mutableState.value = State(message = when {
                    error.suppressed.isNotEmpty() -> "Pairing failed and recovery was incomplete. Restart Plink before trying again."
                    current.previous != null -> "Pairing did not complete. The previous session was restored."
                    else -> "Pairing did not complete. Try again with fresh codes."
                })
            } finally {
                oldSecret?.fill(0)
                release(current)
                // Do not let a later Cancel hide a failed recovery and permit another replacement.
                if (failure?.suppressed?.isNotEmpty() == true) recoveryFailed = true
            }
        }
    }

    private var recoveryFailed = false

    /** Transfer an independent key to the controller, wiping it if activation throws. */
    private fun configure(session: ActivePlinkSession, port: Int) {
        val owned = session.copy(sessionKey = session.copySessionKey())
        try { environment.configure(owned, port) }
        catch (error: Exception) {
            try { environment.stop() } catch (cleanup: Exception) { error.addSuppressed(cleanup) }
            owned.sessionKey.fill(0)
            throw error
        }
    }

    private fun restore(current: Attempt) {
        if (!current.stoppedSession) return
        environment.stop()
        current.previous?.let { configure(it, current.previousPort) }
    }

    private fun stopNetwork(current: Attempt) {
        current.jobs.forEach { it.cancel() }
        current.jobs.clear()
        current.connection?.close()
        current.connection = null
    }

    private fun release(current: Attempt) {
        try { stopNetwork(current) }
        finally {
            current.gate.cancel()
            current.prepared.key.fill(0)
            current.previous?.sessionKey?.fill(0)
            current.previous = null
            if (attempt === current) attempt = null
        }
    }

    private fun reset(state: State): Boolean {
        val current = attempt
        try {
            if (current != null) {
                // Release the pairing listener before restoring the previous session listener.
                stopNetwork(current)
                restore(current)
            }
        } catch (_: Exception) {
            recoveryFailed = true
        } finally {
            if (current != null) release(current)
        }
        mutableState.value = if (recoveryFailed)
            State(message = "Pairing recovery was incomplete. Restart Plink before trying again.") else state
        return !recoveryFailed
    }

    private fun fail(current: Attempt, message: String) {
        if (attempt === current) reset(State(message = message))
    }

    private companion object {
        fun environment(app: PlinkApplication) = Environment(
            store = KeystorePairingStore(app), secrets = KeystorePairingSecretStore(app),
            frameState = FileFrameStateStore(File(app.filesDir, "transport-state")),
            prepare = { offer, endpoint ->
                val androidId = Settings.Secure.getString(app.contentResolver, Settings.Secure.ANDROID_ID).orEmpty()
                val deviceId = "pixel-${androidId.ifBlank { "local" }}"
                val targeted = offer.copy(targetDeviceId = deviceId)
                val machine = PairingStateMachine()
                try {
                    val code = machine.receiveOffer(targeted, endpoint).verificationCode
                    val (candidate, confirmation) = machine.previewWithResponse(deviceId, Build.MODEL, endpoint)
                    Prepared(targeted, confirmation, candidate, checkNotNull(machine.lastSessionKey), code)
                } catch (error: Exception) {
                    machine.lastSessionKey?.fill(0)
                    throw error
                }
            },
            snapshot = { app.invalidateSavedSessionRestoreAndSnapshot() }, stop = {
                app.invalidateSavedSessionRestore()
                app.sessionController.stop()
            },
            configure = { session, port ->
                app.sessionController.configure(session.localDeviceId, session.pairedDevice, session.sessionKey, port)
                check(app.sessionController.status.value == SessionStatus.READY) { "Pairing session was not activated." }
            },
            connect = { SocketConnection(it) }, now = SystemClock::elapsedRealtime
        )
    }
}

/** Closing an attempt also closes in-flight reads, connects and writes. */
private class SocketConnection(port: Int) : PairingCoordinator.Connection {
    private val server = ServerSocket()
    private val sockets = mutableSetOf<Socket>()
    private var closed = false

    init {
        try {
            server.reuseAddress = true
            server.bind(InetSocketAddress(port))
            server.soTimeout = 1_000
        } catch (error: Exception) { server.close(); throw error }
    }

    @Synchronized private fun register(socket: Socket) {
        if (closed) { socket.close(); throw java.io.IOException("Pairing connection closed.") }
        sockets += socket
    }

    @Synchronized private fun unregister(socket: Socket) { sockets -= socket }

    override suspend fun send(endpoint: String, payload: ByteArray) {
        val separator = endpoint.lastIndexOf(':')
        val host = endpoint.substring(0, separator).removePrefix("[").removeSuffix("]")
        val port = endpoint.substring(separator + 1).toInt()
        Socket().use { socket ->
            register(socket)
            try {
                socket.connect(InetSocketAddress(host, port), 5_000)
                LengthPrefixedFrameCodec.write(DataOutputStream(socket.getOutputStream()), payload)
            } finally { unregister(socket) }
        }
    }

    override suspend fun receive(): ByteArray? {
        val socket = try { server.accept() } catch (_: SocketTimeoutException) { return null }
        socket.use {
            register(socket)
            try { return readBoundedFrame(socket) }
            catch (_: Exception) { return null }
            finally { unregister(socket) }
        }
    }

    @Synchronized override fun close() {
        closed = true
        runCatching { server.close() }
        sockets.forEach { runCatching { it.close() } }
        sockets.clear()
    }

    private fun readBoundedFrame(socket: Socket): ByteArray {
        val deadline = SystemClock.elapsedRealtime() + 5_000
        val input = socket.getInputStream()
        fun readExact(size: Int): ByteArray {
            val bytes = ByteArray(size)
            var offset = 0
            while (offset < size) {
                val remaining = deadline - SystemClock.elapsedRealtime()
                if (remaining <= 0) throw SocketTimeoutException("Pairing frame deadline exceeded.")
                socket.soTimeout = minOf(remaining, 200L).toInt().coerceAtLeast(1)
                val count = try { input.read(bytes, offset, size - offset) }
                    catch (_: SocketTimeoutException) { continue }
                if (count < 0) throw java.io.EOFException("Incomplete pairing frame.")
                offset += count
            }
            return bytes
        }
        val size = java.nio.ByteBuffer.wrap(readExact(4)).int
        require(size in 1..16_384) { "Pairing frame is too large." }
        return readExact(size)
    }
}
