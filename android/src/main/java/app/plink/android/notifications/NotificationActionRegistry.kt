package app.plink.android.notifications

import app.plink.android.protocol.NotificationActionsPolicy as Policy
import app.plink.android.protocol.PlinkEnvelope
import app.plink.android.protocol.PlinkEventType
import kotlinx.serialization.json.*
import java.time.Instant
import java.util.UUID

class NotificationActionFailure(val code: String) : Exception(code)

/** One claim shared by the legacy and v1 routes. All access uses ReplyDispatchLock. */
class NotificationActionClaim {
    private var live = true
    private var consumed = false
    fun take(): Boolean = ReplyDispatchLock.serialized {
        if (!live || consumed) false else { consumed = true; true }
    }
    fun available(): Boolean = ReplyDispatchLock.serialized { live && !consumed }
    internal fun revoke() { live = false }
}

data class NotificationActionSpec(
    val label: String,
    val kind: String,
    val authenticationRequired: Boolean = false,
    val inputLabel: String? = null,
    val destructive: Boolean = false,
    val reason: String? = null,
    val unlocked: () -> Boolean? = { null },
    val execute: (String?) -> Unit = {}
)

data class NotificationActionOffer(val envelope: PlinkEnvelope, val claims: Map<Int, NotificationActionClaim>)
data class NotificationActionSnapshot internal constructor(
    internal val session: String, internal val epoch: Long, internal val revision: Long,
    internal val keys: Set<String>
)

/** Current-admission authority only. No disk storage, timers, retries or notification history. */
class NotificationActionRegistry(private val nowMillis: () -> Long = System::currentTimeMillis) {
    private data class Live(val token: String, val spec: NotificationActionSpec, val claim: NotificationActionClaim)
    private data class Entry(val envelope: PlinkEnvelope, val expires: Long, val actions: Map<Int, Live>)
    private var local = ""
    private var peer = ""
    private var generation = -1L
    private var session: String? = null
    private var epoch = 1L
    private var revision = 0L
    private var floor = 0L
    private var listener = false
    private var feature = false
    private var enabled = false
    private val entries = linkedMapOf<String, Entry>()
    private val keyRevisions = linkedMapOf<String, Long>()
    var onState: (PlinkEnvelope) -> Unit = {}
    var onRetireKey: (String) -> Unit = {}

    fun beginSession(localDeviceId: String, peerDeviceId: String, generation: Long) = ReplyDispatchLock.serialized {
        clear(); local = localDeviceId; peer = peerDeviceId; this.generation = generation
        session = UUID.randomUUID().toString(); epoch = 1; revision = 0; floor = 0; enabled = false
    }
    fun retireSession() = ReplyDispatchLock.serialized { clear(); session = null; enabled = false; generation = -1 }
    fun setListenerAvailable(value: Boolean, forceReset: Boolean = false) = ReplyDispatchLock.serialized {
        if (listener != value || forceReset) { listener = value; revokeEpoch() }
    }
    fun setFeatureEnabled(value: Boolean) = ReplyDispatchLock.serialized {
        if (feature != value) { feature = value; revokeEpoch() }
    }
    private fun available() = session != null && listener && feature
    private fun clear() { entries.keys.toList().forEach(::remove); keyRevisions.clear() }
    private fun revokeEpoch() {
        clear()
        if (session == null) return
        if (epoch >= Policy.MAX_INTEGER) { retireSession(); return }
        epoch++
        if (enabled) state()?.let(onState)
    }
    fun state(): PlinkEnvelope? = ReplyDispatchLock.serialized {
        if (!enabled || session == null) null else envelope(Policy.State, buildJsonObject {
            common(); put("actionsEpoch", epoch); put("state", if (available()) "enabled" else "disabled")
        })
    }
    fun currentSession(): String? = ReplyDispatchLock.serialized { session }
    fun liveSetCount(): Int = ReplyDispatchLock.serialized { entries.size }
    private fun JsonObjectBuilder.common() { put("actionsVersion", 1); put("actionsSession", session!!) }
    private fun envelope(type: String, payload: JsonObject) = PlinkEnvelope(
        id = UUID.randomUUID().toString(), type = type, sentAt = Instant.ofEpochMilli(nowMillis()).toString(),
        sourceDeviceId = local, targetDeviceId = peer, payload = payload
    )
    private fun touch(key: String): Long? {
        if (revision >= Policy.MAX_INTEGER) { retireSession(); return null }
        revision++
        keyRevisions.remove(key); keyRevisions[key] = revision
        while (keyRevisions.size > 128) {
            val oldest = keyRevisions.entries.first(); floor = maxOf(floor, oldest.value); keyRevisions.remove(oldest.key)
        }
        return revision
    }
    private fun remove(key: String) {
        entries.remove(key)?.actions?.values?.forEach { it.claim.revoke() }
        onRetireKey(key)
    }
    fun invalidateKey(key: String) = ReplyDispatchLock.serialized {
        remove(key)
        if (session != null) touch(key)
        Unit
    }

