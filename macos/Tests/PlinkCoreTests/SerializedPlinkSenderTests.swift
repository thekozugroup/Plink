import Dispatch
import Foundation
@testable import PlinkCore
import Testing

@Test func queuedScreenPayloadExpiresWhileOrdinaryWriteIsBlocked() async throws {
    let transport = ControlledDeadlineTransport(blockOrdinary: true)
    let sender = SerializedPlinkSender(transport: transport)
    let ordinary = ordinaryEnvelope(id: "ordinary-blocker")
    let screen = screenControlEnvelope(id: "screen-expiry")

    let ordinaryTask = Task { try await sender.send(ordinary) }
    try await waitUntil { await transport.hasStarted(id: ordinary.id) }
    let startedAt = ContinuousClock.now
    let screenTask = Task { try await sender.send(screen) }
    let screenError = await taskError(screenTask)
    let elapsed = startedAt.duration(to: .now)

    #expect(screenError as? SerializedPlinkSenderError == .expired)
    #expect(elapsed >= .seconds(1))
    #expect(elapsed < .milliseconds(1_750))
    let expiryStarts = await transport.startedIDs()
    #expect(expiryStarts == [ordinary.id])

    await transport.releaseOrdinary()
    let ordinaryError = await taskError(ordinaryTask)
    #expect(ordinaryError == nil)
    await sender.shutdown()
}

@Test func invalidateClosesAdmissionSynchronously() async {
    let transport = ControlledDeadlineTransport()
    let sender = SerializedPlinkSender(transport: transport)

    sender.invalidate()
    let sendTask = Task { try await sender.send(ordinaryEnvelope(id: "after-invalidate")) }
    let error = await taskError(sendTask)
    let starts = await transport.startedIDs()

    #expect(error as? SerializedPlinkSenderError == .cancelled)
    #expect(starts.isEmpty)
    await sender.shutdown()
}

@Test func replacementWaitsForPredecessorShutdownCompletion() async throws {
    let previousTransport = ControlledDeadlineTransport(
        blockOrdinary: true,
        holdCancellationCompletion: true
    )
    let replacementTransport = ControlledDeadlineTransport()
    let previous = SerializedPlinkSender(transport: previousTransport)
    let previousEnvelope = ordinaryEnvelope(id: "predecessor-active")
    let replacementEnvelope = ordinaryEnvelope(id: "replacement-send")

    let previousTask = Task { try await previous.send(previousEnvelope) }
    try await waitUntil { await previousTransport.hasStarted(id: previousEnvelope.id) }

    let replacement = SerializedPlinkSender(
        transport: replacementTransport,
        previousSender: previous
    )
    let replacementTask = Task { try await replacement.send(replacementEnvelope) }
    try await waitUntil { await previousTransport.hasCancelled(id: previousEnvelope.id) }
    try await Task.sleep(for: .milliseconds(30))

    let startsBeforeBarrier = await replacementTransport.startedIDs()
    #expect(startsBeforeBarrier.isEmpty)

    await previousTransport.releaseCancellationCompletion()
    let previousError = await taskError(previousTask)
    let replacementError = await taskError(replacementTask)
    let startsAfterBarrier = await replacementTransport.startedIDs()

    #expect(previousError as? SerializedPlinkSenderError == .cancelled)
    #expect(replacementError == nil)
    #expect(startsAfterBarrier == [replacementEnvelope.id])
    await replacement.shutdown()
}

