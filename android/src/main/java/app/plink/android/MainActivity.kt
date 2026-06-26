package app.plink.android

import android.Manifest
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.Message
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.ContentCopy
import androidx.compose.material.icons.rounded.Devices
import androidx.compose.material.icons.rounded.Folder
import androidx.compose.material.icons.rounded.Link
import androidx.compose.material.icons.rounded.Notifications
import androidx.compose.material.icons.rounded.Phone
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.Security
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material.icons.rounded.Sync
import androidx.compose.material3.AssistChip
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalInspectionMode
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.plink.android.continuity.CallRingingEvent
import app.plink.android.continuity.ClipboardUpdatedEvent
import app.plink.android.continuity.ContinuityEnvelopeFactory
import app.plink.android.continuity.MessageReceivedEvent
import app.plink.android.features.ContinuityFeature
import app.plink.android.features.FeatureAvailability
import app.plink.android.features.FeaturePolicy
import app.plink.android.pairing.PairingCrypto
import app.plink.android.pairing.PairingPayloadCodec
import app.plink.android.pairing.PairingOffer
import app.plink.android.pairing.PairingStateMachine
import app.plink.android.pairing.PairingStatus
import app.plink.android.pairing.PairingTranscript
import app.plink.android.pairing.PairingVerificationCode
import app.plink.android.pairing.DiscoveredPairingOffer
import app.plink.android.pairing.NearbyPairingDiscovery
import app.plink.android.permissions.AndroidPermissionReader
import app.plink.android.permissions.PermissionAction
import app.plink.android.permissions.PermissionOnboarding
import app.plink.android.permissions.PermissionOnboardingStep
import app.plink.android.permissions.PermissionState
import app.plink.android.protocol.PlinkEnvelope
import app.plink.android.services.PlinkSessionController
import app.plink.android.services.DiagnosticHandoff
import app.plink.android.services.DiagnosticSendResult
import app.plink.android.services.HandoffDiagnostics
import app.plink.android.storage.KeystorePairingSecretStore
import app.plink.android.storage.KeystorePairingStore
import java.net.Inet4Address
import java.net.NetworkInterface
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    private val notificationPermissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) {}

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            PlinkApp(
                onRequestPostNotifications = {
                    if (Build.VERSION.SDK_INT >= 33) {
                        notificationPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
                    }
                }
            )
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PlinkApp(onRequestPostNotifications: () -> Unit = {}) {
    val context = LocalContext.current
    val isPreview = LocalInspectionMode.current
    val dynamicColors = Build.VERSION.SDK_INT >= 31 && !isPreview
    val darkTheme = isSystemInDarkTheme()
    MaterialTheme(
        colorScheme = when {
            dynamicColors && darkTheme -> dynamicDarkColorScheme(context)
            dynamicColors -> dynamicLightColorScheme(context)
            darkTheme -> PlinkDarkColors
            else -> PlinkLightColors
        },
        typography = MaterialTheme.typography.copy(
            displaySmall = MaterialTheme.typography.displaySmall.copy(
                fontFamily = GoogleSansFlex,
                fontWeight = FontWeight.Bold
            ),
            headlineMedium = MaterialTheme.typography.headlineMedium.copy(
                fontFamily = GoogleSansFlex,
                fontWeight = FontWeight.Bold
            ),
            titleLarge = MaterialTheme.typography.titleLarge.copy(
                fontFamily = GoogleSansFlex,
                fontWeight = FontWeight.SemiBold
            ),
            titleMedium = MaterialTheme.typography.titleMedium.copy(
                fontFamily = GoogleSansFlex,
                fontWeight = FontWeight.SemiBold
            ),
            bodyLarge = MaterialTheme.typography.bodyLarge.copy(fontFamily = GoogleSansFlex),
            labelLarge = MaterialTheme.typography.labelLarge.copy(
                fontFamily = GoogleSansFlex,
                fontWeight = FontWeight.SemiBold
            )
        ),
        shapes = MaterialTheme.shapes.copy(
            extraSmall = RoundedCornerShape(10.dp),
            small = RoundedCornerShape(16.dp),
            medium = RoundedCornerShape(24.dp),
            large = RoundedCornerShape(32.dp),
            extraLarge = RoundedCornerShape(40.dp)
        )
    ) {
        Surface(modifier = Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
            Scaffold(
                topBar = {
                    TopAppBar(
                        title = {
                            Column {
                                Text("Plink", fontWeight = FontWeight.Bold)
                                Text(
                                    "Pixel + Mac continuity",
                                    style = MaterialTheme.typography.labelLarge,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                        }
                    )
                }
            ) { padding ->
                PlinkHome(
                    modifier = Modifier.padding(padding),
                    onRequestPostNotifications = onRequestPostNotifications
                )
            }
        }
    }
}

@Composable
private fun PlinkHome(
    modifier: Modifier = Modifier,
    onRequestPostNotifications: () -> Unit = {}
) {
    val context = LocalContext.current
    val previewKey = remember { PairingCrypto.generateKeyPair() }
    val verificationCode = remember(previewKey.publicKeyBase64) {
        PairingTranscript.verificationCode(
            PairingTranscript.canonical(
                sourceDeviceId = "pixel-preview",
                targetDeviceId = "mac-preview",
                endpoint = "mac.local:45731",
                nonce = "preview-nonce",
                sourcePublicKey = previewKey.publicKeyBase64,
                targetPublicKey = "mac-preview-public-key",
                protocolVersion = 1
            )
        )
    }
    var permissions by remember { mutableStateOf(AndroidPermissionReader.read(context)) }
    val features = remember(permissions) {
        FeaturePolicy.evaluate(permissions)
            .filter { it.feature != ContinuityFeature.Sms && it.feature != ContinuityFeature.ScreenMirror }
    }
    val onboarding = remember(permissions) { PermissionOnboarding.steps(permissions) }
    val simulatedEvents = remember { continuityPreviewEvents() }
    val activeFeatureCount = features.count { it.available && it.enabled }
    val setupProgress = setupProgress(permissions)

    LazyColumn(
        modifier = modifier.fillMaxSize(),
        contentPadding = PaddingValues(start = 20.dp, top = 10.dp, end = 20.dp, bottom = 28.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        item {
            PairingHeroCard(
                verificationCode = verificationCode,
                setupProgress = setupProgress,
                activeFeatureCount = activeFeatureCount
            )
        }
        item {
            ManualPairingCard()
        }
        item {
            ConnectionCard(setupProgress = setupProgress)
        }
        item {
            PermissionsCard(
                onboarding = onboarding,
                onRequestPostNotifications = onRequestPostNotifications,
                onRefresh = { permissions = AndroidPermissionReader.read(context) },
                onOpenSettings = { action ->
                    context.startActivity(AndroidPermissionReader.settingsIntent(action))
                    permissions = AndroidPermissionReader.read(context)
                }
            )
        }
        item {
            SectionHeader(title = "Continuity", label = "$activeFeatureCount active")
        }
        items(features, key = { it.feature.name }) { feature ->
            FeatureRow(feature)
        }
        item {
            SimulatorCard(simulatedEvents)
        }
    }
}

@Composable
private fun PairingHeroCard(
    verificationCode: PairingVerificationCode,
    setupProgress: Float,
    activeFeatureCount: Int
) {
    val progress by animateFloatAsState(targetValue = setupProgress, label = "setupProgress")
    Card(
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.primaryContainer),
        shape = RoundedCornerShape(40.dp),
        elevation = CardDefaults.cardElevation(defaultElevation = 0.dp)
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(22.dp),
            verticalArrangement = Arrangement.spacedBy(18.dp)
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                StatusPill("Ready to pair", Icons.Rounded.Security)
                Spacer(Modifier.weight(1f))
                StatusBubble(text = "$activeFeatureCount")
            }
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(
                    "Match on Mac",
                    style = MaterialTheme.typography.displaySmall,
                    color = MaterialTheme.colorScheme.onPrimaryContainer
                )
                Text(
                    "Confirm only when both devices show the same emoji and number.",
                    style = MaterialTheme.typography.bodyLarge,
                    color = MaterialTheme.colorScheme.onPrimaryContainer
                )
            }
            Text(
                verificationCode.emoji.joinToString("  "),
                style = MaterialTheme.typography.displaySmall,
                color = MaterialTheme.colorScheme.onPrimaryContainer
            )
            Row(
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                FilledTonalButton(
                    onClick = {},
                    shape = RoundedCornerShape(24.dp),
                    colors = ButtonDefaults.filledTonalButtonColors(
                        containerColor = MaterialTheme.colorScheme.surface,
                        contentColor = MaterialTheme.colorScheme.primary
                    )
                ) {
                    Text("Code ${verificationCode.numeric}")
                }
                Text(
                    verificationCode.labels.joinToString(" + "),
                    style = MaterialTheme.typography.labelLarge,
                    color = MaterialTheme.colorScheme.onPrimaryContainer,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f)
                )
            }
            LinearProgressIndicator(
                progress = { progress },
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(100.dp)),
                color = MaterialTheme.colorScheme.primary,
                trackColor = MaterialTheme.colorScheme.surface.copy(alpha = 0.52f)
            )
        }
    }
}

