package app.plink.android.pairing

class PairingStateMachine(
    initial: PairingStatus = PairingStatus.Idle,
    private val localKeyPair: DeviceKeyPair = PairingCrypto.generateKeyPair()
) {
    var status: PairingStatus = initial
        private set
    var lastSessionKey: ByteArray? = null
        private set
    val localPublicKeyBase64: String
        get() = localKeyPair.publicKeyBase64

    fun receiveOffer(offer: PairingOffer): PairingStatus.ShowingCode {
        val next = PairingStatus.ShowingCode(
            offer = offer,
            emoji = offer.emojiCode,
            verificationCode = PairingTranscript.verificationCode(pairingTranscript(offer))
        )
        status = next
        return next
    }

    fun confirm(): PairingStatus.Paired {
        val showing = status as? PairingStatus.ShowingCode
            ?: error("Pairing can only be confirmed after an offer is shown.")
        val session = deriveSession(showing.offer)
        val device = PairedDevice(
            id = showing.offer.deviceId,
            name = showing.offer.deviceName,
            platform = showing.offer.platform,
            endpoint = showing.offer.endpoint,
            sessionId = session.sessionId,
            peerPublicKey = showing.offer.publicKey,
            localPublicKey = localKeyPair.publicKeyBase64,
            trusted = true
        )
        val next = PairingStatus.Paired(device)
        status = next
        return next
    }

    fun confirmWithResponse(
        localDeviceId: String,
        localDeviceName: String,
        localEndpoint: String
    ): Pair<PairingStatus.Paired, PairingConfirmation> {
        val showing = status as? PairingStatus.ShowingCode
            ?: error("Pairing can only be confirmed after an offer is shown.")
        val paired = confirm()
        val session = lastSessionKey ?: error("Pairing session key was not derived.")
        val sessionId = DerivedSession(
            sessionId = PairingCrypto.sessionId(session),
            sessionKey = session
        ).sessionId
        val confirmation = PairingConfirmation(
            deviceId = localDeviceId,
            deviceName = localDeviceName,
            platform = "android",
            endpoint = localEndpoint,
            publicKey = localKeyPair.publicKeyBase64,
            targetDeviceId = showing.offer.deviceId,
            offerNonce = showing.offer.nonce,
            sessionId = sessionId,
            protocolVersion = showing.offer.protocolVersion
        )
        return paired to confirmation
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
            transcript = pairingTranscript(offer)
        )
        lastSessionKey = session.sessionKey
        return session
    }

    private fun pairingTranscript(offer: PairingOffer): String = PairingTranscript.canonical(
        sourceDeviceId = offer.deviceId,
        targetDeviceId = offer.targetDeviceId,
        endpoint = offer.endpoint,
        nonce = offer.nonce,
        sourcePublicKey = offer.publicKey,
        targetPublicKey = localKeyPair.publicKeyBase64,
        protocolVersion = offer.protocolVersion
    )
}