@Test func successorScreenExpiryAndCancellationRunWhilePredecessorIsHeld() async throws {
    let previousTransport = ControlledDeadlineTransport(
        blockOrdinary: true,
        holdCancellationCompletion: true
    )
    let replacementTransport = ControlledDeadlineTransport()
    let previous = SerializedPlinkSender(transport: previousTransport)
    let previousEnvelope = ordinaryEnvelope(id: "held-predecessor")
    let previousTask = Task { try await previous.send(previousEnvelope) }
    try await waitUntil { await previousTransport.hasStarted(id: previousEnvelope.id) }

    let replacement = SerializedPlinkSender(
        transport: replacementTransport,
        previousSender: previous
    )
    try await waitUntil { await previousTransport.hasCancelled(id: previousEnvelope.id) }

    let expiryProbe = SenderCompletionProbe()
    let expiryTask = Task {
        do {
            try await replacement.send(screenControlEnvelope(id: "held-expiry"))
            await expiryProbe.finish(nil)
        } catch {
            await expiryProbe.finish(error as? SerializedPlinkSenderError)
        }
    }
    let cancellationProbe = SenderCompletionProbe()
    let cancellationTask = Task {
        do {
            try await replacement.send(screenDataEnvelope(id: "held-cancellation"))
            await cancellationProbe.finish(nil)
        } catch {
            await cancellationProbe.finish(error as? SerializedPlinkSenderError)
        }
    }
    try await Task.sleep(for: .milliseconds(20))
    cancellationTask.cancel()

    let cancellationFinished = (try? await waitUntil {
        await cancellationProbe.isComplete
    }) != nil
    let expiryFinished = (try? await waitUntil(timeout: .milliseconds(1_750)) {
        await expiryProbe.isComplete
    }) != nil
    let replacementStarts = await replacementTransport.startedIDs()
    let cancellationError = await cancellationProbe.error
    let expiryError = await expiryProbe.error

    #expect(cancellationFinished)
    #expect(cancellationError == .cancelled)
    #expect(expiryFinished)
    #expect(expiryError == .expired)
    #expect(replacementStarts.isEmpty)

    if !expiryFinished { expiryTask.cancel() }
    await previousTransport.releaseCancellationCompletion()
    await expiryTask.value
    await cancellationTask.value
    let previousError = await taskError(previousTask)
    #expect(previousError as? SerializedPlinkSenderError == .cancelled)
    await replacement.shutdown()
}

@Test func shutdownReturnsOnlyAfterActiveProducerCompletes() async throws {
    let transport = ControlledDeadlineTransport(
        blockOrdinary: true,
        holdCancellationCompletion: true
    )
    let sender = SerializedPlinkSender(transport: transport)
    let envelope = ordinaryEnvelope(id: "shutdown-barrier")
    let sendTask = Task { try await sender.send(envelope) }
    try await waitUntil { await transport.hasStarted(id: envelope.id) }

    let completion = CompletionProbe()
    let shutdownTask = Task {
        await sender.shutdown()
        await completion.markComplete()
    }
    try await waitUntil { await transport.hasCancelled(id: envelope.id) }
    let completedBeforeProducer = await completion.isComplete
    #expect(!completedBeforeProducer)

    await transport.releaseCancellationCompletion()
    await shutdownTask.value
    let sendError = await taskError(sendTask)
    let completedAfterProducer = await completion.isComplete
    #expect(sendError as? SerializedPlinkSenderError == .cancelled)
    #expect(completedAfterProducer)
}

@Test func sharedSenderSerializesTrafficAndPrioritizesOrdinaryWork() async throws {
    let transport = ControlledDeadlineTransport(blockOrdinary: true, blockScreen: true)
    let sender = SerializedPlinkSender(transport: transport)
    let ordinary = ordinaryEnvelope(id: "ordinary-first")
    let file = ordinaryEnvelope(id: "file-second", type: .fileCancel)
    let screen = screenDataEnvelope(id: "screen-third")

    let firstTask = Task { try await sender.send(ordinary) }
    try await waitUntil { await transport.hasStarted(id: ordinary.id) }

    let screenTask = Task { try await sender.send(screen) }
    try await Task.sleep(for: .milliseconds(20))
    let fileTask = Task { try await sender.send(file) }
    try await Task.sleep(for: .milliseconds(20))

    await transport.releaseOrdinary()
    try await waitUntil { await transport.hasStarted(id: file.id) }
    try await waitUntil { await transport.hasStarted(id: screen.id) }
    let starts = await transport.startedIDs()
    let maximumConcurrent = await transport.maximumConcurrentSends()
    #expect(starts == [ordinary.id, file.id, screen.id])
    #expect(maximumConcurrent == 1)

    await transport.releaseScreen()
    let firstError = await taskError(firstTask)
    let fileError = await taskError(fileTask)
    let screenError = await taskError(screenTask)
    #expect(firstError == nil)
    #expect(fileError == nil)
    #expect(screenError == nil)
    await sender.shutdown()
}

