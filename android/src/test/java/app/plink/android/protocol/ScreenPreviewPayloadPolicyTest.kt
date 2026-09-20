package app.plink.android.protocol

import app.plink.android.security.AuthenticatedFrameResult
import app.plink.android.security.EncryptedFrameCodec
import app.plink.android.security.EncryptedPlinkFrame
import app.plink.android.security.PayloadPolicy
import java.io.File
import java.time.Instant
import java.util.Base64
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class ScreenPreviewPayloadPolicyTest {
    private val fixture by lazy {
        val root = generateSequence(File(requireNotNull(System.getProperty("user.dir")))) { it.parentFile }
            .first { File(it, FIXTURE_PATH).isFile }
        Json.parseToJsonElement(File(root, FIXTURE_PATH).readText()).jsonObject
    }

    @Test
    fun sharedCasesMatchAndroidWirePolicy() {
        for (case in fixture.getValue("cases").jsonArray) {
            val item = case.jsonObject
            val raw = item["rawEnvelope"]?.jsonPrimitive?.content
                ?: item.getValue("envelope").toString()
            val accepted = runCatching {
                PayloadPolicy.requireAcceptable(PlinkEnvelope.decode(raw))
            }.isSuccess

            assertEquals(
                item.getValue("name").jsonPrimitive.content,
                item.getValue("valid").jsonPrimitive.boolean,
                accepted
            )
        }
    }

    @Test
    fun sharedEncryptedVectorsOpenOrReturnSanitizedRejection() {
        for (vector in fixture.getValue("encryptedVectors").jsonArray) {
            val item = vector.jsonObject
            val frame = Json.decodeFromJsonElement<EncryptedPlinkFrame>(item.getValue("frame"))
            val codec = EncryptedFrameCodec(
                Base64.getDecoder().decode(item.getValue("sessionKeyBase64").jsonPrimitive.content)
            )
            val result = codec.openAuthenticated(
                frame = frame,
                now = Instant.parse(item.getValue("issuedAt").jsonPrimitive.content),
                expectedSourceDeviceId = frame.sourceDeviceId,
                expectedTargetDeviceId = frame.targetDeviceId,
                wireBytes = Json.encodeToString(EncryptedPlinkFrame.serializer(), frame)
                    .toByteArray(Charsets.UTF_8).size
            )

            if (item["expectedError"] == null) {
                assertTrue(item.getValue("name").jsonPrimitive.content, result is AuthenticatedFrameResult.Message)
                assertEquals(
                    PlinkEnvelope.decode(item.getValue("plaintext").jsonPrimitive.content),
                    (result as AuthenticatedFrameResult.Message).envelope
                )
            } else {
                assertTrue(
                    item.getValue("name").jsonPrimitive.content,
                    result is AuthenticatedFrameResult.RejectedScreen
                )
                val rejection = (result as AuthenticatedFrameResult.RejectedScreen).rejection
                assertEquals(item["expectedRequestId"]?.jsonPrimitive?.contentOrNull, rejection.requestId)
                assertEquals(item["expectedStreamId"]?.jsonPrimitive?.contentOrNull, rejection.streamId)
                assertEquals(frame.sourceDeviceId, rejection.sourceDeviceId)
                assertEquals(frame.targetDeviceId, rejection.targetDeviceId)
            }
        }
    }

    @Test
    fun sharedInvalidDecoderCasesFailBeforePixelAllocation() {
        val template = fixture.getValue("cases").jsonArray
            .map { it.jsonObject }
            .first { it.getValue("name").jsonPrimitive.content == "baseline jpeg frame" }
            .getValue("envelope")
            .let { Json.decodeFromJsonElement<PlinkEnvelope>(it) }

        for (case in fixture.getValue("decoderInvalidCases").jsonArray) {
            val item = case.jsonObject
            val payload = template.payload.toMutableMap().apply {
                this["width"] = JsonPrimitive(item.getValue("width").jsonPrimitive.int)
                this["height"] = JsonPrimitive(item.getValue("height").jsonPrimitive.int)
                this["data"] = JsonPrimitive(item.getValue("data").jsonPrimitive.content)
            }

            assertTrue(
                item.getValue("name").jsonPrimitive.content,
                runCatching { PayloadPolicy.requireAcceptable(template.copy(payload = JsonObject(payload))) }.isFailure
            )
        }
    }

    @Test
    fun rawControlLimitCountsWhitespaceBeforeCanonicalization() {
        val raw = fixture.getValue("cases").jsonArray
            .map { it.jsonObject }
            .first { it.getValue("name").jsonPrimitive.content == "request" }
            .getValue("envelope")
            .toString()
        ScreenPreviewPayloadPolicy.validateRawJSON(raw)
        val paddingBytes = ScreenPreviewPayloadPolicy.maxControlEnvelopeBytes + 1 -
            raw.toByteArray(Charsets.UTF_8).size
        assertTrue(paddingBytes > 0)

        assertThrows(IllegalArgumentException::class.java) {
            ScreenPreviewPayloadPolicy.validateRawJSON(raw + " ".repeat(paddingBytes))
        }
    }

    @Test
    fun exifOrientationMustBeUprightAndBounded() {
        val item = fixture.getValue("decoderInvalidCases").jsonArray.map { it.jsonObject }
            .first { it.getValue("name").jsonPrimitive.content == "exif orientation six" }
        val original = Base64.getDecoder().decode(item.getValue("data").jsonPrimitive.content)
        val width = item.getValue("width").jsonPrimitive.int
        val height = item.getValue("height").jsonPrimitive.int
        // Locate the TIFF header in this fixed shared EXIF fixture.
        val signature = byteArrayOf(0x45, 0x78, 0x69, 0x66, 0, 0)
        val base = (0..original.size - signature.size).first { p ->
            signature.indices.all { original[p + it] == signature[it] }
        } + signature.size
        val little = original[base] == 0x49.toByte()
        fun short(bytes: ByteArray, p: Int, value: Int) {
            bytes[p] = (if (little) value else value shr 8).toByte()
            bytes[p + 1] = (if (little) value shr 8 else value).toByte()
        }
        val orientation = base + 8 + 2 + 8
        val upright = original.copyOf().also { short(it, orientation, 1) }
        BaselineJpegValidator(upright).validate(width, height)
        for (value in listOf(0, 2, 6, 8, 65535)) {
            val rotated = upright.copyOf().also { short(it, orientation, value) }
            assertThrows(IllegalArgumentException::class.java) {
                BaselineJpegValidator(rotated).validate(width, height)
            }
        }
        val invalidOffset = upright.copyOf().also { bytes ->
            for (p in base + 4 until base + 8) bytes[p] = 0xff.toByte()
        }
        assertThrows(IllegalArgumentException::class.java) {
            BaselineJpegValidator(invalidOffset).validate(width, height)
        }
    }

    @Test
    fun fixtureProfileMatchesProductionLimits() {
        val profile = fixture.getValue("profile").jsonObject
        assertEquals(ScreenPreviewPayloadPolicy.profile, profile.getValue("name").jsonPrimitive.content)
        assertEquals(
            ScreenPreviewPayloadPolicy.minimumPullIntervalMillis,
            profile.getValue("minimumPullIntervalMs").jsonPrimitive.content.toLong()
        )
        assertEquals(ScreenPreviewPayloadPolicy.maxLongEdge, profile.getValue("maxLongEdge").jsonPrimitive.int)
        assertEquals(ScreenPreviewPayloadPolicy.maxShortEdge, profile.getValue("maxShortEdge").jsonPrimitive.int)
        assertEquals(ScreenPreviewPayloadPolicy.maxPixels, profile.getValue("maxPixels").jsonPrimitive.int)
        assertEquals(ScreenPreviewPayloadPolicy.maxJpegBytes, profile.getValue("maxJPEGBytes").jsonPrimitive.int)
        assertEquals(
            ScreenPreviewPayloadPolicy.maxBase64Characters,
            profile.getValue("maxBase64Characters").jsonPrimitive.int
        )
        assertEquals(
            ScreenPreviewPayloadPolicy.maxControlEnvelopeBytes,
            profile.getValue("maxControlEnvelopeBytes").jsonPrimitive.int
        )
        assertEquals(
            ScreenPreviewPayloadPolicy.maxScreenWireBytes,
            profile.getValue("maxScreenWireBytes").jsonPrimitive.int
        )
    }

    private companion object {
        const val FIXTURE_PATH = "shared/protocol/v1/screen-preview/cases.json"
    }
}
