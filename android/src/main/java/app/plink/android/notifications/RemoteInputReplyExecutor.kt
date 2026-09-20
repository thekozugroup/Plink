package app.plink.android.notifications

import android.app.Notification
import android.app.PendingIntent
import android.app.RemoteInput
import android.content.Context
import android.content.Intent
import android.os.Bundle
import app.plink.android.protocol.PlinkEnvelope
import java.time.Clock
import java.time.Duration
import java.time.Instant

data class ReplyCapabilityGeneration(
    val listenerEpoch: Long,
    val sessionGeneration: Long
)

object ReplyDispatchLock {
    private val lock = Any()

    fun <T> serialized(block: () -> T): T = synchronized(lock, block)
}

data class LiveRemoteInputAction(
    val replyToken: String,
    val notificationKey: String,
    val action: Notification.Action,
    val remoteInputs: Array<RemoteInput>,
    val capabilityGeneration: ReplyCapabilityGeneration,
    val createdAt: Instant,
    val expiresAt: Instant
) {
    fun isExpired(now: Instant): Boolean = !expiresAt.isAfter(now)

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is LiveRemoteInputAction) return false
        return replyToken == other.replyToken &&
            notificationKey == other.notificationKey &&
            action == other.action &&
            remoteInputs.contentEquals(other.remoteInputs) &&
            capabilityGeneration == other.capabilityGeneration &&
            createdAt == other.createdAt &&
            expiresAt == other.expiresAt
    }

    override fun hashCode(): Int {
        var result = replyToken.hashCode()
        result = 31 * result + notificationKey.hashCode()
        result = 31 * result + action.hashCode()
        result = 31 * result + remoteInputs.contentHashCode()
        result = 31 * result + capabilityGeneration.hashCode()
        result = 31 * result + createdAt.hashCode()
        result = 31 * result + expiresAt.hashCode()
        return result
    }
}

class RemoteInputReplyRegistry(
    private val clock: Clock = Clock.systemUTC(),
    private val ttl: Duration = Duration.ofMinutes(10),
    private val capabilityGeneration: () -> ReplyCapabilityGeneration?
) {
    private val actions = linkedMapOf<String, LiveRemoteInputAction>()

    @Synchronized
    fun register(replyToken: String, notificationKey: String, action: Notification.Action): Boolean {
        val generation = capabilityGeneration() ?: return false
        val remoteInputs = action.remoteInputs?.filter { it.allowFreeFormInput }?.toTypedArray() ?: return false
        if (action.actionIntent == null || remoteInputs.isEmpty()) {
            return false
        }
        if (android.os.Build.VERSION.SDK_INT >= 31 && action.isAuthenticationRequired) return false
        val now = Instant.now(clock)
        prune(now)
        actions[replyToken] = LiveRemoteInputAction(
            replyToken = replyToken,
            notificationKey = notificationKey,
            action = action,
            remoteInputs = remoteInputs,
            capabilityGeneration = generation,
            createdAt = now,
            expiresAt = now.plus(ttl)
        )
        return true
    }

    @Synchronized
    fun consume(replyToken: String): LiveRemoteInputAction? {
        val now = Instant.now(clock)
        prune(now)
        return actions.remove(replyToken)
    }

    @Synchronized
    fun peek(replyToken: String): LiveRemoteInputAction? {
        val now = Instant.now(clock)
        prune(now)
        return actions[replyToken]
    }

    @Synchronized
    fun removeByNotificationKey(notificationKey: String) {
        actions.entries.removeIf { it.value.notificationKey == notificationKey }
    }

    fun replaceForNotification(notificationKey: String) = removeByNotificationKey(notificationKey)

    @Synchronized
    fun clear() = actions.clear()

    @Synchronized
    fun remove(replyToken: String) {
        actions.remove(replyToken)
    }

    @Synchronized
    fun size(): Int {
        prune(Instant.now(clock))
        return actions.size
    }

    private fun prune(now: Instant) {
        actions.entries.removeIf { it.value.isExpired(now) }
    }
}

class RemoteInputReplyExecutor(
    private val context: Context,
    private val routes: ReplyRouteRegistry,
    private val actions: RemoteInputReplyRegistry,
    private val isAuthorized: (LiveRemoteInputAction, ValidatedInboundReply) -> Boolean
) {
    @Throws(PendingIntent.CanceledException::class)
    fun execute(envelope: PlinkEnvelope, localDeviceId: String): ValidatedInboundReply =
        ReplyDispatchLock.serialized {
            val reply = InboundReplyValidator.validate(envelope, routes, localDeviceId)
            val replyToken = reply.route.replyToken
            val liveAction = actions.peek(replyToken)
            if (liveAction == null) {
                routes.consume(replyToken)
                throw IllegalArgumentException("Reply action was not found.")
            }
            if (!isAuthorized(liveAction, reply)) {
                routes.consume(replyToken)
                actions.consume(replyToken)
                throw IllegalArgumentException("Reply authorization was revoked.")
            }
            val consumedRoute = routes.consume(replyToken)
                ?: throw IllegalArgumentException("Reply route was already consumed.")
            require(consumedRoute == reply.route) { "Reply route changed during validation." }
            val consumedAction = actions.consume(replyToken)
                ?: throw IllegalArgumentException("Reply action was already consumed.")
            require(consumedAction == liveAction) { "Reply action changed during validation." }
            val intent = Intent()
            val results = Bundle()
            liveAction.remoteInputs.forEach { input ->
                results.putCharSequence(input.resultKey, reply.text)
            }
            RemoteInput.addResultsToIntent(liveAction.remoteInputs, intent, results)
            liveAction.action.actionIntent.send(context, 0, intent)
            reply
        }
}