@Composable
private fun ManualPairingCard() {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val pairingMachine = remember { PairingStateMachine() }
    val sessionController = remember { PlinkSessionController(context.applicationContext) }
    val localDeviceId = remember { context.localPlinkDeviceId() }
    val localEndpoint = remember { "${localLanAddress()}:45731" }
    var offerPayload by remember { mutableStateOf("") }
    var showingCode by remember { mutableStateOf<PairingStatus.ShowingCode?>(null) }
    var responsePayload by remember { mutableStateOf("") }
    var statusText by remember { mutableStateOf("Paste the Mac offer to start real pairing.") }
    var discoveredOffers by remember { mutableStateOf(emptyList<DiscoveredPairingOffer>()) }
    var discoveryStatus by remember { mutableStateOf("Nearby scan idle") }
    var scanningNearby by remember { mutableStateOf(false) }
    val discovery = remember {
        NearbyPairingDiscovery(
            context = context.applicationContext,
            onOffersChanged = { discoveredOffers = it },
            onStatusChanged = { discoveryStatus = it }
        )
    }

    DisposableEffect(discovery) {
        onDispose { discovery.stop() }
    }

    fun importOffer(offer: PairingOffer) {
        runCatching {
            val targetedOffer = offer.copy(targetDeviceId = localDeviceId)
            offerPayload = PairingPayloadCodec.encodeOffer(targetedOffer)
            showingCode = pairingMachine.receiveOffer(targetedOffer)
            responsePayload = ""
            statusText = "Confirm only if this code matches on your Mac."
        }.onFailure { error ->
            showingCode = null
            statusText = error.localizedMessage ?: "Pairing offer could not be read."
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
                Text("Manual pairing", style = MaterialTheme.typography.titleLarge)
                Spacer(Modifier.weight(1f))
                StatusPill("Secure", Icons.Rounded.Security)
            }
            Text(
                statusText,
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
                    shape = RoundedCornerShape(22.dp)
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
            discoveredOffers.take(3).forEach { discovered ->
                NearbyOfferRow(
                    discovered = discovered,
                    onUse = { importOffer(discovered.offer) }
                )
            }
            OutlinedTextField(
                value = offerPayload,
                onValueChange = { offerPayload = it },
                modifier = Modifier.fillMaxWidth(),
                minLines = 3,
                label = { Text("Mac pairing offer") }
            )
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedButton(
                    onClick = {
                        runCatching {
                            PairingPayloadCodec.decodeOffer(offerPayload)
                        }.onFailure { error ->
                            showingCode = null
                            statusText = error.localizedMessage ?: "Pairing offer could not be read."
                        }.onSuccess { offer ->
                            importOffer(offer)
                        }
                    },
                    shape = RoundedCornerShape(22.dp),
                    enabled = offerPayload.isNotBlank()
                ) {
                    Text("Import")
                }
                FilledTonalButton(
                    onClick = {
                        scope.launch {
                            runCatching {
                                val (paired, confirmation) = pairingMachine.confirmWithResponse(
                                    localDeviceId = localDeviceId,
                                    localDeviceName = Build.MODEL,
                                    localEndpoint = localEndpoint
                                )
                                val sessionKey = pairingMachine.lastSessionKey
                                    ?: error("Pairing session key was not derived.")
                                KeystorePairingStore(context).save(paired.device)
                                KeystorePairingSecretStore(context).save(sessionKey, paired.device.sessionId)
                                sessionController.configure(
                                    localDeviceId = localDeviceId,
                                    pairedDevice = paired.device,
                                    sessionKey = sessionKey
                                )
                                PairingPayloadCodec.encodeConfirmation(confirmation)
                            }.onSuccess { response ->
                                responsePayload = response
                                context.copyToClipboard("Plink pairing response", response)
                                statusText = "Paired. Response copied for your Mac."
                            }.onFailure { error ->
                                statusText = error.localizedMessage ?: "Pairing confirmation failed."
                            }
                        }
                    },
                    shape = RoundedCornerShape(22.dp),
                    enabled = showingCode != null
                ) {
                    Text("Confirm")
                }
            }
            showingCode?.let { code ->
                Text(
                    code.verificationCode.emoji.joinToString("  "),
                    style = MaterialTheme.typography.displaySmall,
                    color = MaterialTheme.colorScheme.primary
                )
                Text(
                    "Code ${code.verificationCode.numeric}",
                    style = MaterialTheme.typography.titleLarge
                )
            }
            if (responsePayload.isNotBlank()) {
                Text(
                    responsePayload,
                    style = MaterialTheme.typography.bodyLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 4,
                    overflow = TextOverflow.Ellipsis
                )
            }
        }
    }
}

