package app.plink.android.storage

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.security.KeyStore
import java.security.SecureRandom
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

interface PairingSecretStore {
    suspend fun save(sessionKey: ByteArray, sessionId: String)
    suspend fun load(sessionId: String): ByteArray?
    suspend fun remove(sessionId: String)
}

class InMemoryPairingSecretStore : PairingSecretStore {
    private val secrets = linkedMapOf<String, ByteArray>()

    override suspend fun save(sessionKey: ByteArray, sessionId: String) {
        secrets[sessionId] = sessionKey.copyOf()
    }

    override suspend fun load(sessionId: String): ByteArray? = secrets[sessionId]?.copyOf()

    override suspend fun remove(sessionId: String) {
        secrets.remove(sessionId)
    }
}

class KeystorePairingSecretStore(
    context: Context,
    private val alias: String = "plink_pairing_secret_store"
) : PairingSecretStore {
    private val prefs = context.getSharedPreferences("paired_session_secrets", Context.MODE_PRIVATE)

    override suspend fun save(sessionKey: ByteArray, sessionId: String) {
        prefs.edit()
            .putString(sessionId, Base64.getEncoder().encodeToString(encrypt(sessionKey)))
            .apply()
    }

    override suspend fun load(sessionId: String): ByteArray? {
        val encrypted = prefs.getString(sessionId, null) ?: return null
        return decrypt(Base64.getDecoder().decode(encrypted))
    }

    override suspend fun remove(sessionId: String) {
        prefs.edit().remove(sessionId).apply()
    }

    private fun encrypt(value: ByteArray): ByteArray {
        val iv = ByteArray(12).also { SecureRandom().nextBytes(it) }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, getOrCreateKey(), GCMParameterSpec(128, iv))
        return iv + cipher.doFinal(value)
    }

    private fun decrypt(value: ByteArray): ByteArray {
        require(value.size > 12) { "Stored session secret is malformed." }
        val iv = value.copyOfRange(0, 12)
        val ciphertext = value.copyOfRange(12, value.size)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, getOrCreateKey(), GCMParameterSpec(128, iv))
        return cipher.doFinal(ciphertext)
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
