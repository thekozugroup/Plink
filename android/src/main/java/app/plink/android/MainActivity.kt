package app.plink.android

import android.Manifest
import android.app.Activity
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
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.compose.LocalLifecycleOwner
import app.plink.android.features.FeaturePolicy
import app.plink.android.permissions.AndroidPermissionReader
import app.plink.android.permissions.PermissionAction
import app.plink.android.permissions.PermissionOnboarding
import app.plink.android.screen.ScreenConsentAttempt
import app.plink.android.screen.ScreenConsentLaunch
import app.plink.android.ui.PlinkAppScreen
import app.plink.android.ui.PlinkUiActions
import app.plink.android.ui.PlinkUiState
import app.plink.android.ui.theme.PlinkTheme

class MainActivity : ComponentActivity() {
    // Retain only the opaque attempt across rotation, never the OS consent Intent.
    private val screenConsentState by lazy {
        ViewModelProvider(this)[ScreenConsentState::class.java]
    }

    class ScreenConsentState : ViewModel() {
        var attempt: ScreenConsentAttempt? = null
    }

    private val notificationPermissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) {}

    private val screenConsentLauncher = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { result ->
        val attempt = screenConsentState.attempt
        screenConsentState.attempt = null
        if (attempt != null) {
            (application as PlinkApplication).sessionController.completeScreenConsent(
                attempt = attempt,
                resultCode = result.resultCode,
                data = result.data
            )
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            PlinkApp(
                onRequestPostNotifications = {
                    if (Build.VERSION.SDK_INT >= 33) {
                        notificationPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
                    }
                },
                onBeginScreenConsent = ::beginScreenConsent
            )
        }
    }

    private fun beginScreenConsent(requestId: String) {
        val controller = (application as PlinkApplication).sessionController
        val launch: ScreenConsentLaunch = controller.beginScreenConsent(requestId) ?: return
        screenConsentState.attempt = launch.attempt
        try {
            screenConsentLauncher.launch(launch.intent)
        } catch (_: RuntimeException) {
            val attempt = screenConsentState.attempt
            screenConsentState.attempt = null
            if (attempt != null) {
                controller.completeScreenConsent(attempt, Activity.RESULT_CANCELED, null)
            }
        }
    }
}

@Composable
fun PlinkApp(
    onRequestPostNotifications: () -> Unit = {},
    onBeginScreenConsent: (String) -> Unit = {}
) {
    val context = LocalContext.current
    val application = context.applicationContext as PlinkApplication
    val sessionStatus by application.sessionController.status.collectAsState()
    val fileTransferState by application.sessionController.fileTransferState.collectAsState()
    val featureSettings by application.featureSettings.enabled.collectAsState()
    val backgroundConnectionEnabled by application.featureSettings.backgroundConnectionEnabled.collectAsState()
    val backgroundConnectionState by application.backgroundConnectionState.collectAsState()
    val screenPreviewState by application.sessionController.screenPreviewState.collectAsState()
    var permissions by remember { mutableStateOf(AndroidPermissionReader.read(context)) }
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner, context) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) {
                permissions = AndroidPermissionReader.read(context)
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
                    screenPreviewState = screenPreviewState
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
                    onBeginScreenConsent = onBeginScreenConsent,
                    onStopScreenPreview = { application.sessionController.stopScreenPreview() }
                )
            )
        }
    }
}