    fun offer(source: PlinkEnvelope, specs: List<NotificationActionSpec>, removed: Boolean = false): NotificationActionOffer? = ReplyDispatchLock.serialized {
        if (session == null || source.sourceDeviceId != local || source.targetDeviceId != peer || source.type != PlinkEventType.MessageReceived) return@serialized null
        val key = runCatching { Policy.string(source.payload, "notificationKey", 500) }.getOrNull() ?: return@serialized null
        if (runCatching { Policy.string(source.payload, "packageName", 300) }.isFailure) return@serialized null
        remove(key)
        val next = touch(key) ?: return@serialized null
        val issuedAtMillis = nowMillis()
        if (issuedAtMillis !in 0..(Policy.MAX_INTEGER - 600_000)) {
            retireSession()
            return@serialized null
        }
        val expires = issuedAtMillis + 600_000
        val selected = if (removed || !available()) emptyList() else specs.take(10)
        val live = selected.mapIndexedNotNull { i, spec ->
            if (spec.kind in setOf("invoke", "text")) i to Live(UUID.randomUUID().toString(), spec, NotificationActionClaim()) else null
        }.toMap()
        val fields = buildJsonObject {
            common(); put("actionsEpoch", epoch); put("actionsRevision", next); put("actionsExpiresAtMs", expires)
            put("actionsCount", selected.size); put("actionsOverflowCount", if (removed || !available()) 0 else maxOf(0, specs.size - 10))
            selected.forEachIndexed { i, spec ->
                val prefix = "action$i"
                put(prefix + "Label", spec.label); put(prefix + "Kind", spec.kind)
                put(prefix + "AuthenticationRequired", spec.authenticationRequired)
                if (spec.destructive) put(prefix + "Destructive", true)
                spec.inputLabel?.let { put(prefix + "InputLabel", it) }
                spec.reason?.let { put(prefix + "Reason", it) }
                live[i]?.let { put(prefix + "Token", it.token) }
            }
        }
        val offered = source.copy(sentAt = Instant.ofEpochMilli(issuedAtMillis).toString(),
            payload = JsonObject(source.payload.filterKeys { !Policy.reserved(it) } + fields +
            if (removed) mapOf("removed" to JsonPrimitive(true)) else emptyMap()))
        if (!Policy.hasValidOffer(offered) || offered.encode().toByteArray(Charsets.UTF_8).size > 65_536) {
            live.values.forEach { it.claim.revoke() }; return@serialized null
        }
        if (!removed) {
            entries[key] = Entry(offered, expires, live)
            while (entries.size > 128) remove(entries.keys.first())
        }
        NotificationActionOffer(offered, live.mapValues { it.value.claim })
    }

