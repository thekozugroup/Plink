import Darwin
import Foundation

public enum ReconnectSessionError: Error, Equatable, Sendable {
    case cancelled
    case timedOut
    case busy
    case invalidCandidate
    case unavailableNetworkOrPermission
    case socketFailure(Int32)
    case endpointMismatch
    case authenticationFailed
    case wrongPhase
    case staleLifetime
}

public final class PairWriteGate: @unchecked Sendable {
    private final class Waiter: @unchecked Sendable {
        let id: UUID
        let deadline: ContinuousClock.Instant
        var continuation: CheckedContinuation<Void, any Error>?

        init(id: UUID, deadline: ContinuousClock.Instant) {
            self.id = id
            self.deadline = deadline
        }
    }

    private let lock = NSLock()
    private var active: UUID?
    private var waiters: [Waiter] = []
    private var invalidated = false

    public init() {}

    public func withWrite<T: Sendable>(
        deadline: ContinuousClock.Instant,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let id = UUID()
        try await acquire(id: id, deadline: deadline)
        defer { release(id: id) }
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw ReconnectSessionError.timedOut }
        let result = try await body()
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw ReconnectSessionError.timedOut }
        return result
    }

    public func invalidate() {
        let continuations: [CheckedContinuation<Void, any Error>] = lock.withLock {
            guard !invalidated else { return [] }
            invalidated = true
            let values = waiters.compactMap(\.continuation)
            waiters.removeAll()
            return values
        }
        continuations.forEach { $0.resume(throwing: ReconnectSessionError.cancelled) }
    }

    private func acquire(id: UUID, deadline: ContinuousClock.Instant) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let waiter = Waiter(id: id, deadline: deadline)
                waiter.continuation = continuation
                let placement: Int = lock.withLock {
                    guard !invalidated else { return 0 }
                    if active == nil, waiters.isEmpty {
                        active = id
                        waiter.continuation = nil
                        return 1
                    }
                    waiters.append(waiter)
                    return 2
                }
                if placement == 0 {
                    continuation.resume(throwing: ReconnectSessionError.cancelled)
                } else if placement == 1 {
                    continuation.resume()
                } else {
                    if Task.isCancelled {
                        cancel(id: id, error: ReconnectSessionError.cancelled)
                        return
                    }
                    Task { [weak self] in
                        do { try await ContinuousClock().sleep(until: deadline) } catch { return }
                        self?.cancel(id: id, error: ReconnectSessionError.timedOut)
                    }
                }
            }
        } onCancel: {
            cancel(id: id, error: ReconnectSessionError.cancelled)
        }
    }

    private func cancel(id: UUID, error: any Error) {
        let continuation: CheckedContinuation<Void, any Error>? = lock.withLock {
            guard let index = waiters.firstIndex(where: { $0.id == id }) else { return nil }
            let waiter = waiters.remove(at: index)
            let continuation = waiter.continuation
            waiter.continuation = nil
            return continuation
        }
        continuation?.resume(throwing: error)
    }

    private func release(id: UUID) {
        var resume: CheckedContinuation<Void, any Error>?
        var expired: [CheckedContinuation<Void, any Error>] = []
        lock.withLock {
            guard active == id else { return }
            active = nil
            while !waiters.isEmpty {
                let waiter = waiters.removeFirst()
                guard ContinuousClock.now < waiter.deadline else {
                    if let continuation = waiter.continuation { expired.append(continuation) }
                    waiter.continuation = nil
                    continue
                }
                active = waiter.id
                resume = waiter.continuation
                waiter.continuation = nil
                break
            }
        }
        expired.forEach { $0.resume(throwing: ReconnectSessionError.timedOut) }
        resume?.resume()
    }
}

public struct ReconnectSocketObservation: Equatable, Sendable {
    public let local: IPv4Endpoint
    public let remote: IPv4Endpoint
}

public struct VerifiedNetworkBinding: Equatable, Sendable {
    public let interface: ReconnectInterfaceSnapshot
    public let localIPv4: String
    public let peer: IPv4Endpoint
    public let localListenerPort: UInt16
    public let peerListenerPort: UInt16
    public let interfaceGeneration: UUID

    public init(
        interface: ReconnectInterfaceSnapshot,
        localIPv4: String,
        peer: IPv4Endpoint,
        localListenerPort: UInt16,
        peerListenerPort: UInt16,
        interfaceGeneration: UUID = UUID()
    ) {
        self.interface = interface
        self.localIPv4 = localIPv4
        self.peer = peer
        self.localListenerPort = localListenerPort
        self.peerListenerPort = peerListenerPort
        self.interfaceGeneration = interfaceGeneration
    }
}

private final class OwnedSocketDescriptor: @unchecked Sendable {
    let descriptor: Int32
    private let lock = NSLock()
    private var cancelled = false
    private var transferred = false
    private var closed = false

    init(_ descriptor: Int32) { self.descriptor = descriptor }
    deinit { close() }

    func cancel() {
        let shouldShutdown = lock.withLock { () -> Bool in
            cancelled = true
            return !closed && !transferred
        }
        if shouldShutdown { Darwin.shutdown(descriptor, SHUT_RDWR) }
    }

