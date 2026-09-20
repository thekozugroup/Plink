package app.plink.android.reconnect

import app.plink.android.protocol.PlinkEnvelope
import app.plink.android.services.EventOutbox
import app.plink.android.services.OrdinaryAdmissionLease
import app.plink.android.services.SerializedOutboundQueue
import app.plink.android.services.SharedOutboundBridge
import app.plink.android.transport.OutboundPlinkSender
import kotlinx.coroutines.CoroutineScope

/** Unpublished resources. Disk preparation must finish before entering the lifecycle owner. */
internal class PreparedOrdinaryResources private constructor(
    val outbox: EventOutbox,
    val admission: OrdinaryAdmissionLease,
    val outbound: SerializedOutboundQueue
) {
    fun publish(
        owner: ReconnectLifecycleOwner,
        token: ReconnectAttemptToken,
        pairIsCurrent: () -> Boolean,
        publicationLock: Any,
        install: () -> Boolean
    ): Boolean = owner.publish(token, pairIsCurrent) {
        synchronized(publicationLock) {
            // Lock acquisition itself can wait; revalidate immediately before installing state.
            if (!owner.isCurrent(token, pairIsCurrent)) return@synchronized false
            install()
        }
    }

    fun stop() {
        admission.revoke()
        outbound.stop()
    }

    suspend fun awaitStopped() {
        admission.dispatch.awaitStopped()
        outbound.awaitStopped()
    }

    companion object {
        fun prepare(
            outbox: EventOutbox,
            disabledTypes: Set<String>,
            sender: OutboundPlinkSender,
            generation: Long,
            binding: ReconnectLiveBinding?,
            attemptToken: ReconnectAttemptToken?,
            scope: CoroutineScope,
            isAllowed: (PlinkEnvelope) -> Boolean
        ): PreparedOrdinaryResources {
            // Includes encryption, temporary-file write and fsync. No owner lock or admission yet.
            outbox.removeTypes(disabledTypes)
            val admission = OrdinaryAdmissionLease(generation, binding, attemptToken, scope, initiallyAdmitted = false)
            try {
                val outbound = SharedOutboundBridge.prepare(sender, outbox) {
                    admission.isAdmitted() && isAllowed(it)
                }
                return PreparedOrdinaryResources(outbox, admission, outbound)
            } catch (failure: Exception) {
                admission.revoke()
                throw failure
            }
        }
    }
}
