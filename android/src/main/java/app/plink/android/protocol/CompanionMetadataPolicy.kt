package app.plink.android.protocol

import kotlinx.serialization.json.JsonPrimitive

object CompanionMetadataPolicy {
    private val addressPattern = Regex("[0-9A-F]{2}(:[0-9A-F]{2}){5}")
    private val placeholders = setOf("00:00:00:00:00:00", "FF:FF:FF:FF:FF:FF", "02:00:00:00:00:00")

    fun requireAddress(address: String) {
        require(address.isEmpty() || (addressPattern.matches(address) && address !in placeholders)) {
            "Invalid companion Bluetooth address."
        }
    }

    fun address(envelope: PlinkEnvelope): String {
        require(envelope.type == PlinkEventType.DeviceCompanion)
        require(!envelope.requiresAck) { "Companion metadata does not request acknowledgement." }
        require(envelope.payload.keys == setOf("bluetoothAddress"))
        val value = envelope.payload["bluetoothAddress"] as? JsonPrimitive
        require(value != null && value.isString) { "Companion Bluetooth address must be a string." }
        return value.content.also(::requireAddress)
    }
}
