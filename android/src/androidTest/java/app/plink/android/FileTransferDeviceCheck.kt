package app.plink.android

import android.content.Context
import android.os.Bundle
import app.plink.android.continuity.*
import app.plink.android.protocol.PlinkEnvelope
import app.plink.android.protocol.PlinkEventType
import app.plink.android.security.EncryptedFrameCodec
import app.plink.android.security.InMemoryFrameStateStore
import app.plink.android.transport.SecureSocketPlinkClient
import app.plink.android.transport.SecureSocketPlinkServer
import java.io.File
import java.util.Base64
import java.util.UUID
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonPrimitive

/** Real engine/file/socket IO with isolated synthetic files; no user documents or picker automation. */
internal suspend fun checkFileRoundtrip(context: Context, arguments: Bundle, progress: (String) -> Unit): String = coroutineScope {
    val root = File(context.cacheDir, "plink-file-roundtrip-${UUID.randomUUID()}").apply { mkdirs() }
    val key = Base64.getDecoder().decode(requireNotNull(arguments.getString("sessionKey")))
    val codec = EncryptedFrameCodec(key)
    val frameState = InMemoryFrameStateStore()
    val server = SecureSocketPlinkServer(requireNotNull(arguments.getString("replyPort")).toInt(),
        codec, frameState, expectedSourceDeviceId = "test-mac", expectedTargetDeviceId = "test-pixel")
    val client = SecureSocketPlinkClient(arguments.getString("macHost") ?: "127.0.0.1",
        requireNotNull(arguments.getString("macPort")).toInt(), codec, frameState)
    var offerHandle: String? = null
    var savedResult: PlinkEnvelope? = null
    val environment = object : FileTransferEnvironment {
        override fun openSource(token: String) = File(root, token).inputStream()
        override fun openDestination(token: String) = File(root, token).outputStream()
        override fun showIncomingOffer(handle: String, offer: IncomingFileOffer): Boolean {
            check(offerHandle == null)
            offerHandle = handle
            return true
        }
        override fun dismissIncomingOffer(handle: String) { if (offerHandle == handle) offerHandle = null }
        override fun deleteNewDestination(token: String) = File(root, token).delete()
        override fun releaseDestination(token: String) = Unit
    }
    val coordinator = FileTransferCoordinator(stagingBase = File(root, "stage"), scope = this,
        environment = environment, filesEnabled = { true },
        sendEnvelope = { envelope, _, stillValid ->
            if (envelope.type == PlinkEventType.FileResult &&
                envelope.payload["status"]?.jsonPrimitive?.content == "saved") {
                savedResult = envelope
            }
            try {
                check(stillValid())
                client.send(envelope)
            } catch (failure: Exception) {
                // The engine may retain local Saved after a failed terminal send.
                // Log only event type and category, never payloads, paths or keys.
                val category = when (failure) {
                    is TimeoutCancellationException, is java.net.SocketTimeoutException -> "timeout"
                    is CancellationException -> "cancelled"
                    is java.net.SocketException -> "socket"
                    is java.io.IOException -> "io"
                    is java.security.GeneralSecurityException -> "cryptographic"
                    is IllegalArgumentException -> "validation"
                    is IllegalStateException -> "state"
                    else -> "other"
                }
                progress("FILE ROUNDTRIP send_failed type=${envelope.type} category=$category")
                throw failure
            }
        }, scheduleWatchdog = false)
    try {
        server.start()
        coordinator.activateSession("test-pixel", "test-mac", generation = 91)
        // Ten separate transfers retain their production 300-second deadlines.
        // The emulator can spend minutes on encrypted maximum-size roundtrips.
        withTimeout(900_000) {
            for ((boundaryIndex, size) in listOf(0, 1, 32_768, 32_769, 16_777_216).withIndex()) {
                savedResult = null
                val sourceName = "boundary-$size.bin"
                val targetName = "returned-$size.bin"
                File(root, sourceName).outputStream().use { output ->
                    val block = ByteArray(32_768)
                    var offset = 0
                    while (offset < size) {
                        val count = minOf(block.size, size - offset)
                        for (index in 0 until count) block[index] = ((offset + index) % 251).toByte()
                        output.write(block, 0, count)
                        offset += count
                    }
                }
                check(coordinator.offerOutgoing(OutgoingFileSource(sourceName, sourceName, "application/octet-stream")) == FileOfferStartResult.Offered)
                var returningFile = false
                var returnTransferId: String? = null
                while (true) {
                    val inbound = try {
                        withTimeout(30_000) { server.receiveOnce() }
                    } catch (timeout: TimeoutCancellationException) {
                        progress("FILE ROUNDTRIP boundary=$size receive_timeout")
                        throw timeout
                    }
                    if (inbound.type == PlinkEventType.FileOffer) {
                        check(returnTransferId == null) { "Unexpected second return offer" }
                        returnTransferId = inbound.payload.getValue("transferId").jsonPrimitive.content
                    }
                    coordinator.handle(inbound, generation = 91)
                    offerHandle?.let { handle ->
                        check(coordinator.pendingIncoming(handle)?.sizeBytes == size.toLong())
                        returningFile = true
                        check(coordinator.acceptIncoming(handle, IncomingFileDestination(targetName, newlyCreated = true)))
                    }
                    if (returningFile && coordinator.state.value is FileTransferState.Saved) break
                    check(coordinator.state.value !is FileTransferState.Failed) { "Transfer failed: ${coordinator.state.value}" }
                }
                val returned = File(root, targetName)
                check(returned.length() == size.toLong())
                returned.inputStream().use { input ->
                    val block = ByteArray(32_768)
                    var offset = 0
                    while (true) {
                        val count = input.read(block)
                        if (count < 0) break
                        for (index in 0 until count) check(block[index] == ((offset + index) % 251).toByte())
                        offset += count
                    }
                    check(offset == size)
                }
                check(File(root, "stage").walkTopDown().none { it.isFile }) { "Transfer staging was not cleaned" }
                check(File(root, sourceName).delete() && returned.delete())
                val result = checkNotNull(savedResult) { "Return saved result was not attempted" }
                check(returnTransferId != null &&
                    result.payload["transferId"]?.jsonPrimitive?.content == returnTransferId)
                // Local Saved is insufficient: the Mac must process this exact result
                // and finish cleanup before another offer (or final success).
                val ack = try {
                    withTimeout(30_000) { server.receiveOnce() }
                } catch (timeout: TimeoutCancellationException) {
                    progress("FILE ROUNDTRIP boundary=$size boundary_ack_timeout")
                    throw timeout
                }
                check(ack.type == PlinkEventType.Ack &&
                    ack.sourceDeviceId == "test-mac" && ack.targetDeviceId == "test-pixel" &&
                    !ack.requiresAck &&
                    ack.payload["eventId"]?.jsonPrimitive?.content == result.id &&
                    ack.payload["status"]?.jsonPrimitive?.content == "executed" &&
                    ack.payload["transferId"]?.jsonPrimitive?.content == returnTransferId &&
                    ack.payload["sizeBytes"]?.jsonPrimitive?.intOrNull == size &&
                    ack.payload["boundaryIndex"]?.jsonPrimitive?.intOrNull == boundaryIndex
                ) { "Invalid file boundary acknowledgement" }
                progress("FILE ROUNDTRIP boundary=$size: Android returned bytes verified, temporary files removed, Mac cleanup acknowledged")
            }
        }
        "Encrypted Android–Swift files both directions at 0, 1, 32768, 32769, 16777216 bytes, byte equality and private staging cleanup"
    } finally {
        coordinator.close()
        server.close()
        key.fill(0)
        check(root.deleteRecursively()) { "File roundtrip temporary cleanup failed" }
    }
}