@Composable
private fun NearbyOfferRow(
    discovered: DiscoveredPairingOffer,
    onUse: () -> Unit
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(22.dp))
            .background(MaterialTheme.colorScheme.surfaceContainerHighest)
            .padding(horizontal = 14.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        ExpressiveIcon(Icons.Rounded.Devices, MaterialTheme.colorScheme.primary)
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(
                discovered.offer.deviceName,
                style = MaterialTheme.typography.titleMedium,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
            Text(
                discovered.offer.endpoint,
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
        }
        FilledTonalButton(onClick = onUse, shape = RoundedCornerShape(22.dp)) {
            Text("Use")
        }
    }
}

@Composable
private fun ConnectionCard(setupProgress: Float) {
    Card(
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.secondaryContainer),
        shape = RoundedCornerShape(32.dp)
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(20.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            ExpressiveIcon(Icons.Rounded.Sync, MaterialTheme.colorScheme.secondary)
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text("Encrypted session pending", style = MaterialTheme.typography.titleLarge)
                Text(
                    "Secure local transport uses paired-device keys and encrypted frames.",
                    style = MaterialTheme.typography.bodyLarge,
                    color = MaterialTheme.colorScheme.onSecondaryContainer
                )
            }
            StatusBubble("${(setupProgress * 100).toInt()}%")
        }
    }
}

