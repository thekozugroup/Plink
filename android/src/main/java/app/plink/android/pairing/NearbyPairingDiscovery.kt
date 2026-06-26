package app.plink.android.pairing

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Handler
import android.os.Looper
import java.net.InetAddress

data class DiscoveredPairingOffer(
    val serviceName: String,
    val host: String,
    val port: Int,
    val offer: PairingOffer
)

object NearbyPairingOfferParser {
    const val SERVICE_TYPE = "_plink._tcp."

    fun parse(
        serviceName: String,
        attributes: Map<String, ByteArray>,
        host: String?,
        port: Int
    ): DiscoveredPairingOffer? {
        if (attributes.text("plink") != "1") return null
        val protocolVersion = attributes.text("protocolVersion")?.toIntOrNull() ?: return null
        if (protocolVersion != 1) return null
        val endpoint = attributes.text("endpoint")
            ?: host?.takeIf { it.isNotBlank() }?.let { "$it:$port" }
            ?: return null
        val offer = PairingOffer(
            deviceId = attributes.text("deviceId") ?: return null,
            deviceName = attributes.text("deviceName") ?: serviceName,
            platform = attributes.text("platform") ?: "macos",
            endpoint = endpoint,
            nonce = attributes.text("nonce") ?: return null,
            publicKey = attributes.text("publicKey") ?: return null,
            targetDeviceId = attributes.text("targetDeviceId") ?: "pixel-pending",
            protocolVersion = protocolVersion
        )
        val resolvedHost = host ?: endpoint.substringBeforeLast(":", missingDelimiterValue = "")
        return DiscoveredPairingOffer(
            serviceName = serviceName,
            host = resolvedHost,
            port = port,
            offer = offer
        )
    }

    private fun Map<String, ByteArray>.text(key: String): String? =
        this[key]?.toString(Charsets.UTF_8)?.takeIf { it.isNotBlank() }
}

class NearbyPairingDiscovery(
    context: Context,
    private val onOffersChanged: (List<DiscoveredPairingOffer>) -> Unit,
    private val onStatusChanged: (String) -> Unit
) {
    private val manager = context.getSystemService(NsdManager::class.java)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val offers = linkedMapOf<String, DiscoveredPairingOffer>()
    private var listener: NsdManager.DiscoveryListener? = null

    fun start() {
        if (listener != null) return
        val discoveryListener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(regType: String) {
                postStatus("Scanning for nearby Macs")
            }

            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                if (serviceInfo.serviceType != NearbyPairingOfferParser.SERVICE_TYPE) return
                resolve(serviceInfo)
            }

            override fun onServiceLost(serviceInfo: NsdServiceInfo) {
                offers.remove(serviceInfo.serviceName)
                postOffers()
            }

            override fun onDiscoveryStopped(serviceType: String) {
                postStatus("Scan stopped")
            }

            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                stop()
                postStatus("Scan failed")
            }

            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
                postStatus("Scan stop failed")
            }
        }
        listener = discoveryListener
        manager.discoverServices(
            NearbyPairingOfferParser.SERVICE_TYPE,
            NsdManager.PROTOCOL_DNS_SD,
            discoveryListener
        )
    }

    fun stop() {
        val active = listener ?: return
        runCatching { manager.stopServiceDiscovery(active) }
        listener = null
    }

    @Suppress("DEPRECATION")
    private fun resolve(serviceInfo: NsdServiceInfo) {
        manager.resolveService(
            serviceInfo,
            object : NsdManager.ResolveListener {
                override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                    postStatus("Could not resolve ${serviceInfo.serviceName}")
                }

                override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                    val host = serviceInfo.hostAddress()
                    val discovered = NearbyPairingOfferParser.parse(
                        serviceName = serviceInfo.serviceName,
                        attributes = serviceInfo.attributes,
                        host = host,
                        port = serviceInfo.port
                    ) ?: return
                    offers[serviceInfo.serviceName] = discovered
                    postOffers()
                    postStatus("Found ${discovered.offer.deviceName}")
                }
            }
        )
    }

    private fun postOffers() {
        val snapshot = offers.values.toList()
        mainHandler.post { onOffersChanged(snapshot) }
    }

    private fun postStatus(status: String) {
        mainHandler.post { onStatusChanged(status) }
    }
}

@Suppress("DEPRECATION")
private fun NsdServiceInfo.hostAddress(): String? {
    val address: InetAddress? = host
    return address?.hostAddress
}