    func take() throws -> Int32 {
        try lock.withLock {
            guard !cancelled, !closed, !transferred else { throw ReconnectSessionError.cancelled }
            transferred = true
            return descriptor
        }
    }

    func close() {
        let shouldClose = lock.withLock { () -> Bool in
            guard !closed, !transferred else { return false }
            closed = true
            return true
        }
        if shouldClose { Darwin.close(descriptor) }
    }
}

public final class PairSessionLifetime: @unchecked Sendable {
    public let localID: String
    public let peerID: String
    public let sessionID: String
    public let sessionKey: Data
    public let codec: EncryptedFrameCodec
    public let stateStore: any FrameStateStoring
    public let writeGate = PairWriteGate()
    public let validation: ReconnectValidationPolicy

    private let lock = NSLock()
    private var valid = true
    private var admission: (generation: UUID, binding: VerifiedNetworkBinding)?

    public init(
        localID: String,
        peerID: String,
        sessionID: String,
        sessionKey: Data,
        stateStore: any FrameStateStoring,
        validation: ReconnectValidationPolicy = .production
    ) {
        self.localID = localID
        self.peerID = peerID
        self.sessionID = sessionID
        self.sessionKey = sessionKey
        codec = EncryptedFrameCodec(sessionKey: sessionKey)
        self.stateStore = stateStore
        self.validation = validation
    }

    public var isCurrent: Bool { lock.withLock { valid } }

    public func closeOrdinaryAdmission() {
        lock.withLock { admission = nil }
    }

    @discardableResult
    public func openOrdinaryAdmission(binding: VerifiedNetworkBinding) throws -> UUID {
        try lock.withLock {
            guard valid else { throw ReconnectSessionError.staleLifetime }
            let generation = UUID()
            admission = (generation, binding)
            return generation
        }
    }

    public func ordinaryAdmission() -> (generation: UUID, binding: VerifiedNetworkBinding)? {
        lock.withLock { valid ? admission : nil }
    }

    func acceptNonblocking(
        listenerDescriptor: Int32
    ) throws -> (descriptor: Int32, admission: (generation: UUID, binding: VerifiedNetworkBinding)?)? {
        let flags = fcntl(listenerDescriptor, F_GETFL, 0)
        guard flags >= 0 else { throw ReconnectSessionError.socketFailure(errno) }
        guard flags & O_NONBLOCK != 0 else { throw ReconnectSessionError.socketFailure(EINVAL) }
        return try lock.withLock {
            guard valid else { throw ReconnectSessionError.staleLifetime }
            let accepted = Darwin.accept(listenerDescriptor, nil, nil)
            if accepted < 0 {
                guard errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR else {
                    throw ReconnectSessionError.socketFailure(errno)
                }
                return nil
            }
            return (accepted, admission)
        }
    }

    public func requireCurrent(binding: VerifiedNetworkBinding, generation: UUID) throws {
        let stored = try lock.withLock { () throws -> VerifiedNetworkBinding in
            guard valid, let admission, admission.generation == generation, admission.binding == binding else {
                throw ReconnectSessionError.staleLifetime
            }
            return admission.binding
        }
        guard ReconnectCandidatePolicy.currentInterfaces().contains(where: {
            $0.name == stored.interface.name && $0.index == stored.interface.index &&
                $0.localIPv4 == stored.localIPv4 && $0.prefixLength == stored.interface.prefixLength &&
                ReconnectCandidatePolicy.candidate(endpoint: stored.peer.description, interface: $0,
                    validation: validation) != nil
        }) else { throw ReconnectSessionError.unavailableNetworkOrPermission }
    }

    public func invalidate() {
        let changed = lock.withLock { () -> Bool in
            guard valid else { return false }
            valid = false
            admission = nil
            return true
        }
        if changed { writeGate.invalidate() }
    }
}

