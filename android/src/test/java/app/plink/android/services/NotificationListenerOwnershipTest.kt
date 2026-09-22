package app.plink.android.services

import app.plink.android.notifications.ReplyDispatchLock
import org.junit.Assert.*
import org.junit.Test

class NotificationListenerOwnershipTest {
    @Test fun replacementListenerSurvivesOldDisconnectAndDestroy() = ReplyDispatchLock.serialized {
        val old = Any(); val current = Any()
        try {
            SharedReplyDispatchAuthority.sessionChanged(24, true)
            SharedReplyDispatchAuthority.listenerConnected(old)
            val previous = requireNotNull(SharedReplyDispatchAuthority.capture())
            SharedReplyDispatchAuthority.listenerConnected(current)
            val replacement = requireNotNull(SharedReplyDispatchAuthority.capture())
            assertFalse(SharedReplyDispatchAuthority.isListenerOwner(old))
            assertTrue(SharedReplyDispatchAuthority.isListenerOwner(current))
            assertFalse(SharedReplyDispatchAuthority.isCurrent(previous))
            repeat(2) { // Old disconnect and old destroy are both inert.
                assertFalse(SharedReplyDispatchAuthority.listenerDisconnected(old))
                assertEquals(replacement, SharedReplyDispatchAuthority.capture())
                assertTrue(SharedReplyDispatchAuthority.isCurrent(replacement))
            }
            assertTrue(SharedReplyDispatchAuthority.listenerDisconnected(current))
            assertNull(SharedReplyDispatchAuthority.capture())
            assertFalse(SharedReplyDispatchAuthority.isListenerOwner(current))
            assertFalse(SharedReplyDispatchAuthority.listenerDisconnected(current))
        } finally {
            SharedReplyDispatchAuthority.listenerDisconnected(current)
            SharedReplyDispatchAuthority.sessionChanged(25, false)
        }
    }

    @Test fun repeatedConnectSameInstanceInvalidatesCapturedListenerGeneration() = ReplyDispatchLock.serialized {
        val owner = Any()
        try {
            SharedReplyDispatchAuthority.sessionChanged(24, true)
            SharedReplyDispatchAuthority.listenerConnected(owner)
            val first = requireNotNull(SharedReplyDispatchAuthority.capture())
            SharedReplyDispatchAuthority.listenerConnected(owner)
            val second = requireNotNull(SharedReplyDispatchAuthority.capture())
            assertTrue(second.listenerEpoch > first.listenerEpoch)
            assertFalse(SharedReplyDispatchAuthority.isCurrent(first))
            assertTrue(SharedReplyDispatchAuthority.isCurrent(second))
        } finally {
            SharedReplyDispatchAuthority.listenerDisconnected(owner)
            SharedReplyDispatchAuthority.sessionChanged(25, false)
        }
    }
}
