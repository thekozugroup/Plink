package app.plink.android.services

import app.plink.android.protocol.PlinkEnvelope
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.receiveAsFlow

object SharedNotificationEvents {
    private val events = Channel<PlinkEnvelope>(capacity = Channel.BUFFERED)
    val inbound: Flow<PlinkEnvelope> = events.receiveAsFlow()

    fun trySend(envelope: PlinkEnvelope): Boolean = events.trySend(envelope).isSuccess
}
