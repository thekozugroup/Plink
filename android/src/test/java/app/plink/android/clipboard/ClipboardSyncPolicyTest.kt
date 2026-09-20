package app.plink.android.clipboard

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ClipboardSyncPolicyTest {
    private val epoch = ClipboardSyncPolicy.Epoch(7, 1)

    @Test fun enableAndReconnectEstablishBaselineWithoutSendingOldContent() {
        val policy = ClipboardSyncPolicy()
        policy.begin(epoch)
        assertNull(policy.observe(requireNotNull(policy.capture()), "old clipboard", 1))
        assertEquals("new copy", policy.observe(requireNotNull(policy.capture()), "new copy", 2))
        val old = requireNotNull(policy.capture())
        policy.begin(epoch.copy(session = 8))
        assertNull(policy.observe(old, "late previous session", 3))
        assertNull(policy.observe(requireNotNull(policy.capture()), "new copy", 2))
    }

    @Test fun offAndEnableRevisionInvalidateCapturedWork() {
        val policy = ClipboardSyncPolicy()
        policy.begin(epoch)
        val capture = requireNotNull(policy.capture())
        policy.clear()
        assertFalse(policy.isCurrent(capture))
        assertNull(policy.observe(capture, "must not send", 2))
        policy.begin(epoch.copy(enableRevision = 3))
        assertFalse(policy.isCurrent(capture))
        assertNull(policy.observe(requireNotNull(policy.capture()), "baseline after enabling", 3))
    }

    @Test fun remoteWriteInvalidatesInFlightReadAndSuppressesOnlyItsObservation() {
        val policy = ClipboardSyncPolicy()
        policy.begin(epoch)
        policy.observe(requireNotNull(policy.capture()), "baseline", 1)
        val inFlightRead = requireNotNull(policy.capture())
        policy.remoteApplied(epoch, "from Mac", "remote-1")
        assertNull(policy.observe(inFlightRead, "stale Pixel copy", 2))
        assertNull(policy.observe(requireNotNull(policy.capture()), "from Mac", 3, origin = "remote-1"))
        // A later user copy of identical text is a new clipboard revision, not a permanent hash match.
        assertEquals("from Mac", policy.observe(requireNotNull(policy.capture()), "from Mac", 4))
    }

    @Test fun newerCopyInvalidatesPendingOlderSend() {
        val policy = ClipboardSyncPolicy()
        policy.begin(epoch)
        policy.observe(requireNotNull(policy.capture()), "baseline", 1)
        policy.observe(requireNotNull(policy.capture()), "first", 2)
        val pending = requireNotNull(policy.capture())
        assertEquals("second", policy.observe(requireNotNull(policy.capture()), "second", 3))
        assertFalse(policy.isCurrent(pending))
    }

    @Test fun sensitiveTextAndUtf8LimitsAreEnforcedWithoutTrimmingUrls() {
        assertTrue(ClipboardSyncPolicy.acceptable("a".repeat(32_768)))
        assertFalse(ClipboardSyncPolicy.acceptable("a".repeat(32_769)))
        assertTrue(ClipboardSyncPolicy.acceptable("é".repeat(16_384)))
        assertFalse(ClipboardSyncPolicy.acceptable("é".repeat(16_385)))
        assertFalse(ClipboardSyncPolicy.acceptable(" \n"))
        val policy = ClipboardSyncPolicy()
        policy.begin(epoch)
        policy.observe(requireNotNull(policy.capture()), null, 1)
        assertNull(policy.observe(requireNotNull(policy.capture()), "password", 2, sensitive = true))
        assertEquals(" https://example.com \n", policy.observe(requireNotNull(policy.capture()), " https://example.com \n", 3))
    }
}
