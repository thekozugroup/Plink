package app.plink.android.services

import app.plink.android.notifications.NotificationActionRegistry
import app.plink.android.notifications.NotificationActionSpec
import app.plink.android.notifications.NotificationHandoff
import app.plink.android.notifications.ReplyCapabilityGeneration
import app.plink.android.notifications.ReplyDispatchLock
import app.plink.android.protocol.PlinkEnvelope
import app.plink.android.protocol.PlinkEventType
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.*
import org.junit.Test

class NotificationHandoffPublicationTest {
    private fun message(id: String = "generic") = PlinkEnvelope(
        id = id, type = PlinkEventType.MessageReceived, sentAt = "2026-09-22T00:00:00Z",
        sourceDeviceId = "phone", targetDeviceId = "mac", payload = buildJsonObject {
            put("sender", "Synthetic"); put("preview", "Synthetic"); put("canReply", false)
            put("packageName", "fixture"); put("notificationKey", "synthetic-key")
        }
    )

    private fun handoff(callType: String = PlinkEventType.CallRinging): NotificationHandoff {
        val registry = NotificationActionRegistry { 1_790_000_000_000L }
        registry.beginSession("phone", "mac", 28)
        registry.setListenerAvailable(true); registry.setFeatureEnabled(true)
        val prior = requireNotNull(registry.offer(message(), listOf(NotificationActionSpec("Synthetic", "invoke"))))
        val retirement = requireNotNull(registry.offer(message("retirement"), emptyList(), removed = true)).envelope
        assertFalse(prior.claims.getValue(0).available())
        return NotificationHandoff(message("call").copy(type = callType), null, retirement)
    }

    private fun withOwner(block: (Any, ReplyCapabilityGeneration) -> Unit) {
        val owner = Any()
        try {
            val generation = ReplyDispatchLock.serialized {
                SharedReplyDispatchAuthority.sessionChanged(28, true)
                SharedReplyDispatchAuthority.listenerConnected(owner)
                requireNotNull(SharedReplyDispatchAuthority.capture())
            }
            block(owner, generation)
        } finally {
            ReplyDispatchLock.serialized {
                SharedReplyDispatchAuthority.listenerDisconnected(owner)
                SharedReplyDispatchAuthority.sessionChanged(29, false)
            }
        }
    }

    @Test fun versionedRetirementPrecedesBothCallPostAndRemovalUnderReplyAuthority() {
        withOwner { owner, generation ->
            for (type in listOf(PlinkEventType.CallRinging, PlinkEventType.CallEnded)) {
                val handoff = handoff(type)
                val sent = mutableListOf<PlinkEnvelope>()
                assertTrue(SharedReplyDispatchAuthority.publishHandoff(owner, generation, handoff, { true }) {
                    assertTrue(ReplyDispatchLock.heldByCurrentThread())
                    sent += it
                })
                assertEquals(listOf(handoff.retirement, handoff.envelope), sent)
            }
        }
    }

    @Test fun staleOwnerAndRepeatedAttachCannotPublishCapturedRetirement() {
        withOwner { owner, generation ->
            val handoff = handoff()
            val replacement = Any()
            try {
                ReplyDispatchLock.serialized { SharedReplyDispatchAuthority.listenerConnected(replacement) }
                assertFalse(SharedReplyDispatchAuthority.publishHandoff(owner, generation, handoff, { true }) { fail("Stale owner published") })
                ReplyDispatchLock.serialized { SharedReplyDispatchAuthority.listenerConnected(owner) }
                assertFalse(SharedReplyDispatchAuthority.publishHandoff(owner, generation, handoff, { true }) { fail("Stale epoch published") })
            } finally {
                ReplyDispatchLock.serialized { SharedReplyDispatchAuthority.listenerDisconnected(replacement) }
            }
        }
    }

