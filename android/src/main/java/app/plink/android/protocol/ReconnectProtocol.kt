package app.plink.android.protocol

import java.net.Inet4Address
import java.net.InetAddress
import java.nio.CharBuffer
import java.nio.charset.CodingErrorAction
import java.time.Instant
import java.util.Base64
import java.util.UUID
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

data class ReconnectEndpoint(val address: String, val port: Int) {
    override fun toString(): String = "$address:$port"

    companion object {
        private val ipv4 = Regex("(?:0|[1-9][0-9]{0,2})(?:\\.(?:0|[1-9][0-9]{0,2})){3}")

        fun parse(raw: String, requiredPort: Int? = null): ReconnectEndpoint {
            val separator = raw.lastIndexOf(':')
            require(separator > 0 && separator == raw.indexOf(':')) { "Endpoint must be numeric IPv4:port." }
            val address = raw.substring(0, separator)
            val portToken = raw.substring(separator + 1)
            require(ipv4.matches(address) && portToken.matches(Regex("[1-9][0-9]{0,4}"))) {
                "Endpoint must be canonical numeric IPv4:port."
            }
            val octets = address.split('.').map(String::toInt)
            require(octets.all { it in 0..255 }) { "Endpoint IPv4 octet is invalid." }
            val port = portToken.toInt()
            require(port in 1..65535 && (requiredPort == null || port == requiredPort)) {
                "Endpoint port is invalid."
            }
            val parsed = InetAddress.getByAddress(octets.map(Int::toByte).toByteArray())
            require(parsed is Inet4Address && parsed.hostAddress == address) { "Endpoint IPv4 is not canonical." }
            return ReconnectEndpoint(address, port)
        }
    }
}

data class ReconnectPayload(
    val messageId: String,
    val mac: ReconnectEndpoint,
    val phone: ReconnectEndpoint,
    val proof: String? = null,
    val reverseProof: String? = null
)

object ReconnectPayloadPolicy {
    const val maxPlaintextBytes = 2_048
    const val maxEncryptedJsonBytes = 4_096
    const val reconnectPort = 45_731

    val eventTypes = linkedSetOf(
        PlinkEventType.ReconnectHello,
        PlinkEventType.ReconnectChallenge,
        PlinkEventType.ReconnectProof,
        PlinkEventType.ReconnectReverse,
        PlinkEventType.ReconnectReverseProof,
        PlinkEventType.ReconnectReady,
        PlinkEventType.ReconnectCommit,
        PlinkEventType.ReconnectDone
    )

    private val envelopeFields = setOf(
        "version", "id", "sentAt", "sourceDeviceId", "targetDeviceId", "requiresAck", "type", "payload"
    )
    private val nonceFields = setOf("m", "p", "r")
    private val stringEnvelopeFields = setOf("id", "sentAt", "sourceDeviceId", "targetDeviceId", "type")
    private val uuidV4 = Regex("[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}")
    private val wholeSecondUtc = Regex("[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z")
    private val tokenPattern = Regex(""""(?:[^"\\]|\\.)*+"|-?[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?|true|false|null|[{}\[\]:,]""")

    fun requireAcceptable(envelope: PlinkEnvelope) {
        if (envelope.type !in eventTypes) return
        require(envelope.version == 1 && !envelope.requiresAck) { "Invalid reconnect envelope flags." }
        require(isCanonicalUuidV4(envelope.id)) { "Invalid reconnect envelope id." }
        requireCanonicalTimestamp(envelope.sentAt)
        requireDeviceId(envelope.sourceDeviceId)
        requireDeviceId(envelope.targetDeviceId)
        requireFields(envelope.type, envelope.payload.keys)
        require(integer(envelope.payload, "v") == 1) { "Reconnect version must be 1." }
        nonce(envelope.payload, "m")
        if ("p" in envelope.payload) nonce(envelope.payload, "p")
        if ("r" in envelope.payload) nonce(envelope.payload, "r")
        parseWireEndpoint(text(envelope.payload, "mac"))
        parseWireEndpoint(text(envelope.payload, "phone"))
        require(envelope.encode().toByteArray(Charsets.UTF_8).size <= maxPlaintextBytes) {
            "Reconnect plaintext exceeds $maxPlaintextBytes UTF-8 bytes."
        }
    }

    fun requireCanonicalTimestamp(value: String) {
        require(wholeSecondUtc.matches(value) && runCatching {
            Instant.parse(value).toString() == value
        }.getOrDefault(false)) { "Invalid reconnect timestamp." }
    }