@Composable
private fun PermissionsCard(
    onboarding: List<PermissionOnboardingStep>,
    onRequestPostNotifications: () -> Unit,
    onRefresh: () -> Unit,
    onOpenSettings: (PermissionAction) -> Unit
) {
    Card(
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerHigh),
        shape = RoundedCornerShape(32.dp)
    ) {
        Column(
            modifier = Modifier.padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp)
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Permissions", style = MaterialTheme.typography.titleLarge)
                Spacer(Modifier.weight(1f))
                OutlinedButton(
                    onClick = onRefresh,
                    shape = RoundedCornerShape(22.dp)
                ) {
                    Icon(Icons.Rounded.Refresh, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(8.dp))
                    Text("Refresh")
                }
            }
            onboarding.filter { it.enabled }.take(4).forEach { step ->
                PermissionStepRow(
                    step = step,
                    onClick = {
                        if (step.action == PermissionAction.RequestPostNotifications) {
                            onRequestPostNotifications()
                        } else {
                            onOpenSettings(step.action)
                        }
                    }
                )
            }
        }
    }
}

@Composable
private fun PermissionStepRow(step: PermissionOnboardingStep, onClick: () -> Unit) {
    val containerColor by animateColorAsState(
        targetValue = if (step.completed) {
            MaterialTheme.colorScheme.tertiaryContainer
        } else {
            MaterialTheme.colorScheme.surfaceContainerHighest
        },
        label = "permissionContainer"
    )
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(24.dp))
            .background(containerColor)
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(14.dp)
        ) {
            ExpressiveIcon(
                icon = if (step.completed) Icons.Rounded.CheckCircle else Icons.Rounded.Notifications,
                tint = if (step.completed) MaterialTheme.colorScheme.tertiary else MaterialTheme.colorScheme.primary
            )
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(step.title, style = MaterialTheme.typography.titleMedium)
                Text(
                    step.summary,
                    style = MaterialTheme.typography.bodyLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 3,
                    overflow = TextOverflow.Ellipsis
                )
            }
        }
        AssistChip(
            onClick = onClick,
            label = { Text(if (step.completed) "Done" else "Set up") },
            leadingIcon = {
                Icon(
                    if (step.completed) Icons.Rounded.CheckCircle else Icons.Rounded.Settings,
                    contentDescription = null,
                    modifier = Modifier.size(18.dp)
                )
            },
            modifier = Modifier.align(Alignment.End)
        )
    }
}

