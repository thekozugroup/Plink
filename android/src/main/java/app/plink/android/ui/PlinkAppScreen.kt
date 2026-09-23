/*
 * Copyright (c) 2025-2026 Nishant Mishra
 *
 * This file is adapted from Tomato - a minimalist pomodoro timer for Android.
 *
 * Tomato is free software: you can redistribute it and/or modify it under the terms of the GNU
 * General Public License as published by the Free Software Foundation, either version 3 of the
 * License, or (at your option) any later version.
 *
 * Tomato is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even
 * the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General
 * Public License for more details.
 *
 * You should have received a copy of the GNU General Public License along with Tomato.
 * If not, see <https://www.gnu.org/licenses/>.
 */

package app.plink.android.ui

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.MaterialTheme.motionScheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import app.plink.android.clipboard.ClipboardSyncState
import app.plink.android.continuity.FileTransferState
import app.plink.android.features.ContinuityFeature
import app.plink.android.features.FeatureAvailability
import app.plink.android.permissions.PermissionAction
import app.plink.android.permissions.PermissionOnboardingStep
import app.plink.android.services.BackgroundConnectionState
import app.plink.android.services.SessionStatus
import app.plink.android.reconnect.ReconnectState
import app.plink.android.ui.theme.PlinkShapeDefaults
import app.plink.android.ui.theme.plinkTopBarTitleStyle

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun PlinkAppScreen(
    state: PlinkUiState,
    actions: PlinkUiActions,
    reconnectState: ReconnectState,
    reconnectAvailable: Boolean,
    onCancelReconnect: () -> Unit,
    modifier: Modifier = Modifier
) {
    var destination by remember { mutableStateOf(PlinkDestination.Connection) }
    val motionScheme = MaterialTheme.motionScheme
    val displayState = state.copy(
        sessionStatus = when {
            state.sessionStatus == SessionStatus.REPAIR_REQUIRED -> SessionStatus.REPAIR_REQUIRED
            reconnectState is ReconnectState.ConnectedInternetUnverified -> SessionStatus.READY
            state.sessionStatus == SessionStatus.DISCONNECTED && reconnectAvailable ->
                SessionStatus.AWAITING_RECONNECT
            else -> state.sessionStatus
        }
    )

    Scaffold(
        modifier = modifier.fillMaxSize(),
        bottomBar = {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .navigationBarsPadding()
                    .padding(start = 12.dp, end = 12.dp, bottom = 12.dp),
                contentAlignment = Alignment.Center
            ) {
                FloatingNavigation(destination, { destination = it })
            }
        }
    ) { padding ->
        AnimatedContent(
            targetState = destination,
            transitionSpec = {
                fadeIn(motionScheme.defaultEffectsSpec()) togetherWith
                    fadeOut(motionScheme.defaultEffectsSpec())
            },
            label = "Plink destination",
            modifier = Modifier.fillMaxSize()
        ) { screen ->
            when (screen) {
                PlinkDestination.Connection -> ConnectionScreen(
                    displayState,
                    actions,
                    reconnectState,
                    reconnectAvailable,
                    onCancelReconnect,
                    padding
                )
                PlinkDestination.Activity -> ActivityScreen(displayState, reconnectAvailable, padding)
                PlinkDestination.Settings -> SettingsScreen(state, actions, padding)
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ConnectionScreen(
    state: PlinkUiState,
    actions: PlinkUiActions,
    reconnectState: ReconnectState,
    reconnectAvailable: Boolean,
    onCancelReconnect: () -> Unit,
    contentPadding: PaddingValues
) {
    val screenEnabled = state.features.any {
        it.feature == ContinuityFeature.ScreenMirror && it.enabled && it.available
    }
    ScreenScaffold("Plink", "Pixel + Mac continuity", contentPadding) { innerPadding ->
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = innerPadding,
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            item { ConnectionRing(state.sessionStatus) }
            if (screenEnabled) {
                item(key = "screenPreview") {
                    Box(Modifier.widthIn(max = PlinkShapeDefaults.paneMaxWidth).padding(horizontal = 16.dp)) {
                        ScreenPreviewControls(
                            state.screenPreviewState,
                            actions.onBeginScreenConsent,
                            actions.onStopScreenPreview
                        )
                    }
                }
            }
            if (reconnectAvailable) {
                item {
                    Box(Modifier.widthIn(max = PlinkShapeDefaults.paneMaxWidth).padding(horizontal = 16.dp)) {
                        ReconnectControls(reconnectState, onCancelReconnect)
                    }
                }
            }
            item {
                Text(
                    when (state.sessionStatus) {
                        SessionStatus.READY -> "Your Pixel and Mac are connected."
                        SessionStatus.AWAITING_RECONNECT ->
                            "Your Mac is paired. Waiting to connect."
                        SessionStatus.REPAIR_REQUIRED -> "Pair your Mac again to continue."
                        SessionStatus.DISCONNECTED -> if (reconnectAvailable) {
                            "Your Mac is paired. Waiting to connect."
                        } else {
                            "Select a nearby Mac and confirm the same code on both devices."
                        }
                    },
                    style = MaterialTheme.typography.bodyLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.widthIn(max = 420.dp).padding(horizontal = 24.dp)
                )
            }
            item {
                Box(Modifier.widthIn(max = PlinkShapeDefaults.paneMaxWidth).padding(horizontal = 16.dp)) {
                    ManualPairingCard()
                }
            }
            item {
                PermissionsGroup(state.onboarding, actions, Modifier.padding(horizontal = 16.dp))
            }
            item { Spacer(Modifier.height(4.dp)) }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ActivityScreen(state: PlinkUiState, reconnectAvailable: Boolean, contentPadding: PaddingValues) {
    ScreenScaffold("Activity", "Current status", contentPadding) { innerPadding ->
        val visibleFeatures = state.features.filterNot {
            it.feature == ContinuityFeature.Sms || it.feature == ContinuityFeature.Clipboard
        }
        val enabled = visibleFeatures.count { it.enabled && it.available } +
            if (state.clipboardSyncEnabled &&
                (state.clipboardSyncState.canSend || state.clipboardSyncState.canReceive)
            ) 1 else 0
        val blocked = visibleFeatures.count { !it.available } +
            if (state.clipboardSyncState.needsPermission) 1 else 0
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = innerPadding,
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            item {
                SummaryCard(
                    title = when (state.sessionStatus) {
                        SessionStatus.READY -> "Connected"
                        SessionStatus.AWAITING_RECONNECT -> "Paired"
                        SessionStatus.REPAIR_REQUIRED -> "Pair again"
                        SessionStatus.DISCONNECTED -> if (reconnectAvailable) "Paired" else "Not paired"
                    },
                    detail = when (state.sessionStatus) {
                        SessionStatus.READY -> "Your Pixel and Mac are connected."
                        SessionStatus.AWAITING_RECONNECT ->
                            "Waiting to connect to your Mac."
                        SessionStatus.REPAIR_REQUIRED -> "Pair your Mac again to continue."
                        SessionStatus.DISCONNECTED -> if (reconnectAvailable) {
                            "Waiting to connect to your Mac."
                        } else {
                            "Pair a Mac from the Connection tab."
                        }
                    },
                    icon = LucideIcons.Devices,
                    container = MaterialTheme.colorScheme.primaryContainer
                )
            }
            item {
                SummaryCard(
                    title = "$enabled features on",
                    detail = if (blocked == 0) "All listed features are available." else "$blocked features need setup.",
                    icon = LucideIcons.Tune,
                    container = MaterialTheme.colorScheme.secondaryContainer
                )
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SettingsScreen(
    state: PlinkUiState,
    actions: PlinkUiActions,
    contentPadding: PaddingValues
) {
    val visibleFeatures = state.features.filterNot {
        it.feature == ContinuityFeature.Sms || it.feature == ContinuityFeature.Clipboard
    }
    ScreenScaffold(
        title = "Settings",
        subtitle = "Continuity controls",
        outerPadding = contentPadding,
        containerColor = MaterialTheme.colorScheme.surfaceContainer
    ) { innerPadding ->
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = innerPadding,
            verticalArrangement = Arrangement.spacedBy(2.dp)
        ) {
            item { SectionTitle("Connection") }
            item {
                BackgroundConnectionSettingRow(
                    enabled = state.backgroundConnectionEnabled,
                    state = state.backgroundConnectionState,
                    onChange = actions.onBackgroundConnectionEnabledChange
                )
            }
            item { Spacer(Modifier.height(14.dp)) }
            item { SectionTitle("Integrations") }
            item {
                ClipboardSyncSettingRow(
                    enabled = state.clipboardSyncEnabled,
                    state = state.clipboardSyncState,
                    onChange = actions.onClipboardSyncEnabledChange,
                    onSetUp = actions.onSetUpClipboardSync
                )
            }
            itemsIndexed(visibleFeatures, key = { _, feature -> feature.feature.name }) { index, feature ->
                FeatureSettingRow(
                    feature = feature,
                    index = index,
                    count = visibleFeatures.size,
                    onChange = { actions.onFeatureEnabledChange(feature.feature, it) }
                )
            }
            item { Spacer(Modifier.height(14.dp)) }
            item { SectionTitle("File transfer") }
            item { FileTransferCard(state.fileTransferState, actions.onCancelFileTransfer) }
            item { Spacer(Modifier.height(14.dp)) }
            item { SectionTitle("Permissions") }
            itemsIndexed(state.onboarding, key = { _, step -> step.title }) { index, step ->
                PermissionSettingRow(
                    step = step,
                    index = index,
                    count = state.onboarding.size,
                    onClick = {
                        if (step.action == PermissionAction.RequestPostNotifications) {
                            actions.onRequestPostNotifications()
                        } else {
                            actions.onOpenPermissionSettings(step.action)
                        }
                    }
                )
            }
            item {
                FilledTonalButton(
                    onClick = actions.onRefreshPermissions,
                    modifier = Modifier.padding(top = 12.dp).heightIn(min = 48.dp)
                ) {
                    Icon(LucideIcons.Refresh, contentDescription = null)
                    Text("Refresh permissions", modifier = Modifier.padding(start = 8.dp))
                }
            }
        }
    }
}

@Composable
private fun ClipboardSyncSettingRow(
    enabled: Boolean,
    state: ClipboardSyncState,
    onChange: (Boolean) -> Unit,
    onSetUp: () -> Unit
) {
    Surface(
        shape = MaterialTheme.shapes.large,
        color = if (enabled) MaterialTheme.colorScheme.primaryContainer else MaterialTheme.colorScheme.surfaceBright,
        modifier = Modifier.fillMaxWidth().heightIn(min = 76.dp)
    ) {
        Column(
            modifier = Modifier.padding(horizontal = 18.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(14.dp)
            ) {
                Icon(
                    LucideIcons.ContentCopy,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary
                )
                Column(Modifier.weight(1f)) {
                    Text("Clipboard sync", style = MaterialTheme.typography.titleMedium)
                    Text(
                        if (!enabled && state == ClipboardSyncState())
                            "Copy text on either device to paste on the other. Requires Shizuku on your phone."
                        else state.message,
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                Switch(
                    checked = enabled,
                    onCheckedChange = onChange,
                    modifier = Modifier.semantics { contentDescription = "Clipboard sync" }
                )
            }
            if (state.needsPermission) {
                FilledTonalButton(onClick = onSetUp, modifier = Modifier.heightIn(min = 48.dp)) {
                    Text("Set Up Clipboard Sync")
                }
            }
        }
    }
}

@Composable
private fun FileTransferCard(state: FileTransferState, onCancel: () -> Unit) {
    val title: String
    val detail: String
    val canCancel: Boolean
    when (state) {
        FileTransferState.Idle -> {
            title = "No active file transfer"
            detail = "Files appear here while Plink sends or receives them."
            canCancel = false
        }
        is FileTransferState.Preparing -> {
            title = "Preparing ${state.name}"
            detail = "Plink is getting the file ready."
            canCancel = true
        }
        is FileTransferState.Offered -> {
            title = "Waiting for your Mac"
            detail = "${state.name} (${formatBytes(state.sizeBytes)}) is ready to send."
            canCancel = true
        }
        is FileTransferState.AwaitingDestination -> {
            title = "Choose where to save ${state.offer.name}"
            detail = "Use the file notification to select a destination for ${formatBytes(state.offer.sizeBytes)}."
            canCancel = true
        }
        is FileTransferState.Transferring -> {
            val percent = if (state.totalBytes == 0L) 100 else
                ((state.completedBytes * 100) / state.totalBytes).coerceIn(0, 100)
            title = "Transferring ${state.name}"
            detail = "${formatBytes(state.completedBytes)} of ${formatBytes(state.totalBytes)} ($percent%)."
            canCancel = true
        }
        is FileTransferState.Verifying -> {
            title = "Saving ${state.name}"
            detail = "Plink is checking that the file was saved."
            canCancel = true
        }
        is FileTransferState.Saved -> {
            title = "Saved ${state.name}"
            detail = "The file was saved successfully."
            canCancel = false
        }
        is FileTransferState.OutcomeUnconfirmed -> {
            title = "Save confirmation unavailable"
            detail = "${state.name} was sent, but Plink did not receive final save confirmation."
            canCancel = false
        }
        is FileTransferState.Failed -> {
            title = state.name?.let { "Could not transfer $it" } ?: "File transfer failed"
            detail = if (state.cleanupNeeded) {
                "${fileFailureDetail(state.reason)} Remove the empty or partial document from the selected location."
            } else {
                fileFailureDetail(state.reason)
            }
            canCancel = false
        }
    }

    Card(
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerHigh),
        shape = MaterialTheme.shapes.large,
        modifier = Modifier.fillMaxWidth()
    ) {
        Column(
            modifier = Modifier.padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            Text(title, style = MaterialTheme.typography.titleMedium)
            Text(detail, style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (canCancel) {
                FilledTonalButton(onClick = onCancel, modifier = Modifier.heightIn(min = 48.dp)) {
                    Text("Cancel transfer")
                }
            }
        }
    }
}

private fun formatBytes(bytes: Long): String = when {
    bytes < 1_024 -> "$bytes B"
    bytes < 1_048_576 -> "${bytes / 1_024} KiB"
    else -> "${bytes / 1_048_576} MiB"
}

private fun fileFailureDetail(reason: String): String = when (reason) {
    "busy" -> "Another file transfer is active."
    "cancelled" -> "The file transfer was cancelled."
    "disconnected" -> "The connection ended before the transfer finished."
    "invalid" -> "The file could not be verified."
    "receive_unavailable" -> "The other device could not receive the file."
    "storage" -> "The selected file or destination could not be read or written."
    "timeout" -> "The file transfer timed out."
    "too_large" -> "Files must be 16 MiB or smaller."
    else -> "The file transfer failed."
}

@Composable
private fun BackgroundConnectionSettingRow(
    enabled: Boolean,
    state: BackgroundConnectionState,
    onChange: (Boolean) -> Unit
) {
    val summary = when (state) {
        BackgroundConnectionState.Disabled -> "Keep continuity available while Plink is closed."
        BackgroundConnectionState.Starting -> "Starting background connection…"
        BackgroundConnectionState.Running -> "Active in the background."
        BackgroundConnectionState.AwaitingReconnect -> "Paired. Waiting to connect to your Mac."
        is BackgroundConnectionState.RePairRequired ->
            "Pair again to enable updated security. Your previous pairing record is preserved."
        is BackgroundConnectionState.ActionRequired -> state.message
        is BackgroundConnectionState.Failed -> state.message
    }
    val problem = state is BackgroundConnectionState.RePairRequired ||
        state is BackgroundConnectionState.ActionRequired ||
        state is BackgroundConnectionState.Failed
    Surface(
        shape = MaterialTheme.shapes.large,
        color = if (problem) MaterialTheme.colorScheme.errorContainer else MaterialTheme.colorScheme.surfaceContainer,
        modifier = Modifier.fillMaxWidth().heightIn(min = 76.dp)
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 18.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(14.dp)
        ) {
            Icon(LucideIcons.Devices, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
            Column(Modifier.weight(1f)) {
                Text("Background connection", style = MaterialTheme.typography.titleMedium)
                Text(
                    summary,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            Switch(checked = enabled, onCheckedChange = onChange)
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ScreenScaffold(
    title: String,
    subtitle: String,
    outerPadding: PaddingValues,
    containerColor: Color = MaterialTheme.colorScheme.background,
    content: @Composable (PaddingValues) -> Unit
) {
    val titleStyle = plinkTopBarTitleStyle()

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.fillMaxWidth()) {
                        Text(title, style = titleStyle)
                        Text(subtitle, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = Color.Transparent)
            )
        },
        containerColor = containerColor
    ) { inner ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(top = inner.calculateTopPadding())
                .clipToBounds()
        ) {
            content(
                PaddingValues(
                    start = 16.dp,
                    top = 8.dp,
                    end = 16.dp,
                    bottom = outerPadding.calculateBottomPadding() + 16.dp
                )
            )
        }
    }
}

@Composable
private fun PermissionsGroup(
    onboarding: List<PermissionOnboardingStep>,
    actions: PlinkUiActions,
    modifier: Modifier = Modifier
) {
    Column(modifier.widthIn(max = PlinkShapeDefaults.paneMaxWidth), verticalArrangement = Arrangement.spacedBy(2.dp)) {
        SectionTitle("Device access")
        onboarding.forEachIndexed { index, step ->
            PermissionSettingRow(
                step,
                index,
                onboarding.size,
                onClick = {
                    if (step.action == PermissionAction.RequestPostNotifications) {
                        actions.onRequestPostNotifications()
                    } else {
                        actions.onOpenPermissionSettings(step.action)
                    }
                }
            )
        }
    }
}

@Composable
private fun FeatureSettingRow(
    feature: FeatureAvailability,
    index: Int,
    count: Int,
    onChange: (Boolean) -> Unit
) {
    val checked = feature.enabled && feature.available
    Surface(
        onClick = { onChange(!checked) },
        enabled = feature.available,
        shape = PlinkShapeDefaults.groupedItem(index, count),
        color = if (checked) MaterialTheme.colorScheme.primaryContainer else MaterialTheme.colorScheme.surfaceBright,
        modifier = Modifier.fillMaxWidth().heightIn(min = 76.dp)
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 18.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(14.dp)
        ) {
            Icon(feature.feature.icon(), contentDescription = null, tint = MaterialTheme.colorScheme.primary)
            Column(Modifier.weight(1f)) {
                Text(feature.feature.label(), style = MaterialTheme.typography.titleMedium)
                Text(
                    feature.reason ?: if (checked) "On" else "Off",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            Switch(checked = checked, enabled = feature.available, onCheckedChange = null)
        }
    }
}

@Composable
private fun PermissionSettingRow(
    step: PermissionOnboardingStep,
    index: Int,
    count: Int,
    onClick: () -> Unit
) {
    Surface(
        onClick = onClick,
        enabled = step.enabled,
        shape = PlinkShapeDefaults.groupedItem(index, count),
        color = if (step.completed) MaterialTheme.colorScheme.tertiaryContainer else MaterialTheme.colorScheme.surfaceContainer,
        modifier = Modifier.fillMaxWidth().heightIn(min = 76.dp)
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 18.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(14.dp)
        ) {
            Icon(
                if (step.completed) LucideIcons.CheckCircle else LucideIcons.Notifications,
                contentDescription = null,
                tint = if (step.completed) MaterialTheme.colorScheme.tertiary else MaterialTheme.colorScheme.primary
            )
            Column(Modifier.weight(1f)) {
                Text(step.title, style = MaterialTheme.typography.titleMedium)
                Text(
                    step.summary,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            Icon(if (step.completed) LucideIcons.CheckCircle else LucideIcons.Settings, contentDescription = null)
        }
    }
}

@Composable
private fun SummaryCard(title: String, detail: String, icon: ImageVector, container: Color) {
    Card(
        colors = CardDefaults.cardColors(containerColor = container),
        shape = MaterialTheme.shapes.large,
        modifier = Modifier.fillMaxWidth()
    ) {
        Row(
            modifier = Modifier.padding(20.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            Icon(icon, contentDescription = null, modifier = Modifier.size(36.dp))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(title, style = MaterialTheme.typography.titleLarge)
                Text(detail, style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

@Composable
private fun SectionTitle(title: String) {
    Text(
        title,
        style = MaterialTheme.typography.titleLarge,
        modifier = Modifier.fillMaxWidth().padding(start = 4.dp, top = 8.dp, bottom = 8.dp)
    )
}

private fun ContinuityFeature.label(): String = when (this) {
    ContinuityFeature.Calls -> "Calls"
    ContinuityFeature.Messages -> "Messages"
    ContinuityFeature.Clipboard -> "Clipboard"
    ContinuityFeature.Files -> "Files"
    ContinuityFeature.Web -> "Web links"
    ContinuityFeature.Battery -> "Battery"
    ContinuityFeature.Media -> "Media"
    ContinuityFeature.Sms -> "SMS"
    ContinuityFeature.ScreenMirror -> "Screen preview"
}

private fun ContinuityFeature.icon(): ImageVector = when (this) {
    ContinuityFeature.Calls -> LucideIcons.Phone
    ContinuityFeature.Messages, ContinuityFeature.Sms -> LucideIcons.Message
    ContinuityFeature.Clipboard -> LucideIcons.ContentCopy
    ContinuityFeature.Files -> LucideIcons.Folder
    ContinuityFeature.Web -> LucideIcons.Link
    ContinuityFeature.Battery -> LucideIcons.BatteryCharging
    ContinuityFeature.Media -> LucideIcons.MusicNote
    ContinuityFeature.ScreenMirror -> LucideIcons.Devices
}
