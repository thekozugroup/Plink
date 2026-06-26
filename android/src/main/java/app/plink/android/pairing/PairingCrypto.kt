package app.plink.android.pairing

import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.PublicKey
import java.security.SecureRandom
import java.security.spec.ECGenParameterSpec
import java.security.spec.X509EncodedKeySpec
import java.util.Base64
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

data class DeviceKeyPair(
    val publicKeyBase64: String,
    val privateKey: PrivateKey
)

data class DerivedSession(
    val sessionId: String,
    val sessionKey: ByteArray
)

object PairingCrypto {
    fun generateKeyPair(random: SecureRandom = SecureRandom()): DeviceKeyPair {
        val generator = KeyPairGenerator.getInstance("EC")
        generator.initialize(ECGenParameterSpec("secp256r1"), random)
        val pair = generator.generateKeyPair()
        return DeviceKeyPair(
            publicKeyBase64 = Base64.getEncoder().encodeToString(pair.public.encoded),
            privateKey = pair.private
        )
    }

    fun decodePublicKey(publicKeyBase64: String): PublicKey {
        require(publicKeyBase64.isNotBlank()) { "Pairing public key is required." }
        val bytes = Base64.getDecoder().decode(publicKeyBase64)
        return KeyFactory.getInstance("EC").generatePublic(X509EncodedKeySpec(bytes))
    }

    fun deriveSession(
        localPrivateKey: PrivateKey,
        peerPublicKeyBase64: String,
        nonce: String,
        transcript: String
    ): DerivedSession {
        require(nonce.isNotBlank()) { "Pairing nonce is required." }
        val agreement = KeyAgreement.getInstance("ECDH")
        agreement.init(localPrivateKey)
        agreement.doPhase(decodePublicKey(peerPublicKeyBase64), true)
        val sharedSecret = agreement.generateSecret()
        val sessionKey = hkdfSha256(
            inputKeyMaterial = sharedSecret,
            salt = MessageDigest.getInstance("SHA-256").digest(nonce.toByteArray(Charsets.UTF_8)),
            info = "plink-session-v1|$transcript".toByteArray(Charsets.UTF_8),
            length = 32
        )
        return DerivedSession(sessionId = sessionId(sessionKey), sessionKey = sessionKey)
    }

    fun sessionId(sessionKey: ByteArray): String = MessageDigest.getInstance("SHA-256")
        .digest(sessionKey)
        .joinToString(separator = "") { "%02x".format(it) }
        .take(32)

    private fun hkdfSha256(inputKeyMaterial: ByteArray, salt: ByteArray, info: ByteArray, length: Int): ByteArray {
        val prk = hmac(salt, inputKeyMaterial)
        val output = mutableListOf<Byte>()
        var previous = ByteArray(0)
        var counter = 1
        while (output.size < length) {
            previous = hmac(prk, previous + info + counter.toByte())
            output.addAll(previous.toList())
            counter += 1
        }
        return output.take(length).toByteArray()
    }

    private fun hmac(key: ByteArray, data: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        return mac.doFinal(data)
    }
}
