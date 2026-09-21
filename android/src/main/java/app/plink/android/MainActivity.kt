package app.plink.android

import android.Manifest
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import app.plink.android.features.FeaturePolicy
import app.plink.android.permissions.AndroidPermissionReader
import app.plink.android.permissions.PermissionAction
import app.plink.android.permissions.PermissionOnboarding
import app.plink.android.ui.PlinkAppScreen
import app.plink.android.ui.PlinkUiActions
import app.plink.android.ui.PlinkUiState
import app.plink.android.ui.theme.PlinkTheme

class MainActivity : ComponentActivity() {
    /** Bind the clipboard setup button to this explicit user action. */
    fun requestClipboardSyncSetup() {
        (application as PlinkApplication).clipboardSync.requestShizukuPermission()
    }

    override fun onResume() {
        super.onResume()
        (application as PlinkApplication).clipboardSync.refresh()
    }

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

@Composable
fun PlinkApp(
    onRequestPostNotifications: () -> Unit = {}
) {
    val context = LocalContext.current
    val application = context.applicationContext as PlinkApplication
    val sessionStatus by application.sessionController.status.collectAsState()
    val fileTransferState by application.sessionController.fileTransferState.collectAsState()
    val featureSettings by application.featureSettings.enabled.collectAsState()
    val clipboardSyncEnabled by application.featureSettings.clipboardSyncEnabled.collectAsState()
    val clipboardSyncState by application.clipboardSync.state.collectAsState()
    val backgroundConnectionEnabled by application.featureSettings.backgroundConnectionEnabled.collectAsState()
    val backgroundConnectionState by application.backgroundConnectionState.collectAsState()
    val reconnectState by application.sessionController.reconnectState.collectAsState()
    val reconnectAvailable by application.sessionController.reconnectAvailable.collectAsState()
    var permissions by remember { mutableStateOf(AndroidPermissionReader.read(context)) }
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner, context) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) {
                permissions = AndroidPermissionReader.read(context)
                application.sessionController.refreshReconnectAddresses()
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }
    val features = remember(permissions, featureSettings) {
        FeaturePolicy.evaluate(permissions, application.featureSettings)
    }
    val onboarding = remember(permissions) { PermissionOnboarding.steps(permissions) }

    PlinkTheme {
        Surface(modifier = Modifier.fillMaxSize()) {
            PlinkAppScreen(
                state = PlinkUiState(
                    sessionStatus = sessionStatus,
                    features = features,
                    onboarding = onboarding,
                    backgroundConnectionEnabled = backgroundConnectionEnabled,
                    backgroundConnectionState = backgroundConnectionState,
                    fileTransferState = fileTransferState,
                    clipboardSyncEnabled = clipboardSyncEnabled,
                    clipboardSyncState = clipboardSyncState
                ),
                actions = PlinkUiActions(
                    onRequestPostNotifications = onRequestPostNotifications,
                    onRefreshPermissions = { permissions = AndroidPermissionReader.read(context) },
                    onOpenPermissionSettings = { action: PermissionAction ->
                        context.startActivity(AndroidPermissionReader.settingsIntent(action))
                    },
                    onFeatureEnabledChange = application.featureSettings::setEnabled,
                    onBackgroundConnectionEnabledChange = { enabled ->
                        application.requestBackgroundConnection(enabled)
                    },
                    onCancelFileTransfer = application.sessionController::cancelFileTransfer,
                    onClipboardSyncEnabledChange = application.clipboardSync::setEnabled,
                    onSetUpClipboardSync = application.clipboardSync::requestShizukuPermission
                ),
                reconnectState = reconnectState,
                reconnectAvailable = reconnectAvailable,
                onCancelReconnect = { application.sessionController.cancelReconnect() }
            )
        }
    }
}
