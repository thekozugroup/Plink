import Foundation

public enum SerializedPlinkSenderError: Error, Equatable, Sendable {
    case congested
    case expired
    case timedOut
    case cancelled
}

/// One explicit drain owns reserve-sequence, seal, connect, and write completion.
/// Screen payloads are volatile and bounded; ordinary traffic has priority.
public final class SerializedPlinkSender: PlinkTransport, @unchecked Sendable {
    private let lifecycle: SenderLifecycle
    private let queue: Queue
    private let predecessorShutdown: Task<Void, Never>?

    public init(
        transport: any PlinkTransport,
        previousSender: SerializedPlinkSender? = nil
    ) {
        let lifecycle = SenderLifecycle()
        let predecessorShutdown: Task<Void, Never>?
        if let previousSender {
            previousSender.invalidate()
            predecessorShutdown = Task { await previousSender.shutdown() }
        } else {
            predecessorShutdown = nil
        }
        self.lifecycle = lifecycle
        self.predecessorShutdown = predecessorShutdown
        queue = Queue(
            transport: transport,
            lifecycle: lifecycle,
            dispatchBarrier: predecessorShutdown
        )
    }

    public func send(_ envelope: PlinkEnvelope) async throws {
        guard lifecycle.isAccepting, !Task.isCancelled else {
            throw SerializedPlinkSenderError.cancelled
        }
        try await queue.send(envelope)
    }

    public func cancelScreenWork(requestID: String? = nil, streamID: String? = nil) async {
        await queue.cancelScreenWork(requestID: requestID, streamID: streamID)
    }

    public func shutdown() async {
        invalidate()
        await queue.shutdown()
        await predecessorShutdown?.value
    }

    /// Immediately closes admission and cancels the one active producer.
    /// Await `shutdown()` when the transport replacement needs a completion barrier.
    public nonisolated func invalidate() {
        guard lifecycle.invalidate() else { return }
        let queue = queue
        Task { await queue.invalidate() }
    }
}

private final class SenderLifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private var accepting = true
    private var active: (id: UUID, task: Task<Void, any Error>)?

    var isAccepting: Bool {
        lock.lock(); defer { lock.unlock() }
        return accepting
    }

    func invalidate() -> Bool {
        lock.lock()
        guard accepting else { lock.unlock(); return false }
        accepting = false
        let task = active?.task
        lock.unlock()
        task?.cancel()
        return true
    }

    func makeActive(
        id: UUID,
        operation: @escaping @Sendable () async throws -> Void
    ) -> Task<Void, any Error>? {
        lock.lock()
        guard accepting else { lock.unlock(); return nil }
        let task = Task { try await operation() }
        active = (id, task)
        lock.unlock()
        return task
    }

    func clearActive(id: UUID) {
        lock.lock()
        if active?.id == id { active = nil }
        lock.unlock()
    }
}

