package app.plink.android.continuity

import app.plink.android.protocol.FileTransferPayloadPolicy
import app.plink.android.protocol.PlinkEnvelope
import app.plink.android.protocol.PlinkEventType
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import kotlinx.serialization.json.put
import java.io.File
import java.io.InputStream
import java.io.OutputStream
import java.io.RandomAccessFile
import java.security.MessageDigest
import java.time.Instant
import java.util.Base64
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean

data class OutgoingFileSource(
    val token: String,
    val displayName: String,
    val mimeType: String
)

data class IncomingFileDestination(
    val token: String,
    val newlyCreated: Boolean,
    val persistedPermission: Boolean = false
)

data class IncomingFileOffer(
    val name: String,
    val mimeType: String,
    val sizeBytes: Long
)

interface FileTransferEnvironment {
    fun openSource(token: String): InputStream
    fun openDestination(token: String): OutputStream
    fun showIncomingOffer(handle: String, offer: IncomingFileOffer): Boolean
    fun dismissIncomingOffer(handle: String)
    fun deleteNewDestination(token: String): Boolean
    fun releaseDestination(token: String)
}

sealed interface FileTransferState {
    data object Idle : FileTransferState
    data class Preparing(val name: String) : FileTransferState
    data class Offered(val name: String, val sizeBytes: Long) : FileTransferState
    data class AwaitingDestination(val offer: IncomingFileOffer) : FileTransferState
    data class Transferring(val name: String, val completedBytes: Long, val totalBytes: Long) : FileTransferState
    data class Verifying(val name: String) : FileTransferState
    data class Saved(val name: String) : FileTransferState
    data class OutcomeUnconfirmed(val name: String) : FileTransferState
    data class Failed(val name: String?, val reason: String, val cleanupNeeded: Boolean = false) : FileTransferState
}

enum class FileOfferStartResult { Offered, Busy, Disabled, Unavailable, TooLarge, Invalid, Failed }

