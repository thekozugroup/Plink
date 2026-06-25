package app.plink.android.pairing

class PairingStateMachine(
    initial: PairingStatus = PairingStatus.Idle,
    private val localKeyPair: DeviceKeyPair = PairingCrypto.generateKeyPair()
) {
    var status: PairingStatus = initial
        private set
    var lastSessionKey: ByteArray? = null
        private set

    fun receiveOffer(offer: PairingOffer): PairingStatus.ShowingCode {
        val next = PairingStatus.ShowingCode(offer, offer.emojiCode)
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
            sessionId = deriveSession(showing.offer).sessionId,
            peerPublicKey = showing.offer.publicKey,
            localPublicKey = localKeyPair.publicKeyBase64,
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

    private fun deriveSession(offer: PairingOffer): DerivedSession {
        val session = PairingCrypto.deriveSession(
            localPrivateKey = localKeyPair.privateKey,
            peerPublicKeyBase64 = offer.publicKey,
            nonce = offer.nonce,
            transcript = "${offer.deviceId}|${offer.targetDeviceId}|${offer.endpoint}|plink-v${offer.protocolVersion}"
        )
        lastSessionKey = session.sessionKey
        return session
    }
}