@Composable
private fun FeatureRow(feature: FeatureAvailability) {
    var enabled by remember(feature.feature, feature.enabled) { mutableStateOf(feature.enabled) }
    val effectiveEnabled = enabled && feature.available
    val containerColor by animateColorAsState(
        targetValue = if (effectiveEnabled) {
            MaterialTheme.colorScheme.primaryContainer
        } else {
            MaterialTheme.colorScheme.surfaceContainer
        },
        label = "featureContainer"
    )
    Card(
        colors = CardDefaults.cardColors(containerColor = containerColor),
        shape = RoundedCornerShape(30.dp),
        elevation = CardDefaults.cardElevation(defaultElevation = 0.dp)
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(18.dp),
            horizontalArrangement = Arrangement.spacedBy(16.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            ExpressiveIcon(iconFor(feature.feature), MaterialTheme.colorScheme.primary)
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(feature.feature.label(), style = MaterialTheme.typography.titleMedium)
                Text(
                    feature.reason ?: if (feature.available) "Available for paired Macs" else "Unavailable",
                    style = MaterialTheme.typography.bodyLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.widthIn(max = 320.dp)
                )
            }
            Switch(
                checked = effectiveEnabled,
                enabled = feature.available,
                onCheckedChange = { enabled = it }
            )
        }
    }
}

@Composable
private fun SimulatorCard(simulatedEvents: List<PlinkEnvelope>) {
    var diagnosticStatus by remember { mutableStateOf("Ready for paired diagnostics") }
    Card(
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.tertiaryContainer),
        shape = RoundedCornerShape(32.dp)
    ) {
        Column(
            modifier = Modifier.padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Preview events", style = MaterialTheme.typography.titleLarge)
                Spacer(Modifier.weight(1f))
                StatusPill("Model", Icons.Rounded.Devices)
            }
            Text(
                diagnosticStatus,
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onTertiaryContainer
            )
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                DiagnosticHandoff.entries.forEach { kind ->
                    FilledTonalButton(
                        onClick = {
                            diagnosticStatus = when (val result = HandoffDiagnostics.send(kind)) {
                                is DiagnosticSendResult.Sent -> "Sent ${result.envelope.type}"
                                DiagnosticSendResult.NotPaired -> "Pair first, then send diagnostics."
                            }
                        },
                        shape = RoundedCornerShape(22.dp)
                    ) {
                        Text(kind.label)
                    }
                }
            }
            simulatedEvents.forEach { envelope ->
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(22.dp))
                        .background(MaterialTheme.colorScheme.surface.copy(alpha = 0.58f))
                        .padding(horizontal = 14.dp, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    Icon(
                        iconForEvent(envelope.type),
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.tertiary
                    )
                    Column {
                        Text(envelope.type, style = MaterialTheme.typography.titleMedium)
                        Text(
                            "Target ${envelope.targetDeviceId}",
                            style = MaterialTheme.typography.bodyLarge,
                            color = MaterialTheme.colorScheme.onTertiaryContainer
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun SectionHeader(title: String, label: String) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = 6.dp, start = 4.dp, end = 4.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(title, style = MaterialTheme.typography.titleLarge)
        Spacer(Modifier.weight(1f))
        StatusPill(label, Icons.Rounded.CheckCircle)
    }
}

@Composable
private fun ExpressiveIcon(icon: ImageVector, tint: Color) {
    Box(
        modifier = Modifier
            .size(52.dp)
            .clip(RoundedCornerShape(18.dp))
            .background(tint.copy(alpha = 0.16f)),
        contentAlignment = Alignment.Center
    ) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(28.dp))
    }
}