public final class ReconnectSocket: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32
    public let observation: ReconnectSocketObservation

    private init(descriptor: Int32, observation: ReconnectSocketObservation) throws {
        self.descriptor = descriptor
        self.observation = observation
        var noSigPipe: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe,
                         socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            Darwin.close(descriptor)
            throw ReconnectSessionError.socketFailure(errno)
        }
        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            Darwin.close(descriptor)
            throw ReconnectSessionError.socketFailure(errno)
        }
    }

    deinit { close() }

    public static func connect(candidate: ReconnectCandidate, timeout: TimeInterval = 2) async throws -> ReconnectSocket {
        try await connect(candidate: candidate, deadline: ContinuousClock.now.advanced(by: .seconds(timeout)))
    }

    static func connect(candidate: ReconnectCandidate, deadline: ContinuousClock.Instant) async throws -> ReconnectSocket {
        guard ContinuousClock.now < deadline else { throw ReconnectSessionError.timedOut }
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ReconnectSessionError.socketFailure(errno) }
        let operation = OwnedSocketDescriptor(descriptor)
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            var index = candidate.interface.index
            guard setsockopt(descriptor, IPPROTO_IP, IP_BOUND_IF, &index,
                             socklen_t(MemoryLayout<UInt32>.size)) == 0 else {
                throw ReconnectSessionError.unavailableNetworkOrPermission
            }
            var local = try socketAddress(ip: candidate.interface.localIPv4, port: 0)
            let bound = withUnsafePointer(to: &local) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0 else { throw ReconnectSessionError.unavailableNetworkOrPermission }
            let flags = fcntl(descriptor, F_GETFL, 0)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw ReconnectSessionError.socketFailure(errno)
            }
            var remote = try socketAddress(ip: candidate.endpoint.address, port: candidate.endpoint.port)
            let result = withUnsafePointer(to: &remote) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if result != 0 {
                guard errno == EINPROGRESS else { throw ReconnectSessionError.socketFailure(errno) }
                try pollDescriptor(descriptor, events: Int16(POLLOUT), deadline: deadline)
                var socketError: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0,
                      socketError == 0 else { throw ReconnectSessionError.socketFailure(socketError == 0 ? errno : socketError) }
            }
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw ReconnectSessionError.timedOut }
            let observation = try socketObservation(descriptor)
            guard observation.local.address == candidate.interface.localIPv4,
                  observation.remote == candidate.endpoint else { throw ReconnectSessionError.endpointMismatch }
            return observation
        }
        do {
            let observation = try await withTaskCancellationHandler {
                let observation = try await task.value
                try Task.checkCancellation()
                return observation
            } onCancel: {
                task.cancel()
                operation.cancel()
            }
            let owned = try operation.take()
            let socket = try ReconnectSocket(descriptor: owned, observation: observation)
            if Task.isCancelled {
                socket.close()
                throw ReconnectSessionError.cancelled
            }
            return socket
        } catch {
            task.cancel()
            operation.cancel()
            _ = try? await task.value
            operation.close()
            if Task.isCancelled || error is CancellationError { throw ReconnectSessionError.cancelled }
            throw error
        }
    }

    static func accepted(descriptor: Int32) throws -> ReconnectSocket {
        let observation: ReconnectSocketObservation
        do { observation = try socketObservation(descriptor) }
        catch { Darwin.close(descriptor); throw error }
        return try ReconnectSocket(descriptor: descriptor, observation: observation)
    }

    public func send(
        _ envelope: PlinkEnvelope,
        lifetime: PairSessionLifetime,
        timeout: TimeInterval = 2
    ) async throws {
        try await send(envelope, lifetime: lifetime,
            deadline: ContinuousClock.now.advanced(by: .seconds(timeout)))
    }

    func send(
        _ envelope: PlinkEnvelope,
        lifetime: PairSessionLifetime,
        deadline: ContinuousClock.Instant,
        authorization: @escaping @Sendable () throws -> Void = {}
    ) async throws {
        try await withOwnedDescriptor { descriptor in
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw ReconnectSessionError.timedOut }
            try authorization()
            let sequence = try lifetime.stateStore.reserveSequence(scope: lifetime.codec.stateScope(
                sourceDeviceId: envelope.sourceDeviceId, targetDeviceId: envelope.targetDeviceId))
            let frame = try lifetime.codec.seal(envelope, sequence: sequence)
            let wire = try PlinkJSON.encoder().encode(frame)
            try ReconnectPayloadPolicy.validate(envelope, validation: lifetime.validation,
                plaintextBytes: try PlinkJSON.encoder().encode(envelope).count, encryptedBytes: wire.count)
            let framed = try LengthPrefixedFrameCodec.encode(wire)
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw ReconnectSessionError.timedOut }
            try authorization()
            try writeAll(framed, descriptor: descriptor, deadline: deadline)
        }
    }

    public func receive(
        lifetime: PairSessionLifetime,
        timeout: TimeInterval = 2,
        maxWireBytes: Int = 4_096
    ) async throws -> PlinkEnvelope {
        try await receive(lifetime: lifetime, deadline: ContinuousClock.now.advanced(by: .seconds(timeout)),
            maxWireBytes: maxWireBytes)
    }

    func receive(
        lifetime: PairSessionLifetime,
        deadline: ContinuousClock.Instant,
        maxWireBytes: Int = 4_096
    ) async throws -> PlinkEnvelope {
        try await withOwnedDescriptor { descriptor in
            let header = try readExact(count: 4, descriptor: descriptor, deadline: deadline)
            let size = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard size > 0, size <= maxWireBytes else { throw NetworkPlinkServerError.invalidFrame }
            let wire = try readExact(count: Int(size), descriptor: descriptor, deadline: deadline)
            let frame = try PlinkJSON.decoder().decode(EncryptedPlinkFrame.self, from: wire)
            let envelope = try lifetime.codec.open(frame, expectedSourceDeviceId: lifetime.peerID,
                expectedTargetDeviceId: lifetime.localID, stateStore: lifetime.stateStore,
                wireBytes: wire.count, rawFrameData: wire, reconnectValidation: lifetime.validation)
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw ReconnectSessionError.timedOut }
            return envelope
        }
    }

    public func close() {
        let value: Int32 = lock.withLock {
            let value = descriptor
            descriptor = -1
            return value
        }
        if value >= 0 {
            Darwin.shutdown(value, SHUT_RDWR)
            Darwin.close(value)
        }
    }

    private func duplicateDescriptor() throws -> Int32 {
        try lock.withLock {
            guard descriptor >= 0 else { throw ReconnectSessionError.cancelled }
            let duplicate = Darwin.dup(descriptor)
            guard duplicate >= 0 else { throw ReconnectSessionError.socketFailure(errno) }
            return duplicate
        }
    }

    private func withOwnedDescriptor<T: Sendable>(
        _ body: @escaping @Sendable (Int32) throws -> T
    ) async throws -> T {
        let operation = OwnedSocketDescriptor(try duplicateDescriptor())
        let descriptor = operation.descriptor
        let task = Task.detached(priority: .utility) { try body(descriptor) }
        defer { operation.close() }
        do {
            return try await withTaskCancellationHandler {
                let value = try await task.value
                try Task.checkCancellation()
                return value
            } onCancel: {
                task.cancel()
                operation.cancel()
            }
        } catch {
            task.cancel()
            operation.cancel()
            _ = try? await task.value
            if Task.isCancelled || error is CancellationError { throw ReconnectSessionError.cancelled }
            throw error
        }
    }
}

