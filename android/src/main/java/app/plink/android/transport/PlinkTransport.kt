package app.plink.android.transport

import app.plink.android.protocol.PlinkEnvelope
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.receiveAsFlow

interface PlinkTransport {
    val inbound: Flow<PlinkEnvelope>
    suspend fun send(envelope: PlinkEnvelope)
}

class InMemoryPlinkTransport : PlinkTransport {
    private val events = Channel<PlinkEnvelope>(capacity = Channel.BUFFERED)

    override val inbound: Flow<PlinkEnvelope> = events.receiveAsFlow()

    override suspend fun send(envelope: PlinkEnvelope) {
        events.send(envelope)
    }
}