private actor Queue {
    private final class SendRegistration: @unchecked Sendable {
        private enum State: Equatable { case pending, queued, active, cancelled }
        private let lock = NSLock()
        private var state: State = .pending

        func claimQueue() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard state == .pending else { return false }
            state = .queued
            return true
        }

        func claimActive() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard state == .queued else { return false }
            state = .active
            return true
        }

        func cancel() {
            lock.lock()
            state = .cancelled
            lock.unlock()
        }

        var isCancelled: Bool {
            lock.lock(); defer { lock.unlock() }
            return state == .cancelled
        }
    }

    private enum Kind: Equatable, Sendable {
        case ordinary
        case screenControl
        case screenData

        var isScreen: Bool { self != .ordinary }
    }

    private struct Entry: @unchecked Sendable {
        let id: UUID
        let envelope: PlinkEnvelope
        let kind: Kind
        let expiresAt: ContinuousClock.Instant?
        let registration: SendRegistration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct Expiry: Sendable {
        let id: UUID
        let instant: ContinuousClock.Instant
    }

    private struct Bucket: Sendable {
        var tokens: Double
        var updatedAt: ContinuousClock.Instant
    }

    private let transport: any PlinkTransport
    private let lifecycle: SenderLifecycle
    private let dispatchBarrier: Task<Void, Never>?
    private var ordinary: [Entry] = []
    private var controls: [Entry] = []
    private var data: [Entry] = []
    private var controlBuckets: [String: Bucket] = [:]
    private var dataBuckets: [String: Bucket] = [:]
    private var expiryTask: Task<Void, Never>?
    private var draining = false
    private var stopped = false
    private var active: Entry?
    private var activeTask: Task<Void, any Error>?
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        transport: any PlinkTransport,
        lifecycle: SenderLifecycle,
        dispatchBarrier: Task<Void, Never>?
    ) {
        self.transport = transport
        self.lifecycle = lifecycle
        self.dispatchBarrier = dispatchBarrier
    }

    func send(_ envelope: PlinkEnvelope) async throws {
        let id = UUID()
        let registration = SendRegistration()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enqueue(
                    id: id,
                    envelope: envelope,
                    registration: registration,
                    continuation: continuation
                )
            }
        } onCancel: {
            registration.cancel()
            Task { await self.cancel(id: id) }
        }
    }

    func cancelScreenWork(requestID: String?, streamID: String?) {
        let matches: (Entry) -> Bool = { entry in
            guard entry.kind.isScreen else { return false }
            if let requestID, entry.envelope.payload["requestId"]?.stringValue != requestID { return false }
            if let streamID, entry.envelope.payload["streamId"]?.stringValue != streamID { return false }
            return true
        }
        failQueued(where: matches, error: SerializedPlinkSenderError.cancelled)
        scheduleExpiry()
        if let active, matches(active) {
            active.registration.cancel()
            activeTask?.cancel()
        }
    }

    func shutdown() async {
        stop()
        guard draining || activeTask != nil else { return }
        await withCheckedContinuation { shutdownWaiters.append($0) }
    }

    func invalidate() {
        stop()
    }

    private func enqueue(
        id: UUID,
        envelope: PlinkEnvelope,
        registration: SendRegistration,
        continuation: CheckedContinuation<Void, any Error>
    ) {
        guard !stopped, lifecycle.isAccepting, registration.claimQueue() else {
            continuation.resume(throwing: SerializedPlinkSenderError.cancelled)
            return
        }
        let kind = Self.kind(for: envelope.type)
        let now = ContinuousClock.now
        let expiry = kind.isScreen ? now.advanced(by: .seconds(1)) : nil
        let entry = Entry(
            id: id,
            envelope: envelope,
            kind: kind,
            expiresAt: expiry,
            registration: registration,
            continuation: continuation
        )
        switch kind {
        case .ordinary:
            ordinary.append(entry)
        case .screenControl:
            let activeCount = active?.kind == .screenControl ? 1 : 0
            guard controls.count + activeCount < 2,
                  consumeToken(peer: envelope.targetDeviceId, rate: 8, capacity: 4, now: now, buckets: &controlBuckets)
            else {
                continuation.resume(throwing: SerializedPlinkSenderError.congested)
                return
            }
            controls.append(entry)
        case .screenData:
            let activeCount = active?.kind == .screenData ? 1 : 0
            guard data.count + activeCount < 1,
                  consumeToken(peer: envelope.targetDeviceId, rate: 2, capacity: 2, now: now, buckets: &dataBuckets)
            else {
                continuation.resume(throwing: SerializedPlinkSenderError.congested)
                return
            }
            data.append(entry)
        }
        if kind.isScreen { scheduleExpiry() }
        if !draining {
            draining = true
            Task { await self.drain() }
        }
    }

    private func drain() async {
        await dispatchBarrier?.value
        while !stopped {
            expireQueued(now: .now, reschedule: false)
            guard let entry = takeNext() else { break }
            if let expiresAt = entry.expiresAt, ContinuousClock.now >= expiresAt {
                entry.continuation.resume(throwing: SerializedPlinkSenderError.expired)
                continue
            }
            guard entry.registration.claimActive() else {
                entry.continuation.resume(throwing: SerializedPlinkSenderError.cancelled)
                continue
            }
            active = entry
            let transport = transport
            guard let task = lifecycle.makeActive(id: entry.id, operation: {
                guard !entry.registration.isCancelled else { throw CancellationError() }
                if entry.kind.isScreen {
                    try await Self.sendScreen(envelope: entry.envelope, transport: transport)
                } else {
                    try await transport.send(entry.envelope)
                }
                guard !entry.registration.isCancelled else { throw CancellationError() }
            }) else {
                active = nil
                entry.registration.cancel()
                entry.continuation.resume(throwing: SerializedPlinkSenderError.cancelled)
                continue
            }
            activeTask = task
            do {
                try await task.value
                entry.continuation.resume()
            } catch is CancellationError {
                entry.continuation.resume(throwing: SerializedPlinkSenderError.cancelled)
            } catch FoundationPlinkServerError.timedOut {
                entry.continuation.resume(throwing: SerializedPlinkSenderError.timedOut)
            } catch {
                entry.continuation.resume(throwing: error)
            }
            lifecycle.clearActive(id: entry.id)
            activeTask = nil
            active = nil
            await Task.yield()
        }
        draining = false
        if !stopped, !(ordinary.isEmpty && controls.isEmpty && data.isEmpty) {
            draining = true
            Task { await self.drain() }
        } else {
            let waiters = shutdownWaiters
            shutdownWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    private func stop() {
        guard !stopped else { return }
        stopped = true
        expiryTask?.cancel()
        expiryTask = nil
        failQueued(where: { _ in true }, error: SerializedPlinkSenderError.cancelled)
        active?.registration.cancel()
        activeTask?.cancel()
        if !draining && activeTask == nil {
            let waiters = shutdownWaiters
            shutdownWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    private static func sendScreen(envelope: PlinkEnvelope, transport: any PlinkTransport) async throws {
        guard let transport = transport as? any DeadlinePlinkTransport else {
            throw SerializedPlinkSenderError.timedOut
        }
        try await transport.send(envelope, timeout: 1)
    }

    private func takeNext() -> Entry? {
        if !ordinary.isEmpty { return ordinary.removeFirst() }
        if !controls.isEmpty {
            let entry = controls.removeFirst()
            scheduleExpiry()
            return entry
        }
        if !data.isEmpty {
            let entry = data.removeFirst()
            scheduleExpiry()
            return entry
        }
        return nil
    }

    private func cancel(id: UUID) {
        if active?.id == id { active?.registration.cancel() }
        failQueued(where: { $0.id == id }, error: SerializedPlinkSenderError.cancelled)
        scheduleExpiry()
        if active?.id == id { activeTask?.cancel() }
    }

    private func expiryFired(id: UUID) {
        failQueued(where: { $0.id == id }, error: SerializedPlinkSenderError.expired)
        scheduleExpiry()
    }

    private func expireQueued(now: ContinuousClock.Instant, reschedule: Bool = true) {
        failQueued(where: { $0.expiresAt.map { now >= $0 } ?? false }, error: SerializedPlinkSenderError.expired)
        if reschedule { scheduleExpiry() }
    }

    private func failQueued(where predicate: (Entry) -> Bool, error: any Error) {
        func filter(_ entries: inout [Entry]) {
            var retained: [Entry] = []
            retained.reserveCapacity(entries.count)
            for entry in entries {
                if predicate(entry) {
                    entry.registration.cancel()
                    entry.continuation.resume(throwing: error)
                }
                else { retained.append(entry) }
            }
            entries = retained
        }
        filter(&ordinary)
        filter(&controls)
        filter(&data)
    }

    private func scheduleExpiry() {
        expiryTask?.cancel()
        let next = (controls + data).compactMap { entry -> Expiry? in
            entry.expiresAt.map { Expiry(id: entry.id, instant: $0) }
        }.min { $0.instant < $1.instant }
        guard let next else {
            expiryTask = nil
            return
        }
        expiryTask = Task { [weak self] in
            do { try await ContinuousClock().sleep(until: next.instant) }
            catch { return }
            await self?.expiryFired(id: next.id)
        }
    }


    private func consumeToken(
        peer: String,
        rate: Double,
        capacity: Double,
        now: ContinuousClock.Instant,
        buckets: inout [String: Bucket]
    ) -> Bool {
        var bucket = buckets[peer] ?? Bucket(tokens: capacity, updatedAt: now)
        let elapsed = bucket.updatedAt.duration(to: now)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        bucket.tokens = min(capacity, bucket.tokens + max(0, seconds) * rate)
        bucket.updatedAt = now
        guard bucket.tokens >= 1 else {
            buckets[peer] = bucket
            return false
        }
        bucket.tokens -= 1
        buckets[peer] = bucket
        return true
    }

    private static func kind(for type: EventType) -> Kind {
        guard ScreenPreviewPayloadPolicy.eventTypes.contains(type) else { return .ordinary }
        return type == .screenFrame ? .screenData : .screenControl
    }
}
