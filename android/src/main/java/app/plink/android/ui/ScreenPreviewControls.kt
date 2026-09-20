package app.plink.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import app.plink.android.screen.ScreenPreviewPhase
import app.plink.android.screen.ScreenPreviewUiState

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun ScreenPreviewControls(
    state: ScreenPreviewUiState,
    onBeginConsent: (String) -> Unit,
    onStop: () -> Unit,
    modifier: Modifier = Modifier
) {
    val peerName = state.peerName ?: "your Mac"
    val title = when (state.phase) {
        ScreenPreviewPhase.AWAITING_CONSENT -> "Screen sharing requested"
        ScreenPreviewPhase.STARTING -> "Starting screen preview"
        ScreenPreviewPhase.CAPTURING -> "Screen preview active"
        ScreenPreviewPhase.STOPPING -> "Stopping screen preview"
        ScreenPreviewPhase.UNAVAILABLE -> "Screen preview unavailable"
        ScreenPreviewPhase.ERROR -> "Screen preview stopped"
        ScreenPreviewPhase.IDLE -> "Screen preview"
    }
    val detail = when (state.phase) {
        ScreenPreviewPhase.AWAITING_CONSENT ->
            "$peerName requested a view-only preview. Review Android’s sharing prompt before you start."
        ScreenPreviewPhase.STARTING ->
            "Starting a view-only preview for $peerName. No recording, controls, or audio."
        ScreenPreviewPhase.CAPTURING ->
            "Sharing a view-only preview with $peerName. No recording, controls, or audio."
        ScreenPreviewPhase.STOPPING -> state.message ?: "Releasing the screen preview."
        ScreenPreviewPhase.UNAVAILABLE ->
            state.message ?: "Screen preview requires Android 14 or later."
        ScreenPreviewPhase.ERROR -> state.message ?: "Screen preview is no longer active."
        ScreenPreviewPhase.IDLE ->
            "A paired Mac can request a view-only preview. Android 14 or later."
    }
    val requestId = state.requestId
    val canShare = state.phase == ScreenPreviewPhase.AWAITING_CONSENT && requestId != null
    val canStop = state.phase == ScreenPreviewPhase.AWAITING_CONSENT ||
        state.phase == ScreenPreviewPhase.STARTING ||
        state.phase == ScreenPreviewPhase.CAPTURING

    Card(
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.primaryContainer),
        shape = MaterialTheme.shapes.large,
        modifier = modifier.fillMaxWidth()
    ) {
        Column(
            modifier = Modifier.padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.Top,
                horizontalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                Icon(LucideIcons.Devices, contentDescription = null)
                Text(
                    title,
                    style = MaterialTheme.typography.titleLarge,
                    modifier = Modifier.weight(1f)
                )
            }
            Text(detail, style = MaterialTheme.typography.bodyLarge)
            if (canShare || canStop) {
                FlowRow(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    if (canShare) {
                        requestId?.let { safeRequestId ->
                            FilledTonalButton(
                                onClick = { onBeginConsent(safeRequestId) },
                                modifier = Modifier.heightIn(min = 48.dp)
                            ) {
                                Text("Share screen")
                            }
                        }
                    }
                    if (canStop) {
                        OutlinedButton(
                            onClick = onStop,
                            modifier = Modifier.heightIn(min = 48.dp)
                        ) {
                            Text(if (state.phase == ScreenPreviewPhase.AWAITING_CONSENT) "Decline" else "Stop")
                        }
                    }
                }
            }
        }
    }
}
