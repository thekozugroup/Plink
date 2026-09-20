package app.plink.android.protocol

import kotlinx.serialization.json.*
import java.util.Base64
import java.util.UUID

/** Validates the shared wire contract; active-transfer ordering/consent belongs to the coordinator. */
object FileTransferPayloadPolicy {
    const val maxFileBytes = 16_777_216
    const val chunkBytes = 32_768
    val eventTypes = setOf(PlinkEventType.FileOffer, PlinkEventType.FileAccept,
        PlinkEventType.FileChunk, PlinkEventType.FileProgress, PlinkEventType.FileComplete,
        PlinkEventType.FileResult, PlinkEventType.FileCancel)
    private val cancelReasons = setOf("cancelled", "timeout", "disconnected", "invalid", "storage")
    private val errorCodes = cancelReasons + setOf("receive_unavailable", "busy")

    fun requireAcceptable(envelope: PlinkEnvelope) {
        if (envelope.type !in eventTypes) return
        val p = envelope.payload
        val id = text(p, "transferId")
        require(runCatching { UUID.fromString(id).toString() == id }.getOrDefault(false)) { "Invalid transfer identity." }
        fun fields(vararg keys: String) = require(p.keys == keys.toSet() + "transferId") { "Invalid transfer fields." }
        when (envelope.type) {
            PlinkEventType.FileOffer -> {
                fields("name", "mimeType", "sizeBytes", "sha256", "chunkBytes")
                val name = text(p, "name")
                require(name.any { !isBlankScalar(it.code) } && name.toByteArray(Charsets.UTF_8).size <= 255 &&
                    name != "." && name != ".." && name.none { it == '/' || it == '\\' || it.code < 32 || it.code == 127 })
                val mime = text(p, "mimeType")
                require(mime.isNotBlank() && mime.length <= 127 && mime.all { it.code in 32..126 })
                number(p, "sizeBytes", 0..maxFileBytes)
                number(p, "chunkBytes", chunkBytes..chunkBytes)
                require(text(p, "sha256").matches(Regex("[0-9a-f]{64}")))
            }
            PlinkEventType.FileAccept, PlinkEventType.FileComplete -> fields()
            PlinkEventType.FileChunk -> {
                fields("index", "data")
                number(p, "index", 0 until (maxFileBytes / chunkBytes))
                val raw = text(p, "data")
                require(raw.length <= 43_692)
                val bytes = Base64.getDecoder().decode(raw)
                require(bytes.size in 1..chunkBytes && Base64.getEncoder().encodeToString(bytes) == raw)
            }
            PlinkEventType.FileProgress -> {
                fields("nextIndex")
                number(p, "nextIndex", 0..(maxFileBytes / chunkBytes))
            }
            PlinkEventType.FileResult -> when (text(p, "status")) {
                "saved" -> fields("status")
                "error" -> { fields("status", "code"); require(text(p, "code") in errorCodes) }
                else -> error("Invalid transfer result.")
            }
            PlinkEventType.FileCancel -> { fields("reason"); require(text(p, "reason") in cancelReasons) }
        }
    }

    /** Keeps file tokens exact before any typed decoding; non-file rules are unchanged. */
    fun validateRawJSON(raw: String) {
        // Disjoint string alternatives need no backtracking; *+ avoids JVM stack overflow on chunks.
        val matches = Regex(""""(?:[^"\\]|\\.)*+"|-?[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?|true|false|null|[{}\[\]:,]""")
            .findAll(raw).toList()
        val tokens = matches.map { it.value }
        val root = members(tokens)
        val fileEnvelope = root.any { (key, value) ->
            key == "type" && value.size == 1 &&
                runCatching { Json.parseToJsonElement(value.single()).jsonPrimitive.content in eventTypes }.getOrDefault(false)
        }
        if (!fileEnvelope) return
        var end = 0
        for (match in matches) {
            require(raw.substring(end, match.range.first).all { it in "\t\n\r " })
            end = match.range.last + 1
        }
        require(raw.substring(end).all { it in "\t\n\r " })
        require(raw.toByteArray(Charsets.UTF_8).size <= 65_536 && root.map { it.first }.toSet().size == root.size)
        val payload = root.firstOrNull { it.first == "payload" } ?: error("Missing file payload.")
        val fields = members(payload.second)
        require(fields.map { it.first }.toSet().size == fields.size) { "Duplicate file fields." }
        for ((key, value) in fields) {
            if (key in setOf("sizeBytes", "chunkBytes", "index", "nextIndex")) {
                require(value.size == 1 && isIntegerToken(value.single())) { "Expected unsigned integer token." }
            }
        }
    }

    private fun isIntegerToken(value: String): Boolean = value.length in 1..8 &&
        (value.length == 1 || value[0] != '0') && value.all { it in '0'..'9' }

    /** Splits object members without interpreting numbers. The JSON decoder checks grammar. */
    private fun members(tokens: List<String>): List<Pair<String, List<String>>> {
        require(tokens.firstOrNull() == "{" && tokens.lastOrNull() == "}")
        val result = mutableListOf<Pair<String, List<String>>>()
        var i = 1
        while (i < tokens.size - 1) {
            val key = Json.parseToJsonElement(tokens[i]).jsonPrimitive
            require(key.isString && i + 2 < tokens.size && tokens[i + 1] == ":")
            i += 2
            val start = i
            var depth = 0
            while (i < tokens.size) {
                val token = tokens[i]
                if (depth == 0 && (token == "," || token == "}")) break
                if (token == "{" || token == "[") depth++
                if (token == "}" || token == "]") depth--
                require(depth >= 0)
                i++
            }
            require(i > start && i < tokens.size && depth == 0)
            result += key.content to tokens.subList(start, i)
            if (tokens[i] == ",") {
                i++
                require(i < tokens.size - 1) { "Trailing comma in file object." }
            } else break
        }
        return result
    }

    // Unicode White_Space: the same fixed scalar table as Swift.
    private fun isBlankScalar(value: Int): Boolean = value in 9..13 || value == 0x20 ||
        value == 0x85 || value == 0xA0 || value == 0x1680 || value in 0x2000..0x200A ||
        value == 0x2028 || value == 0x2029 || value == 0x202F || value == 0x205F || value == 0x3000

    private fun text(p: JsonObject, key: String): String {
        val value = p[key] as? JsonPrimitive
        require(value != null && value.isString) { "Expected transfer text." }
        return value.content
    }

    private fun number(p: JsonObject, key: String, range: IntRange): Int {
        val value = p[key] as? JsonPrimitive
        require(value != null && !value.isString) { "Expected transfer number." }
        require(isIntegerToken(value.content)) { "Expected unsigned integer token." }
        val number = value.content.toIntOrNull()
        require(number != null && number in range) { "Transfer number out of range." }
        return number
    }
}