    fun captureSnapshot(): NotificationActionSnapshot? = ReplyDispatchLock.serialized {
        if (!available()) null else NotificationActionSnapshot(session!!, epoch, revision, entries.keys.toSet())
    }
    fun canApplySnapshot(snapshot: NotificationActionSnapshot, key: String): Boolean = ReplyDispatchLock.serialized {
        available() && snapshot.session == session && snapshot.epoch == epoch && snapshot.revision >= floor &&
            (keyRevisions[key] ?: 0) <= snapshot.revision
    }
    fun removeMissing(snapshot: NotificationActionSnapshot, actualKeys: Set<String>): List<PlinkEnvelope> = ReplyDispatchLock.serialized {
        snapshot.keys.filter { it !in actualKeys && canApplySnapshot(snapshot, it) }.mapNotNull { key ->
            val old = entries[key]?.envelope ?: return@mapNotNull null
            val tombstone = old.copy(id = UUID.randomUUID().toString(), payload = buildJsonObject {
                put("sender", "Phone"); put("preview", "Notification removed."); put("canReply", false)
                put("packageName", old.payload.getValue("packageName")); put("notificationKey", key)
            })
            offer(tombstone, emptyList(), removed = true)?.envelope
        }
    }

    /** Caller additionally holds the existing ordinary-admission gate through this synchronous dispatch. */
    fun handle(command: PlinkEnvelope, currentGeneration: Long, authorized: () -> Boolean = { true }): PlinkEnvelope = ReplyDispatchLock.serialized {
        val requestedSession = (command.payload["actionsSession"] as? JsonPrimitive)?.content.orEmpty()
        var code: String? = null
        var status = "dispatched"
        try {
            try { Policy.requireAcceptable(command) } catch (_: Exception) { fail("invalid_action") }
            if (command.type !in setOf(Policy.Enable, Policy.Invoke)) fail("invalid_action")
            if (!authorized() || session == null || currentGeneration != generation || command.sourceDeviceId != peer || command.targetDeviceId != local || requestedSession != session) fail("stale_action")
            if (command.type == Policy.Enable) { enabled = true; status = "enabled" }
            else {
                if (!enabled) fail("action_not_enabled")
                if (!available()) fail("actions_disabled")
                if (Policy.integer(command.payload, "actionsEpoch", 1) != epoch) fail("stale_action")
                val key = Policy.string(command.payload, "notificationKey")
                val entry = entries[key] ?: fail("stale_action")
                if (entry.expires <= nowMillis()) { entry.actions.values.forEach { it.claim.revoke() }; fail("action_expired") }
                if (Policy.string(command.payload, "sourceEnvelopeId") != entry.envelope.id || command.payload["packageName"] != entry.envelope.payload["packageName"]) fail("stale_action")
                val live = entry.actions[Policy.integer(command.payload, "actionIndex", 0, 9).toInt()] ?: fail("unsupported_input")
                if (Policy.string(command.payload, "actionToken") != live.token || !live.claim.available()) fail("stale_action")
                val text = command.payload["text"]?.let { Policy.string(command.payload, "text") }
                if ((live.spec.kind == "text") != (text != null)) fail("invalid_action")
                if (live.spec.authenticationRequired && runCatching(live.spec.unlocked).getOrNull() != true) fail("phone_locked")
                if (!authorized()) fail("stale_action")
                if (!live.claim.take()) fail("stale_action")
                try { live.spec.execute(text) } catch (failure: NotificationActionFailure) { throw failure }
                catch (_: Exception) { fail("action_canceled") }
            }
        } catch (failure: NotificationActionFailure) { code = failure.code }
        return@serialized envelope(if (code == null) PlinkEventType.Ack else PlinkEventType.Error, buildJsonObject {
            put("eventId", command.id); put("action", command.type); put("actionsVersion", 1); put("actionsSession", requestedSession)
            if (code == null) { put("status", status); if (command.type == Policy.Enable) put("actionsEpoch", epoch) }
            else { put("code", code); put("message", if (code == "phone_locked") "Unlock your phone." else "This action is no longer available. Check your phone.") }
        })
    }
    private fun fail(code: String): Nothing = throw NotificationActionFailure(code)
}
