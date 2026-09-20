package app.plink.android.screen

import java.util.UUID
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.awaitAll

class ScreenProjectionStartTicket internal constructor(
    internal val token: String,
    val requestId: String,
    val streamId: String,
    val sessionGeneration: Long,
    internal val ownerGeneration: Long,
    internal val completion: CompletableDeferred<Unit>
)

/** Tracks issued launches through delivery and release, even after authorization is revoked. */
internal class ScreenProjectionLifecycles<Owner : Any> {
    private data class Lifecycle<Owner>(
        val ticket: ScreenProjectionStartTicket,
        var launchIssued: Boolean = false,
        var active: Boolean = true,
        var owner: Owner? = null
    )

    private val lock = Any()
    private val entries = linkedMapOf<String, Lifecycle<Owner>>()

    internal val outstandingCount: Int get() = synchronized(lock) { entries.size }

    fun register(
        requestId: String, streamId: String, sessionGeneration: Long, ownerGeneration: Long
    ): ScreenProjectionStartTicket {
        val ticket = ScreenProjectionStartTicket(
            UUID.randomUUID().toString(), requestId, streamId, sessionGeneration,
            ownerGeneration, CompletableDeferred()
        )
        synchronized(lock) { entries[ticket.token] = Lifecycle(ticket) }
        return ticket
    }

    fun markLaunchIssued(ticket: ScreenProjectionStartTicket): Boolean = synchronized(lock) {
        val entry = entries[ticket.token]
        if (entry?.ticket !== ticket || !entry.active || entry.launchIssued) return@synchronized false
        entry.launchIssued = true
        true
    }

    /** Delivery ownership is recorded even for a revoked launch; it does not authorize capture. */
    fun claimDelivery(
        token: String, requestId: String, streamId: String, sessionGeneration: Long,
        ownerGeneration: Long, owner: Owner
    ): ScreenProjectionStartTicket? = synchronized(lock) {
        val entry = entries[token]?.takeIf {
            it.launchIssued && it.owner == null && it.ticket.requestId == requestId &&
                it.ticket.streamId == streamId && it.ticket.sessionGeneration == sessionGeneration &&
                it.ticket.ownerGeneration == ownerGeneration
        } ?: return@synchronized null
        entry.owner = owner
        entry.ticket
    }

    fun isCurrent(ticket: ScreenProjectionStartTicket, owner: Owner): Boolean = synchronized(lock) {
        entries[ticket.token]?.let { it.ticket === ticket && it.active && it.owner === owner } == true
    }

    fun currentOwner(ticket: ScreenProjectionStartTicket): Owner? = synchronized(lock) {
        entries[ticket.token]?.takeIf { it.ticket === ticket && it.active }?.owner
    }

    fun stopping(ticket: ScreenProjectionStartTicket, owner: Owner): Boolean = synchronized(lock) {
        val entry = entries[ticket.token]
        if (entry?.ticket !== ticket || entry.owner !== owner) return@synchronized false
        entry.active = false
        true
    }

    fun invalidate(ticket: ScreenProjectionStartTicket): Owner? = revoke(ticket, launchFailed = false)

    fun launchFailed(ticket: ScreenProjectionStartTicket): Owner? = revoke(ticket, launchFailed = true)

    private fun revoke(ticket: ScreenProjectionStartTicket, launchFailed: Boolean): Owner? {
        var completion: CompletableDeferred<Unit>? = null
        val owner = synchronized(lock) {
            val entry = entries[ticket.token]
            if (entry?.ticket !== ticket) return null
            entry.active = false
            if (entry.owner == null && (!entry.launchIssued || launchFailed)) {
                entries.remove(ticket.token)
                completion = ticket.completion
            }
            entry.owner
        }
        completion?.complete(Unit)
        return owner
    }

    /** The service calls this only after the delivered launch has no remaining owned resources. */
    fun complete(ticket: ScreenProjectionStartTicket, owner: Owner) {
        val complete = synchronized(lock) {
            val entry = entries[ticket.token]
            if (entry?.ticket !== ticket || entry.owner !== owner) false else {
                entries.remove(ticket.token)
                true
            }
        }
        if (complete) ticket.completion.complete(Unit)
    }

    suspend fun awaitQuiescence() {
        while (true) {
            val completions = synchronized(lock) { entries.values.map { it.ticket.completion } }
            if (completions.isEmpty()) return
            completions.awaitAll()
        }
    }
}
