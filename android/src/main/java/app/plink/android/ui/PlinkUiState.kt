package app.plink.android.ui

import app.plink.android.clipboard.ClipboardSyncState
import app.plink.android.continuity.FileTransferState
import app.plink.android.features.ContinuityFeature
import app.plink.android.features.FeatureAvailability
import app.plink.android.permissions.PermissionAction
import app.plink.android.permissions.PermissionOnboardingStep
import app.plink.android.services.BackgroundConnectionState
import app.plink.android.services.SessionStatus
import app.plink.android.screen.ScreenPreviewUiState
import app.plink.android.screen.ScreenPreviewPhase

data class PlinkUiState(
    val sessionStatus: SessionStatus,
    val features: List<FeatureAvailability>,
    val onboarding: List<PermissionOnboardingStep>,
    val backgroundConnectionEnabled: Boolean,
    val backgroundConnectionState: BackgroundConnectionState,
    val fileTransferState: FileTransferState,
    val screenPreviewState: ScreenPreviewUiState = ScreenPreviewUiState(ScreenPreviewPhase.IDLE),
    val clipboardSyncEnabled: Boolean = false,
    val clipboardSyncState: ClipboardSyncState = ClipboardSyncState()
)

data class PlinkUiActions(
    val onRequestPostNotifications: () -> Unit,
    val onRefreshPermissions: () -> Unit,
    val onOpenPermissionSettings: (PermissionAction) -> Unit,
    val onFeatureEnabledChange: (ContinuityFeature, Boolean) -> Unit,
    val onBackgroundConnectionEnabledChange: (Boolean) -> Unit,
    val onCancelFileTransfer: () -> Unit,
    val onBeginScreenConsent: (String) -> Unit = {},
    val onStopScreenPreview: () -> Unit = {},
    val onClipboardSyncEnabledChange: (Boolean) -> Unit = {},
    val onSetUpClipboardSync: () -> Unit = {}
)
