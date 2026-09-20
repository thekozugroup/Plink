package app.plink.android.reconnect

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkAddress
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import app.plink.android.protocol.ReconnectEndpoint
import app.plink.android.protocol.ReconnectPayloadPolicy
import app.plink.android.transport.ObservedSocketTuple
import app.plink.android.transport.SocketChannelBinding
import java.io.Closeable
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.nio.channels.SocketChannel
import java.security.MessageDigest
import java.util.Collections
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

data class ReconnectInterfaceSnapshot(
    val name: String,
    val index: Int,
    val localIPv4: String,
    val prefixLength: Int,
    val up: Boolean,
    val loopback: Boolean,
    val pointToPoint: Boolean,
    val broadcast: Boolean,
    val vpn: Boolean,
    val matchingAndroidNetwork: Boolean
)

enum class ReconnectCandidateFailure {
    UNSUPPORTED_ENDPOINT,
    INELIGIBLE_INTERFACE,
    NO_CONNECTED_PREFIX_MATCH,
    SELF_NETWORK_OR_BROADCAST,
    UNAVAILABLE_NETWORK_OR_PERMISSION
}

sealed interface ReconnectCandidateDecision {
    data object Accepted : ReconnectCandidateDecision
    data class Rejected(val failure: ReconnectCandidateFailure) : ReconnectCandidateDecision
}

object ReconnectCandidatePolicy {
    fun evaluate(endpoint: String, interfaceSnapshot: ReconnectInterfaceSnapshot): ReconnectCandidateDecision {
        val parsed = runCatching {
            ReconnectEndpoint.parse(endpoint, ReconnectPayloadPolicy.reconnectPort)
        }.getOrElse {
            return ReconnectCandidateDecision.Rejected(ReconnectCandidateFailure.UNSUPPORTED_ENDPOINT)
        }
        if (!interfaceSnapshot.up || interfaceSnapshot.loopback || interfaceSnapshot.pointToPoint ||
            !interfaceSnapshot.broadcast || interfaceSnapshot.vpn || interfaceSnapshot.index <= 0 ||
            interfaceSnapshot.prefixLength !in 1..30
        ) {
            return ReconnectCandidateDecision.Rejected(ReconnectCandidateFailure.INELIGIBLE_INTERFACE)
        }
        val local = ipv4Value(interfaceSnapshot.localIPv4) ?: return ReconnectCandidateDecision.Rejected(
            ReconnectCandidateFailure.INELIGIBLE_INTERFACE
        )
        val peer = ipv4Value(parsed.address) ?: return ReconnectCandidateDecision.Rejected(
            ReconnectCandidateFailure.UNSUPPORTED_ENDPOINT
        )
        if (!isAllowedLocalAddress(local) || !isAllowedLocalAddress(peer)) {
            return ReconnectCandidateDecision.Rejected(ReconnectCandidateFailure.UNSUPPORTED_ENDPOINT)
        }
        val mask = -1 shl (32 - interfaceSnapshot.prefixLength)
        val network = local and mask
        val broadcast = network or mask.inv()
        if (peer == local || peer == network || peer == broadcast) {
            return ReconnectCandidateDecision.Rejected(ReconnectCandidateFailure.SELF_NETWORK_OR_BROADCAST)
        }
        if ((peer and mask) != network) {
            return ReconnectCandidateDecision.Rejected(ReconnectCandidateFailure.NO_CONNECTED_PREFIX_MATCH)
        }
        if (!interfaceSnapshot.matchingAndroidNetwork) {
            return ReconnectCandidateDecision.Rejected(ReconnectCandidateFailure.UNAVAILABLE_NETWORK_OR_PERMISSION)
        }
        return ReconnectCandidateDecision.Accepted
    }

    fun accepts(endpoint: String, interfaceSnapshot: ReconnectInterfaceSnapshot): Boolean =
        evaluate(endpoint, interfaceSnapshot) == ReconnectCandidateDecision.Accepted