@Test func scopedScreenCancellationAllowsOrdinaryTrafficToProgress() async throws {
    let transport = ControlledDeadlineTransport(blockScreen: true)
    let sender = SerializedPlinkSender(transport: transport)
    let screen = screenDataEnvelope(id: "active-screen")
    let ordinary = ordinaryEnvelope(id: "ordinary-after-screen")

    let screenTask = Task { try await sender.send(screen) }
    try await waitUntil { await transport.hasStarted(id: screen.id) }
    let ordinaryTask = Task { try await sender.send(ordinary) }
    try await Task.sleep(for: .milliseconds(20))

    await sender.cancelScreenWork(
        requestID: screen.payload["requestId"]?.stringValue,
        streamID: screen.payload["streamId"]?.stringValue
    )

    let screenError = await taskError(screenTask)
    let ordinaryError = await taskError(ordinaryTask)
    let starts = await transport.startedIDs()
    let cancellations = await transport.cancelledIDs()
    #expect(screenError as? SerializedPlinkSenderError == .cancelled)
    #expect(ordinaryError == nil)
    #expect(starts == [screen.id, ordinary.id])
    #expect(cancellations == [screen.id])
    await sender.shutdown()
}

@Test func cancelledQueuedProducerCannotSendAfterBlockerClears() async throws {
    let transport = ControlledDeadlineTransport(blockOrdinary: true)
    let sender = SerializedPlinkSender(transport: transport)
    let ordinary = ordinaryEnvelope(id: "ordinary-cancellation-blocker")
    let screen = screenControlEnvelope(id: "cancelled-before-send")

    let ordinaryTask = Task { try await sender.send(ordinary) }
    try await waitUntil { await transport.hasStarted(id: ordinary.id) }

    let screenTask = Task { try await sender.send(screen) }
    screenTask.cancel()
    let screenError = await taskError(screenTask)
    #expect(screenError as? SerializedPlinkSenderError == .cancelled)

    await transport.releaseOrdinary()
    let ordinaryError = await taskError(ordinaryTask)
    #expect(ordinaryError == nil)
    try await Task.sleep(for: .milliseconds(30))
    let starts = await transport.startedIDs()
    #expect(starts == [ordinary.id])
    await sender.shutdown()
}

@Test func screenQueueRejectsWorkBeyondControlAndFrameCaps() async throws {
    let transport = ControlledDeadlineTransport(blockOrdinary: true)
    let sender = SerializedPlinkSender(transport: transport)
    let ordinary = ordinaryEnvelope(id: "ordinary-cap-blocker")
    let control1 = screenControlEnvelope(id: "control-one")
    let control2 = screenControlEnvelope(id: "control-two")
    let control3 = screenControlEnvelope(id: "control-three")
    let frame1 = screenDataEnvelope(id: "frame-one")
    let frame2 = screenDataEnvelope(id: "frame-two")

    let ordinaryTask = Task { try await sender.send(ordinary) }
    try await waitUntil { await transport.hasStarted(id: ordinary.id) }
    let controlTask1 = Task { try await sender.send(control1) }
    try await Task.sleep(for: .milliseconds(10))
    let controlTask2 = Task { try await sender.send(control2) }
    try await Task.sleep(for: .milliseconds(10))
    let controlTask3 = Task { try await sender.send(control3) }
    let frameTask1 = Task { try await sender.send(frame1) }
    try await Task.sleep(for: .milliseconds(10))
    let frameTask2 = Task { try await sender.send(frame2) }

    let controlError3 = await taskError(controlTask3)
    let frameError2 = await taskError(frameTask2)
    #expect(controlError3 as? SerializedPlinkSenderError == .congested)
    #expect(frameError2 as? SerializedPlinkSenderError == .congested)

    await sender.cancelScreenWork()
    let controlError1 = await taskError(controlTask1)
    let controlError2 = await taskError(controlTask2)
    let frameError1 = await taskError(frameTask1)
    #expect(controlError1 as? SerializedPlinkSenderError == .cancelled)
    #expect(controlError2 as? SerializedPlinkSenderError == .cancelled)
    #expect(frameError1 as? SerializedPlinkSenderError == .cancelled)
    await transport.releaseOrdinary()
    let ordinaryError = await taskError(ordinaryTask)
    #expect(ordinaryError == nil)
    await sender.shutdown()
}

@Test func monotonicSendDeadlineRejectsBoundaryAndLateSuccess() {
    let instant = DispatchTime.now() + .seconds(1)
    let deadline = MonotonicSendDeadline(uptimeNanoseconds: instant.uptimeNanoseconds)
    // Darwin converts nanoseconds to clock ticks; one nanosecond can round away.
    #expect(!deadline.hasExpired(now: instant - .milliseconds(1)))
    #expect(deadline.hasExpired(now: instant))
    #expect(deadline.hasExpired(now: instant + .milliseconds(1)))
}

