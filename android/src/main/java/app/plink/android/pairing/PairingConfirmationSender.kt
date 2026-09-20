package app.plink.android.pairing

import app.plink.android.transport.sendLengthPrefixedFrame

class PairingConfirmationSender(
    private val connectTimeoutMillis: Int = 5_000,
    private val socketTimeoutMillis: Int = 5_000
) {
    suspend fun send(offer: PairingOffer, confirmation: PairingConfirmation) {
        val (host, port) = parseEndpoint(offer.endpoint)
        val payload = PairingPayloadCodec.encodeConfirmation(confirmation).toByteArray(Charsets.UTF_8)
        sendLengthPrefixedFrame(host, port, payload, minOf(connectTimeoutMillis, socketTimeoutMillis))
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
