package app.plink.android.protocol

import app.plink.android.security.PayloadPolicy
import app.plink.android.security.AuthenticatedFrameResult
import app.plink.android.security.EncryptedFrameCodec
import app.plink.android.security.EncryptedPlinkFrame
import app.plink.android.security.InMemoryFrameStateStore
import app.plink.android.reconnect.requireReconnectControl
import app.plink.android.reconnect.requireReconnectHelloTuple
import app.plink.android.reconnect.requireReconnectHelloBinding
import app.plink.android.reconnect.ReconnectLiveBinding
import app.plink.android.reconnect.ReconnectInterfaceSnapshot
import app.plink.android.transport.ObservedSocketTuple
import app.plink.android.transport.SocketChannelBinding
import java.io.File
import java.util.Base64
import java.time.Instant
import java.security.MessageDigest
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertTrue
import org.junit.Assert.assertEquals
import org.junit.Test

class ReconnectFixtureContractTest {
    @Test
    fun conditionalSharedContextsUseProductionIdentityTranscriptAndHelloBindingChecks() {
        val vectors = Json.parseToJsonElement(File(repositoryRoot,
            "shared/protocol/v1/reconnect/conditional-v2-vectors.json").readText())
            .jsonObject.getValue("vectors").jsonArray
        val androidReceivePhases = setOf("hello", "proof", "reverse_proof", "commit")
        var receiveCases = 0
        var comparisonOnlyCases = 0
        for (value in vectors) {
            val item = value.jsonObject
            if (!item.getValue("expectedV2WirePolicy").jsonPrimitive.boolean) continue
            val name = item.getValue("id").jsonPrimitive.content
            val context = item.getValue("context").jsonObject
            fun text(key: String) = context.getValue(key).jsonPrimitive.content
            val phase = text("phase")
            // Challenge/Reverse/Ready/Done are not Android receive phases. Their fixtures exercise
            // the unchanged generic comparison only, not Android state-machine reception or the
            // Mac's learning of fresh p/r. Android generates p/r, so it compares known values.
            val coverage = if (phase in androidReceivePhases) {
                receiveCases++; "Android receive validator"
            } else {
                comparisonOnlyCases++; "comparison only; not an Android receive phase"
            }
            val expected = ReconnectPayload(
                messageId = text("m"), mac = ReconnectEndpoint.parse(text("mac")),
                phone = ReconnectEndpoint.parse(text("phone")),
                proof = if (phase == "hello") null else text("p"),
                reverseProof = if (phase in setOf("reverse", "reverse_proof", "ready", "commit", "done")) text("r") else null,
                version = 2
            )
            val accepted = runCatching {
                val key = ByteArray(32) { it.toByte() }
                val frame = encryptFixtureBytes(item.getValue("rawEnvelope").jsonPrimitive.content.toByteArray(Charsets.UTF_8), key)
                val envelope = (EncryptedFrameCodec(key).openAuthenticated(frame,
                    now = Instant.parse(frame.issuedAt), expectedSourceDeviceId = text("source"),
                    expectedTargetDeviceId = text("target"), stateStore = InMemoryFrameStateStore())
                    as AuthenticatedFrameResult.Message).envelope
                if (phase == "hello") {
                    val payload = ReconnectPayloadPolicy.payload(envelope)
                    val tuple = ObservedSocketTuple(expected.phone.address, expected.phone.port,
                        expected.mac.address, 49_152)
                    requireReconnectHelloTuple(envelope, payload, tuple, text("source"), text("target"))
                    val binding = object : ReconnectLiveBinding {
                        override val interfaceSnapshot = ReconnectInterfaceSnapshot("fixture", 1,
                            expected.phone.address, 24, true, false, false, true, false, true)
                        override val peer = expected.mac
                        override val listenerPort = expected.phone.port
                        override val generation = 1L
                        override val socketBinding: SocketChannelBinding get() = error("No socket operation in validator test")
                        override fun validateCurrent() = Unit
                    }
                    requireReconnectHelloBinding(payload, binding)
                } else {
                    requireReconnectControl(envelope, "reconnect.$phase", expected, text("source"), text("target"))
                }
            }.isSuccess
            assertEquals("$name ($coverage)", item.getValue("expectedTranscript").jsonPrimitive.boolean, accepted)
        }
        assertEquals(5, receiveCases)
        assertEquals(9, comparisonOnlyCases)
    }