private actor ControlledDeadlineTransport: DeadlinePlinkTransport {
    private var blockOrdinary: Bool
    private var blockScreen: Bool
    private var active = 0
    private var maximumActive = 0
    private var starts: [String] = []
    private var cancellations: [String] = []
    private var holdCancellationCompletion: Bool
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        blockOrdinary: Bool = false,
        blockScreen: Bool = false,
        holdCancellationCompletion: Bool = false
    ) {
        self.blockOrdinary = blockOrdinary
        self.blockScreen = blockScreen
        self.holdCancellationCompletion = holdCancellationCompletion
    }

    func send(_ envelope: PlinkEnvelope) async throws {
        try await perform(envelope, isScreen: false)
    }

    func send(_ envelope: PlinkEnvelope, timeout: TimeInterval) async throws {
        #expect(timeout == 1)
        try await perform(envelope, isScreen: true)
    }

    func releaseOrdinary() { blockOrdinary = false }
    func releaseScreen() { blockScreen = false }
    func releaseCancellationCompletion() {
        holdCancellationCompletion = false
        let waiters = cancellationWaiters
        cancellationWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
    func hasStarted(id: String) -> Bool { starts.contains(id) }
    func hasCancelled(id: String) -> Bool { cancellations.contains(id) }
    func startedIDs() -> [String] { starts }
    func cancelledIDs() -> [String] { cancellations }
    func maximumConcurrentSends() -> Int { maximumActive }

    private func perform(_ envelope: PlinkEnvelope, isScreen: Bool) async throws {
        active += 1
        maximumActive = max(maximumActive, active)
        starts.append(envelope.id)
        defer { active -= 1 }
        do {
            while (isScreen ? blockScreen : blockOrdinary) {
                try await Task.sleep(for: .milliseconds(5))
            }
        } catch is CancellationError {
            cancellations.append(envelope.id)
            if holdCancellationCompletion {
                await withTaskCancellationHandler {
                    await withCheckedContinuation { cancellationWaiters.append($0) }
                } onCancel: {}
            }
            throw CancellationError()
        }
    }
}

private actor CompletionProbe {
    private(set) var isComplete = false
    func markComplete() { isComplete = true }
}

private actor SenderCompletionProbe {
    private(set) var isComplete = false
    private(set) var error: SerializedPlinkSenderError?

    func finish(_ error: SerializedPlinkSenderError?) {
        self.error = error
        isComplete = true
    }
}

private enum SenderTestError: Error {
    case timedOut
}

private func waitUntil(
    timeout: Duration = .seconds(1),
    _ predicate: @escaping @Sendable () async -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !(await predicate()) {
        guard ContinuousClock.now < deadline else { throw SenderTestError.timedOut }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private func taskError(_ task: Task<Void, Error>) async -> Error? {
    do {
        try await task.value
        return nil
    } catch {
        return error
    }
}

private func ordinaryEnvelope(id: String, type: EventType = .deviceStatus) -> PlinkEnvelope {
    PlinkEnvelope(
        id: id,
        type: type,
        sentAt: .now,
        sourceDeviceId: "test-mac",
        targetDeviceId: "test-pixel",
        payload: [:]
    )
}

private func screenControlEnvelope(id: String) -> PlinkEnvelope {
    ScreenPreviewMessage.pull(
        requestID: "11111111-1111-4111-8111-111111111111",
        streamID: "22222222-2222-4222-8222-222222222222",
        index: 1
    ).envelope(
        sourceDeviceID: "test-mac",
        targetDeviceID: "test-pixel",
        id: id
    )
}

private func screenDataEnvelope(id: String) -> PlinkEnvelope {
    ScreenPreviewMessage.frame(ScreenFramePayload(
        requestID: "11111111-1111-4111-8111-111111111111",
        streamID: "22222222-2222-4222-8222-222222222222",
        index: 1,
        width: 1,
        height: 1,
        jpegData: Data([0xff, 0xd8, 0xff, 0xd9])
    )).envelope(
        sourceDeviceID: "test-mac",
        targetDeviceID: "test-pixel",
        id: id
    )
}
