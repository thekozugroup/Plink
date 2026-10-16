package app.plink.android.companion

import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.Serializable
import app.plink.android.protocol.CompanionMetadataPolicy

data class CompanionSetupState(
    val supported: Boolean = false,
    val paired: Boolean = false,
    val registered: Boolean = false,
    val busy: Boolean = false,
    val message: String? = null
)

@Serializable
internal data class CompanionIdentity(val deviceId: String, val peerPublicKey: String, val bluetoothAddress: String = "")

internal data class CompanionPeer(val identity: CompanionIdentity, val name: String)
internal data class CompanionPairings(val selected: CompanionPeer?, val trusted: Set<CompanionIdentity>)
internal data class CompanionAssociation(val id: Int, val bluetoothAddress: String?)

@Serializable
internal data class CompanionRegistration(val associationId: Int, val identity: CompanionIdentity)

@Serializable
internal data class CompanionRegistrations(
    val registration: CompanionRegistration? = null,
    val cleanupIds: Set<Int> = emptySet(),
    val metadata: CompanionIdentity? = null
)

internal interface CompanionEnvironment<Consent> {
    val supported: Boolean
    suspend fun pairings(): CompanionPairings
    fun readRegistrations(): CompanionRegistrations
    fun writeRegistrations(value: CompanionRegistrations)
    // getMyAssociations supplies only associations owned by this application.
    fun associations(): List<CompanionAssociation>
    fun disassociate(id: Int)
    fun associate(bluetoothAddress: String, callback: Callback<Consent>)
    fun requestNotificationAccess()
    suspend fun onMain(action: () -> Unit)

    interface Callback<Consent> {
        fun pending(consent: Consent)
        fun created(id: Int)
        fun failed()
    }
}

