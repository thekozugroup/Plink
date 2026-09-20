package app.plink.android.protocol

import app.plink.android.security.PayloadPolicy
import app.plink.android.security.AuthenticatedFrameResult
import app.plink.android.security.EncryptedFrameCodec
import app.plink.android.security.EncryptedPlinkFrame
import app.plink.android.security.InMemoryFrameStateStore
import java.io.File
import java.util.Base64
import java.time.Instant
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
