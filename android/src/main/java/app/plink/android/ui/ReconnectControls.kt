package app.plink.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import app.plink.android.reconnect.ReconnectState

@Composable
fun ReconnectControls(
    state: ReconnectState,
    onCancel: () -> Unit,
    modifier: Modifier = Modifier
) {
    val title = when (state) {
        is ReconnectState.Idle -> "Wi-Fi waiting"
        is ReconnectState.Reconnecting -> "Connecting"
        is ReconnectState.Disconnecting -> "Switching connections"
        is ReconnectState.ConnectedInternetUnverified -> "Wi-Fi linked"
        is ReconnectState.Failed -> "Couldn’t connect"
        is ReconnectState.Cancelled -> "Connection cancelled"
    }
    val detail = when (state) {
        is ReconnectState.Idle -> "Waiting to connect. Open Plink on your Mac."
        is ReconnectState.Reconnecting -> "Connecting to your paired Mac."
        is ReconnectState.Disconnecting -> "Finishing the previous connection."
        is ReconnectState.ConnectedInternetUnverified -> "Your Pixel and Mac are connected."
        is ReconnectState.Failed -> when (state.reason.wireName) {
            "unavailable_network_or_permission" ->
                "This network cannot connect your devices. Try the same Wi-Fi network on both."
            "unsupported_endpoint" -> "Keep both devices on the same Wi-Fi network and try again."
            "timeout_or_incompatible_peer" ->
                "Your Mac did not respond. Check its connection and try again."
            "authentication_failed" -> "The connection could not be verified. Try reconnecting."
            "storage_error" -> "The connection could not be saved. Try again."
            else -> "No local connection is available. Check both devices and try again."
        }
        is ReconnectState.Cancelled -> "Try again from your Mac."
    }
    val canCancel = state is ReconnectState.Reconnecting || state is ReconnectState.Disconnecting

    Card(
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerHigh),
        shape = MaterialTheme.shapes.large,
        modifier = modifier.fillMaxWidth()
    ) {
        Column(
            modifier = Modifier.padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            Text(title, style = MaterialTheme.typography.titleMedium)
            Text(detail, style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (canCancel) {
                FilledTonalButton(onClick = onCancel, modifier = Modifier.heightIn(min = 48.dp)) {
                    Text("Cancel")
                }
            }
        }
    }
}