internal class CompanionSetupCoordinator<Consent>(
    private val environment: CompanionEnvironment<Consent>,
    private val scope: CoroutineScope
) {
    private class Attempt<T>(val owner: Any, val launch: (T) -> Unit) {
        var peer: CompanionPeer? = null
    }
    private class NotificationRequest(val owner: Any)
    private val mutex = Mutex()
    private val unjournaledIds = mutableSetOf<Int>()
    private val attempt = AtomicReference<Attempt<Consent>?>(null)
    private val notificationRequest = AtomicReference<NotificationRequest?>(null)
    private val mutableState = MutableStateFlow(CompanionSetupState(supported = environment.supported))
    val state: StateFlow<CompanionSetupState> = mutableState.asStateFlow()

    // The caller refreshes after its complete commit/rollback, never from inside this lock.
    suspend fun withPairingTransaction(block: suspend () -> Unit) = mutex.withLock { block() }

    fun refresh() = work { reconcile() }

    suspend fun receiveMetadata(deviceId: String, peerPublicKey: String, bluetoothAddress: String,
        commitIfCurrent: (() -> Unit) -> Boolean) = mutex.withLock {
        CompanionMetadataPolicy.requireAddress(bluetoothAddress)
        val peer = environment.pairings().selected?.identity ?: return@withLock
        if (peer.deviceId != deviceId || peer.peerPublicKey != peerPublicKey) return@withLock
        val saved = environment.readRegistrations()
        // Unavailable metadata must not discard a previously authenticated address for this peer.
        if (bluetoothAddress.isEmpty() && saved.metadata?.let {
            it.deviceId == deviceId && it.peerPublicKey == peerPublicKey && it.bluetoothAddress.isNotEmpty()
        } == true) return@withLock
        val committed = commitIfCurrent {
            environment.writeRegistrations(saved.copy(metadata = peer.copy(bluetoothAddress = bluetoothAddress)))
        }
        if (!committed) return@withLock
        reconcile()
    }

    private suspend fun pairings(): CompanionPairings {
        val raw = environment.pairings()
        val metadata = environment.readRegistrations().metadata
        fun resolve(identity: CompanionIdentity) = if (metadata?.deviceId == identity.deviceId &&
            metadata.peerPublicKey == identity.peerPublicKey) metadata else identity.copy(bluetoothAddress = "")
        return CompanionPairings(raw.selected?.let { it.copy(identity = resolve(it.identity)) }, raw.trusted.map(::resolve).toSet())
    }

    fun setUp(owner: Any, launch: (Consent) -> Unit) {
        val request = Attempt(owner, launch)
        if (!attempt.compareAndSet(null, request)) return
        work(request) {
            if (attempt.get() !== request) return@work
            val (pairings, saved) = reconcile()
            val peer = pairings.selected
            if (!environment.supported || peer == null || peer.identity.bluetoothAddress.isEmpty() || state.value.registered || saved.cleanupIds.isNotEmpty()) {
                attempt.compareAndSet(request, null)
                mutableState.value = state.value.copy(busy = false, message = when {
                    !environment.supported -> "Companion setup requires Android 13 or later."
                    peer == null -> "Pair with a Mac first."
                    peer.identity.bluetoothAddress.isEmpty() -> "Connect to your Mac to finish setup"
                    else -> state.value.message
                })
                return@work
            }
            request.peer = peer
            // This first version keeps one current registration; changing Macs removes the old one.
            if (saved.registration != null) {
                environment.writeRegistrations(saved.copy(
                    registration = null,
                    cleanupIds = saved.cleanupIds + saved.registration.associationId
                ))
                if (reconcile().second.cleanupIds.isNotEmpty()) {
                    attempt.compareAndSet(request, null)
                    mutableState.value = state.value.copy(busy = false)
                    return@work
                }
            }
            environment.onMain {
                if (attempt.get() === request) {
                    environment.associate(peer.identity.bluetoothAddress, object : CompanionEnvironment.Callback<Consent> {
                        override fun pending(consent: Consent) = work(request) {
                            if (attempt.get() !== request) return@work
                            if (pairings().selected?.identity != peer.identity) {
                                attempt.compareAndSet(request, null)
                                reconcile()
                                return@work
                            }
                            environment.onMain {
                                if (attempt.get() === request) request.launch(consent)
                            }
                        }
                        override fun created(id: Int) = work(request) {
                            unjournaledIds += id
                            complete(request, id)
                        }
                        override fun failed() = work(request) {
                            if (attempt.compareAndSet(request, null)) {
                                reconcile()
                                mutableState.value = state.value.copy(message = "Companion setup was not completed. Try again.")
                            }
                        }
                    })
                }
            }
            mutableState.value = state.value.copy(busy = attempt.get() != null)
        }
    }

    fun cancelSetup(owner: Any) {
        val current = attempt.get()
        if (current?.owner === owner) attempt.compareAndSet(current, null)
        val notification = notificationRequest.get()
        if (notification?.owner === owner) notificationRequest.compareAndSet(notification, null)
        work { mutableState.value = state.value.copy(busy = attempt.get() != null) }
    }

    fun removeRegistration() {
        attempt.set(null)
        notificationRequest.set(null)
        work {
            val saved = environment.readRegistrations()
            environment.writeRegistrations(saved.copy(
                registration = null,
                cleanupIds = saved.cleanupIds + listOfNotNull(saved.registration?.associationId)
            ))
            reconcile()
        }
    }

    fun requestNotificationAccess(owner: Any, openSettings: () -> Unit) {
        val request = NotificationRequest(owner)
        if (!notificationRequest.compareAndSet(null, request)) return
        work {
            try {
                val canUseCompanion = try {
                    reconcile()
                    state.value.registered
                } catch (cancellation: CancellationException) {
                    throw cancellation
                } catch (_: Exception) {
                    mutableState.value = state.value.copy(registered = false)
                    false
                }
                environment.onMain {
                    if (notificationRequest.get() !== request) return@onMain
                    if (canUseCompanion) {
                        try {
                            environment.requestNotificationAccess()
                            return@onMain
                        } catch (cancellation: CancellationException) {
                            throw cancellation
                        } catch (_: Exception) {
                            // Sideloaded applications may need restricted settings approved first.
                        }
                    }
                    mutableState.value = state.value.copy(message = "Enable notification access in Settings.")
                    if (notificationRequest.get() === request) openSettings()
                }
            } finally {
                notificationRequest.compareAndSet(request, null)
            }
        }
    }

    private suspend fun complete(request: Attempt<Consent>, id: Int) {
        var saved = environment.readRegistrations()
        val previous = saved.registration
        if (previous?.associationId != id) {
            saved = saved.copy(cleanupIds = saved.cleanupIds + id)
            environment.writeRegistrations(saved)
        }
        unjournaledIds -= id
        val pairings = pairings()
        val peer = request.peer
        val association = environment.associations().singleOrNull { it.id == id &&
            it.bluetoothAddress == peer?.identity?.bluetoothAddress && it.bluetoothAddress != null }
        if (association == null) {
            attempt.compareAndSet(request, null)
            reconcile()
            mutableState.value = state.value.copy(message = "Android could not confirm the companion registration. Try again.")
            return
        }
        // A duplicate callback must not delete a registration already accepted from this request.
        if (peer != null && saved.registration == CompanionRegistration(id, peer.identity) &&
            pairings.selected?.identity == peer.identity && peer.identity in pairings.trusted &&
            id !in saved.cleanupIds) return

        val accept = peer != null && attempt.get() === request && pairings.selected?.identity == peer.identity &&
            peer.identity in pairings.trusted
        val next = if (accept) saved.copy(
            registration = CompanionRegistration(id, checkNotNull(peer).identity),
            cleanupIds = (saved.cleanupIds + listOfNotNull(saved.registration?.associationId)) - id
        ) else saved.copy(cleanupIds = saved.cleanupIds + id)
        environment.writeRegistrations(next)
        if (accept && !attempt.compareAndSet(request, null)) {
            environment.writeRegistrations(next.copy(registration = null, cleanupIds = next.cleanupIds + id))
        }
        attempt.compareAndSet(request, null)
        reconcile()
    }

    private suspend fun reconcile(): Pair<CompanionPairings, CompanionRegistrations> {
        val pairings = pairings()
        if (!environment.supported) {
            mutableState.value = CompanionSetupState(paired = pairings.selected != null)
            return pairings to environment.readRegistrations()
        }
        val associations = environment.associations().associateBy { it.id }
        var saved = environment.readRegistrations()
        if (unjournaledIds.isNotEmpty()) {
            saved = saved.copy(cleanupIds = saved.cleanupIds + unjournaledIds)
            environment.writeRegistrations(saved)
            unjournaledIds.clear()
        }
        val registration = saved.registration
        if (registration != null && (registration.identity !in pairings.trusted ||
            registration.identity.bluetoothAddress.isEmpty() ||
            associations[registration.associationId]?.bluetoothAddress != registration.identity.bluetoothAddress)) {
            saved = saved.copy(registration = null, cleanupIds = saved.cleanupIds + registration.associationId)
            environment.writeRegistrations(saved)
        }
        var cleanupFailed = false
        for (id in saved.cleanupIds) {
            try {
                if (id in associations) environment.disassociate(id)
                val next = saved.copy(cleanupIds = saved.cleanupIds - id)
                environment.writeRegistrations(next)
                saved = next
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (_: Exception) {
                cleanupFailed = true
            }
        }
        val current = attempt.get()
        if (current?.peer != null && current.peer?.identity != pairings.selected?.identity) {
            attempt.compareAndSet(current, null)
        }
        mutableState.value = CompanionSetupState(
            supported = true,
            paired = pairings.selected != null,
            registered = saved.registration?.let {
                it.identity == pairings.selected?.identity && it.associationId in associations && it.associationId !in saved.cleanupIds
            } ?: false,
            busy = attempt.get() != null,
            message = when {
                cleanupFailed -> "Could not remove the old companion registration. Try again."
                pairings.selected?.identity?.bluetoothAddress == "" -> "Connect to your Mac to finish setup"
                else -> null
            }
        )
        return pairings to saved
    }

    private fun work(request: Attempt<Consent>? = null, action: suspend () -> Unit) {
        scope.launch {
            mutex.withLock {
                try {
                    action()
                } catch (cancellation: CancellationException) {
                    throw cancellation
                } catch (_: Exception) {
                    if (request != null) attempt.compareAndSet(request, null)
                    mutableState.value = state.value.copy(registered = false, busy = attempt.get() != null,
                        message = "Companion setup could not be updated. Try again.")
                }
            }
        }
    }
}