@Composable
private fun StatusPill(text: String, icon: ImageVector) {
    Surface(
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.72f),
        contentColor = MaterialTheme.colorScheme.primary,
        shape = RoundedCornerShape(100.dp)
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Icon(icon, contentDescription = null, modifier = Modifier.size(18.dp))
            Text(text, style = MaterialTheme.typography.labelLarge)
        }
    }
}

@Composable
private fun StatusBubble(text: String) {
    Surface(
        modifier = Modifier.size(54.dp),
        color = MaterialTheme.colorScheme.surface,
        contentColor = MaterialTheme.colorScheme.primary,
        shape = CircleShape
    ) {
        Box(contentAlignment = Alignment.Center) {
            Text(text, style = MaterialTheme.typography.titleMedium)
        }
    }
}

private fun continuityPreviewEvents(): List<PlinkEnvelope> = listOf(
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

private fun setupProgress(permissions: PermissionState): Float {
    val completed = listOf(
        permissions.notificationRuntime,
        permissions.notificationListener,
        permissions.canAutoSyncClipboard
    ).count { it }
    return completed / 3f
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

private fun iconForEvent(eventType: String): ImageVector = when (eventType) {
    "call.ringing" -> Icons.Rounded.Phone
    "message.received" -> Icons.AutoMirrored.Rounded.Message
    "clipboard.updated" -> Icons.Rounded.ContentCopy
    else -> Icons.Rounded.Devices
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
    ContinuityFeature.ScreenMirror -> "Screen mirror"
}

private fun Context.localPlinkDeviceId(): String {
    val androidId = Settings.Secure.getString(contentResolver, Settings.Secure.ANDROID_ID).orEmpty()
    return "pixel-${androidId.ifBlank { Build.MODEL.ifBlank { "android" } }}"
}

private fun Context.copyToClipboard(label: String, text: String) {
    val clipboard = getSystemService(ClipboardManager::class.java)
    clipboard.setPrimaryClip(ClipData.newPlainText(label, text))
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

private val GoogleSansFlex = FontFamily(
    Font(R.font.google_sans_flex_400, FontWeight.Normal),
    Font(R.font.google_sans_flex_500, FontWeight.Medium),
    Font(R.font.google_sans_flex_600, FontWeight.SemiBold),
    Font(R.font.google_sans_flex_700, FontWeight.Bold)
)

private val PlinkLightColors = lightColorScheme(
    primary = Color(0xFF0B57D0),
    onPrimary = Color.White,
    primaryContainer = Color(0xFFD8E2FF),
    onPrimaryContainer = Color(0xFF001A41),
    secondary = Color(0xFF146C2E),
    onSecondary = Color.White,
    secondaryContainer = Color(0xFFC9EFCB),
    onSecondaryContainer = Color(0xFF002106),
    tertiary = Color(0xFF8A4A00),
    onTertiary = Color.White,
    tertiaryContainer = Color(0xFFFFDDB4),
    onTertiaryContainer = Color(0xFF2C1600),
    background = Color(0xFFFAF9F4),
    onBackground = Color(0xFF1B1C18),
    surface = Color(0xFFFFFBFE),
    onSurface = Color(0xFF1B1C18),
    surfaceVariant = Color(0xFFE1E2EC),
    onSurfaceVariant = Color(0xFF44474F),
    surfaceContainer = Color(0xFFF0F0EA),
    surfaceContainerHigh = Color(0xFFEAEAE4),
    surfaceContainerHighest = Color(0xFFE4E3DD)
)

private val PlinkDarkColors = darkColorScheme(
    primary = Color(0xFFADC6FF),
    primaryContainer = Color(0xFF284777),
    secondary = Color(0xFFAED4B1),
    secondaryContainer = Color(0xFF34513A),
    tertiary = Color(0xFFFFB95C),
    tertiaryContainer = Color(0xFF683700),
    background = Color(0xFF121310),
    surface = Color(0xFF1B1C18),
    surfaceVariant = Color(0xFF44474F)
)
