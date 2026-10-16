package app.plink.android.companion

import android.companion.AssociationInfo
import android.companion.AssociationRequest
import android.companion.CompanionDeviceManager
import android.companion.BluetoothDeviceFilter
import android.content.ComponentName
import android.content.Context
import android.content.IntentSender
import android.content.pm.PackageManager
import android.os.Build
import androidx.annotation.RequiresApi
import androidx.core.content.ContextCompat
import app.plink.android.services.PlinkNotificationListenerService
import app.plink.android.storage.KeystorePairingStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.withContext
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

class CompanionDeviceController(context: Context, scope: CoroutineScope) {
    private val coordinator = CompanionSetupCoordinator(AndroidCompanionEnvironment(context.applicationContext), scope)
    val state: StateFlow<CompanionSetupState> = coordinator.state

    fun refresh() = coordinator.refresh()
    fun setUp(owner: Any, launch: (IntentSender) -> Unit) = coordinator.setUp(owner, launch)
    fun cancelSetup(owner: Any) = coordinator.cancelSetup(owner)
    fun requestNotificationAccess(owner: Any, openSettings: () -> Unit) = coordinator.requestNotificationAccess(owner, openSettings)
    fun removeRegistration() = coordinator.removeRegistration()
    suspend fun withPairingTransaction(block: suspend () -> Unit) = coordinator.withPairingTransaction(block)
    suspend fun receiveMetadata(deviceId: String, peerPublicKey: String, bluetoothAddress: String,
        commitIfCurrent: (() -> Unit) -> Boolean) = coordinator.receiveMetadata(deviceId, peerPublicKey, bluetoothAddress, commitIfCurrent)
}

private class AndroidCompanionEnvironment(private val context: Context) : CompanionEnvironment<IntentSender> {
    override val supported = Build.VERSION.SDK_INT >= 33 &&
        context.packageManager.hasSystemFeature(PackageManager.FEATURE_COMPANION_DEVICE_SETUP) &&
        context.getSystemService(CompanionDeviceManager::class.java) != null
    private val store = KeystorePairingStore(context)
    private val preferences = context.getSharedPreferences("companion_registration", Context.MODE_PRIVATE)
    private val mainExecutor = ContextCompat.getMainExecutor(context)
    private val mainDispatcher = mainExecutor.asCoroutineDispatcher()
    private val json = Json { ignoreUnknownKeys = true }

    override suspend fun pairings(): CompanionPairings {
        val devices = store.all().filter {
            it.trusted && it.securityVersion == 2 && it.platform == "macos" &&
                it.id.isNotBlank() && it.peerPublicKey.isNotBlank()
        }
        val selectedId = store.activeDeviceId()
        val selected = devices.singleOrNull { it.id == selectedId }?.let {
            CompanionPeer(CompanionIdentity(it.id, it.peerPublicKey), it.name.ifBlank { "Mac" })
        }
        return CompanionPairings(selected, devices.map { CompanionIdentity(it.id, it.peerPublicKey) }.toSet())
    }

    override fun readRegistrations(): CompanionRegistrations =
        preferences.getString("registration", null)?.let { json.decodeFromString<CompanionRegistrations>(it) }
            ?: CompanionRegistrations()

    override fun writeRegistrations(value: CompanionRegistrations) {
        check(preferences.edit().putString("registration", json.encodeToString(value)).commit()) {
            "Could not save companion registration."
        }
    }

    @RequiresApi(33)
    override fun associations(): List<CompanionAssociation> = manager().myAssociations.map {
        CompanionAssociation(it.id, it.deviceMacAddress?.toString()?.uppercase(java.util.Locale.ROOT))
    }

    @RequiresApi(33)
    override fun disassociate(id: Int) = manager().disassociate(id)

    @RequiresApi(33)
    override fun associate(bluetoothAddress: String, callback: CompanionEnvironment.Callback<IntentSender>) {
        val filter = BluetoothDeviceFilter.Builder().setAddress(bluetoothAddress).build()
        val request = AssociationRequest.Builder().addDeviceFilter(filter).setSingleDevice(true).build()
        manager().associate(request, mainExecutor, object : CompanionDeviceManager.Callback() {
            override fun onAssociationPending(intentSender: IntentSender) = callback.pending(intentSender)
            override fun onAssociationCreated(associationInfo: AssociationInfo) = callback.created(associationInfo.id)
            override fun onFailure(error: CharSequence?) = callback.failed()
        })
    }

    override fun requestNotificationAccess() {
        manager().requestNotificationAccess(ComponentName(context, PlinkNotificationListenerService::class.java))
    }

    override suspend fun onMain(action: () -> Unit) = withContext(mainDispatcher) { action() }

    private fun manager(): CompanionDeviceManager = checkNotNull(context.getSystemService(CompanionDeviceManager::class.java))
}
