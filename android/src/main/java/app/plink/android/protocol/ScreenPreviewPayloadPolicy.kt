package app.plink.android.protocol

import app.plink.android.security.PlinkTime
import java.time.Instant
import java.util.Base64
import java.util.UUID
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

data class AuthenticatedScreenCorrelation(
    /** Null means authenticated JSON contained an ambiguous screen type marker. */
    val type: String?,
    val sourceDeviceId: String,
    val targetDeviceId: String,
    val requestId: String?,
    val streamId: String?
)

/** Exact policy shared by authenticated screen messages before coordinator admission. */
object ScreenPreviewPayloadPolicy {
    const val profile = "jpeg-1280-2fps-v1"
    const val minimumPullIntervalMillis = 500L
    const val maxLongEdge = 1_280
    const val maxShortEdge = 720
    const val maxPixels = 921_600
    const val maxJpegBytes = 40_960
    const val maxBase64Characters = 54_616
    const val maxControlEnvelopeBytes = 2_048
    const val maxScreenWireBytes = 98_304

    val eventTypes = setOf(
        PlinkEventType.ScreenRequest,
        PlinkEventType.ScreenState,
        PlinkEventType.ScreenPull,
        PlinkEventType.ScreenFrame,
        PlinkEventType.ScreenIdle,
        PlinkEventType.ScreenStop
    )

    private val rejectedReasons = setOf(
        "denied", "disabled", "unsupported", "busy", "not_ready", "timeout", "capture_error"
    )
    private val stopReasons = setOf(
        "user", "disabled", "locked", "hidden", "disconnected", "timeout",
        "consent_revoked", "capture_error", "protocol_error"
    )
    private val idleReasons = setOf("no_new_frame", "frame_too_large")
    private val envelopeFields = setOf(
        "version", "id", "type", "sentAt", "sourceDeviceId", "targetDeviceId", "requiresAck", "payload"
    )
    private val uuidV4 = Regex("[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}")
    private val unsignedInteger = Regex("0|[1-9][0-9]*")
    private val tokenPattern = Regex(
        """"(?:[^"\\]|\\.)*+"|-?[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?|true|false|null|[{}\[\]:,]"""
    )

    fun requireAcceptable(envelope: PlinkEnvelope) {
        if (envelope.type !in eventTypes) return
        require(envelope.version == 1 && !envelope.requiresAck) { "Invalid screen envelope." }
        require(isCanonicalUuidV4(envelope.id)) { "Invalid screen envelope id." }
        require(validDeviceId(envelope.sourceDeviceId) && validDeviceId(envelope.targetDeviceId)) {
            "Invalid screen routing."
        }
        val sentAt = runCatching { Instant.parse(envelope.sentAt) }.getOrNull()
        require(sentAt != null && PlinkTime.canonicalTimestamp(sentAt) == envelope.sentAt) {
            "Invalid screen timestamp."
        }
        require(envelope.encode().toByteArray(Charsets.UTF_8).size <= app.plink.android.security.PayloadPolicy.maxEnvelopeBytes) {
            "Screen envelope exceeds the plaintext limit."
        }

        val payload = envelope.payload
        require(number(payload, "v", 1..1) == 1)
        val requestId = text(payload, "requestId")
        require(isCanonicalUuidV4(requestId)) { "Invalid screen request id." }
        when (envelope.type) {
            PlinkEventType.ScreenRequest -> {
                fields(payload, "v", "requestId", "profile")
                require(text(payload, "profile") == profile) { "Unsupported screen profile." }
            }
            PlinkEventType.ScreenState -> requireState(payload)
            PlinkEventType.ScreenPull -> {
                fields(payload, "v", "requestId", "streamId", "index")
                requireStreamId(payload)
                number(payload, "index", 1..Int.MAX_VALUE)
            }
            PlinkEventType.ScreenFrame -> requireFrame(payload)
            PlinkEventType.ScreenIdle -> {
                fields(payload, "v", "requestId", "streamId", "index", "reason")
                requireStreamId(payload)
                number(payload, "index", 1..Int.MAX_VALUE)
                require(text(payload, "reason") in idleReasons) { "Invalid screen idle reason." }
            }
            PlinkEventType.ScreenStop -> {
                val expected = if (payload.containsKey("streamId")) {
                    setOf("v", "requestId", "streamId", "reason")
                } else {
                    setOf("v", "requestId", "reason")
                }
                require(payload.keys == expected) { "Invalid screen stop fields." }
                if (payload.containsKey("streamId")) requireStreamId(payload)
                require(text(payload, "reason") in stopReasons) { "Invalid screen stop reason." }
            }
        }
        if (envelope.type != PlinkEventType.ScreenFrame) {
            require(envelope.encode().toByteArray(Charsets.UTF_8).size <= maxControlEnvelopeBytes) {
                "Screen control exceeds its limit."
            }
        }
    }

