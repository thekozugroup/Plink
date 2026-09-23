package app.plink.android.screen

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import app.plink.android.protocol.PlinkEnvelope
import app.plink.android.protocol.PlinkEventType
import app.plink.android.protocol.ScreenPreviewPayloadPolicy
import app.plink.android.security.AuthenticatedScreenRejection
import app.plink.android.security.AuthenticatedFrameResult
import app.plink.android.services.SerializedOutboundQueue
import java.time.Instant
import java.util.UUID
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class ScreenPreviewCoordinatorWiringTest {
    private val context = object : ContextWrapper(null) {
        override fun getApplicationContext(): Context = this
    }

    @Test
    fun currentRequestAdmitsButStaleAuthenticatedRejectionCannotEndIt() = runTest {
        val session = ScreenPreviewSession("pixel", "mac", "Mac", 2)
        var current: ScreenPreviewSession? = session
        val coordinator = coordinator({ current })
        val requestId = UUID.randomUUID().toString()
        coordinator.dispatchAuthenticated(AuthenticatedFrameResult.Message(request(requestId)), 1)
        assertEquals(ScreenPreviewPhase.IDLE, coordinator.state.value.phase)

        coordinator.dispatchAuthenticated(AuthenticatedFrameResult.Message(request(requestId)), 2)
        assertEquals(ScreenPreviewPhase.AWAITING_CONSENT, coordinator.state.value.phase)
        coordinator.dispatchAuthenticated(
            AuthenticatedFrameResult.RejectedScreen(
                AuthenticatedScreenRejection("mac", "pixel", requestId, null)
            ), 1
        )
        assertEquals(ScreenPreviewPhase.AWAITING_CONSENT, coordinator.state.value.phase)
        coordinator.dispatchAuthenticated(
            AuthenticatedFrameResult.RejectedScreen(
                AuthenticatedScreenRejection("mac", "pixel", requestId, null)
            ), 2
        )
        runCurrent()
        assertEquals(ScreenPreviewPhase.IDLE, coordinator.state.value.phase)
        current = null
    }

    @Test
    fun featureOffAndPeerReplacementInvalidateExactPendingConsent() = runTest {
        var enabled = true
        var current = ScreenPreviewSession("pixel", "mac", "Mac", 1)
        var serviceStarts = 0
        val coordinator = coordinator({ current }, { enabled }) { serviceStarts++ }
        val first = UUID.randomUUID().toString()
        coordinator.handleRequest(request(first), 1)
        val firstAttempt = coordinator.beginConsent(first)?.attempt
        assertNotNull(firstAttempt)
        enabled = false
        coordinator.featureDisabled()
        runCurrent()
        coordinator.completeConsent(firstAttempt!!, Activity.RESULT_OK, Intent())
        assertEquals(ScreenPreviewPhase.IDLE, coordinator.state.value.phase)
        assertEquals(0, serviceStarts)

        enabled = true
        val second = UUID.randomUUID().toString()
        coordinator.handleRequest(request(second), 1)
        val secondAttempt = coordinator.beginConsent(second)?.attempt
        assertNotNull(secondAttempt)
        current = ScreenPreviewSession("pixel", "other-mac", "Other Mac", 2)
        coordinator.sessionChanged()
        runCurrent()
        coordinator.completeConsent(secondAttempt!!, Activity.RESULT_OK, Intent())
        assertEquals(ScreenPreviewPhase.IDLE, coordinator.state.value.phase)
        assertEquals(0, serviceStarts)
    }

    @Test
    fun deniedConsentIsTerminalAndExplicitStopRequiresAnotherRequest() = runTest {
        val session = ScreenPreviewSession("pixel", "mac", "Mac", 1)
        var serviceStarts = 0
        val coordinator = coordinator({ session }) { serviceStarts++ }
        val first = UUID.randomUUID().toString()
        coordinator.handleRequest(request(first), 1)
        val denied = coordinator.beginConsent(first)?.attempt
        assertNotNull(denied)
        coordinator.completeConsent(denied!!, Activity.RESULT_CANCELED, null)
        coordinator.completeConsent(denied, Activity.RESULT_OK, Intent())
        assertEquals(ScreenPreviewPhase.IDLE, coordinator.state.value.phase)
        assertEquals(0, serviceStarts)
        assertNull(coordinator.beginConsent(first))

        val second = UUID.randomUUID().toString()
        coordinator.handleRequest(request(second), 1)
        coordinator.stop()
        runCurrent()
        assertEquals(ScreenPreviewPhase.IDLE, coordinator.state.value.phase)
        assertNull(coordinator.beginConsent(second))
        coordinator.handleRequest(request(UUID.randomUUID().toString()), 1)
        assertEquals(ScreenPreviewPhase.AWAITING_CONSENT, coordinator.state.value.phase)
        coordinator.stop()
        runCurrent()
    }

    private fun kotlinx.coroutines.test.TestScope.coordinator(
        session: () -> ScreenPreviewSession?,
        enabled: () -> Boolean = { true },
        start: () -> Unit = {}
    ) = ScreenPreviewCoordinator(
        context = context,
        scope = this,
        monotonicMillis = { testScheduler.currentTime },
        featureEnabled = enabled,
        currentSession = session,
        sendEphemeral = { _, _, _ -> object : SerializedOutboundQueue.EphemeralHandle {
            override suspend fun await() = Unit
            override fun cancel() = Unit
        } },
        projectionStarter = ScreenProjectionStarter { _, _, _ -> start(); true },
        createConsentIntent = { Intent() },
        platformSupported = { true },
        captureAllowed = { true }
    )

    private fun request(requestId: String) = PlinkEnvelope(
        id = UUID.randomUUID().toString(),
        type = PlinkEventType.ScreenRequest,
        sentAt = Instant.now().toString(),
        sourceDeviceId = "mac",
        targetDeviceId = "pixel",
        payload = buildJsonObject {
            put("v", 1)
            put("requestId", requestId)
            put("profile", ScreenPreviewPayloadPolicy.profile)
        }
    )
}
