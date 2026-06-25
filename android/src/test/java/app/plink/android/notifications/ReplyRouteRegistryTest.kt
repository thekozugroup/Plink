package app.plink.android.notifications

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test
import java.time.Clock
import java.time.Duration
import java.time.Instant
import java.time.ZoneOffset

class ReplyRouteRegistryTest {
    @Test
    fun routeCanOnlyBeConsumedOnce() {
        val registry = ReplyRouteRegistry(clock = fixedClock(), ttl = Duration.ofMinutes(10))
        val route = registry.register(
            pairedDeviceId = "mac",
            sourceEnvelopeId = "evt",
            packageName = "pkg",
            notificationKey = "key",
            conversationId = "thread",
            canReply = true
        )

        assertNotNull(registry.consume(route.replyToken))
        assertNull(registry.consume(route.replyToken))
    }

    @Test
    fun removedNotificationDropsRoute() {
        val registry = ReplyRouteRegistry(clock = fixedClock(), ttl = Duration.ofMinutes(10))
        registry.register("mac", "evt", "pkg", "key", null, true)

        registry.removeByNotificationKey("key")

        assertEquals(0, registry.size())
    }

    private fun fixedClock(): Clock = Clock.fixed(Instant.parse("2026-06-25T00:00:00Z"), ZoneOffset.UTC)
}