public final class ReconnectListener: @unchecked Sendable {
    public typealias OrdinaryHandler = @Sendable (Result<PlinkEnvelope, any Error>, UUID) -> Void

    private final class ReverseExpectation: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<(ReconnectSocket, ReconnectMessage), any Error>?
        private var continuation: CheckedContinuation<(ReconnectSocket, ReconnectMessage), any Error>?

        func wait() async throws -> (ReconnectSocket, ReconnectMessage) {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let existing = lock.withLock { () -> Result<(ReconnectSocket, ReconnectMessage), any Error>? in
                        if let result { return result }
                        self.continuation = continuation
                        return nil
                    }
                    if let existing { continuation.resume(with: existing) }
                }
            } onCancel: { resolve(.failure(ReconnectSessionError.cancelled)) }
        }

        func resolve(_ value: Result<(ReconnectSocket, ReconnectMessage), any Error>) {
            let continuation: CheckedContinuation<(ReconnectSocket, ReconnectMessage), any Error>? = lock.withLock {
                guard result == nil else { return nil }
                result = value
                let continuation = self.continuation
                self.continuation = nil
                return continuation
            }
            continuation?.resume(with: value)
        }
    }

    private let port: UInt16
    private let bindAddress: String
    private let lifetime: PairSessionLifetime
    private let ordinaryHandler: OrdinaryHandler
    private let processingRegistrationHook: (@Sendable () -> Void)?
    private let queue = DispatchQueue(label: "com.thekozugroup.plink.reconnect-listener", qos: .utility)
    private let queueKey = DispatchSpecificKey<Bool>()
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var client: ReconnectSocket?
    private var processingTask: Task<Void, Never>?
    private var stopped = false
    private var expectations: [String: ReverseExpectation] = [:]

    public convenience init(
        port: UInt16 = 45_731,
        bindAddress: String = "0.0.0.0",
        lifetime: PairSessionLifetime,
        ordinaryHandler: @escaping OrdinaryHandler
    ) {
        self.init(port: port, bindAddress: bindAddress, lifetime: lifetime,
            processingRegistrationHook: nil, ordinaryHandler: ordinaryHandler)
    }

    init(
        port: UInt16,
        bindAddress: String,
        lifetime: PairSessionLifetime,
        processingRegistrationHook: (@Sendable () -> Void)?,
        ordinaryHandler: @escaping OrdinaryHandler
    ) {
        self.port = port
        self.bindAddress = bindAddress
        self.lifetime = lifetime
        self.processingRegistrationHook = processingRegistrationHook
        self.ordinaryHandler = ordinaryHandler
        queue.setSpecific(key: queueKey, value: true)
    }

    public func start() throws {
        try lock.withLock {
            guard listener < 0, !stopped else { throw ReconnectSessionError.cancelled }
            let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw ReconnectSessionError.socketFailure(errno) }
            var reuse: Int32 = 1
            setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
            var address = try socketAddress(ip: bindAddress, port: port)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard result == 0 else { Darwin.close(descriptor); throw ReconnectSessionError.socketFailure(errno) }
            let flags = fcntl(descriptor, F_GETFL, 0)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                Darwin.close(descriptor)
                throw ReconnectSessionError.socketFailure(errno)
            }
            guard Darwin.listen(descriptor, 8) == 0 else {
                Darwin.close(descriptor); throw ReconnectSessionError.socketFailure(errno)
            }
            listener = descriptor
            queue.async { self.run(descriptor) }
        }
    }

    public func stop() {
        let pending: [ReverseExpectation] = lock.withLock {
            guard !stopped else {
                processingTask?.cancel()
                client?.close()
                return []
            }
            stopped = true
            if listener >= 0 { Darwin.shutdown(listener, SHUT_RDWR) }
            client?.close()
            let pending = Array(expectations.values)
            expectations.removeAll()
            processingTask?.cancel()
            return pending
        }
        pending.forEach { $0.resolve(.failure(ReconnectSessionError.cancelled)) }
        if DispatchQueue.getSpecific(key: queueKey) == nil { queue.sync {} }
    }

    func prepareReverse(m: String, deadline: ContinuousClock.Instant) throws -> @Sendable () async throws -> (ReconnectSocket, ReconnectMessage) {
        let expectation = ReverseExpectation()
        try lock.withLock {
            guard !stopped, expectations[m] == nil else { throw ReconnectSessionError.busy }
            expectations[m] = expectation
        }
        Task { [weak self, weak expectation] in
            do { try await ContinuousClock().sleep(until: deadline) } catch { return }
            guard let self, let expectation else { return }
            self.cancelReverse(m: m, expectation: expectation, error: ReconnectSessionError.timedOut)
        }
        return { try await expectation.wait() }
    }

    func cancelReverse(m: String) {
        let expectation = lock.withLock { expectations.removeValue(forKey: m) }
        expectation?.resolve(.failure(ReconnectSessionError.cancelled))
    }

    private func cancelReverse(m: String, expectation: ReverseExpectation, error: any Error) {
        let removed: ReverseExpectation? = lock.withLock {
            guard expectations[m] === expectation else { return nil }
            return expectations.removeValue(forKey: m)
        }
        removed?.resolve(.failure(error))
    }

    private func run(_ descriptor: Int32) {
        defer {
            lock.withLock {
                listener = -1
                Darwin.close(descriptor)
            }
        }
        while lock.withLock({ !stopped }) {
            var poll = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&poll, 1, 100)
            if ready <= 0 { continue }
            do {
                guard let accepted = try lifetime.acceptNonblocking(listenerDescriptor: descriptor) else { continue }
                let socket = try ReconnectSocket.accepted(descriptor: accepted.descriptor)
                let keep = lock.withLock { () -> Bool in
                    guard !stopped, client == nil else { return false }
                    client = socket
                    return true
                }
                guard keep else { socket.close(); continue }
                process(socket, admissionAtAccept: accepted.admission)
            } catch { continue }
        }
    }

    private func process(
        _ socket: ReconnectSocket,
        admissionAtAccept: (generation: UUID, binding: VerifiedNetworkBinding)?
    ) {
        let semaphore = DispatchSemaphore(value: 0)
        let transfer = ReconnectTransferFlag()
        let registration: (task: Task<Void, Never>, cancelImmediately: Bool) = lock.withLock {
            let task = Task {
                defer { semaphore.signal() }
                do {
                    let envelope = try await socket.receive(lifetime: lifetime, maxWireBytes: 128 * 1_024)
                    if envelope.type == .reconnectReverse {
                        let message = try ReconnectMessage(envelope, validation: lifetime.validation)
                        let expectation = lock.withLock { expectations.removeValue(forKey: message.m) }
                        guard let expectation else { throw ReconnectSessionError.authenticationFailed }
                        transfer.markTransferred()
                        expectation.resolve(.success((socket, message)))
                    } else if let admission = validatedAdmission(admissionAtAccept, socket: socket) {
                        ordinaryHandler(.success(envelope), admission.generation)
                    }
                } catch {
                    if let admission = validatedAdmission(admissionAtAccept, socket: socket) {
                        ordinaryHandler(.failure(error), admission.generation)
                    }
                }
            }
            processingRegistrationHook?()
            processingTask = task
            return (task, stopped)
        }
        if registration.cancelImmediately {
            registration.task.cancel()
            socket.close()
        }
        semaphore.wait()
        lock.withLock {
            if client === socket { client = nil }
            processingTask = nil
        }
        if !transfer.transferred { socket.close() }
    }

    private func validatedAdmission(
        _ admission: (generation: UUID, binding: VerifiedNetworkBinding)?,
        socket: ReconnectSocket
    ) -> (generation: UUID, binding: VerifiedNetworkBinding)? {
        guard let admission, lifetime.ordinaryAdmission()?.generation == admission.generation,
              socket.observation.local.address == admission.binding.localIPv4,
              socket.observation.local.port == admission.binding.localListenerPort,
              socket.observation.remote.address == admission.binding.peer.address,
              (try? lifetime.requireCurrent(binding: admission.binding, generation: admission.generation)) != nil
        else { return nil }
        return admission
    }
}

