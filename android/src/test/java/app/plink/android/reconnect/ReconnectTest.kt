package app.plink.android.reconnect

import java.io.File
import java.util.Base64
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class ReconnectTest {
    @get:Rule val temporaryFolder = TemporaryFolder()

    @Test
    fun frozenNetworkCasesUseProductionCandidatePolicy() {
        val fixture = fixture("shared/protocol/v1/reconnect/network-cases.json")
        for (entry in fixture.getValue("cases").jsonArray) {
            val item = entry.jsonObject
            val network = item.getValue("interface").jsonObject
            val snapshot = ReconnectInterfaceSnapshot(
                name = network.text("name"),
                index = network.number("index"),
                localIPv4 = network.text("localIPv4"),
                prefixLength = network.number("prefixLength"),
                up = network.flag("up"),
                loopback = network.flag("loopback"),
                pointToPoint = network.flag("pointToPoint"),
                broadcast = network.flag("broadcast"),
                vpn = network.flag("vpn"),
                matchingAndroidNetwork = network.flag("matchingAndroidNetwork")
            )
            assertEquals(
                item.text("name"),
                item.getValue("expectedAndroid").jsonPrimitive.boolean,
                ReconnectCandidatePolicy.accepts(item.text("endpoint"), snapshot)
            )
        }
    }

    @Test
    fun frozenEndpointVectorsUseProductionAuthenticationAndFilename() {
        val fixture = fixture("shared/protocol/v1/reconnect/endpoint-store-vectors.json")
        for (entry in fixture.getValue("vectors").jsonArray) {
            val item = entry.jsonObject
            val source = item.getValue("record").jsonObject
            val key = Base64.getDecoder().decode(item.text("sessionKeyBase64"))
            val unsigned = ReconnectEndpointRecord(
                version = source.number("version"),
                localID = source.text("localID"),
                peerID = source.text("peerID"),
                sessionID = source.text("sessionID"),
                endpoint = source.text("endpoint"),
                proofID = source.text("proofID"),
                tag = ""
            )
            assertArrayEquals(
                item.text("name"),
                Base64.getDecoder().decode(item.text("signingInputBase64")),
                ReconnectEndpointStore.signingInput(unsigned)
            )
            assertEquals(
                item.text("name"),
                source.text("tag"),
                ReconnectEndpointStore.authenticate(unsigned, key).tag
            )
            assertEquals(
                item.text("name"),
                item.text("fileName"),
                ReconnectEndpointStore.fileName(key, unsigned.localID, unsigned.peerID)
            )
            key.fill(0)
        }
    }

    @Test
    fun cancellationBetweenStagingAndRenameLeavesNoEndpointHint() {
        val now = 1_000L
        val owner = ReconnectLifecycleOwner { now }
        val token = requireNotNull(owner.begin(10_000))
        val directory = temporaryFolder.newFolder("cancel-before-rename")
        val store = ReconnectEndpointStore(directory) {
            owner.invalidate(token) { _, _ -> false }
        }
        val key = ByteArray(32) { it.toByte() }
        val proof = Base64.getUrlEncoder().withoutPadding().encodeToString(ByteArray(32) { 7 })

        assertThrows(IllegalStateException::class.java) {
            store.commit(
                localID = "pixel",
                peerID = "mac",
                sessionID = "session",
                endpoint = "192.168.50.10:45731",
                proofID = proof,
                sessionKey = key,
                attemptToken = token,
                lifecycleOwner = owner,
                pairIsCurrent = { true }
            )
        }
        assertNull(store.load("pixel", "mac", "session", key))
        assertTrue(directory.listFiles().orEmpty().none { it.extension == "tmp" })
    }

    @Test
    fun cancelAfterDonePreventsPublicationAndOldTokenCannotReviveSameBinding() {
        val now = 2_000L
        val owner = ReconnectLifecycleOwner { now }
        val old = requireNotNull(owner.begin(10_000))
        var publications = 0

        owner.invalidate(old) { _, _ -> false }
        assertFalse(owner.publish(old, { true }) { publications += 1; true })

        val replacement = requireNotNull(owner.begin(10_000))
        val sameBinding = Any()
        var publishedBinding: Any? = null
        assertFalse(owner.publish(old, { true }) { publishedBinding = sameBinding; true })
        assertTrue(owner.publish(replacement, { true }) {
            publications += 1
            publishedBinding = sameBinding
            true
        })
        assertEquals(1, publications)
        assertTrue(publishedBinding === sameBinding)
    }

    @Test
    fun expiredAttemptCannotRenameOrPublish() {
        var now = 3_000L
        val owner = ReconnectLifecycleOwner { now }
        val token = requireNotNull(owner.begin(50))
        now += 50
        var operationRan = false

        assertNull(owner.commit(token, { true }) { operationRan = true })
        assertFalse(owner.publish(token, { true }) { operationRan = true; true })
        assertFalse(operationRan)
    }

    private fun fixture(path: String) = Json.parseToJsonElement(
        generateSequence(File(requireNotNull(System.getProperty("user.dir")))) { it.parentFile }
            .map { File(it, path) }
            .first(File::isFile)
            .readText()
    ).jsonObject

    private fun kotlinx.serialization.json.JsonObject.text(key: String) = getValue(key).jsonPrimitive.content
    private fun kotlinx.serialization.json.JsonObject.number(key: String) = getValue(key).jsonPrimitive.int
    private fun kotlinx.serialization.json.JsonObject.flag(key: String) = getValue(key).jsonPrimitive.boolean
}
