package app.plink.android.notifications

import java.time.Clock
import java.time.Duration
import java.time.Instant
import java.util.UUID

data class LiveReplyRoute(
    val route: ReplyRoute,
    val createdAt: Instant,
    val expiresAt: Instant
) {
    fun isExpired(now: Instant): Boolean = !expiresAt.isAfter(now)
}

class ReplyRouteRegistry(
    private val clock: Clock = Clock.systemUTC(),
    private val ttl: Duration = Duration.ofMinutes(10)
) {
    private val routes = linkedMapOf<String, LiveReplyRoute>()

    @Synchronized
    fun register(
        pairedDeviceId: String,
        sourceEnvelopeId: String,
        packageName: String,
        notificationKey: String,
        conversationId: String?,
        canReply: Boolean,
        replyToken: String = UUID.randomUUID().toString()
    ): ReplyRoute {
        val now = Instant.now(clock)
        prune(now)
        val route = ReplyRoute(
            pairedDeviceId = pairedDeviceId,
            sourceEnvelopeId = sourceEnvelopeId,
            packageName = packageName,
            notificationKey = notificationKey,
            conversationId = conversationId,
            canReply = canReply,
            replyToken = replyToken
        )
        routes[route.replyToken] = LiveReplyRoute(route = route, createdAt = now, expiresAt = now.plus(ttl))
        return route
    }

    @Synchronized
    fun consume(replyToken: String): ReplyRoute? {
        val now = Instant.now(clock)
        prune(now)
        return routes.remove(replyToken)?.route
    }

    @Synchronized
    fun peek(replyToken: String): ReplyRoute? {
        val now = Instant.now(clock)
        prune(now)
        return routes[replyToken]?.route
    }

    @Synchronized
    fun removeByNotificationKey(notificationKey: String) {
        routes.entries.removeIf { it.value.route.notificationKey == notificationKey }
    }

    fun replaceForNotification(notificationKey: String) = removeByNotificationKey(notificationKey)

    @Synchronized
    fun clear() = routes.clear()

    @Synchronized
    fun size(): Int {
        prune(Instant.now(clock))
        return routes.size
    }

    private fun prune(now: Instant) {
        routes.entries.removeIf { it.value.isExpired(now) }
    }
}