private final class ReconnectTransferFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var transferred: Bool { lock.withLock { value } }
    func markTransferred() { lock.withLock { value = true } }
}

private final class ReconnectCandidateChannels: @unchecked Sendable {
    private enum State { case active, timedOut, cancelled, finished }

    private let lock = NSLock()
    private let commitAuthority: ReconnectCandidateCommitAuthority
    private var state = State.active
    private var sockets: [ReconnectSocket] = []

    init(commitAuthority: ReconnectCandidateCommitAuthority) {
        self.commitAuthority = commitAuthority
    }

    var didTimeOut: Bool { lock.withLock { state == .timedOut } }

    func register(_ socket: ReconnectSocket) throws {
        let failure: ReconnectSessionError? = lock.withLock {
            switch state {
            case .active:
                sockets.append(socket)
                return nil
            case .timedOut:
                return .timedOut
            case .cancelled, .finished:
                return .cancelled
            }
        }
        if let failure {
            socket.close()
            throw failure
        }
    }

    @discardableResult
    func expire() -> Bool { stop(as: .timedOut) }
    func cancel() { stop(as: .cancelled) }
    func finish() { stop(as: .finished) }

    @discardableResult
    private func stop(as newState: State) -> Bool {
        let owned: [ReconnectSocket]? = lock.withLock {
            guard state == .active else { return nil }
            state = newState
            let owned = sockets
            sockets.removeAll()
            return owned
        }
        guard let owned else { return false }
        commitAuthority.invalidate()
        owned.forEach { $0.close() }
        return true
    }
}

