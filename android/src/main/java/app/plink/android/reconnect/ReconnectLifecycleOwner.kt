package app.plink.android.reconnect

/** Exact ownership for one reconnect attempt. All commit points use this same lock. */
internal data class ReconnectAttemptToken(
    val value: Long,
    val deadlineMillis: Long,
    val conditional: Boolean = false
)

internal data class ReconnectInvalidation(
    val invalidated: Boolean,
    val cleanupRequired: Boolean
)

internal class ReconnectLifecycleOwner(
    private val monotonicMillis: () -> Long
) {
    private val lock = Any()
    private var nextValue = 0L
    private var current: ReconnectAttemptToken? = null
    private var published: ReconnectAttemptToken? = null
    private var closed = false

    fun begin(timeoutMillis: Long): ReconnectAttemptToken? = synchronized(lock) {
        require(timeoutMillis > 0)
        if (closed || current != null) return@synchronized null
        ReconnectAttemptToken(++nextValue, monotonicMillis() + timeoutMillis).also { current = it }
    }

    /** Reserve while admission is still locked; a snapshot before begin() is insufficient. */
    fun beginConditional(
        timeoutMillis: Long,
        admissionLock: Any,
        eligible: () -> Boolean
    ): ReconnectAttemptToken? = synchronized(lock) {
        require(timeoutMillis > 0)
        if (closed || current != null) return@synchronized null
        synchronized(admissionLock) claim@{
            if (!eligible()) return@claim null
            ReconnectAttemptToken(++nextValue, monotonicMillis() + timeoutMillis, conditional = true)
                .also { current = it }
        }
    }

    fun isCurrent(token: ReconnectAttemptToken, pairIsCurrent: () -> Boolean): Boolean = synchronized(lock) {
        validLocked(token, pairIsCurrent)
    }

    fun <T> commit(
        token: ReconnectAttemptToken,
        pairIsCurrent: () -> Boolean,
        operation: () -> T
    ): T? = synchronized(lock) {
        if (!validLocked(token, pairIsCurrent)) return@synchronized null
        operation()
    }

    fun publish(
        token: ReconnectAttemptToken,
        pairIsCurrent: () -> Boolean,
        operation: () -> Boolean
    ): Boolean = synchronized(lock) {
        if (!validLocked(token, pairIsCurrent) || !operation()) return@synchronized false
        published = token
        true
    }

    fun invalidate(
        token: ReconnectAttemptToken? = null,
        revoke: (ReconnectAttemptToken, Boolean) -> Boolean
    ): ReconnectInvalidation = synchronized(lock) {
        val owned = current ?: return@synchronized ReconnectInvalidation(false, false)
        if (token != null && owned != token) return@synchronized ReconnectInvalidation(false, false)
        current = null
        val wasPublished = published == owned
        if (wasPublished) published = null
        ReconnectInvalidation(true, revoke(owned, wasPublished))
    }

    fun finish(token: ReconnectAttemptToken) = synchronized(lock) {
        if (current == token) current = null
        if (published == token) published = null
    }

    fun close(revoke: (ReconnectAttemptToken, Boolean) -> Boolean): ReconnectInvalidation = synchronized(lock) {
        closed = true
        val owned = current ?: return@synchronized ReconnectInvalidation(false, false)
        current = null
        val wasPublished = published == owned
        published = null
        ReconnectInvalidation(true, revoke(owned, wasPublished))
    }

    private fun validLocked(token: ReconnectAttemptToken, pairIsCurrent: () -> Boolean): Boolean =
        !closed && current == token && monotonicMillis() < token.deadlineMillis && pairIsCurrent()
}
