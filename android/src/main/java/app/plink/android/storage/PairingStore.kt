package app.plink.android.storage

import app.plink.android.pairing.PairedDevice

interface PairingStore {
    suspend fun save(device: PairedDevice)
    suspend fun all(): List<PairedDevice>
    suspend fun remove(deviceId: String)
    suspend fun activeDeviceId(): String?
    suspend fun setActiveDeviceId(deviceId: String?)
}

class InMemoryPairingStore : PairingStore {
    private val devices = linkedMapOf<String, PairedDevice>()
    private var activeDeviceId: String? = null

    override suspend fun save(device: PairedDevice) {
        devices[device.id] = device
    }

    override suspend fun all(): List<PairedDevice> = devices.values.toList()

    override suspend fun remove(deviceId: String) {
        devices.remove(deviceId)
    }

    override suspend fun activeDeviceId(): String? = activeDeviceId

    override suspend fun setActiveDeviceId(deviceId: String?) {
        activeDeviceId = deviceId
    }
}
