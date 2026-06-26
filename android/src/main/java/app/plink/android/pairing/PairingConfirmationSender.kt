package app.plink.android.pairing

import app.plink.android.transport.LengthPrefixedFrameCodec
import java.io.DataOutputStream
import java.net.InetSocketAddress
import java.net.Socket
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

class PairingConfirmationSender(
    private val connectTimeoutMillis: Int = 5_000,
    private val socketTimeoutMillis: Int = 5_000
) {
    suspend fun send(offer: PairingOffer, confirmation: PairingConfirmation) {
        val (host, port) = parseEndpoint(offer.endpoint)
        val payload = PairingPayloadCodec.encodeConfirmation(confirmation).toByteArray(Charsets.UTF_8)
        withContext(Dispatchers.IO) {
            Socket().use { socket ->
                socket.connect(InetSocketAddress(host, port), connectTimeoutMillis)
                socket.soTimeout = socketTimeoutMillis
                socket.tcpNoDelay = true
                LengthPrefixedFrameCodec.write(DataOutputStream(socket.getOutputStream()), payload)
            }
        }
    }

    private fun parseEndpoint(endpoint: String): Pair<String, Int> {
        val separator = endpoint.lastIndexOf(":")
        require(separator > 0 && separator < endpoint.lastIndex) { "Mac endpoint must be host:port." }
        val host = endpoint.substring(0, separator)
        val port = endpoint.substring(separator + 1).toInt()
        require(port in 1..65535) { "Mac endpoint port is invalid." }
        return host to port
    }
}