class FileTransferCoordinator(
    private val stagingBase: File,
    private val scope: CoroutineScope,
    private val environment: FileTransferEnvironment,
    private val filesEnabled: () -> Boolean,
    private val sendEnvelope: suspend (PlinkEnvelope, allowRevoked: Boolean, stillValid: () -> Boolean) -> Unit,
    private val monotonicMillis: () -> Long = { android.os.SystemClock.elapsedRealtime() },
    scheduleWatchdog: Boolean = true
) {
    private data class Session(val localDeviceId: String, val peerDeviceId: String, val generation: Long)

    private sealed interface ActiveTransfer {
        val id: String
        val name: String
        val session: Session
        val directory: File
        val startedAt: Long
        var lastActivityAt: Long
        val revoked: AtomicBoolean
    }

    private data class Preparing(
        override val id: String,
        override val name: String,
        override val session: Session,
        override val directory: File,
        override val startedAt: Long,
        override var lastActivityAt: Long,
        override val revoked: AtomicBoolean = AtomicBoolean(false)
    ) : ActiveTransfer

    private data class Outgoing(
        override val id: String,
        override val name: String,
        val mimeType: String,
        val sizeBytes: Long,
        val sha256: String,
        val snapshot: File,
        override val session: Session,
        override val directory: File,
        override val startedAt: Long,
        override var lastActivityAt: Long,
        override val revoked: AtomicBoolean = AtomicBoolean(false),
        var accepted: Boolean = false,
        var nextIndex: Int = 0,
        var waitingForResult: Boolean = false
    ) : ActiveTransfer

    private data class Incoming(
        override val id: String,
        override val name: String,
        val mimeType: String,
        val sizeBytes: Long,
        val sha256: String,
        val handle: String,
        override val session: Session,
        override val directory: File,
        override val startedAt: Long,
        override var lastActivityAt: Long,
        override val revoked: AtomicBoolean = AtomicBoolean(false),
        var destination: IncomingFileDestination? = null,
        var staging: File? = null,
        var nextIndex: Int = 0,
        var receivedBytes: Long = 0,
        var destinationOpened: Boolean = false,
        var exportCompleted: Boolean = false
    ) : ActiveTransfer

    private val mutex = Mutex()
    private val ownershipLock = Any()
    @Volatile private var session: Session? = null
    @Volatile private var active: ActiveTransfer? = null
    @Volatile private var pendingView: Pair<String, IncomingFileOffer>? = null
    private val _state = MutableStateFlow<FileTransferState>(FileTransferState.Idle)
    val state: StateFlow<FileTransferState> = _state.asStateFlow()
    private val watchdog: Job? = if (scheduleWatchdog) scope.launch {
        while (isActive) {
            delay(WATCHDOG_INTERVAL_MILLIS)
            checkTimeouts()
        }
    } else null

    init { stagingBase.mkdirs() }

    fun activateSession(localDeviceId: String, peerDeviceId: String, generation: Long) {
        deactivateSession()
        synchronized(ownershipLock) {
            session = Session(localDeviceId, peerDeviceId, generation)
            _state.value = FileTransferState.Idle
        }
    }

    fun deactivateSession() {
        val transfer = synchronized(ownershipLock) {
            session = null
            revokeOwnership("disconnected")
        } ?: return
        scope.launch {
            mutex.withLock {
                sendTerminalBestEffort(transfer, PlinkEventType.FileCancel, allowRevoked = true) {
                    put("reason", "disconnected")
                }
                cleanupDetached(transfer)
            }
        }
    }

    fun close() {
        deactivateSession()
        watchdog?.cancel()
    }

    suspend fun offerOutgoing(source: OutgoingFileSource): FileOfferStartResult {
        val name = sanitizeDisplayName(source.displayName) ?: return FileOfferStartResult.Invalid
        val mimeType = sanitizeMimeType(source.mimeType) ?: return FileOfferStartResult.Invalid
        val preparing = mutex.withLock { synchronized(ownershipLock) {
            val currentSession = session ?: return FileOfferStartResult.Unavailable
            if (!filesEnabled()) return FileOfferStartResult.Disabled
            if (active != null) return FileOfferStartResult.Busy
            val id = UUID.randomUUID().toString()
            val directory = File(stagingBase, id)
            if (!directory.mkdirs()) return FileOfferStartResult.Failed
            Preparing(id, name, currentSession, directory, monotonicMillis(), monotonicMillis()).also {
                active = it
                _state.value = FileTransferState.Preparing(name)
            }
        } }
        val snapshot = File(preparing.directory, "outgoing.bin")
        var handedOff = false
        try {
            val prepared = snapshotSource(source.token, snapshot, preparing)
            return mutex.withLock {
                requirePreparing(preparing)
                val outgoing = synchronized(ownershipLock) {
                    check(!preparing.revoked.get() && active === preparing && session == preparing.session && filesEnabled())
                    Outgoing(
                    id = preparing.id, name = name, mimeType = mimeType,
                    sizeBytes = prepared.first, sha256 = prepared.second, snapshot = snapshot,
                    session = preparing.session, directory = preparing.directory,
                    startedAt = preparing.startedAt, lastActivityAt = monotonicMillis(), revoked = preparing.revoked
                    ).also { active = it }
                }
                handedOff = true
                val offer = envelope(outgoing, PlinkEventType.FileOffer) {
                    put("name", name)
                    put("mimeType", mimeType)
                    put("sizeBytes", prepared.first)
                    put("sha256", prepared.second)
                    put("chunkBytes", FileTransferPayloadPolicy.chunkBytes)
                }
                if (!sendOrFail(outgoing, offer)) return@withLock FileOfferStartResult.Failed
                if (active === outgoing && !outgoing.revoked.get()) {
                    _state.value = FileTransferState.Offered(name, prepared.first)
                }
                FileOfferStartResult.Offered
            }
        } catch (_: FileTooLargeException) {
            if (active === preparing) _state.value = FileTransferState.Failed(name, "too_large")
            return FileOfferStartResult.TooLarge
        } catch (cancellation: CancellationException) {
            if (active === preparing) _state.value = FileTransferState.Failed(name, "cancelled")
            throw cancellation
        } catch (_: Exception) {
            if (active === preparing && !preparing.revoked.get()) {
                _state.value = FileTransferState.Failed(name, "storage")
            }
            return FileOfferStartResult.Failed
        } finally {
            if (!handedOff) {
                // The reservation survives revocation until blocked source IO has
                // unwound. Its owner alone removes staging after closing streams.
                preparing.directory.deleteRecursively()
                if (active === preparing) active = null
            }
        }
    }

    suspend fun handle(envelope: PlinkEnvelope, generation: Long): Unit = mutex.withLock {
        if (envelope.type !in FileTransferPayloadPolicy.eventTypes) return
        val currentSession = session ?: return
        if (generation != currentSession.generation ||
            envelope.sourceDeviceId != currentSession.peerDeviceId ||
            envelope.targetDeviceId != currentSession.localDeviceId) return
        try {
            FileTransferPayloadPolicy.requireAcceptable(envelope)
        } catch (_: RuntimeException) {
            val transferId = envelope.payload["transferId"]?.jsonPrimitive?.contentOrNull
            if (transferId != null && active?.id == transferId) failActiveInvalid()
            return
        }
        val transferId = envelope.payload.getValue("transferId").jsonPrimitive.content
        if (envelope.type == PlinkEventType.FileOffer) {
            receiveOffer(envelope, transferId, currentSession)
            return
        }
        val transfer = active?.takeIf { it.id == transferId && it.session == currentSession } ?: return
        if (transfer is Preparing || transfer.revoked.get()) return
        if (expired(transfer, offerOnly = transfer is Incoming && transfer.destination == null ||
                transfer is Outgoing && !transfer.accepted)) {
            timeout(transfer)
            return
        }
        transfer.lastActivityAt = monotonicMillis()
        when (envelope.type) {
            PlinkEventType.FileAccept -> onAccepted(transfer)
            PlinkEventType.FileChunk -> onChunk(transfer, envelope)
            PlinkEventType.FileProgress -> onProgress(transfer, envelope)
            PlinkEventType.FileComplete -> onComplete(transfer)
            PlinkEventType.FileResult -> onResult(transfer, envelope)
            PlinkEventType.FileCancel -> if (transfer is Outgoing && transfer.waitingForResult) {
                finishUnconfirmed(transfer)
            } else finishFailed(transfer, envelope.payload.getValue("reason").jsonPrimitive.content)
        }
    }

    fun pendingIncoming(handle: String): IncomingFileOffer? = pendingView?.takeIf { it.first == handle }?.second

    suspend fun acceptIncoming(handle: String, destination: IncomingFileDestination): Boolean = mutex.withLock {
        val incoming = active as? Incoming ?: return false
        if (incoming.handle != handle || pendingView?.first != handle || !filesEnabled()) return false
        if (expired(incoming, offerOnly = true)) {
            timeout(incoming)
            return false
        }
        incoming.destination = destination
        incoming.staging = File(incoming.directory, "incoming.bin").also { it.createNewFile() }
        incoming.lastActivityAt = monotonicMillis()
        pendingView = null
        environment.dismissIncomingOffer(handle)
        _state.value = FileTransferState.Transferring(incoming.name, 0, incoming.sizeBytes)
        if (!sendOrFail(incoming, envelope(incoming, PlinkEventType.FileAccept))) return false
        true
    }

    suspend fun declineIncoming(handle: String): Boolean = mutex.withLock {
        val incoming = active as? Incoming ?: return false
        if (incoming.handle != handle) return false
        sendTerminalBestEffort(incoming, PlinkEventType.FileResult) {
            put("status", "error")
            put("code", "cancelled")
        }
        finishFailed(incoming, "cancelled")
        true
    }

    fun featureDisabled() {
        val transfer = revokeOwnership("cancelled") ?: return
        scope.launch {
            mutex.withLock {
                sendTerminalBestEffort(transfer, PlinkEventType.FileCancel, allowRevoked = true) {
                    put("reason", "cancelled")
                }
                cleanupDetached(transfer)
            }
        }
    }

    suspend fun cancelActive(reason: String = "cancelled", allowRevoked: Boolean = false) {
        val transfer = revokeOwnership(reason) ?: return
        mutex.withLock {
            if (transfer !is Preparing) {
                sendTerminalBestEffort(transfer, PlinkEventType.FileCancel, allowRevoked) { put("reason", reason) }
            }
            cleanupDetached(transfer)
        }
    }

    suspend fun checkTimeouts(): Unit = mutex.withLock {
        val transfer = active ?: return
        if (transfer is Preparing) {
            if (monotonicMillis() - transfer.startedAt >= ABSOLUTE_TIMEOUT_MILLIS) revokeOwnership("timeout")
            return
        }
        if (expired(transfer, offerOnly = transfer is Incoming && transfer.destination == null ||
                transfer is Outgoing && !transfer.accepted)) timeout(transfer)
    }

    private suspend fun receiveOffer(envelope: PlinkEnvelope, transferId: String, currentSession: Session) {
        if (!filesEnabled()) {
            sendStandaloneResult(currentSession, transferId, "receive_unavailable")
            return
        }
        if (active != null) {
            sendStandaloneResult(currentSession, transferId, "busy")
            return
        }
        val name = envelope.payload.getValue("name").jsonPrimitive.content
        val mimeType = envelope.payload.getValue("mimeType").jsonPrimitive.content
        val size = envelope.payload.getValue("sizeBytes").jsonPrimitive.long
        val started = monotonicMillis()
        val directory = File(stagingBase, transferId).also { check(it.mkdirs()) }
        val handle = UUID.randomUUID().toString()
        val incoming = Incoming(
            id = transferId,
            name = name,
            mimeType = mimeType,
            sizeBytes = size,
            sha256 = envelope.payload.getValue("sha256").jsonPrimitive.content,
            handle = handle,
            session = currentSession,
            directory = directory,
            startedAt = started,
            lastActivityAt = started
        )
        active = incoming
        val offer = IncomingFileOffer(name, mimeType, size)
        pendingView = handle to offer
        if (!environment.showIncomingOffer(handle, offer)) {
            pendingView = null
            sendTerminalBestEffort(incoming, PlinkEventType.FileResult) {
                put("status", "error")
                put("code", "receive_unavailable")
            }
            finishFailed(incoming, "receive_unavailable")
            return
        }
        _state.value = FileTransferState.AwaitingDestination(offer)
    }

    private suspend fun onAccepted(transfer: ActiveTransfer) {
        val outgoing = transfer as? Outgoing ?: return failActiveInvalid()
        if (outgoing.accepted) return failActiveInvalid()
        outgoing.accepted = true
        _state.value = FileTransferState.Transferring(outgoing.name, 0, outgoing.sizeBytes)
        sendNext(outgoing)
    }

    private suspend fun onProgress(transfer: ActiveTransfer, envelope: PlinkEnvelope) {
        val outgoing = transfer as? Outgoing ?: return failActiveInvalid()
        if (!outgoing.accepted || outgoing.waitingForResult) return failActiveInvalid()
        val expected = outgoing.nextIndex
        if (envelope.payload.getValue("nextIndex").jsonPrimitive.int != expected) return failActiveInvalid()
        sendNext(outgoing)
    }

    private suspend fun sendNext(outgoing: Outgoing) {
        val offset = outgoing.nextIndex.toLong() * FileTransferPayloadPolicy.chunkBytes
        if (offset >= outgoing.sizeBytes) {
            outgoing.waitingForResult = true
            _state.value = FileTransferState.Verifying(outgoing.name)
            sendOrFail(outgoing, envelope(outgoing, PlinkEventType.FileComplete))
            return
        }
        val expected = minOf(FileTransferPayloadPolicy.chunkBytes.toLong(), outgoing.sizeBytes - offset).toInt()
        val bytes = withContext(Dispatchers.IO) {
            RandomAccessFile(outgoing.snapshot, "r").use { file ->
                file.seek(offset)
                ByteArray(expected).also(file::readFully)
            }
        }
        val index = outgoing.nextIndex++
        val sent = sendOrFail(outgoing, envelope(outgoing, PlinkEventType.FileChunk) {
            put("index", index)
            put("data", Base64.getEncoder().encodeToString(bytes))
        })
        if (sent) _state.value = FileTransferState.Transferring(
            outgoing.name,
            minOf(outgoing.sizeBytes, offset + bytes.size),
            outgoing.sizeBytes
        )
    }

    private suspend fun onChunk(transfer: ActiveTransfer, envelope: PlinkEnvelope) {
        val incoming = transfer as? Incoming ?: return failActiveInvalid()
        val staging = incoming.staging ?: return failActiveInvalid()
        val index = envelope.payload.getValue("index").jsonPrimitive.int
        val bytes = Base64.getDecoder().decode(envelope.payload.getValue("data").jsonPrimitive.content)
        val expectedSize = minOf(
            FileTransferPayloadPolicy.chunkBytes.toLong(),
            incoming.sizeBytes - incoming.receivedBytes
        ).toInt()
        if (index != incoming.nextIndex || expectedSize <= 0 || bytes.size != expectedSize) return failActiveInvalid()
        withContext(Dispatchers.IO) {
            requireActive(incoming)
            staging.appendBytes(bytes)
            requireActive(incoming)
        }
        incoming.nextIndex += 1
        incoming.receivedBytes += bytes.size
        _state.value = FileTransferState.Transferring(incoming.name, incoming.receivedBytes, incoming.sizeBytes)
        sendOrFail(incoming, envelope(incoming, PlinkEventType.FileProgress) {
            put("nextIndex", incoming.nextIndex)
        })
    }

    private suspend fun onComplete(transfer: ActiveTransfer) {
        val incoming = transfer as? Incoming ?: return failActiveInvalid()
        val staging = incoming.staging ?: return failActiveInvalid()
        if (incoming.receivedBytes != incoming.sizeBytes || sha256(staging) != incoming.sha256) {
            sendTerminalBestEffort(incoming, PlinkEventType.FileResult) {
                put("status", "error")
                put("code", "invalid")
            }
            finishFailed(incoming, "invalid")
            return
        }
        _state.value = FileTransferState.Verifying(incoming.name)
        val destination = incoming.destination ?: return failActiveInvalid()
        val exported = runCatching {
            withTimeout(remainingMillis(incoming, offerOnly = false)) {
                withContext(Dispatchers.IO) {
                    requireActive(incoming)
                    incoming.destinationOpened = true
                    environment.openDestination(destination.token).use { output ->
                        requireActive(incoming)
                        staging.inputStream().use { input ->
                            val buffer = ByteArray(FileTransferPayloadPolicy.chunkBytes)
                            while (true) {
                                requireActive(incoming)
                                val count = input.read(buffer)
                                if (count < 0) break
                                requireActive(incoming)
                                output.write(buffer, 0, count)
                            }
                        }
                        requireActive(incoming)
                        output.flush()
                        requireActive(incoming)
                    }
                    // A successful close means the selected output exists. Keep it
                    // even if cancellation arrived while the provider closed it.
                    incoming.exportCompleted = true
                }
            }
        }.isSuccess
        if (!exported) {
            if (incoming.revoked.get() || active !== incoming || session != incoming.session || !filesEnabled()) return
            sendTerminalBestEffort(incoming, PlinkEventType.FileResult) {
                put("status", "error")
                put("code", "storage")
            }
            finishFailed(incoming, "storage")
            return
        }
        if (incoming.revoked.get() || active !== incoming || session != incoming.session || !filesEnabled()) return
        val result = envelope(incoming, PlinkEventType.FileResult) { put("status", "saved") }
        try {
            FileTransferPayloadPolicy.requireAcceptable(result)
            withTimeout(remainingMillis(incoming, offerOnly = false)) { sendEnvelope(result, false) { active === incoming && !incoming.revoked.get() && session == incoming.session } }
        } catch (_: Exception) {
            finishSaved(incoming)
            return
        }
        finishSaved(incoming)
    }

    private fun onResult(transfer: ActiveTransfer, envelope: PlinkEnvelope) {
        val outgoing = transfer as? Outgoing ?: return
        val status = envelope.payload.getValue("status").jsonPrimitive.content
        if (status == "saved" && outgoing.waitingForResult) {
            finishSaved(outgoing)
        } else if (status == "error") {
            finishFailed(outgoing, envelope.payload["code"]?.jsonPrimitive?.contentOrNull ?: "invalid")
        } else {
            finishFailed(outgoing, "invalid")
        }
    }

    private suspend fun failActiveInvalid() {
        val transfer = active ?: return
        if (transfer is Incoming) {
            sendTerminalBestEffort(transfer, PlinkEventType.FileResult) {
                put("status", "error")
                put("code", "invalid")
            }
        } else {
            sendTerminalBestEffort(transfer, PlinkEventType.FileCancel) { put("reason", "invalid") }
        }
        finishFailed(transfer, "invalid")
    }

    private suspend fun timeout(transfer: ActiveTransfer) {
        if (transfer is Outgoing && transfer.waitingForResult) {
            finishUnconfirmed(transfer)
            return
        }
        if (transfer is Incoming) {
            sendTerminalBestEffort(transfer, PlinkEventType.FileResult) {
                put("status", "error")
                put("code", "timeout")
            }
        } else {
            sendTerminalBestEffort(transfer, PlinkEventType.FileCancel) { put("reason", "timeout") }
        }
        finishFailed(transfer, "timeout")
    }

    private suspend fun sendStandaloneResult(session: Session, transferId: String, code: String) {
        val envelope = PlinkEnvelope(
            id = UUID.randomUUID().toString(),
            type = PlinkEventType.FileResult,
            sentAt = Instant.now().toString(),
            sourceDeviceId = session.localDeviceId,
            targetDeviceId = session.peerDeviceId,
            payload = buildJsonObject {
                put("transferId", transferId)
                put("status", "error")
                put("code", code)
            }
        )
        runCatching { withTimeout(5_000) { sendEnvelope(envelope, true) { this@FileTransferCoordinator.session == session } } }
    }

    private suspend fun sendOrFail(transfer: ActiveTransfer, envelope: PlinkEnvelope): Boolean {
        fun failed(reason: String) {
            if (transfer is Outgoing && transfer.waitingForResult) finishUnconfirmed(transfer)
            else finishFailed(transfer, reason)
        }
        return try {
            check(active === transfer && !transfer.revoked.get() && session == transfer.session && filesEnabled())
            FileTransferPayloadPolicy.requireAcceptable(envelope)
            withTimeout(remainingMillis(transfer, offerOnly =
                transfer is Incoming && transfer.destination == null || transfer is Outgoing && !transfer.accepted
            )) { sendEnvelope(envelope, false) { active === transfer && !transfer.revoked.get() && session == transfer.session } }
            if (active !== transfer || transfer.revoked.get()) return false
            transfer.lastActivityAt = monotonicMillis()
            true
        } catch (_: kotlinx.coroutines.TimeoutCancellationException) {
            failed("timeout")
            false
        } catch (cancellation: CancellationException) {
            failed("cancelled")
            throw cancellation
        } catch (_: Exception) {
            failed("send_failed")
            false
        }
    }

    private suspend fun sendTerminalBestEffort(
        transfer: ActiveTransfer,
        type: String,
        allowRevoked: Boolean = false,
        payload: kotlinx.serialization.json.JsonObjectBuilder.() -> Unit
    ) {
        if (transfer is Preparing) return
        runCatching { withTimeout(5_000) { sendEnvelope(envelope(transfer, type, payload), allowRevoked) {
            session == transfer.session && (allowRevoked || (active === transfer && !transfer.revoked.get()))
        } } }
    }

    private fun envelope(
        transfer: ActiveTransfer,
        type: String,
        payload: kotlinx.serialization.json.JsonObjectBuilder.() -> Unit = {}
    ) = PlinkEnvelope(
        id = UUID.randomUUID().toString(),
        type = type,
        sentAt = Instant.now().toString(),
        sourceDeviceId = transfer.session.localDeviceId,
        targetDeviceId = transfer.session.peerDeviceId,
        payload = buildJsonObject {
            put("transferId", transfer.id)
            payload()
        }
    )

    private suspend fun snapshotSource(token: String, destination: File, preparing: Preparing): Pair<Long, String> =
        withContext(Dispatchers.IO) {
            val digest = MessageDigest.getInstance("SHA-256")
            var total = 0L
            requirePreparing(preparing)
            environment.openSource(token).use { input ->
                requirePreparing(preparing)
                destination.outputStream().use { output ->
                    val buffer = ByteArray(FileTransferPayloadPolicy.chunkBytes)
                    while (true) {
                        requirePreparing(preparing)
                        val count = input.read(buffer)
                        requirePreparing(preparing)
                        if (count < 0) break
                        total += count
                        if (total > FileTransferPayloadPolicy.maxFileBytes) throw FileTooLargeException()
                        output.write(buffer, 0, count)
                        digest.update(buffer, 0, count)
                    }
                    output.flush()
                }
            }
            total to digest.digest().joinToString("") { "%02x".format(it) }
        }

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(FileTransferPayloadPolicy.chunkBytes)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    private fun expired(transfer: ActiveTransfer, offerOnly: Boolean): Boolean {
        val now = monotonicMillis()
        return now - transfer.startedAt >= ABSOLUTE_TIMEOUT_MILLIS ||
            if (offerOnly) now - transfer.startedAt >= OFFER_TIMEOUT_MILLIS
            else now - transfer.lastActivityAt >= INACTIVITY_TIMEOUT_MILLIS
    }

    private fun remainingMillis(transfer: ActiveTransfer, offerOnly: Boolean): Long {
        val now = monotonicMillis()
        val absolute = ABSOLUTE_TIMEOUT_MILLIS - (now - transfer.startedAt)
        val phase = if (offerOnly) {
            OFFER_TIMEOUT_MILLIS - (now - transfer.startedAt)
        } else {
            INACTIVITY_TIMEOUT_MILLIS - (now - transfer.lastActivityAt)
        }
        return minOf(absolute, phase).coerceAtLeast(1L)
    }

    private fun finishSaved(transfer: ActiveTransfer) {
        if (active !== transfer) return
        active = null
        pendingView = null
        if (transfer is Incoming) environment.dismissIncomingOffer(transfer.handle)
        releaseDestination(transfer as? Incoming)
        transfer.directory.deleteRecursively()
        _state.value = FileTransferState.Saved(transfer.name)
    }

    private fun finishFailed(transfer: ActiveTransfer, reason: String, cleanupNeeded: Boolean = false) {
        if (active !== transfer) return
        active = null
        pendingView = null
        if (transfer is Incoming) environment.dismissIncomingOffer(transfer.handle)
        val partialOutput = cleanupOutput(transfer as? Incoming)
        releaseDestination(transfer as? Incoming)
        transfer.directory.deleteRecursively()
        _state.value = FileTransferState.Failed(transfer.name, reason, cleanupNeeded || partialOutput)
    }

    private fun finishUnconfirmed(transfer: Outgoing) {
        if (active !== transfer) return
        active = null
        transfer.directory.deleteRecursively()
        _state.value = FileTransferState.OutcomeUnconfirmed(transfer.name)
    }

    private fun releaseDestination(incoming: Incoming?) {
        incoming?.destination?.let { environment.releaseDestination(it.token) }
    }

    private fun revokeOwnership(reason: String): ActiveTransfer? = synchronized(ownershipLock) {
        val transfer = active ?: return null
        if (!transfer.revoked.compareAndSet(false, true)) return null
        // Keep the slot reserved until its IO owner has released streams and the
        // mutex-protected cleanup completes. A new transfer cannot be cleared by
        // delayed cleanup from the old one.
        pendingView = null
        if (transfer is Incoming) environment.dismissIncomingOffer(transfer.handle)
        _state.value = if (transfer is Outgoing && transfer.waitingForResult) {
            FileTransferState.OutcomeUnconfirmed(transfer.name)
        } else {
            FileTransferState.Failed(transfer.name, reason)
        }
        return transfer
    }

    private fun cleanupDetached(transfer: ActiveTransfer) {
        if (transfer is Preparing || active !== transfer) return
        active = null
        val partialOutput = cleanupOutput(transfer as? Incoming)
        releaseDestination(transfer as? Incoming)
        transfer.directory.deleteRecursively()
        if (partialOutput && active == null && session == transfer.session) {
            val old = _state.value as? FileTransferState.Failed
            if (old != null) _state.value = old.copy(cleanupNeeded = true)
        }
    }

    private fun cleanupOutput(incoming: Incoming?): Boolean {
        if (incoming == null || incoming.exportCompleted) return false
        val destination = incoming.destination ?: return false
        if (!destination.newlyCreated) return incoming.destinationOpened
        return !runCatching { environment.deleteNewDestination(destination.token) }.getOrDefault(false)
    }

    private suspend fun requirePreparing(preparing: Preparing) {
        currentCoroutineContext().ensureActive()
        check(!preparing.revoked.get() && active === preparing && session == preparing.session &&
            filesEnabled() && monotonicMillis() - preparing.startedAt < ABSOLUTE_TIMEOUT_MILLIS) {
            "The file selection is no longer active."
        }
    }

    private suspend fun requireActive(transfer: ActiveTransfer) {
        currentCoroutineContext().ensureActive()
        check(
            !transfer.revoked.get() &&
                active === transfer &&
                session == transfer.session &&
                filesEnabled() &&
                !expired(transfer, offerOnly = false)
        ) {
            "The transfer is no longer active."
        }
    }

    private fun sanitizeDisplayName(raw: String): String? {
        val cleaned = raw.substringAfterLast('/').substringAfterLast('\\')
            .filterNot { it.code < 32 || it.code == 127 }.trim()
        if (cleaned.isBlank() || cleaned == "." || cleaned == "..") return null
        var result = cleaned.take(255)
        while (result.toByteArray(Charsets.UTF_8).size > 255) result = result.dropLast(1)
        return result.takeIf { it.isNotBlank() }
    }

    private fun sanitizeMimeType(raw: String): String? {
        val value = raw.ifBlank { "application/octet-stream" }
        return value.takeIf { it.length <= 127 && it.all { character -> character.code in 32..126 } }
    }

    private class FileTooLargeException : Exception()

    private companion object {
        const val OFFER_TIMEOUT_MILLIS = 60_000L
        const val INACTIVITY_TIMEOUT_MILLIS = 30_000L
        const val ABSOLUTE_TIMEOUT_MILLIS = 300_000L
        const val WATCHDOG_INTERVAL_MILLIS = 1_000L
    }
}