    private fun ipv4Value(raw: String): Int? = runCatching {
        val endpoint = ReconnectEndpoint.parse("$raw:1")
        endpoint.address.split('.').fold(0) { value, octet -> (value shl 8) or octet.toInt() }
    }.getOrNull()

    private fun isAllowedLocalAddress(value: Int): Boolean {
        val first = value ushr 24 and 0xff
        val second = value ushr 16 and 0xff
        return first == 10 || first == 192 && second == 168 || first == 172 && second in 16..31 ||
            first == 169 && second == 254
    }
}

class VerifiedNetworkBinding internal constructor(
    val interfaceSnapshot: ReconnectInterfaceSnapshot,
    val peer: ReconnectEndpoint,
    val listenerPort: Int,
    val generation: Long,
    internal val network: Network,
    internal val linkProperties: ReconnectLinkPropertiesSnapshot
)

/** Immutable public-SDK values used to detect any relevant LinkProperties change. */
internal data class ReconnectLinkPropertiesSnapshot(
    val interfaceName: String?,
    val linkAddresses: List<String>,
    val routes: List<String>,
    val dnsServers: List<String>,
    val domains: String?,
    val mtu: Int?,
    val httpProxy: String?
)

private fun snapshotLinkProperties(properties: LinkProperties): ReconnectLinkPropertiesSnapshot =
    ReconnectLinkPropertiesSnapshot(
        interfaceName = properties.interfaceName,
        linkAddresses = properties.linkAddresses.mapNotNull {
            val address = it.address.hostAddress ?: return@mapNotNull null
            "$address/${it.prefixLength}"
        }.sorted(),
        routes = properties.routes.map {
            listOf(
                it.destination.toString(),
                it.gateway?.hostAddress.orEmpty(),
                it.getInterface().orEmpty(),
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) it.type.toString() else it.toString()
            ).joinToString("|")
        }.sorted(),
        dnsServers = properties.dnsServers.mapNotNull { it.hostAddress }.sorted(),
        domains = properties.domains,
        // Older public SDKs do not expose MTU. LinkProperties callbacks still
        // invalidate the connection on every change, including an MTU change.
        mtu = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) properties.mtu else null,
        httpProxy = properties.httpProxy?.toString()
    )

interface ReconnectLiveBinding {
    val interfaceSnapshot: ReconnectInterfaceSnapshot
    val peer: ReconnectEndpoint
    val listenerPort: Int
    val generation: Long
    val socketBinding: SocketChannelBinding
    fun validateCurrent()
}

class ReconnectNetworkResolver(context: Context) {
    private val connectivity = context.getSystemService(ConnectivityManager::class.java)
    private val generations = AtomicLong()

