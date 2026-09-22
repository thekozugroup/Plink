package app.plink.android.protocol

import kotlinx.serialization.json.*

/** Scalar extension validation. A bad offer loses capabilities, never ordinary message text. */
object NotificationActionsPolicy {
    const val Enable = "notification.actions.enable"
    const val State = "notification.actions.state"
    const val Invoke = "notification.action"
    const val MAX_INTEGER = 9_007_199_254_740_991L
    val eventTypes = setOf(Enable, State, Invoke)
    private val uuid = Regex("[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}")
    private val indexed = Regex("action[0-9].*")
    private val reasons = setOf("missing_intent", "data_input", "choice_input", "multiple_inputs", "invalid_label", "unsupported_input", "immutable_input")
    val errors = setOf("phone_locked", "stale_action", "action_expired", "actions_disabled", "action_not_enabled", "unsupported_input", "action_canceled", "invalid_action")
    fun reserved(key: String) = key.startsWith("actions") || indexed.matches(key)
    fun validLabel(value: String): Boolean = value.isNotBlank() && validUnicode(value) &&
        value.codePointCount(0, value.length) <= 128 && value.toByteArray(Charsets.UTF_8).size <= 512
    private fun validUnicode(value: String): Boolean {
        var index = 0
        while (index < value.length) {
            val c = value[index++]
            if (c.isHighSurrogate()) { if (index == value.length || !value[index++].isLowSurrogate()) return false }
            else if (c.isLowSurrogate()) return false
        }
        return true
    }
    fun string(payload: JsonObject, key: String, maxScalars: Int = Int.MAX_VALUE): String {
        val value = payload[key] as? JsonPrimitive
        require(value != null && value.isString)
        return value.content.also { require(it.isNotBlank() && validUnicode(it) && it.codePointCount(0, it.length) <= maxScalars) }
    }
    fun integer(payload: JsonObject, key: String, minimum: Long = 0, maximum: Long = MAX_INTEGER): Long {
        val value = payload[key] as? JsonPrimitive
        require(value != null && !value.isString && Regex("-?(0|[1-9][0-9]*)").matches(value.content))
        return value.content.toLongOrNull().also { require(it != null && it in minimum..maximum) }!!
    }
    private fun bool(payload: JsonObject, key: String): Boolean {
        val value = payload[key] as? JsonPrimitive
        require(value != null && !value.isString && value.booleanOrNull != null)
        return value.boolean
    }
    private fun common(payload: JsonObject) {
        integer(payload, "actionsVersion", 1, 1)
        require(uuid.matches(string(payload, "actionsSession")))
    }
    fun hasValidOffer(envelope: PlinkEnvelope): Boolean = runCatching {
        require(envelope.type == PlinkEventType.MessageReceived)
        val p = envelope.payload
        common(p); integer(p, "actionsEpoch", 1); integer(p, "actionsRevision", 1)
        integer(p, "actionsExpiresAtMs"); integer(p, "actionsOverflowCount")
        string(p, "packageName", 300); string(p, "notificationKey", 500)
        require(envelope.id.isNotBlank() && envelope.id.codePointCount(0, envelope.id.length) <= 200)
        val count = integer(p, "actionsCount", 0, 10).toInt()
        if ((p["removed"] as? JsonPrimitive)?.booleanOrNull == true) require(count == 0)
        val keys = mutableSetOf("actionsVersion", "actionsSession", "actionsEpoch", "actionsRevision", "actionsExpiresAtMs", "actionsCount", "actionsOverflowCount")
        repeat(count) { i ->
            val prefix = "action$i"
            require(validLabel(string(p, prefix + "Label")))
            bool(p, prefix + "AuthenticationRequired")
            keys += listOf(prefix + "Label", prefix + "Kind", prefix + "AuthenticationRequired")
            if (prefix + "Destructive" in p) { bool(p, prefix + "Destructive"); keys += prefix + "Destructive" }
            when (string(p, prefix + "Kind")) {
                "invoke", "text" -> {
                    require(uuid.matches(string(p, prefix + "Token"))); keys += prefix + "Token"
                    if (p[prefix + "Kind"]?.jsonPrimitive?.content == "text" && prefix + "InputLabel" in p) {
                        require(validLabel(string(p, prefix + "InputLabel"))); keys += prefix + "InputLabel"
                    }
                }
                "phone" -> { require(string(p, prefix + "Reason") in reasons); keys += prefix + "Reason" }
                else -> error("Invalid action kind")
            }
        }
        require(p.keys.filter(::reserved).all { it in keys })
    }.isSuccess

    fun requireAcceptable(envelope: PlinkEnvelope) {
        val p = envelope.payload
        when (envelope.type) {
            Enable -> {
                common(p); require(envelope.requiresAck)
                require(p.keys == setOf("actionsVersion", "actionsSession"))
            }
            State -> {
                common(p); integer(p, "actionsEpoch", 1)
                require(string(p, "state") in setOf("enabled", "disabled"))
                require(p.keys == setOf("actionsVersion", "actionsSession", "actionsEpoch", "state"))
            }
            Invoke -> {
                common(p); require(envelope.requiresAck); integer(p, "actionsEpoch", 1)
                string(p, "sourceEnvelopeId", 200); string(p, "packageName", 300); string(p, "notificationKey", 500)
                integer(p, "actionIndex", 0, 9); require(uuid.matches(string(p, "actionToken")))
                val keys = setOf("actionsVersion", "actionsSession", "actionsEpoch", "sourceEnvelopeId", "packageName", "notificationKey", "actionIndex", "actionToken")
                if ("text" in p) require(string(p, "text").length <= 4000)
                require(p.keys == keys || p.keys == keys + "text")
            }
            PlinkEventType.Ack, PlinkEventType.Error -> if (p["action"]?.let { (it as? JsonPrimitive)?.content } in setOf(Enable, Invoke)) {
                common(p); string(p, "eventId", 200)
                val action = string(p, "action")
                if (envelope.type == PlinkEventType.Ack) {
                    require(string(p, "status") == if (action == Enable) "enabled" else "dispatched")
                    if (action == Enable) integer(p, "actionsEpoch", 1)
                } else require(string(p, "code") in errors)
            }
        }
    }
}