    @Test fun changedOrStoppedSessionCannotPublishCapturedRetirement() {
        withOwner { owner, generation ->
            val handoff = handoff()
            for (active in listOf(true, false)) {
                ReplyDispatchLock.serialized { SharedReplyDispatchAuthority.sessionChanged(29, active) }
                assertFalse(SharedReplyDispatchAuthority.publishHandoff(owner, generation, handoff, { true }) { fail("Stale session published") })
            }
        }
    }

    @Test fun featureOffAfterMappingSuppressesBothFramesWithoutPrivacyBypass() {
        withOwner { owner, generation ->
            val handoff = handoff()
            var checks = 0
            assertFalse(SharedReplyDispatchAuthority.publishHandoff(owner, generation, handoff,
                { checks++; false }) { fail("Disabled call feature published") })
            assertEquals(1, checks)
        }
    }

    @Test fun ordinaryPreviewKeepsOfflinePublicationButRetirementRequiresCurrentAdmission() {
        withOwner { owner, _ ->
            val retirement = handoff()
            ReplyDispatchLock.serialized { SharedReplyDispatchAuthority.sessionChanged(29, false) }
            assertFalse(SharedReplyDispatchAuthority.publishHandoff(owner, null, retirement, { true }) { fail("Inactive retirement published") })
            val ordinary = NotificationHandoff(message(), null)
            val sent = mutableListOf<PlinkEnvelope>()
            assertTrue(SharedReplyDispatchAuthority.publishHandoff(owner, null, ordinary, { true }, send = { sent += it }))
            assertEquals(listOf(ordinary.envelope), sent)
        }
    }

    @Test fun retirementOnlySendsNoCallAndRechecksMessagesPrivacy() {
        withOwner { owner, generation ->
            val retired = requireNotNull(handoff().retirement)
            val cleanup = NotificationHandoff(retired, null, retirementOnly = true)
            val sent = mutableListOf<PlinkEnvelope>()
            assertTrue(SharedReplyDispatchAuthority.publishHandoff(owner, generation, cleanup,
                allowed = { true }, retirementAllowed = { true }, send = { sent += it }))
            assertEquals(listOf(retired), sent)
            assertFalse(SharedReplyDispatchAuthority.publishHandoff(owner, generation, cleanup,
                allowed = { true }, retirementAllowed = { false }) { fail("Messages Off cleanup published") })
            assertFalse(SharedReplyDispatchAuthority.publishHandoff(owner, null, cleanup,
                allowed = { true }) { fail("Cleanup without admission published") })
        }
    }

    @Test fun messagesOffBlocksRetirementWithoutEnablingOrBlockingAllowedCallFrame() {
        withOwner { owner, generation ->
            val handoff = handoff()
            val sent = mutableListOf<PlinkEnvelope>()
            assertTrue(SharedReplyDispatchAuthority.publishHandoff(owner, generation, handoff,
                allowed = { true }, retirementAllowed = { false }, send = { sent += it }))
            assertEquals(listOf(handoff.envelope), sent)
        }
    }

    @Test fun reentrantRevocationDuringRetirementBlocksFollowingCallFrame() {
        for (cause in listOf("owner", "session", "feature")) {
            withOwner { owner, generation ->
                val handoff = handoff()
                var callsEnabled = true
                val sent = mutableListOf<PlinkEnvelope>()
                val completed = SharedReplyDispatchAuthority.publishHandoff(owner, generation, handoff,
                    allowed = { callsEnabled }, retirementAllowed = { true }) { outgoing ->
                    assertTrue(ReplyDispatchLock.heldByCurrentThread())
                    sent += outgoing
                    if (outgoing === handoff.retirement) {
                        when (cause) {
                            "owner" -> SharedReplyDispatchAuthority.listenerDisconnected(owner)
                            "session" -> SharedReplyDispatchAuthority.sessionChanged(29, false)
                            "feature" -> callsEnabled = false
                        }
                    }
                }
                assertFalse("Call publication completed after reentrant $cause revocation", completed)
                assertEquals("Call frame escaped reentrant $cause revocation", listOf(handoff.retirement), sent)
            }
        }
    }
}
