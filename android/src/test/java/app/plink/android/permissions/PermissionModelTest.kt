package app.plink.android.permissions

import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
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

    @Test
    fun onboardingDoesNotPromptForFutureSmsModeByDefault() {
        assertFalse(PermissionOnboarding.steps(PermissionState())
            .any { it.action == PermissionAction.OpenDefaultSmsRole })
    }

    @Test
    fun notificationAccessStepIsActionableWhenMissing() {
        val notificationStep = PermissionOnboarding.steps(PermissionState())
            .first { it.action == PermissionAction.OpenNotificationListenerSettings }

        assertTrue(notificationStep.enabled)
        assertFalse(notificationStep.completed)
    }
}