    /** Keeps screen integer tokens, duplicate keys, nulls and unknown fields exact. */
    fun validateRawJSON(raw: String) {
        val tokens = tokenize(raw)
        val root = members(tokens)
        val types = root.filter { it.first == "type" }.mapNotNull { stringToken(it.second) }
        if (types.none { it in eventTypes }) return
        require(types.size == 1 && types.single() in eventTypes) { "Ambiguous screen type." }
        require(raw.toByteArray(Charsets.UTF_8).size <=
            if (types.single() == PlinkEventType.ScreenFrame) app.plink.android.security.PayloadPolicy.maxEnvelopeBytes
            else maxControlEnvelopeBytes) { "Screen plaintext exceeds its limit." }
        require(root.map { it.first }.toSet().size == root.size && root.map { it.first }.toSet() == envelopeFields) {
            "Invalid screen envelope fields."
        }
        require(integerToken(root.value("version"), 1..1) == 1)
        require(root.value("requiresAck") == listOf("false")) { "Screen acknowledgement is forbidden." }
        val payload = members(root.value("payload"))
        require(payload.map { it.first }.toSet().size == payload.size) { "Duplicate screen payload fields." }
        val type = types.single()
        val expected = when (type) {
            PlinkEventType.ScreenRequest -> setOf("v", "requestId", "profile")
            PlinkEventType.ScreenState -> when (stringToken(payload.value("state"))) {
                "needs_consent" -> setOf("v", "requestId", "state")
                "started" -> setOf("v", "requestId", "state", "streamId", "profile")
                "rejected" -> setOf("v", "requestId", "state", "reason")
                else -> error("Invalid screen state.")
            }
            PlinkEventType.ScreenPull -> setOf("v", "requestId", "streamId", "index")
            PlinkEventType.ScreenFrame -> setOf("v", "requestId", "streamId", "index", "width", "height", "data")
            PlinkEventType.ScreenIdle -> setOf("v", "requestId", "streamId", "index", "reason")
            PlinkEventType.ScreenStop -> if (payload.any { it.first == "streamId" }) {
                setOf("v", "requestId", "streamId", "reason")
            } else {
                setOf("v", "requestId", "reason")
            }
            else -> error("Unsupported screen type.")
        }
        require(payload.map { it.first }.toSet() == expected) { "Invalid screen payload fields." }
        integerToken(payload.value("v"), 1..1)
        for (key in setOf("index", "width", "height")) {
            payload.firstOrNull { it.first == key }?.let { integerToken(it.second, 1..Int.MAX_VALUE) }
        }
    }

    /** Extracts only authenticated routing/correlation; raw media and JSON never leave this call. */
    fun inspectAuthenticated(raw: String): AuthenticatedScreenCorrelation? = runCatching {
        val root = members(tokenize(raw))
        val typeValues = root.filter { it.first == "type" }.mapNotNull { stringToken(it.second) }
        if (typeValues.none { it in eventTypes }) return@runCatching null
        val source = root.uniqueString("sourceDeviceId") ?: return@runCatching null
        val target = root.uniqueString("targetDeviceId") ?: return@runCatching null
        if (!validDeviceId(source) || !validDeviceId(target)) return@runCatching null
        val payloadEntries = root.filter { it.first == "payload" }
        val payload = if (payloadEntries.size == 1) runCatching { members(payloadEntries.single().second) }.getOrNull() else null
        AuthenticatedScreenCorrelation(
            type = typeValues.singleOrNull()?.takeIf { it in eventTypes },
            sourceDeviceId = source,
            targetDeviceId = target,
            requestId = payload?.uniqueCanonicalUuid("requestId"),
            streamId = payload?.uniqueCanonicalUuid("streamId")
        )
    }.getOrNull()

    fun requestId(envelope: PlinkEnvelope): String = text(envelope.payload, "requestId")
    fun streamId(envelope: PlinkEnvelope): String? =
        envelope.payload["streamId"]?.let { text(envelope.payload, "streamId") }
    fun index(envelope: PlinkEnvelope): Int = number(envelope.payload, "index", 1..Int.MAX_VALUE)

    private fun requireState(payload: JsonObject) {
        when (text(payload, "state")) {
            "needs_consent" -> fields(payload, "v", "requestId", "state")
            "started" -> {
                fields(payload, "v", "requestId", "state", "streamId", "profile")
                requireStreamId(payload)
                require(text(payload, "profile") == profile) { "Unsupported screen profile." }
            }
            "rejected" -> {
                fields(payload, "v", "requestId", "state", "reason")
                require(text(payload, "reason") in rejectedReasons) { "Invalid screen rejection reason." }
            }
            else -> error("Invalid screen state.")
        }
    }

