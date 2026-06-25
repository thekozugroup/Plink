package app.plink.android.permissions

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PermissionModelTest {
    @Test
    fun notificationListenerEnablesMessageMirroringAndReply() {
        val state = PermissionState(notificationListener = true)

        assertTrue(state.canMirrorMessages)
        assertTrue(state.canReplyToMessages)
    }

    @Test
    fun smsRoleEnablesDirectReplyWithoutMirroring() {
        val state = PermissionState(smsRole = true)

        assertFalse(state.canMirrorMessages)
        assertTrue(state.canReplyToMessages)
    }
}