public struct ReconnectAttemptResult: Sendable {
    public let binding: VerifiedNetworkBinding
    public let proofID: String
    public let observedOutbound: ReconnectSocketObservation
    public let observedReverse: ReconnectSocketObservation
}

public final class ReconnectInitiator: @unchecked Sendable {
    private let lifetime: PairSessionLifetime
    private let listener: ReconnectListener
    private let endpointCommitter: any ReconnectEndpointCommitting
    private let commitAuthority: ReconnectCommitAuthority
    private let listenerPort: UInt16
    private let nonce: @Sendable () throws -> String
    private let onCandidateExpired: @Sendable () -> Void

    public init(
        lifetime: PairSessionLifetime,
        listener: ReconnectListener,
        commitAuthority: ReconnectCommitAuthority,
        endpointStore: ReconnectEndpointStore = .applicationDefault,
        listenerPort: UInt16 = 45_731,
        nonce: @escaping @Sendable () throws -> String = ReconnectNonce.generate,
        onCandidateExpired: @escaping @Sendable () -> Void = {}
    ) {
        self.lifetime = lifetime
        self.listener = listener
        self.commitAuthority = commitAuthority
        endpointCommitter = endpointStore
        self.listenerPort = listenerPort
        self.nonce = nonce
        self.onCandidateExpired = onCandidateExpired
    }

    init(
        lifetime: PairSessionLifetime,
        listener: ReconnectListener,
        commitAuthority: ReconnectCommitAuthority,
        endpointCommitter: any ReconnectEndpointCommitting,
        listenerPort: UInt16,
        nonce: @escaping @Sendable () throws -> String = ReconnectNonce.generate,
        onCandidateExpired: @escaping @Sendable () -> Void = {}
    ) {
        self.lifetime = lifetime
        self.listener = listener
        self.commitAuthority = commitAuthority
        self.endpointCommitter = endpointCommitter
        self.listenerPort = listenerPort
        self.nonce = nonce
        self.onCandidateExpired = onCandidateExpired
    }

    public func attempt(candidate: ReconnectCandidate, timeout: Duration = .seconds(30)) async throws -> ReconnectAttemptResult {
        try await attempt(candidate: candidate, deadline: ContinuousClock.now.advanced(by: timeout))
    }

    public func attempt(
        candidate: ReconnectCandidate,
        deadline: ContinuousClock.Instant
    ) async throws -> ReconnectAttemptResult {
        guard ContinuousClock.now < deadline else { throw ReconnectSessionError.timedOut }
        let candidateAuthority: ReconnectCandidateCommitAuthority
        do { candidateAuthority = try commitAuthority.makeCandidate(deadline: deadline) }
        catch where ContinuousClock.now >= deadline { throw ReconnectSessionError.timedOut }
        let channels = ReconnectCandidateChannels(commitAuthority: candidateAuthority)
        let processing = Task {
            try await performAttempt(candidate: candidate, deadline: deadline,
                candidateAuthority: candidateAuthority, channels: channels)
        }
        let onCandidateExpired = self.onCandidateExpired
        let watchdog = Task.detached(priority: .utility) {
            do { try await ContinuousClock().sleep(until: deadline) } catch { return }
            guard channels.expire() else { return }
            processing.cancel()
            onCandidateExpired()
        }
        do {
            let result = try await withTaskCancellationHandler {
                try await processing.value
            } onCancel: {
                processing.cancel()
                channels.cancel()
                self.commitAuthority.invalidate()
            }
            watchdog.cancel()
            await watchdog.value
            if channels.didTimeOut || ContinuousClock.now >= deadline {
                if channels.expire() { onCandidateExpired() }
                throw ReconnectSessionError.timedOut
            }
            channels.finish()
            return result
        } catch {
            watchdog.cancel()
            await watchdog.value
            processing.cancel()
            channels.cancel()
            _ = try? await processing.value
            if channels.didTimeOut || ContinuousClock.now >= deadline {
                throw ReconnectSessionError.timedOut
            }
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw error
        }
    }

