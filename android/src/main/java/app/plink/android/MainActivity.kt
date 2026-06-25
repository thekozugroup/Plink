package app.plink.android

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.Message
import androidx.compose.material.icons.rounded.ContentCopy
import androidx.compose.material.icons.rounded.Devices
import androidx.compose.material.icons.rounded.Folder
import androidx.compose.material.icons.rounded.Link
import androidx.compose.material.icons.rounded.Phone
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.plink.android.continuity.CallRingingEvent
import app.plink.android.continuity.ClipboardUpdatedEvent
import app.plink.android.continuity.ContinuityEnvelopeFactory
import app.plink.android.continuity.MessageReceivedEvent
import app.plink.android.features.ContinuityFeature
import app.plink.android.features.FeaturePolicy
import app.plink.android.permissions.PermissionState
import app.plink.android.pairing.EmojiPairing

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent { PlinkApp() }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PlinkApp() {
    MaterialTheme(
        colorScheme = lightColorScheme(
            primary = GoogleBlue,
            secondary = GoogleGreen,
            tertiary = GoogleYellow,
            surface = GoogleSurface,
            background = GoogleSurface
        ),
        typography = MaterialTheme.typography.copy(
            headlineMedium = MaterialTheme.typography.headlineMedium.copy(
                fontFamily = FontFamily.SansSerif,
                fontWeight = FontWeight.SemiBold
            ),
            bodyLarge = MaterialTheme.typography.bodyLarge.copy(fontFamily = FontFamily.SansSerif)
        ),
        shapes = MaterialTheme.shapes.copy(
            medium = RoundedCornerShape(28.dp),
            large = RoundedCornerShape(32.dp)
        )
    ) {
        Surface(modifier = Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
            Scaffold(
                topBar = {
                    TopAppBar(
                        title = {
                            Column {
                                Text("Plink", fontWeight = FontWeight.SemiBold)
                                Text("Pixel + Mac continuity", style = MaterialTheme.typography.labelLarge)
                            }
                        }
                    )
                }
            ) { padding ->
                PlinkHome(Modifier.padding(padding))
            }
        }
    }
}

@Composable
private fun PlinkHome(modifier: Modifier = Modifier) {
    val emoji = remember { EmojiPairing.derive("pixel-demo", "mac-demo", "demo-nonce") }
    val labels = remember { EmojiPairing.labels("pixel-demo", "mac-demo", "demo-nonce") }
    val permissions = remember {
        PermissionState(
            notificationListener = true,
            notificationRuntime = true,
            phoneState = true,
            smsRole = false,
            accessibilityClipboard = false
        )
    }
    val features = remember {
        FeaturePolicy.evaluate(permissions).filter { it.feature != ContinuityFeature.Sms && it.feature != ContinuityFeature.ScreenMirror }
    }
    val simulatedEvents = remember {
        listOf(
            ContinuityEnvelopeFactory.create(
                CallRingingEvent("Alex Morgan", "+1 555 123 4567"),
                "pixel-demo",
                "mac-demo"
            ),
            ContinuityEnvelopeFactory.create(
                MessageReceivedEvent("thread-demo", "Alex Morgan", "Can you send the deck?", canReply = true),
                "pixel-demo",
                "mac-demo"
            ),
            ContinuityEnvelopeFactory.create(
                ClipboardUpdatedEvent("https://plink.local/demo"),
                "pixel-demo",
                "mac-demo"
            )
        )
    }

    LazyColumn(
        modifier = modifier.fillMaxSize(),
        contentPadding = PaddingValues(20.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp)
    ) {
        item {
            Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.primaryContainer)) {
                Column(
                    modifier = Modifier.padding(20.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    AssistChip(onClick = {}, label = { Text("Ready to pair") })
                    Text("Match this code on your Mac", style = MaterialTheme.typography.titleMedium)
                    Text("${emoji.first}  ${emoji.second}", style = MaterialTheme.typography.displayMedium)
                    Text("${labels.first} + ${labels.second}")
                    Text("Only confirm when the same emoji pair appears on both devices.")
                }
            }
        }
        item {
            Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.secondaryContainer)) {
                Column(
                    modifier = Modifier.padding(18.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    Text("Connection", fontWeight = FontWeight.SemiBold)
                    Text("Local transport ready. Events are queued until your Mac confirms pairing.")
                    AssistChip(onClick = {}, label = { Text("Encrypted session pending") })
                }
            }
        }
        items(features) { feature ->
            FeatureRow(feature)
        }
        item {
            Card {
                Column(
                    modifier = Modifier.padding(18.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    Text("Simulator", fontWeight = FontWeight.SemiBold)
                    simulatedEvents.forEach { envelope ->
                        Text(
                            "${envelope.type} → ${envelope.targetDeviceId}",
                            style = MaterialTheme.typography.bodyMedium
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun FeatureRow(feature: app.plink.android.features.FeatureAvailability) {
    var enabled by remember { mutableStateOf(feature.enabled) }
    Card {
        androidx.compose.foundation.layout.Row(
            modifier = Modifier.padding(18.dp),
            horizontalArrangement = Arrangement.spacedBy(16.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(
                iconFor(feature.feature),
                contentDescription = null,
                modifier = Modifier.size(28.dp),
                tint = MaterialTheme.colorScheme.primary
            )
            Column(modifier = Modifier.weight(1f)) {
                Text(feature.feature.name, fontWeight = FontWeight.SemiBold)
                Text(
                    feature.reason ?: if (feature.available) "Available for paired Macs" else "Unavailable",
                    style = MaterialTheme.typography.bodyMedium,
                    modifier = Modifier.widthIn(max = 260.dp)
                )
            }
            Switch(
                checked = enabled && feature.available,
                enabled = feature.available,
                onCheckedChange = { enabled = it }
            )
        }
    }
}

private fun iconFor(feature: ContinuityFeature): ImageVector = when (feature) {
    ContinuityFeature.Calls -> Icons.Rounded.Phone
    ContinuityFeature.Messages -> Icons.AutoMirrored.Rounded.Message
    ContinuityFeature.Clipboard -> Icons.Rounded.ContentCopy
    ContinuityFeature.Files -> Icons.Rounded.Folder
    ContinuityFeature.Web -> Icons.Rounded.Link
    ContinuityFeature.Battery -> Icons.Rounded.Devices
    ContinuityFeature.Media -> Icons.Rounded.PlayArrow
    ContinuityFeature.Sms -> Icons.AutoMirrored.Rounded.Message
    ContinuityFeature.ScreenMirror -> Icons.Rounded.Devices
}

private val GoogleBlue = androidx.compose.ui.graphics.Color(0xFF1A73E8)
private val GoogleGreen = androidx.compose.ui.graphics.Color(0xFF188038)
private val GoogleYellow = androidx.compose.ui.graphics.Color(0xFFF9AB00)
private val GoogleSurface = androidx.compose.ui.graphics.Color(0xFFF8FAF7)