    fun currentInterfaces(): List<ReconnectInterfaceSnapshot> {
        val networks = connectivity.allNetworks.mapNotNull { network ->
            val capabilities = connectivity.getNetworkCapabilities(network) ?: return@mapNotNull null
            val properties = connectivity.getLinkProperties(network) ?: return@mapNotNull null
            Triple(network, capabilities, properties)
        }
        return Collections.list(NetworkInterface.getNetworkInterfaces()).flatMap { networkInterface ->
            networkInterface.interfaceAddresses.mapNotNull { address ->
                val local = address.address as? Inet4Address ?: return@mapNotNull null
                val localAddress = local.hostAddress ?: return@mapNotNull null
                val matching = networks.filter { (_, capabilities, properties) ->
                    capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN) &&
                        properties.interfaceName == networkInterface.name &&
                        properties.linkAddresses.any { it.address == local && it.prefixLength == address.networkPrefixLength.toInt() }
                }
                ReconnectInterfaceSnapshot(
                    name = networkInterface.name,
                    index = networkInterface.index,
                    localIPv4 = localAddress,
                    prefixLength = address.networkPrefixLength.toInt(),
                    up = runCatching { networkInterface.isUp }.getOrDefault(false),
                    loopback = runCatching { networkInterface.isLoopback }.getOrDefault(true),
                    pointToPoint = runCatching { networkInterface.isPointToPoint }.getOrDefault(true),
                    broadcast = address.broadcast is Inet4Address,
                    vpn = networks.any { (_, capabilities, properties) ->
                        properties.interfaceName == networkInterface.name &&
                            !capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
                    },
                    matchingAndroidNetwork = matching.size == 1
                )
            }
        }.sortedWith(compareBy({ it.name }, { it.localIPv4 }))
    }

    fun resolve(localAddress: String, peer: ReconnectEndpoint, listenerPort: Int): VerifiedNetworkBinding? {
        val snapshot = currentInterfaces().singleOrNull {
            it.localIPv4 == localAddress && ReconnectCandidatePolicy.accepts(peer.toString(), it)
        } ?: return null
        val local = InetAddress.getByName(snapshot.localIPv4)
        val matches = connectivity.allNetworks.mapNotNull { network ->
            val capabilities = connectivity.getNetworkCapabilities(network) ?: return@mapNotNull null
            val properties = connectivity.getLinkProperties(network) ?: return@mapNotNull null
            if (!capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN) ||
                properties.interfaceName != snapshot.name ||
                properties.linkAddresses.none { it.address == local && it.prefixLength == snapshot.prefixLength }
            ) null else network to properties
        }
        if (matches.size != 1) return null
        return VerifiedNetworkBinding(
            interfaceSnapshot = snapshot,
            peer = peer,
            listenerPort = listenerPort,
            generation = generations.incrementAndGet(),
            network = matches.single().first,
            linkProperties = snapshotLinkProperties(matches.single().second)
        )
    }

    fun resolveInbound(tuple: ObservedSocketTuple, macListenerPort: Int): VerifiedNetworkBinding? =
        resolve(tuple.localAddress, ReconnectEndpoint(tuple.remoteAddress, macListenerPort), tuple.localPort)

    fun socketBinding(binding: VerifiedNetworkBinding): SocketChannelBinding = AndroidNetworkSocketBinding(
        connectivity,
        binding
    )

    fun resolveLive(localAddress: String, peer: ReconnectEndpoint, listenerPort: Int): ReconnectLiveBinding? {
        val verified = resolve(localAddress, peer, listenerPort) ?: return null
        val channelBinding = socketBinding(verified)
        return object : ReconnectLiveBinding {
            override val interfaceSnapshot = verified.interfaceSnapshot
            override val peer = verified.peer
            override val listenerPort = verified.listenerPort
            override val generation = verified.generation
            override val socketBinding = channelBinding
            override fun validateCurrent() {
                AndroidNetworkSocketBinding.validateCurrent(connectivity, verified)
            }
        }
    }

    fun resolveInboundLive(tuple: ObservedSocketTuple, macListenerPort: Int): ReconnectLiveBinding? =
        resolveLive(tuple.localAddress, ReconnectEndpoint(tuple.remoteAddress, macListenerPort), tuple.localPort)
}

private class AndroidNetworkSocketBinding(
    private val connectivity: ConnectivityManager,
    private val binding: VerifiedNetworkBinding
) : SocketChannelBinding {
    override fun bindBeforeConnect(channel: SocketChannel) {
        validateCurrent()
        binding.network.bindSocket(channel.socket())
        channel.bind(InetSocketAddress(InetAddress.getByName(binding.interfaceSnapshot.localIPv4), 0))
    }

    override fun validateConnected(channel: SocketChannel) {
        validateCurrent()
        val local = channel.localAddress as? InetSocketAddress ?: error("Socket has no local endpoint.")
        val remote = channel.remoteAddress as? InetSocketAddress ?: error("Socket has no remote endpoint.")
        check(local.address is Inet4Address && local.address.hostAddress == binding.interfaceSnapshot.localIPv4) {
            "Socket local address changed."
        }
        check(remote.address is Inet4Address && remote.address.hostAddress == binding.peer.address && remote.port == binding.peer.port) {
            "Socket peer changed."
        }
    }

    private fun validateCurrent() {
        validateCurrent(connectivity, binding)
    }

    companion object {
        internal fun validateCurrent(connectivity: ConnectivityManager, binding: VerifiedNetworkBinding) {
            val capabilities = connectivity.getNetworkCapabilities(binding.network)
                ?: error("Bound Android Network is unavailable.")
            val properties = connectivity.getLinkProperties(binding.network)
                ?: error("Bound Android Network has no LinkProperties.")
            check(capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)) {
                "VPN Network is not allowed."
            }
            check(properties.interfaceName == binding.interfaceSnapshot.name) { "Network interface changed." }
            val local = InetAddress.getByName(binding.interfaceSnapshot.localIPv4)
            check(properties.linkAddresses.any {
                it.address == local && it.prefixLength == binding.interfaceSnapshot.prefixLength
            }) { "Network address or prefix changed." }
            check(snapshotLinkProperties(properties) == binding.linkProperties) {
                "Network routes or LinkProperties changed."
            }
        }
    }
}