    private func performAttempt(
        candidate: ReconnectCandidate,
        deadline: ContinuousClock.Instant,
        candidateAuthority: ReconnectCandidateCommitAuthority,
        channels: ReconnectCandidateChannels
    ) async throws -> ReconnectAttemptResult {
        guard ContinuousClock.now < deadline, lifetime.isCurrent,
              ReconnectCandidatePolicy.candidate(endpoint: candidate.endpoint.description,
                interface: candidate.interface, validation: lifetime.validation) != nil else {
            if ContinuousClock.now >= deadline { throw ReconnectSessionError.timedOut }
            throw ReconnectSessionError.invalidCandidate
        }
        lifetime.closeOrdinaryAdmission()
        let m = try nonce()
        let waitForReverse = try listener.prepareReverse(m: m, deadline: deadline)
        defer { listener.cancelReverse(m: m) }
        let outbound = try await ReconnectSocket.connect(candidate: candidate,
            deadline: min(deadline, ContinuousClock.now.advanced(by: .seconds(2))))
        try channels.register(outbound)
        let outboundObservation = outbound.observation
        defer { outbound.close() }
        let mac = try IPv4Endpoint(address: outboundObservation.local.address, port: listenerPort)
        let phone = candidate.endpoint

        try await send(ReconnectMessage(type: .reconnectHello, m: m, p: nil, r: nil, mac: mac, phone: phone)
            .envelope(source: lifetime.localID, target: lifetime.peerID), on: outbound, deadline: deadline)
        let challenge = try await receive(on: outbound, deadline: deadline)
        try require(challenge, type: .reconnectChallenge, m: m, p: nil, r: nil, mac: mac, phone: phone)
        guard let p = challenge.p else { throw ReconnectSessionError.wrongPhase }
        try await send(ReconnectMessage(type: .reconnectProof, m: m, p: p, r: nil, mac: mac, phone: phone)
            .envelope(source: lifetime.localID, target: lifetime.peerID), on: outbound, deadline: deadline)
        outbound.close()

        let (reverseSocket, reverse) = try await waitForReverse()
        try channels.register(reverseSocket)
        defer { reverseSocket.close() }
        try require(reverse, type: .reconnectReverse, m: m, p: p, r: nil, mac: mac, phone: phone)
        guard reverseSocket.observation.remote.address == phone.address,
              reverseSocket.observation.local == mac,
              let r = reverse.r else { throw ReconnectSessionError.endpointMismatch }
        try await send(ReconnectMessage(type: .reconnectReverseProof, m: m, p: p, r: r, mac: mac, phone: phone)
            .envelope(source: lifetime.localID, target: lifetime.peerID), on: reverseSocket, deadline: deadline)
        let ready = try await receive(on: reverseSocket, deadline: deadline)
        try require(ready, type: .reconnectReady, m: m, p: p, r: r, mac: mac, phone: phone)
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline, lifetime.isCurrent else {
            throw ContinuousClock.now >= deadline ? ReconnectSessionError.timedOut : ReconnectSessionError.staleLifetime
        }
        do {
            _ = try endpointCommitter.commit(localID: lifetime.localID, peerID: lifetime.peerID,
                sessionID: lifetime.sessionID, endpoint: phone, proofID: m, sessionKey: lifetime.sessionKey,
                authority: commitAuthority, candidateAuthority: candidateAuthority, deadline: deadline)
        } catch where ContinuousClock.now >= deadline {
            throw ReconnectSessionError.timedOut
        }
        try await send(ReconnectMessage(type: .reconnectCommit, m: m, p: p, r: r, mac: mac, phone: phone)
            .envelope(source: lifetime.localID, target: lifetime.peerID), on: reverseSocket, deadline: deadline)
        let done = try await receive(on: reverseSocket, deadline: deadline)
        try require(done, type: .reconnectDone, m: m, p: p, r: r, mac: mac, phone: phone)
        guard ContinuousClock.now < deadline, lifetime.isCurrent else {
            throw ContinuousClock.now >= deadline ? ReconnectSessionError.timedOut : ReconnectSessionError.staleLifetime
        }
        let binding = VerifiedNetworkBinding(interface: candidate.interface, localIPv4: mac.address,
            peer: phone, localListenerPort: listenerPort, peerListenerPort: phone.port)
        return ReconnectAttemptResult(binding: binding, proofID: m,
            observedOutbound: outboundObservation, observedReverse: reverseSocket.observation)
    }

    private func send(
        _ envelope: PlinkEnvelope,
        on socket: ReconnectSocket,
        deadline: ContinuousClock.Instant
    ) async throws {
        try await lifetime.writeGate.withWrite(deadline: deadline) {
            guard self.lifetime.isCurrent else { throw ReconnectSessionError.staleLifetime }
            try await socket.send(envelope, lifetime: self.lifetime,
                deadline: min(deadline, ContinuousClock.now.advanced(by: .seconds(2))))
        }
    }

    private func receive(on socket: ReconnectSocket, deadline: ContinuousClock.Instant) async throws -> ReconnectMessage {
        guard ContinuousClock.now < deadline else { throw ReconnectSessionError.timedOut }
        let envelope = try await socket.receive(lifetime: lifetime,
            deadline: min(deadline, ContinuousClock.now.advanced(by: .seconds(2))))
        return try ReconnectMessage(envelope, validation: lifetime.validation)
    }

    private func require(
        _ message: ReconnectMessage,
        type: EventType,
        m: String,
        p: String?,
        r: String?,
        mac: IPv4Endpoint,
        phone: IPv4Endpoint
    ) throws {
        guard message.type == type, message.m == m, message.p == p || p == nil && message.p != nil,
              message.r == r || r == nil && message.r != nil,
              message.mac == mac, message.phone == phone else { throw ReconnectSessionError.wrongPhase }
    }
}

public final class BoundSecureNetworkPlinkClient: DeadlinePlinkTransport, @unchecked Sendable {
    private let lifetime: PairSessionLifetime
    private let binding: VerifiedNetworkBinding
    private let generation: UUID

