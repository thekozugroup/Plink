package app.plink.android.services

import android.content.Context
import app.plink.android.notifications.RemoteInputReplyExecutor
import app.plink.android.pairing.PairedDevice
import app.plink.android.protocol.PlinkEventType
import app.plink.android.security.EncryptedFrameCodec
import app.plink.android.security.ReplayWindow
import app.plink.android.transport.SecureSocketPlinkClient
import app.plink.android.transport.SecureSocketPlinkServer
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

class PlinkSessionController(
    private val context: Context,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
) {
    private var replyReceiverJob: Job? = null

    fun configure(
        localDeviceId: String,
        pairedDevice: PairedDevice,
        sessionKey: ByteArray,
        localReplyPort: Int = 45731
    ) {
        SharedSessionState.configure(
            ActivePlinkSession(
                localDeviceId = localDeviceId,
                pairedDevice = pairedDevice,
                sessionKey = sessionKey
            )
        )
        configureOutbound(pairedDevice, sessionKey)
        startReplyReceiver(localDeviceId, pairedDevice.id, sessionKey, localReplyPort)
    }

    fun stop() {
        replyReceiverJob?.cancel()
        replyReceiverJob = null
        SharedOutboundBridge.configure(null)
        SharedSessionState.clear()
    }

    private fun configureOutbound(pairedDevice: PairedDevice, sessionKey: ByteArray) {
        val (host, port) = parseEndpoint(pairedDevice.endpoint)
        SharedOutboundBridge.configure(
            SecureSocketPlinkClient(
                host = host,
                port = port,
                codec = EncryptedFrameCodec(sessionKey)
            )
        )
    }

    private fun startReplyReceiver(
        localDeviceId: String,
        pairedDeviceId: String,
        sessionKey: ByteArray,
        localReplyPort: Int
    ) {
        replyReceiverJob?.cancel()
        val executor = RemoteInputReplyExecutor(
            context = context.applicationContext,
            routes = SharedReplyRoutes.registry,
            actions = SharedReplyActions.registry
        )
        replyReceiverJob = scope.launch {
            val replayWindow = ReplayWindow()
            while (isActive) {
                runCatching {
                    SecureSocketPlinkServer(
                        port = localReplyPort,
                        codec = EncryptedFrameCodec(sessionKey),
                        replayWindow = replayWindow,
                        expectedSourceDeviceId = pairedDeviceId,
                        expectedTargetDeviceId = localDeviceId
                    ).receiveOnce()
                }.onSuccess { envelope ->
                    if (envelope.type == PlinkEventType.MessageReply) {
                        executor.execute(envelope, localDeviceId)
                    }
                }.onFailure {
                    delay(500)
                }
            }
        }
    }

    private fun parseEndpoint(endpoint: String): Pair<String, Int> {
        val separator = endpoint.lastIndexOf(':')
        require(separator > 0 && separator < endpoint.lastIndex) { "Paired endpoint must be host:port." }
        val host = endpoint.substring(0, separator)
        val port = endpoint.substring(separator + 1).toInt()
        require(port in 1..65535) { "Paired endpoint port is invalid." }
        return host to port
    }
}
