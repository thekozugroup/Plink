package app.plink.android.storage

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import app.plink.android.pairing.PairedDevice
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import java.security.KeyStore
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class KeystorePairingStore(
    context: Context,
    private val alias: String = "plink_pairing_store",
    private val json: Json = Json { encodeDefaults = true; ignoreUnknownKeys = true }
) : PairingStore {
    private val prefs = context.getSharedPreferences("paired_devices", Context.MODE_PRIVATE)

    override suspend fun save(device: PairedDevice) {
        val devices = all().filterNot { it.id == device.id } + device
        persist(devices)
    }

    override suspend fun all(): List<PairedDevice> {
        val encrypted = prefs.getString("devices", null) ?: return emptyList()
        val decoded = decrypt(Base64.getDecoder().decode(encrypted))
        return json.decodeFromString(ListSerializer(PairedDevice.serializer()), decoded)
    }

    override suspend fun remove(deviceId: String) {
        persist(all().filterNot { it.id == deviceId })
    }

    private fun persist(devices: List<PairedDevice>) {
        val encoded = json.encodeToString(ListSerializer(PairedDevice.serializer()), devices)
        prefs.edit()
            .putString("devices", Base64.getEncoder().encodeToString(encrypt(encoded)))
            .apply()
    }

    private fun encrypt(value: String): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, getOrCreateKey())
        return cipher.iv + cipher.doFinal(value.toByteArray(Charsets.UTF_8))
    }

    private fun decrypt(value: ByteArray): String {
        require(value.size > 12) { "Stored pairing data is malformed." }
        val iv = value.copyOfRange(0, 12)
        val ciphertext = value.copyOfRange(12, value.size)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, getOrCreateKey(), GCMParameterSpec(128, iv))
        return String(cipher.doFinal(ciphertext), Charsets.UTF_8)
    }

    private fun getOrCreateKey(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keyStore.getKey(alias, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        val spec = KeyGenParameterSpec.Builder(
            alias,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setRandomizedEncryptionRequired(true)
            .build()
        generator.init(spec)
        return generator.generateKey()
    }
}
