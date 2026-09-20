package app.plink.android.services

import app.plink.android.reconnect.ReconnectAttemptToken
import app.plink.android.reconnect.ReconnectLiveBinding
import java.io.Closeable
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch

/** Bounded ordinary work owned by one admission generation. */
internal class OrdinaryDispatchOwner(
    scope: CoroutineScope,
    capacity: Int = 16
) {
    private val tasks = Channel<suspend () -> Unit>(capacity)
    private val worker: Job = scope.launch {
        for (task in tasks) {
            try {
                task()
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (_: Exception) {
                // An authenticated command failure is local to that command.
            }
        }
    }

    fun submit(task: suspend () -> Unit): Boolean = tasks.trySend(task).isSuccess

    fun stop() {
        tasks.cancel()
        worker.cancel()
    }

    suspend fun awaitStopped() = worker.join()
}

internal class OrdinaryAdmissionLease(
    val generation: Long,
    val binding: ReconnectLiveBinding?,
    val attemptToken: ReconnectAttemptToken?,
    scope: CoroutineScope,
    initiallyAdmitted: Boolean = true
) {
    private val lock = Any()
    private var admitted = initiallyAdmitted
    private var revoked = false
    private val acceptedSockets = mutableSetOf<Closeable>()
    val dispatch = OrdinaryDispatchOwner(scope)

    fun isAdmitted(): Boolean = synchronized(lock) { admitted }

    fun admit() = synchronized(lock) {
        check(!revoked) { "Revoked ordinary resources cannot be admitted." }
        admitted = true
    }

    fun runIfAdmitted(action: () -> Unit): Boolean = synchronized(lock) {
        if (!admitted) return@synchronized false
        action()
        true
    }

    fun trackAcceptedSocket(socket: Closeable): Boolean = synchronized(lock) {
        if (!admitted) return@synchronized false
        acceptedSockets += socket
        true
    }

    fun releaseAcceptedSocket(socket: Closeable) = synchronized(lock) {
        acceptedSockets -= socket
        Unit
    }

    fun revoke() {
        val sockets = synchronized(lock) {
            revoked = true
            admitted = false
            acceptedSockets.toList().also { acceptedSockets.clear() }
        }
        sockets.forEach { runCatching { it.close() } }
        dispatch.stop()
    }
}
