package app.plink.android.notifications

import app.plink.android.protocol.PlinkEnvelope
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class NotificationActionRegistryTest {
    private var now = 1_790_000_000_000L
    private var sends = 0
    private fun registry() = NotificationActionRegistry(nowMillis = { now }).also {
        it.beginSession("phone", "mac", 7)
        it.setListenerAvailable(true)
        it.setFeatureEnabled(true)
    }
    private fun message(key: String = "key", id: String = "source") = PlinkEnvelope(
        id = id, type = "message.received", sentAt = "2026-09-22T00:00:00Z", sourceDeviceId = "phone",
        targetDeviceId = "mac", payload = buildJsonObject {
            put("sender", "Synthetic"); put("preview", "Synthetic"); put("packageName", "fixture"); put("notificationKey", key)
        }
    )
    private fun offer(r: NotificationActionRegistry, key: String = "key", auth: Boolean = false,
                      unlocked: () -> Boolean? = { true }): NotificationActionOffer =
        r.offer(message(key), listOf(NotificationActionSpec("Action", "invoke", auth,
            unlocked = unlocked, execute = { sends++ })))!!
    private fun command(offer: NotificationActionOffer, type: String = "notification.action") = PlinkEnvelope(
        id = "command", type = type, sentAt = "2026-09-22T00:00:00Z", sourceDeviceId = "mac", targetDeviceId = "phone",
        requiresAck = true, payload = buildJsonObject {
            put("actionsVersion", 1); put("actionsSession", offer.envelope.payload.getValue("actionsSession"))
            if (type == "notification.action") {
                put("actionsEpoch", offer.envelope.payload.getValue("actionsEpoch"))
                put("sourceEnvelopeId", offer.envelope.id); put("packageName", "fixture")
                put("notificationKey", offer.envelope.payload.getValue("notificationKey"))
                put("actionIndex", 0); put("actionToken", offer.envelope.payload.getValue("action0Token"))
            }
        }
    )
    private fun enable(r: NotificationActionRegistry, o: NotificationActionOffer) {
        assertEquals("enabled", r.handle(command(o, "notification.actions.enable"), 7).payload["status"]?.jsonPrimitive?.content)
    }
    private fun code(r: NotificationActionRegistry, o: NotificationActionOffer) = r.handle(command(o), 7).payload["code"]?.jsonPrimitive?.content

    @Test fun delayedMappingIssuesTimestampAndExpiryFromOneClockSample() {
        var samples = 0
        val issuance = 1_790_000_000_123L
        val r = NotificationActionRegistry(nowMillis = { issuance + samples++ }).also {
            it.beginSession("phone", "mac", 7); it.setListenerAvailable(true); it.setFeatureEnabled(true)
        }
        val earlier = message().copy(sentAt = java.time.Instant.ofEpochMilli(issuance - 250).toString())
        val produced = r.offer(earlier, listOf(NotificationActionSpec("Action", "invoke")))!!.envelope
        val wire = PlinkEnvelope.decode(produced.encode())
        assertEquals(1, samples)
        assertEquals(issuance, java.time.Instant.parse(wire.sentAt).toEpochMilli())
        assertEquals(issuance + 600_000, wire.payload.getValue("actionsExpiresAtMs").jsonPrimitive.long)
        assertEquals(earlier.id, wire.id)
    }

    @Test fun invalidIssuanceClockRetiresScopeBeforeExpiryArithmeticCanOverflow() {
        for (invalid in listOf(-1L, app.plink.android.protocol.NotificationActionsPolicy.MAX_INTEGER - 599_999, Long.MAX_VALUE)) {
            val r = registry(); val prior = offer(r)
            now = invalid
            assertNull(r.offer(message(), emptyList()))
            assertNull(r.currentSession())
            assertFalse(prior.claims.getValue(0).take())
            now = 1_790_000_000_000L
        }
    }

    @Test fun delayedSnapshotRemovalIssuesFreshTimestampRatherThanCopiedOldTimestamp() {
        val r = registry(); val initial = offer(r)
        now += 3_600_123
        val snapshot = r.captureSnapshot()!!
        val wire = PlinkEnvelope.decode(r.removeMissing(snapshot, emptySet()).single().encode())
        assertEquals(now, java.time.Instant.parse(wire.sentAt).toEpochMilli())
        assertEquals(now + 600_000, wire.payload.getValue("actionsExpiresAtMs").jsonPrimitive.long)
        assertEquals(true, wire.payload.getValue("removed").jsonPrimitive.boolean)
        assertEquals(0, wire.payload.getValue("actionsCount").jsonPrimitive.int)
        assertTrue(wire.payload.getValue("actionsRevision").jsonPrimitive.long > initial.envelope.payload.getValue("actionsRevision").jsonPrimitive.long)
        assertNotEquals(initial.envelope.id, wire.id)
    }

    @Test fun negotiationAndAllBindingsPrecedeExactlyOnceClaim() {
        val r = registry(); val o = offer(r)
        assertEquals("action_not_enabled", code(r, o)); assertEquals(0, sends)
        enable(r, o)
        for (field in listOf("actionsSession", "sourceEnvelopeId", "packageName", "notificationKey", "actionToken")) {
            val c = command(o); val wrong = if (field in listOf("actionsSession", "actionToken")) "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa" else "wrong"
            assertEquals("error", r.handle(c.copy(payload = JsonObject(c.payload + (field to JsonPrimitive(wrong)))), 7).type)
        }
        assertEquals("error", r.handle(command(o).copy(sourceDeviceId = "other"), 7).type)
        assertEquals("error", r.handle(command(o), 8).type)
        assertEquals(0, sends)
        assertEquals("dispatched", r.handle(command(o), 7).payload["status"]?.jsonPrimitive?.content)
        assertEquals("stale_action", code(r, o)); assertEquals(1, sends)
    }

    @Test fun lockUnknownAndLockedDoNotClaimButExplicitUnlockedAttemptDoes() {
        var unlocked: Boolean? = null
        val r = registry(); val o = offer(r, auth = true, unlocked = { unlocked }); enable(r, o)
        assertEquals("phone_locked", code(r, o)); unlocked = false
        assertEquals("phone_locked", code(r, o)); unlocked = true
        assertNull(code(r, o)); assertEquals(1, sends)
    }

    @Test fun updateRemoveOffListenerAndSessionRevoke() {
        for (revoke in listOf<(NotificationActionRegistry) -> Unit>(
            { offer(it) }, { it.offer(message(), emptyList(), removed = true) },
            { it.setFeatureEnabled(false) }, { it.setListenerAvailable(false) },
            { it.beginSession("phone", "mac", 8) }, { it.retireSession() }
        )) {
            val r = registry(); val o = offer(r); enable(r, o); revoke(r)
            assertNotNull(code(r, o))
        }
        assertEquals(0, sends)
    }

    @Test fun expiryAndAttemptFailureNeverRestoreClaim() {
        val r = registry(); val expired = offer(r); enable(r, expired); now += 600_000
        assertEquals("action_expired", code(r, expired))
        val failed = r.offer(message(), listOf(NotificationActionSpec("Action", "invoke", execute = {
            sends++; throw NotificationActionFailure("action_canceled")
        })))!!
        assertEquals("action_canceled", code(r, failed)); assertEquals("stale_action", code(r, failed)); assertEquals(1, sends)
    }

    @Test fun legacyAndV1ShareTheSameSingleUseClaimInEitherOrder() {
        for (legacyFirst in listOf(true, false)) {
            val r = registry(); val o = offer(r); enable(r, o); val claim = o.claims.getValue(0)
            if (legacyFirst) { assertTrue(claim.take()); assertEquals("stale_action", code(r, o)) }
            else { assertNull(code(r, o)); assertFalse(claim.take()) }
        }
        assertEquals(1, sends)
    }

    @Test fun unsupportedOlderTextOfferHasNoTokenAndForgedInvocationCannotExecute() {
        for (sdk in listOf(26, 30)) {
            val r = registry()
            val reason = NotificationActionInputPolicy.reason(sdk, true) { error("Unavailable accessor") }
            val offered = r.offer(message(), listOf(NotificationActionSpec("Reply", "phone", reason = reason,
                execute = { sends++ })))!!
            assertTrue(offered.claims.isEmpty())
            assertNull(offered.envelope.payload["action0Token"])
            enable(r, offered)
            val forgedOffer = offered.copy(envelope = offered.envelope.copy(payload = JsonObject(offered.envelope.payload +
                ("action0Token" to JsonPrimitive("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")))))
            assertEquals("unsupported_input", code(r, forgedOffer))
        }
        assertEquals(0, sends)
    }

    @Test fun exactTextAndNoInputRequirementsAreCheckedBeforeClaim() {
        val r = registry()
        var delivered: String? = null
        val text = r.offer(message(), listOf(NotificationActionSpec("Reply", "text", execute = { delivered = it })))!!
        enable(r, text)
        assertEquals("invalid_action", code(r, text))
        val exact = "  Synthetic \uD83D\uDC69\u200D\uD83D\uDCBB\n"
        val request = command(text).let { it.copy(payload = JsonObject(it.payload + ("text" to JsonPrimitive(exact)))) }
        assertEquals("ack", r.handle(request, 7).type)
        assertEquals(exact, delivered)
        assertEquals("error", r.handle(request, 7).type)
        val invoke = offer(r)
        val invented = command(invoke).let { it.copy(payload = JsonObject(it.payload + ("text" to JsonPrimitive("invented")))) }
        assertEquals("invalid_action", r.handle(invented, 7).payload["code"]?.jsonPrimitive?.content)
        assertNull(code(r, invoke)); assertEquals(1, sends)
    }

    @Test fun revocationIsSerializedWithActualDispatchWithoutAReplayAfterOutcomeLoss() {
        val r = registry()
        val entered = java.util.concurrent.CountDownLatch(1)
        val release = java.util.concurrent.CountDownLatch(1)
        val revoked = java.util.concurrent.CountDownLatch(1)
        val failure = java.util.concurrent.atomic.AtomicReference<Throwable?>()
        val o = r.offer(message(), listOf(NotificationActionSpec("Action", "invoke", execute = {
            entered.countDown()
            check(release.await(5, java.util.concurrent.TimeUnit.SECONDS))
            sends++
        })))!!
        enable(r, o)
        val sender = Thread { try { r.handle(command(o), 7) } catch (e: Throwable) { failure.set(e) } }
        val revoker = Thread { r.setFeatureEnabled(false); revoked.countDown() }
        sender.start()
        try {
            assertTrue(entered.await(5, java.util.concurrent.TimeUnit.SECONDS))
            revoker.start()
            assertEquals(1L, revoked.count) // Dispatch still owns the common authority lock.
        } finally { release.countDown(); sender.join(5000); if (revoker.state != Thread.State.NEW) revoker.join(5000) }
        assertNull(failure.get()); assertFalse(sender.isAlive); assertFalse(revoker.isAlive)
        assertEquals(1, sends); assertEquals("actions_disabled", code(r, o))
        r.setFeatureEnabled(true)
        assertEquals("stale_action", code(r, o)); assertEquals(1, sends)
    }

    @Test fun repeatedConnectedRevokesGenericClaimAndCapturedRefreshEvenWhenAlreadyAvailable() {
        val r = registry(); val offered = offer(r); enable(r, offered)
        val snapshot = r.captureSnapshot()!!
        r.setListenerAvailable(true, forceReset = true)
        assertEquals("stale_action", code(r, offered))
        assertFalse(offered.claims.getValue(0).take())
        assertFalse(r.canApplySnapshot(snapshot, "key"))
        assertEquals(0, sends)
        val fresh = offer(r)
        assertNull(code(r, fresh)); assertEquals(1, sends)
    }

    @Test fun heldSnapshotCannotUndoUpdateRemovalEpochOrEvictedWatermark() {
        val r = registry(); offer(r); val snapshot = r.captureSnapshot()!!
        offer(r); assertFalse(r.canApplySnapshot(snapshot, "key"))
        val removed = r.captureSnapshot()!!; r.offer(message(), emptyList(), removed = true)
        assertFalse(r.canApplySnapshot(removed, "key"))
        val epoch = r.captureSnapshot()!!; r.setFeatureEnabled(false); r.setFeatureEnabled(true)
        assertFalse(r.canApplySnapshot(epoch, "untouched"))
        val bounded = r.captureSnapshot()!!
        repeat(130) { r.offer(message("key$it"), emptyList(), removed = true) }
        assertFalse(r.canApplySnapshot(bounded, "key0"))
    }

    @Test fun snapshotAbsentReconciliationProtectsConcurrentReplacement() {
        val r = registry(); offer(r, "old"); offer(r, "changed"); val snapshot = r.captureSnapshot()!!
        offer(r, "changed")
        val tombstones = r.removeMissing(snapshot, emptySet())
        assertEquals(listOf("old"), tombstones.map { it.payload.getValue("notificationKey").jsonPrimitive.content })
        assertEquals(true, tombstones.single().payload["removed"]?.jsonPrimitive?.boolean)
    }

    @Test fun evictionRevokesLegacyClaimAndStatePrecedesNewEpochOffer() {
        val events = mutableListOf<String>()
        val r = registry(); r.onState = { events += "state:${it.payload["state"]}" }
        val first = offer(r); enable(r, first)
        repeat(128) { offer(r, "key$it") }
        assertFalse(first.claims.getValue(0).take())
        r.setFeatureEnabled(false); r.setFeatureEnabled(true)
        events += "offer:${offer(r).envelope.payload["actionsEpoch"]}"
        assertEquals(listOf("state:\"disabled\"", "state:\"enabled\""), events.take(2))
        assertEquals(1, r.liveSetCount())
    }
}