    fun payload(envelope: PlinkEnvelope): ReconnectPayload {
        requireAcceptable(envelope)
        return ReconnectPayload(
            messageId = text(envelope.payload, "m"),
            mac = parseWireEndpoint(text(envelope.payload, "mac")),
            phone = parseWireEndpoint(text(envelope.payload, "phone")),
            proof = envelope.payload["p"]?.let { text(envelope.payload, "p") },
            reverseProof = envelope.payload["r"]?.let { text(envelope.payload, "r") }
        )
    }

    fun envelope(
        type: String,
        sourceDeviceId: String,
        targetDeviceId: String,
        payload: ReconnectPayload,
        id: String = UUID.randomUUID().toString(),
        sentAt: String = Instant.now().truncatedTo(java.time.temporal.ChronoUnit.SECONDS).toString()
    ): PlinkEnvelope {
        require(type in eventTypes)
        val value = PlinkEnvelope(
            id = id,
            type = type,
            sentAt = sentAt,
            sourceDeviceId = sourceDeviceId,
            targetDeviceId = targetDeviceId,
            requiresAck = false,
            payload = buildJsonObject {
                put("v", 1)
                put("m", payload.messageId)
                put("mac", payload.mac.toString())
                put("phone", payload.phone.toString())
                payload.proof?.let { put("p", it) }
                payload.reverseProof?.let { put("r", it) }
            }
        )
        requireAcceptable(value)
        return value
    }

    /** Validates exact JSON tokens before kotlinx.serialization can discard duplicates or numeric spelling. */
    fun validateRawJSON(raw: String) {
        val tokens = tokenize(raw)
        val root = members(tokens)
        val types = root.filter { it.first == "type" }.mapNotNull { stringToken(it.second) }
        if (types.none { it in eventTypes }) return
        require(raw.toByteArray(Charsets.UTF_8).size <= maxPlaintextBytes) {
            "Reconnect plaintext exceeds $maxPlaintextBytes UTF-8 bytes."
        }
        require(root.map { it.first }.toSet().size == root.size) { "Duplicate reconnect envelope key." }
        require(root.map { it.first }.toSet() == envelopeFields) { "Invalid reconnect envelope fields." }
        val values = root.toMap()
        require(values.getValue("version") == listOf("1")) { "Reconnect version must be integer token 1." }
        require(values.getValue("requiresAck") == listOf("false")) { "Reconnect requiresAck must be false." }
        for (field in stringEnvelopeFields) {
            require(stringToken(values.getValue(field)) != null) { "Reconnect $field must be text." }
        }
        val type = requireNotNull(stringToken(values.getValue("type")))
        require(type in eventTypes)
        val id = requireNotNull(stringToken(values.getValue("id")))
        val sentAt = requireNotNull(stringToken(values.getValue("sentAt")))
        require(isCanonicalUuidV4(id)) { "Invalid reconnect envelope id." }
        require(wholeSecondUtc.matches(sentAt) && runCatching { Instant.parse(sentAt).toString() == sentAt }.getOrDefault(false)) {
            "Invalid reconnect timestamp."
        }
        requireDeviceId(requireNotNull(stringToken(values.getValue("sourceDeviceId"))))
        requireDeviceId(requireNotNull(stringToken(values.getValue("targetDeviceId"))))

        val payload = members(values.getValue("payload"))
        require(payload.map { it.first }.toSet().size == payload.size) { "Duplicate reconnect payload key." }
        requireFields(type, payload.map { it.first }.toSet())
        val fields = payload.toMap()
        require(fields.getValue("v") == listOf("1")) { "Reconnect v must be integer token 1." }
        for (field in nonceFields.intersect(fields.keys)) {
            requireCanonicalNonce(requireNotNull(stringToken(fields.getValue(field))))
        }
        parseWireEndpoint(requireNotNull(stringToken(fields.getValue("mac"))))
        parseWireEndpoint(requireNotNull(stringToken(fields.getValue("phone"))))
    }

    private fun requireFields(type: String, actual: Set<String>) {
        val expected = when (type) {
            PlinkEventType.ReconnectHello -> setOf("v", "m", "mac", "phone")
            PlinkEventType.ReconnectChallenge, PlinkEventType.ReconnectProof -> setOf("v", "m", "p", "mac", "phone")
            else -> setOf("v", "m", "p", "r", "mac", "phone")
        }
        require(actual == expected) { "Invalid $type payload fields." }
    }