/** Advertises only while the authenticated pair listener is bound. No network switch or tether action occurs. */
class ReconnectDiscovery(
    context: Context,
    private val onNetworkChanged: () -> Unit = {}
) : Closeable {
    private val appContext = context.applicationContext
    private val nsd = appContext.getSystemService(NsdManager::class.java)
    private val connectivity = appContext.getSystemService(ConnectivityManager::class.java)
    private val resolver = ReconnectNetworkResolver(appContext)
    private val _addresses = MutableStateFlow<List<String>>(emptyList())
    val addresses: StateFlow<List<String>> = _addresses.asStateFlow()
    private var registration: NsdManager.RegistrationListener? = null
    private var callbackRegistered = false

    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) = changed()
        override fun onLost(network: Network) = changed()
        override fun onLinkPropertiesChanged(network: Network, linkProperties: LinkProperties) = changed()
        override fun onCapabilitiesChanged(network: Network, networkCapabilities: NetworkCapabilities) = changed()
        private fun changed() {
            runCatching { refresh() }.onFailure { _addresses.value = emptyList() }
            onNetworkChanged()
        }
    }

    fun start(deviceId: String, port: Int) {
        require(port in 1..65535 && deviceId.toByteArray(Charsets.UTF_8).size in 1..128)
        refresh()
        if (!callbackRegistered) {
            val request = NetworkRequest.Builder()
                .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
                .build()
            connectivity.registerNetworkCallback(request, networkCallback)
            callbackRegistered = true
        }
        if (registration != null) return
        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(serviceInfo: NsdServiceInfo) = Unit
            override fun onRegistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) = Unit
            override fun onServiceUnregistered(serviceInfo: NsdServiceInfo) = Unit
            override fun onUnregistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) = Unit
        }
        val info = NsdServiceInfo().apply {
            serviceName = "Plink-${stableServiceSuffix(deviceId)}"
            serviceType = "_plink._tcp."
            setPort(port)
            setAttribute("reconnect", "1")
            setAttribute("deviceId", deviceId)
            setAttribute("platform", "android")
        }
        nsd.registerService(info, NsdManager.PROTOCOL_DNS_SD, listener)
        registration = listener
    }

    fun refresh() {
        _addresses.value = resolver.currentInterfaces()
            .filter {
                it.up && !it.loopback && !it.pointToPoint && it.broadcast && !it.vpn &&
                    it.matchingAndroidNetwork
            }
            .map { it.localIPv4 }
            .distinct()
            .take(4)
    }

    override fun close() {
        registration?.let { runCatching { nsd.unregisterService(it) } }
        registration = null
        if (callbackRegistered) runCatching { connectivity.unregisterNetworkCallback(networkCallback) }
        callbackRegistered = false
        _addresses.value = emptyList()
    }

    private fun stableServiceSuffix(deviceId: String): String = MessageDigest.getInstance("SHA-256")
        .digest(deviceId.toByteArray(Charsets.UTF_8))
        .take(8)
        .joinToString("") { "%02x".format(it) }
}
