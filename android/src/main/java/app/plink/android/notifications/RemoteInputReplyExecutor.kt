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

data class LiveRemoteInputAction(
    val replyToken: String,
    val notificationKey: String,
    val action: Notification.Action,
    val remoteInputs: Array<RemoteInput>,
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
            createdAt == other.createdAt &&
            expiresAt == other.expiresAt
    }

    override fun hashCode(): Int {
        var result = replyToken.hashCode()
        result = 31 * result + notificationKey.hashCode()
        result = 31 * result + action.hashCode()
        result = 31 * result + remoteInputs.contentHashCode()
        result = 31 * result + createdAt.hashCode()
        result = 31 * result + expiresAt.hashCode()
        return result
    }
}

class RemoteInputReplyRegistry(
    private val clock: Clock = Clock.systemUTC(),
    private val ttl: Duration = Duration.ofMinutes(10)
) {
    private val actions = linkedMapOf<String, LiveRemoteInputAction>()

    @Synchronized
    fun register(replyToken: String, notificationKey: String, action: Notification.Action): Boolean {
        val remoteInputs = action.remoteInputs ?: return false
        if (remoteInputs.isEmpty()) return false
        val now = Instant.now(clock)
        prune(now)
        actions[replyToken] = LiveRemoteInputAction(
            replyToken = replyToken,
            notificationKey = notificationKey,
            action = action,
            remoteInputs = remoteInputs,
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
    fun removeByNotificationKey(notificationKey: String) {
        actions.entries.removeIf { it.value.notificationKey == notificationKey }
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
    private val actions: RemoteInputReplyRegistry
) {
    @Throws(PendingIntent.CanceledException::class)
    fun execute(envelope: PlinkEnvelope, localDeviceId: String): ValidatedInboundReply {
        val reply = InboundReplyValidator.consume(envelope, routes, localDeviceId)
        val liveAction = actions.consume(reply.route.replyToken)
            ?: throw IllegalArgumentException("Reply action was not found.")
        val intent = Intent()
        val results = Bundle()
        liveAction.remoteInputs.forEach { input ->
            results.putCharSequence(input.resultKey, reply.text)
        }
        RemoteInput.addResultsToIntent(liveAction.remoteInputs, intent, results)
        liveAction.action.actionIntent.send(context, 0, intent)
        return reply
    }
}
