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
    val features = remember {
        listOf(
            Feature("Calls", "Show native Mac call notifications", Icons.Rounded.Phone, true),
            Feature("Messages", "Reply from Mac notifications", Icons.AutoMirrored.Rounded.Message, true),
            Feature("Clipboard", "Share copied text and links", Icons.Rounded.ContentCopy, true),
            Feature("Files", "Send files both ways", Icons.Rounded.Folder, true),
            Feature("Web", "Open Pixel links on Mac", Icons.Rounded.Link, true),
            Feature("Media", "Mirror media state and controls", Icons.Rounded.PlayArrow, false)
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
                    Text("Only confirm when the same emoji pair appears on both devices.")
                }
            }
        }
        items(features) { feature ->
            FeatureRow(feature)
        }
    }
}

@Composable
private fun FeatureRow(feature: Feature) {
    var enabled by remember { mutableStateOf(feature.enabled) }
    Card {
        androidx.compose.foundation.layout.Row(
            modifier = Modifier.padding(18.dp),
            horizontalArrangement = Arrangement.spacedBy(16.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(
                feature.icon,
                contentDescription = null,
                modifier = Modifier.size(28.dp),
                tint = MaterialTheme.colorScheme.primary
            )
            Column(modifier = Modifier.weight(1f)) {
                Text(feature.title, fontWeight = FontWeight.SemiBold)
                Text(feature.description, style = MaterialTheme.typography.bodyMedium)
            }
            Switch(checked = enabled, onCheckedChange = { enabled = it })
        }
    }
}

private data class Feature(
    val title: String,
    val description: String,
    val icon: ImageVector,
    val enabled: Boolean
)

private val GoogleBlue = androidx.compose.ui.graphics.Color(0xFF1A73E8)
private val GoogleGreen = androidx.compose.ui.graphics.Color(0xFF188038)
private val GoogleYellow = androidx.compose.ui.graphics.Color(0xFFF9AB00)
private val GoogleSurface = androidx.compose.ui.graphics.Color(0xFFF8FAF7)