    @Test
    fun conditionalSharedVectorsUseRawPolicyAndEncryptedCodec() {
        val vectors = Json.parseToJsonElement(File(repositoryRoot,
            "shared/protocol/v1/reconnect/conditional-v2-vectors.json").readText())
            .jsonObject.getValue("vectors").jsonArray
        for (value in vectors) {
            val item = value.jsonObject
            val name = item.getValue("id").jsonPrimitive.content
            val raw = item.getValue("rawEnvelope").jsonPrimitive.content.toByteArray(Charsets.UTF_8)
            val valid = item.getValue("expectedV2WirePolicy").jsonPrimitive.boolean
            val decoded = runCatching { PlinkEnvelope.decode(raw).also(PayloadPolicy::requireAcceptable) }
            assertEquals(name, valid, decoded.isSuccess)
            // Seal the original bytes, including duplicate keys and malformed numeric spelling.
            // Production seal() intentionally refuses invalid payloads before encryption.
            val key = ByteArray(32) { it.toByte() }
            val frame = encryptFixtureBytes(raw, key)
            val received = runCatching {
                EncryptedFrameCodec(key).openAuthenticated(frame, now = Instant.parse(frame.issuedAt),
                    expectedSourceDeviceId = frame.sourceDeviceId,
                    expectedTargetDeviceId = frame.targetDeviceId,
                    stateStore = InMemoryFrameStateStore())
            }
            assertEquals("$name encrypted", valid, received.isSuccess)
            if (valid) {
                val envelope = decoded.getOrThrow()
                val codec = EncryptedFrameCodec(ByteArray(32) { it.toByte() })
                val now = Instant.parse(envelope.sentAt)
                val frame = codec.seal(envelope, 1, issuedAt = now)
                val opened = codec.openAuthenticated(frame, now = now,
                    expectedSourceDeviceId = envelope.sourceDeviceId,
                    expectedTargetDeviceId = envelope.targetDeviceId,
                    stateStore = InMemoryFrameStateStore()) as AuthenticatedFrameResult.Message
                assertEquals(name, envelope, opened.envelope)
                assertEquals(name, 2, ReconnectPayloadPolicy.payload(opened.envelope).version)
            }
        }
    }