    private fun text(payload: JsonObject, key: String): String {
        val value = payload[key] as? JsonPrimitive
        require(value != null && value.isString) { "Reconnect $key must be text." }
        return value.content
    }

    private fun integer(payload: JsonObject, key: String): Int {
        val value = payload[key] as? JsonPrimitive
        require(value != null && !value.isString && value.content.matches(Regex("0|[1-9][0-9]*"))) {
            "Reconnect $key must be an integer."
        }
        return requireNotNull(value.content.toIntOrNull())
    }

    private fun nonce(payload: JsonObject, key: String): String = text(payload, key).also(::requireCanonicalNonce)

    private fun requireCanonicalNonce(value: String) {
        require(value.length == 43 && '=' !in value && value.all { it.isLetterOrDigit() || it == '-' || it == '_' }) {
            "Reconnect nonce is not canonical base64url."
        }
        val decoded = runCatching { Base64.getUrlDecoder().decode(value) }.getOrNull()
        require(decoded != null && decoded.size == 32 && Base64.getUrlEncoder().withoutPadding().encodeToString(decoded) == value) {
            "Reconnect nonce must encode 32 bytes canonically."
        }
    }

    private fun requireDeviceId(value: String) {
        val bytes = runCatching {
            Charsets.UTF_8.newEncoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .encode(CharBuffer.wrap(value))
                .remaining()
        }.getOrNull()
        require(bytes != null && bytes in 1..128) { "Reconnect device id is invalid." }
    }

    private fun isCanonicalUuidV4(value: String): Boolean = uuidV4.matches(value) &&
        runCatching { UUID.fromString(value).toString() == value }.getOrDefault(false)

    internal fun parseWireEndpoint(raw: String): ReconnectEndpoint {
        val testPorts = ReconnectProtocolTestHooks.endpointPortsOverride
        return if (testPorts == null) {
            ReconnectEndpoint.parse(raw, reconnectPort)
        } else {
            ReconnectEndpoint.parse(raw).also {
                require(testPorts.isEmpty() || it.port in testPorts) { "Endpoint port is not enabled for this test." }
            }
        }
    }

    private fun tokenize(raw: String): List<String> {
        Json.parseToJsonElement(raw)
        val matches = tokenPattern.findAll(raw).toList()
        var end = 0
        for (match in matches) {
            require(raw.substring(end, match.range.first).all { it in "\t\n\r " }) { "Invalid reconnect JSON token." }
            end = match.range.last + 1
        }
        require(raw.substring(end).all { it in "\t\n\r " }) { "Invalid reconnect JSON token." }
        return matches.map { it.value }
    }

    private fun stringToken(tokens: List<String>): String? = if (tokens.size != 1) null else
        (Json.parseToJsonElement(tokens.single()) as? JsonPrimitive)?.takeIf { it.isString }?.content

    /** Splits an object without normalizing duplicate keys or primitive token spelling. */
    private fun members(tokens: List<String>): List<Pair<String, List<String>>> {
        require(tokens.firstOrNull() == "{" && tokens.lastOrNull() == "}") { "Reconnect JSON must be an object." }
        val result = mutableListOf<Pair<String, List<String>>>()
        var index = 1
        while (index < tokens.lastIndex) {
            val key = (Json.parseToJsonElement(tokens[index]) as? JsonPrimitive)?.takeIf { it.isString }
            require(key != null && index + 2 < tokens.size && tokens[index + 1] == ":") { "Invalid reconnect object." }
            index += 2
            val start = index
            var depth = 0
            while (index < tokens.size) {
                val token = tokens[index]
                if (depth == 0 && (token == "," || token == "}")) break
                if (token == "{" || token == "[") depth++
                if (token == "}" || token == "]") depth--
                require(depth >= 0) { "Invalid reconnect object." }
                index++
            }
            require(index > start && index < tokens.size && depth == 0) { "Invalid reconnect object." }
            result += key.content to tokens.subList(start, index)
            if (tokens[index] == ",") {
                index++
                require(index < tokens.lastIndex) { "Invalid trailing comma." }
            } else break
        }
        return result
    }
}

/** Instrumentation-only override. Production never enables it. */
internal object ReconnectProtocolTestHooks {
    @Volatile var endpointPortsOverride: Set<Int>? = null
}
