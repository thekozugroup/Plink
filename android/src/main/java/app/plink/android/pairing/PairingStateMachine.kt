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

    private var localReplyEndpoint: String = ""

    fun receiveOffer(offer: PairingOffer, localEndpoint: String = ""): PairingStatus.ShowingCode {
        require(offer.protocolVersion == 1) { "Unsupported pairing protocol." }
        localReplyEndpoint = localEndpoint
        lastSessionKey = null
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
            trusted = true,
            securityVersion = 2
        )
        val next = PairingStatus.Paired(device)
        status = next
        return next
    }

    /** Compatibility API. Live callers must use previewWithResponse and mutual consent. */
    fun confirmWithResponse(
        localDeviceId: String,
        localDeviceName: String,
        localEndpoint: String
    ): Pair<PairingStatus.Paired, PairingConfirmation> {
        if (localReplyEndpoint.isEmpty()) localReplyEndpoint = localEndpoint
        val (candidate, confirmation) = previewWithResponse(localDeviceId, localDeviceName, localEndpoint)
        val paired = PairingStatus.Paired(candidate.copy(trusted = true))
        status = paired
        return paired to confirmation
    }

    /** Derives a candidate only. Neither status nor candidate grants trust. */
    fun previewWithResponse(
        localDeviceId: String,
        localDeviceName: String,
        localEndpoint: String
    ): Pair<PairedDevice, PairingConfirmation> {
        val showing = status as? PairingStatus.ShowingCode
            ?: error("Pairing preview requires a displayed offer.")
        require(localEndpoint.isNotBlank() && localEndpoint == localReplyEndpoint) {
            "Pass the reply endpoint to receiveOffer before displaying the code."
        }
        require(localDeviceId == showing.offer.targetDeviceId) { "Pairing target mismatch." }
        val session = deriveSession(showing.offer)
        val candidate = PairedDevice(
            id = showing.offer.deviceId, name = showing.offer.deviceName,
            platform = showing.offer.platform, endpoint = showing.offer.endpoint,
            sessionId = session.sessionId, peerPublicKey = showing.offer.publicKey,
            localPublicKey = localKeyPair.publicKeyBase64, trusted = false, securityVersion = 2
        )
        val confirmation = PairingConfirmation(
            deviceId = localDeviceId, deviceName = localDeviceName, platform = "android",
            endpoint = localEndpoint, publicKey = localKeyPair.publicKeyBase64,
            targetDeviceId = showing.offer.deviceId, offerNonce = showing.offer.nonce,
            sessionId = session.sessionId, protocolVersion = showing.offer.protocolVersion
        )
        return candidate to confirmation
    }

    fun reject(reason: String): PairingStatus.Rejected {
        lastSessionKey = null
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
        protocolVersion = offer.protocolVersion,
        targetEndpoint = localReplyEndpoint
    )
}