    public init(lifetime: PairSessionLifetime, binding: VerifiedNetworkBinding, generation: UUID) {
        self.lifetime = lifetime
        self.binding = binding
        self.generation = generation
    }

    public func send(_ envelope: PlinkEnvelope) async throws { try await send(envelope, timeout: 5) }

    public func send(_ envelope: PlinkEnvelope, timeout: TimeInterval) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        try await lifetime.writeGate.withWrite(deadline: deadline) {
            try self.lifetime.requireCurrent(binding: self.binding, generation: self.generation)
            let candidate = ReconnectCandidate(endpoint: self.binding.peer, interface: self.binding.interface)
            let socket = try await ReconnectSocket.connect(candidate: candidate, deadline: deadline)
            defer { socket.close() }
            guard socket.observation.local.address == self.binding.localIPv4,
                  socket.observation.remote == self.binding.peer else { throw ReconnectSessionError.endpointMismatch }
            try await socket.send(envelope, lifetime: self.lifetime, deadline: deadline) {
                try self.lifetime.requireCurrent(binding: self.binding, generation: self.generation)
            }
        }
    }
}

private func remainingSeconds(until deadline: ContinuousClock.Instant) -> TimeInterval {
    let duration = ContinuousClock.now.duration(to: deadline)
    return max(0.001, Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
}

private func socketAddress(ip: String, port: UInt16) throws -> sockaddr_in {
    var address = in_addr()
    guard inet_pton(AF_INET, ip, &address) == 1 else { throw ReconnectSessionError.invalidCandidate }
    return sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET),
        sin_port: port.bigEndian, sin_addr: address, sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
}

private func socketObservation(_ descriptor: Int32) throws -> ReconnectSocketObservation {
    func endpoint(peer: Bool) throws -> IPv4Endpoint {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                peer ? getpeername(descriptor, $0, &length) : getsockname(descriptor, $0, &length)
            }
        }
        guard result == 0, address.sin_family == sa_family_t(AF_INET) else {
            throw ReconnectSessionError.socketFailure(errno)
        }
        var source = address.sin_addr
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &source, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
            throw ReconnectSessionError.socketFailure(errno)
        }
        let host = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return try IPv4Endpoint(address: host, port: UInt16(bigEndian: address.sin_port))
    }
    return try ReconnectSocketObservation(local: endpoint(peer: false), remote: endpoint(peer: true))
}

private func pollDescriptor(
    _ descriptor: Int32,
    events: Int16,
    deadline: ContinuousClock.Instant
) throws {
    while true {
        if Task.isCancelled { throw ReconnectSessionError.cancelled }
        let now = ContinuousClock.now
        guard now < deadline else { throw ReconnectSessionError.timedOut }
        var value = pollfd(fd: descriptor, events: events, revents: 0)
        let wait = Int32(min(100, max(1, Int(remainingSeconds(until: deadline) * 1_000))))
        let ready = Darwin.poll(&value, 1, wait)
        if ready < 0, errno == EINTR { continue }
        guard ready >= 0 else { throw ReconnectSessionError.socketFailure(errno) }
        if ready == 0 { continue }
        guard value.revents & Int16(POLLERR | POLLNVAL) == 0 else {
            throw ReconnectSessionError.socketFailure(ECONNRESET)
        }
        if value.revents & events != 0 { return }
        if value.revents & Int16(POLLHUP) != 0 { throw ReconnectSessionError.socketFailure(ECONNRESET) }
    }
}

private func readExact(count: Int, descriptor: Int32, deadline: ContinuousClock.Instant) throws -> Data {
    var output = Data(count: count)
    var offset = 0
    while offset < count {
        try pollDescriptor(descriptor, events: Int16(POLLIN), deadline: deadline)
        let amount = output.withUnsafeMutableBytes {
            Darwin.recv(descriptor, $0.baseAddress!.advanced(by: offset), count - offset, MSG_DONTWAIT)
        }
        if amount < 0, errno == EAGAIN || errno == EINTR { continue }
        guard amount > 0 else { throw ReconnectSessionError.socketFailure(errno == 0 ? ECONNRESET : errno) }
        offset += amount
    }
    return output
}

private func writeAll(_ data: Data, descriptor: Int32, deadline: ContinuousClock.Instant) throws {
    var offset = 0
    while offset < data.count {
        try pollDescriptor(descriptor, events: Int16(POLLOUT), deadline: deadline)
        let amount = data.withUnsafeBytes {
            Darwin.send(descriptor, $0.baseAddress!.advanced(by: offset), data.count - offset, MSG_DONTWAIT)
        }
        if amount < 0, errno == EAGAIN || errno == EINTR { continue }
        guard amount > 0 else { throw ReconnectSessionError.socketFailure(errno == 0 ? ECONNRESET : errno) }
        offset += amount
    }
}

private extension ReconnectMessage {
    init(type: EventType, m: String, p: String?, r: String?, mac: IPv4Endpoint, phone: IPv4Endpoint) {
        self.type = type
        self.m = m
        self.p = p
        self.r = r
        self.mac = mac
        self.phone = phone
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
