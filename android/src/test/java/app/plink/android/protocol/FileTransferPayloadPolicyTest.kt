package app.plink.android.protocol

import app.plink.android.security.EncryptedFrameCodec
import app.plink.android.security.PayloadPolicy
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.time.Instant
import java.util.Base64

class FileTransferPayloadPolicyTest {
    @Test fun sharedContractVectorsAgreeWithWirePolicy() {
        val root = generateSequence(File(System.getProperty("user.dir"))) { it.parentFile }
            .first { File(it, "shared/protocol/v1/file-transfer/cases.json").isFile }
        val cases = Json.parseToJsonElement(File(root, "shared/protocol/v1/file-transfer/cases.json").readText()).jsonArray
        for (case in cases) {
            val item = case.jsonObject
            val raw = item["rawEnvelope"]?.jsonPrimitive?.content ?: item.getValue("envelope").toString()
            val actual = runCatching { PayloadPolicy.requireAcceptable(PlinkEnvelope.decode(raw)) }.isSuccess
            assertEquals(item.getValue("name").jsonPrimitive.content, item.getValue("valid").jsonPrimitive.boolean, actual)
        }
    }

    @Test fun maximumChunkFitsEncryptedFrameWithoutRaisingBounds() {
        val envelope = PlinkEnvelope(id = "chunk", type = PlinkEventType.FileChunk,
            sentAt = Instant.now().toString(), sourceDeviceId = "pixel", targetDeviceId = "mac",
            payload = buildJsonObject {
                put("transferId", "00000000-0000-4000-8000-000000000001")
                put("index", 511)
                put("data", Base64.getEncoder().encodeToString(ByteArray(32768) { 255.toByte() }))
            })
        assertTrue(envelope.encode().toByteArray().size < 65536)
        // Exercise the raw scanner directly as well as through encrypted open.
        assertEquals(envelope.payload, PlinkEnvelope.decode(envelope.encode()).payload)
        val codec = EncryptedFrameCodec(ByteArray(32) { 7 })
        val frame = codec.seal(envelope, sequence = 1)
        val encoded = Json.encodeToString(app.plink.android.security.EncryptedPlinkFrame.serializer(), frame)
        assertTrue(encoded.toByteArray().size < 131072)
        assertEquals(envelope.payload, codec.open(frame).payload)
    }
}
