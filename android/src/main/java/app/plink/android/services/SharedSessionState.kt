package app.plink.android.services

import app.plink.android.pairing.PairedDevice

data class ActivePlinkSession(
    val localDeviceId: String,
    val pairedDevice: PairedDevice,
    val sessionKey: ByteArray
) {
    fun copySessionKey(): ByteArray = sessionKey.copyOf()
}

object SharedSessionState {
    private val lock = Any()
    private var active: ActivePlinkSession? = null

    fun configure(session: ActivePlinkSession) {
        synchronized(lock) {
            active = session.copy(sessionKey = session.sessionKey.copyOf())
        }
    }

    fun clear() {
        synchronized(lock) { active = null }
    }

    fun snapshot(): ActivePlinkSession? = synchronized(lock) {
        active?.copy(sessionKey = active?.sessionKey?.copyOf() ?: ByteArray(0))
    }
}
