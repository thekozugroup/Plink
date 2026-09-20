package app.plink.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Devices
import androidx.compose.material.icons.rounded.Security
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.plink.android.pairing.DiscoveredPairingOffer
import app.plink.android.pairing.NearbyPairingDiscovery
import app.plink.android.pairing.PairingCoordinator
import java.net.Inet4Address
import java.net.NetworkInterface

@Composable
fun ManualPairingCard() {
    val context = LocalContext.current
    val coordinator = remember { PairingCoordinator(context) }
    val state by coordinator.state.collectAsState()
    val localEndpoint = remember { "${localLanAddress()}:45731" }
    var discoveredOffers by remember { mutableStateOf(emptyList<DiscoveredPairingOffer>()) }
    var discoveryStatus by remember { mutableStateOf("Nearby scan idle") }
    var scanningNearby by remember { mutableStateOf(true) }
    val discovery = remember {
        NearbyPairingDiscovery(
            context = context.applicationContext,
            onOffersChanged = { discoveredOffers = it },
            onStatusChanged = { discoveryStatus = it }
        )
    }

    DisposableEffect(discovery, coordinator) {
        discovery.start()
        onDispose {
            discovery.stop()
            coordinator.close()
        }
    }

    Card(
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerHigh),
        shape = RoundedCornerShape(32.dp)
    ) {
        Column(
            modifier = Modifier.padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp)
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Nearby pairing", style = MaterialTheme.typography.titleLarge)
                Spacer(Modifier.weight(1f))
                PairingPill(if (state.paired) "Paired" else "Secure")
            }
            Text(
                state.message,
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Row(
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                OutlinedButton(
                    onClick = {
                        if (scanningNearby) {
                            discovery.stop()
                            scanningNearby = false
                            discoveryStatus = "Scan stopped"
                        } else {
                            discoveredOffers = emptyList()
                            scanningNearby = true
                            discovery.start()
                        }
                    },
                    shape = RoundedCornerShape(22.dp),
                    modifier = Modifier.size(width = 112.dp, height = 48.dp)
                ) {
                    Icon(Icons.Rounded.Devices, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(8.dp))
                    Text(if (scanningNearby) "Stop" else "Scan")
                }
                Text(
                    discoveryStatus,
                    style = MaterialTheme.typography.bodyLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f)
                )
            }
            if (discoveredOffers.isEmpty() && state.code == null) {
                Text(
                    "No Mac found yet. Keep Plink open on both devices.",
                    style = MaterialTheme.typography.bodyLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            discoveredOffers.take(4).forEach { discovered ->
                NearbyOfferRow(discovered) {
                    coordinator.select(discovered.offer, localEndpoint)
                }
            }
            state.code?.let { code ->
                Text(
                    code.emoji.joinToString("  "),
                    style = MaterialTheme.typography.displaySmall,
                    color = MaterialTheme.colorScheme.primary
                )
                Text("Code ${code.numeric}", style = MaterialTheme.typography.titleLarge)
                Text(
                    code.labels.joinToString(" + "),
                    style = MaterialTheme.typography.bodyLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    FilledTonalButton(
                        onClick = coordinator::confirm,
                        enabled = state.canConfirm,
                        shape = RoundedCornerShape(22.dp),
                        modifier = Modifier.size(width = 128.dp, height = 48.dp)
                    ) {
                        Text("Confirm")
                    }
                    OutlinedButton(
                        onClick = coordinator::cancelAttempt,
                        shape = RoundedCornerShape(22.dp),
                        modifier = Modifier.size(width = 112.dp, height = 48.dp)
                    ) {
                        Text("Cancel")
                    }
                }
            }
        }
    }
}

@Composable
private fun NearbyOfferRow(discovered: DiscoveredPairingOffer, onUse: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(22.dp))
            .background(MaterialTheme.colorScheme.surfaceContainerHighest)
            .padding(horizontal = 14.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        Icon(Icons.Rounded.Devices, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(discovered.offer.deviceName, style = MaterialTheme.typography.titleMedium, maxLines = 1)
            Text(
                discovered.offer.endpoint,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
        }
        FilledTonalButton(
            onClick = onUse,
            shape = RoundedCornerShape(22.dp),
            modifier = Modifier.size(width = 88.dp, height = 48.dp)
        ) {
            Text("Use")
        }
    }
}

@Composable
private fun PairingPill(text: String) {
    Row(
        modifier = Modifier
            .clip(RoundedCornerShape(100.dp))
            .background(MaterialTheme.colorScheme.surface)
            .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        Icon(Icons.Rounded.Security, contentDescription = null, modifier = Modifier.size(18.dp))
        Text(text, style = MaterialTheme.typography.labelLarge)
    }
}

private fun localLanAddress(): String {
    val interfaces = NetworkInterface.getNetworkInterfaces().toList()
    return interfaces
        .flatMap { it.inetAddresses.toList() }
        .filterIsInstance<Inet4Address>()
        .firstOrNull { !it.isLoopbackAddress && !it.isLinkLocalAddress }
        ?.hostAddress
        ?: "127.0.0.1"
}