    private fun requireFrame(payload: JsonObject) {
        fields(payload, "v", "requestId", "streamId", "index", "width", "height", "data")
        requireStreamId(payload)
        number(payload, "index", 1..Int.MAX_VALUE)
        val width = number(payload, "width", 1..maxLongEdge)
        val height = number(payload, "height", 1..maxLongEdge)
        require(maxOf(width, height) <= maxLongEdge && minOf(width, height) <= maxShortEdge &&
            width.toLong() * height <= maxPixels) { "Screen dimensions exceed the profile." }
        val encoded = text(payload, "data")
        require(encoded.length <= maxBase64Characters && !encoded.any(Char::isWhitespace)) {
            "Screen frame Base64 exceeds its limit."
        }
        val bytes = runCatching { Base64.getDecoder().decode(encoded) }.getOrNull()
        require(bytes != null && bytes.size in 1..maxJpegBytes && Base64.getEncoder().encodeToString(bytes) == encoded) {
            "Invalid screen frame Base64."
        }
        require(isBaselineJpeg(bytes, width, height)) { "Invalid screen JPEG." }
    }

    private fun requireStreamId(payload: JsonObject) {
        require(isCanonicalUuidV4(text(payload, "streamId"))) { "Invalid screen stream id." }
    }

    private fun fields(payload: JsonObject, vararg names: String) {
        require(payload.keys == names.toSet()) { "Invalid screen payload fields." }
    }

    private fun text(payload: JsonObject, key: String): String {
        val value = payload[key] as? JsonPrimitive
        require(value != null && value.isString) { "Expected screen text." }
        return value.content
    }

    private fun number(payload: JsonObject, key: String, range: IntRange): Int {
        val value = payload[key] as? JsonPrimitive
        require(value != null && !value.isString && unsignedInteger.matches(value.content)) {
            "Expected unsigned screen integer."
        }
        return value.content.toIntOrNull()?.takeIf { it in range }
            ?: error("Screen integer is out of range.")
    }

    private fun validDeviceId(value: String): Boolean =
        value.toByteArray(Charsets.UTF_8).size in 1..128

    fun isCanonicalUuidV4(value: String): Boolean = uuidV4.matches(value) &&
        runCatching { UUID.fromString(value).toString() == value }.getOrDefault(false)

    private fun tokenize(raw: String): List<String> {
        require(raw.toByteArray(Charsets.UTF_8).size <= app.plink.android.security.PayloadPolicy.maxEnvelopeBytes)
        Json.parseToJsonElement(raw)
        val matches = tokenPattern.findAll(raw).toList()
        var end = 0
        for (match in matches) {
            require(raw.substring(end, match.range.first).all { it in "\t\n\r " })
            end = match.range.last + 1
        }
        require(raw.substring(end).all { it in "\t\n\r " })
        return matches.map { it.value }
    }

    /** Splits an object without interpreting numeric tokens or discarding duplicate keys. */
    private fun members(tokens: List<String>): List<Pair<String, List<String>>> {
        require(tokens.firstOrNull() == "{" && tokens.lastOrNull() == "}")
        val result = mutableListOf<Pair<String, List<String>>>()
        var index = 1
        while (index < tokens.lastIndex) {
            val key = Json.parseToJsonElement(tokens[index]) as? JsonPrimitive
            require(key != null && key.isString && index + 2 < tokens.size && tokens[index + 1] == ":")
            index += 2
            val start = index
            var depth = 0
            while (index < tokens.size) {
                val token = tokens[index]
                if (depth == 0 && (token == "," || token == "}")) break
                if (token == "{" || token == "[") depth++
                if (token == "}" || token == "]") depth--
                require(depth >= 0)
                index++
            }
            require(index > start && index < tokens.size && depth == 0)
            result += key.content to tokens.subList(start, index)
            if (tokens[index] == ",") {
                index++
                require(index < tokens.lastIndex) { "Trailing comma in screen object." }
            } else {
                break
            }
        }
        return result
    }

    private fun List<Pair<String, List<String>>>.value(key: String): List<String> {
        val values = filter { it.first == key }
        require(values.size == 1) { "Missing or duplicate screen field." }
        return values.single().second
    }

    private fun stringToken(tokens: List<String>): String? =
        if (tokens.size == 1) runCatching {
            (Json.parseToJsonElement(tokens.single()) as? JsonPrimitive)
                ?.takeIf { it.isString }?.content
        }.getOrNull() else null

    private fun integerToken(tokens: List<String>, range: IntRange): Int {
        require(tokens.size == 1 && unsignedInteger.matches(tokens.single())) {
            "Expected exact unsigned screen integer token."
        }
        return tokens.single().toIntOrNull()?.takeIf { it in range }
            ?: error("Screen integer token is out of range.")
    }

    private fun List<Pair<String, List<String>>>.uniqueString(key: String): String? {
        val values = filter { it.first == key }
        return if (values.size == 1) stringToken(values.single().second) else null
    }

    private fun List<Pair<String, List<String>>>.uniqueCanonicalUuid(key: String): String? =
        uniqueString(key)?.takeIf(::isCanonicalUuidV4)

    private fun isBaselineJpeg(bytes: ByteArray, expectedWidth: Int, expectedHeight: Int): Boolean =
        runCatching { BaselineJpegValidator(bytes).validate(expectedWidth, expectedHeight) }.isSuccess
}