    private fun encryptFixtureBytes(raw: ByteArray, key: ByteArray): EncryptedPlinkFrame {
        val json = Json.parseToJsonElement(raw.toString(Charsets.UTF_8)).jsonObject
        val frame = EncryptedPlinkFrame(sequence = 1, nonce = "00000000-0000-4000-8000-000000000099",
            issuedAt = "2026-09-21T00:00:00Z",
            sourceDeviceId = json.getValue("sourceDeviceId").jsonPrimitive.content,
            targetDeviceId = json.getValue("targetDeviceId").jsonPrimitive.content,
            cipherText = "", signature = "")
        val iv = ByteArray(12) { it.toByte() } // Isolated synthetic key/store per vector; never production randomness.
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(MessageDigest.getInstance("SHA-256").digest(key), "AES"),
            GCMParameterSpec(128, iv))
        cipher.updateAAD(listOf("1", "1", frame.nonce, frame.issuedAt, frame.sourceDeviceId,
            frame.targetDeviceId).joinToString("\n").toByteArray(Charsets.UTF_8))
        val encrypted = frame.copy(cipherText = Base64.getEncoder().encodeToString(iv + cipher.doFinal(raw)))
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(MessageDigest.getInstance("SHA-256")
            .digest("plink-frame-hmac".toByteArray(Charsets.UTF_8) + key), "HmacSHA256"))
        return encrypted.copy(signature = Base64.getEncoder()
            .encodeToString(mac.doFinal(encrypted.signingInput().toByteArray(Charsets.UTF_8))))
    }

    private val repositoryRoot by lazy {
        generateSequence(File(requireNotNull(System.getProperty("user.dir")))) { it.parentFile }
            .first { File(it, FIXTURE_PATH).isFile }
    }

    @Test
    fun encryptedVectorsMatchAndroidWirePolicy() {
        checkEncryptedVectors("encrypted-vectors.json")
    }

    @Test
    fun outerTimestampsMatchAndroidWirePolicy() {
        checkEncryptedVectors("outer-timestamp-vectors.json")
    }

    private fun checkEncryptedVectors(file: String) {
        val vectors = Json.parseToJsonElement(File(repositoryRoot,
            "shared/protocol/v1/reconnect/$file").readText())
            .jsonObject.getValue("vectors").jsonArray
        val mismatches = mutableListOf<String>()
        for (value in vectors) {
            val item = value.jsonObject
            val name = item.getValue("name").jsonPrimitive.content
            val valid = item.getValue("valid").jsonPrimitive.boolean
            val wire = item.getValue("wire").jsonPrimitive.content
            val frame = Json.decodeFromString(EncryptedPlinkFrame.serializer(), wire)
            val codec = EncryptedFrameCodec(Base64.getDecoder().decode(
                item.getValue("sessionKeyBase64").jsonPrimitive.content))
            val accepted = runCatching {
                val result = codec.openAuthenticated(frame, now = Instant.parse(frame.issuedAt),
                    expectedSourceDeviceId = frame.sourceDeviceId, expectedTargetDeviceId = frame.targetDeviceId,
                    stateStore = InMemoryFrameStateStore(), wireBytes = wire.toByteArray(Charsets.UTF_8).size)
                require(result is AuthenticatedFrameResult.Message)
                if (valid) {
                    val plaintext = Base64.getDecoder().decode(item.getValue("plaintextBase64").jsonPrimitive.content)
                    assertEquals(name, PlinkEnvelope.decode(plaintext), result.envelope)
                }
            }.isSuccess
            if (accepted != valid) mismatches += "$name: expected accepted=$valid, got $accepted"
        }
        assertTrue(mismatches.joinToString("\n"), mismatches.isEmpty())
    }

    @Test
    fun sharedCasesMatchAndroidWirePolicy() {
        checkCases("cases.json")
    }

    @Test
    fun escapedClassificationMatchesAndroidWirePolicy() {
        checkCases("classification-cases.json")
    }

    private fun checkCases(file: String) {
        val fixture = Json.parseToJsonElement(File(repositoryRoot,
            "shared/protocol/v1/reconnect/$file").readText()).jsonObject
        val mismatches = mutableListOf<String>()

        for (case in fixture.getValue("cases").jsonArray) {
            val item = case.jsonObject
            val name = item.getValue("name").jsonPrimitive.content
            val valid = item.getValue("valid").jsonPrimitive.boolean
            val raw = rawEnvelope(item)

            item["rawEnvelopeBytes"]?.jsonPrimitive?.int?.let { expectedBytes ->
                if (raw.size != expectedBytes) {
                    mismatches += "$name: fixture byte count expected $expectedBytes, got ${raw.size}"
                }
            }

            val accepted = runCatching {
                PayloadPolicy.requireAcceptable(PlinkEnvelope.decode(raw))
            }.isSuccess

            if (accepted != valid) {
                mismatches += "$name: expected accepted=$valid, got $accepted"
            }
        }

        assertTrue(mismatches.joinToString("\n"), mismatches.isEmpty())
    }

    private fun rawEnvelope(item: JsonObject): ByteArray = when {
        item["rawEnvelopeBase64"] != null -> Base64.getDecoder().decode(
            item.getValue("rawEnvelopeBase64").jsonPrimitive.content
        )
        item["rawEnvelope"] != null -> item.getValue("rawEnvelope").jsonPrimitive.content
            .toByteArray(Charsets.UTF_8)
        else -> item.getValue("envelope").toString().toByteArray(Charsets.UTF_8)
    }

    private companion object {
        const val FIXTURE_PATH = "shared/protocol/v1/reconnect/cases.json"
    }
}
