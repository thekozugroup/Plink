package app.plink.android.pairing

/** Uses elapsed-realtime milliseconds, never wall time. Expiration is permanent. */
class PairingConsentGate(private val expiresAtMillis: Long) {
    private var locallyConfirmed = false
    private var remotelyConfirmed = false
    private var closed = false

    @Synchronized fun confirmLocal(nowMillis: Long) {
        requireLive(nowMillis)
        locallyConfirmed = true
    }

    @Synchronized fun confirmRemote(nowMillis: Long) {
        requireLive(nowMillis)
        remotelyConfirmed = true
    }

    @Synchronized fun consume(nowMillis: Long): Boolean {
        requireLive(nowMillis)
        if (!locallyConfirmed || !remotelyConfirmed) return false
        closed = true
        return true
    }

    @Synchronized fun cancel() { closed = true }

    @Synchronized fun checkLive(nowMillis: Long) = requireLive(nowMillis)

    private fun requireLive(nowMillis: Long) {
        if (nowMillis >= expiresAtMillis) closed = true
        check(!closed) { "Pairing attempt expired or was cancelled." }
    }
}
