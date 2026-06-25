package app.plink.android.storage

import app.plink.android.pairing.PairedDevice

interface PairingStore {
    suspend fun save(device: PairedDevice)
    suspend fun all(): List<PairedDevice>
    suspend fun remove(deviceId: String)
}

class InMemoryPairingStore : PairingStore {
    private val devices = linkedMapOf<String, PairedDevice>()

    override suspend fun save(device: PairedDevice) {
        devices[device.id] = device
    }

    override suspend fun all(): List<PairedDevice> = devices.values.toList()

    override suspend fun remove(deviceId: String) {
        devices.remove(deviceId)
    }
}
