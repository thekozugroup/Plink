package app.plink.android.pairing

import java.security.MessageDigest

class PairingStateMachine(
    initial: PairingStatus = PairingStatus.Idle
) {
    var status: PairingStatus = initial
        private set

    fun receiveOffer(offer: PairingOffer): PairingStatus.ShowingCode {
        val next = PairingStatus.ShowingCode(offer, EmojiPairing.derive(offer.deviceId, "mac", offer.nonce))
        status = next
        return next
    }

    fun confirm(): PairingStatus.Paired {
        val showing = status as? PairingStatus.ShowingCode
            ?: error("Pairing can only be confirmed after an offer is shown.")
        val device = PairedDevice(
            id = showing.offer.deviceId,
            name = showing.offer.deviceName,
            platform = showing.offer.platform,
            endpoint = showing.offer.endpoint,
            sessionId = deriveSessionId(showing.offer),
            trusted = true
        )
        val next = PairingStatus.Paired(device)
        status = next
        return next
    }

    fun reject(reason: String): PairingStatus.Rejected {
        val next = PairingStatus.Rejected(reason)
        status = next
        return next
    }

    private fun deriveSessionId(offer: PairingOffer): String {
        val input = "${offer.deviceId}|${offer.endpoint}|${offer.nonce}|plink-v${offer.protocolVersion}"
        val digest = MessageDigest.getInstance("SHA-256").digest(input.toByteArray())
        return digest.joinToString(separator = "") { "%02x".format(it) }.take(32)
    }
}
