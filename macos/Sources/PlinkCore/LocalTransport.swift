import Foundation
import Darwin
import Network

public protocol PlinkTransport: Sendable {
    func send(_ envelope: PlinkEnvelope) async throws
}

public protocol PlinkEventReceiver: Sendable {
    func start(onEnvelope: @escaping @Sendable (Result<PlinkEnvelope, Error>) -> Void) throws
    func stop()
}

public protocol LengthPrefixedMessageReceiver: Sendable {
    func start(onMessage: @escaping @Sendable (Result<Data, Error>) -> Void) throws
    func stop()
}

public actor InMemoryPlinkTransport: PlinkTransport {
    public private(set) var sent: [PlinkEnvelope] = []

    public init() {}

    public func send(_ envelope: PlinkEnvelope) async {
        sent.append(envelope)
    }
}

public enum LengthPrefixedFrameCodec {
    private static let maxFrameBytes = 128 * 1024

    public static func encode(_ payload: Data) throws -> Data {
        guard payload.count > 0, payload.count <= maxFrameBytes else {
            throw NetworkPlinkServerError.invalidFrame
        }
        var length = UInt32(payload.count).bigEndian
        var output = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        output.append(payload)
        return output
    }

    public static func decode(_ data: Data) throws -> Data {
        guard data.count >= 4 else { throw NetworkPlinkServerError.invalidFrame }
        let length = data.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0, length <= maxFrameBytes, data.count >= Int(length) + 4 else {
            throw NetworkPlinkServerError.invalidFrame
        }
        return data.dropFirst(4).prefix(Int(length))
    }

    public static func expectedTotalLength(_ data: Data) throws -> Int? {
        guard data.count >= 4 else { return nil }
        let length = data.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0, length <= maxFrameBytes else {
            throw NetworkPlinkServerError.invalidFrame
        }
        return Int(length) + 4
    }
}

public final class SecureNetworkPlinkClient: PlinkTransport, @unchecked Sendable {
    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private let codec: EncryptedFrameCodec
    private let stateStore: any FrameStateStoring

    public init(host: String, port: UInt16, codec: EncryptedFrameCodec,
                stateStore: any FrameStateStoring = FileFrameStateStore.applicationDefault) {
        self.host = NWEndpoint.Host(host)
        self.port = NWEndpoint.Port(rawValue: port)!
        self.codec = codec
        self.stateStore = stateStore
    }

    public func send(_ envelope: PlinkEnvelope) async throws {
        try Task.checkCancellation()
        let sequence = try stateStore.reserveSequence(scope: codec.stateScope(
            sourceDeviceId: envelope.sourceDeviceId, targetDeviceId: envelope.targetDeviceId))
        let frame = try codec.seal(envelope, sequence: sequence)
        let payload = try LengthPrefixedFrameCodec.encode(PlinkJSON.encoder().encode(frame))
        let operation = NetworkSend(connection: NWConnection(host: host, port: port, using: .tcp))
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operation.start(payload, continuation: continuation)
            }
        } onCancel: { operation.finish(.failure(CancellationError())) }
    }
}

private final class NetworkSend: @unchecked Sendable {
    private let connection: NWConnection
    private let lock = NSLock()
    private var result: Result<Void, Error>?
    private var continuation: CheckedContinuation<Void, any Error>?
    private var timer: DispatchSourceTimer?
    init(connection: NWConnection) { self.connection = connection }
    func start(_ data: Data, continuation: CheckedContinuation<Void, any Error>) {
        lock.lock()
        if let result { lock.unlock(); continuation.resume(with: result); return }
        self.continuation = continuation
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        self.timer = timer
        timer.schedule(deadline: .now() + 5)
        timer.setEventHandler { self.finish(.failure(FoundationPlinkServerError.timedOut)) }
        timer.resume()
        connection.stateUpdateHandler = { state in
            if case .failed(let error) = state { self.finish(.failure(error)) }
        }
        connection.start(queue: .global(qos: .utility))
        connection.send(content: data, completion: .contentProcessed { error in
            if let error { self.finish(.failure(error)) } else { self.finish(.success(())) }
        })
        lock.unlock()
    }
    func finish(_ value: Result<Void, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value
        let pending = continuation
        continuation = nil
        timer?.cancel(); timer = nil
        lock.unlock()
        connection.stateUpdateHandler = nil
        connection.cancel()
        pending?.resume(with: value)
    }
}

/// Shares the bounded, closeable receiver implementation used by the live app.
public final class SecureNetworkPlinkServer: PlinkEventReceiver, @unchecked Sendable {
    private let server: FoundationSecurePlinkServer
    public init(port: UInt16, codec: EncryptedFrameCodec,
                replayProtector: ReplayProtector = ReplayProtector(),
                expectedSourceDeviceId: String? = nil, expectedTargetDeviceId: String? = nil,
                stateStore: any FrameStateStoring = FileFrameStateStore.applicationDefault,
                readTimeout: TimeInterval = 5) throws {
        guard port > 0 else { throw NetworkPlinkServerError.invalidPort }
        server = FoundationSecurePlinkServer(port: port, codec: codec, replayProtector: replayProtector,
            expectedSourceDeviceId: expectedSourceDeviceId, expectedTargetDeviceId: expectedTargetDeviceId,
            stateStore: stateStore, readTimeout: readTimeout)
    }
    public func start(onEnvelope: @escaping @Sendable (Result<PlinkEnvelope, Error>) -> Void) throws {
        try server.start(onEnvelope: onEnvelope)
    }
    public func stop() { server.stop() }
}

public enum NetworkPlinkServerError: Error, Equatable {
    case invalidPort
    case emptyPayload
    case invalidFrame
}

/// A single bounded reader owns all closes. stop() shuts down IO and joins it.
/// start() binds synchronously, so a successful return means the listener exists.
public final class FoundationLengthPrefixedMessageServer: LengthPrefixedMessageReceiver, @unchecked Sendable {
    private let port: UInt16
    private let readTimeout: TimeInterval
    private let queue = DispatchQueue(label: "app.plink.frame-reader", qos: .utility)
    private let queueKey = DispatchSpecificKey<Bool>()
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var client: Int32 = -1
    private var stopped = false
    private var started = false

    public init(port: UInt16, readTimeout: TimeInterval = 5) {
        self.port = port
        self.readTimeout = readTimeout
        queue.setSpecific(key: queueKey, value: true)
    }

    public func start(onMessage: @escaping @Sendable (Result<Data, Error>) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        guard !started, !stopped else { throw FoundationPlinkServerError.stopped }
        guard port > 0, readTimeout > 0 else { throw NetworkPlinkServerError.invalidPort }
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw FoundationPlinkServerError.socketSetupFailed }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size),
            sin_family: sa_family_t(AF_INET), sin_port: port.bigEndian,
            sin_addr: in_addr(s_addr: INADDR_ANY.bigEndian), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { Darwin.close(fd); throw FoundationPlinkServerError.bindFailed }
        guard Darwin.listen(fd, SOMAXCONN) == 0 else { Darwin.close(fd); throw FoundationPlinkServerError.listenFailed }
        listener = fd
        started = true
        queue.async { self.run(fd, onMessage: onMessage) }
    }

    public func stop() {
        lock.lock()
        stopped = true
        if client >= 0 { Darwin.shutdown(client, SHUT_RDWR) }
        if listener >= 0 { Darwin.shutdown(listener, SHUT_RDWR) }
        lock.unlock()
        if DispatchQueue.getSpecific(key: queueKey) == nil { queue.sync {} }
    }

    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    private func run(_ fd: Int32, onMessage: @escaping @Sendable (Result<Data, Error>) -> Void) {
        defer {
            lock.lock()
            listener = -1
            Darwin.close(fd)
            lock.unlock()
        }
        while !isStopped {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&descriptor, 1, 100)
            if ready <= 0 { continue }
            if isStopped { break }
            let accepted = Darwin.accept(fd, nil, nil)
            if accepted < 0 { continue }
            lock.lock()
            if stopped { Darwin.close(accepted); lock.unlock(); break }
            client = accepted
            lock.unlock()
            let result: Result<Data, Error> = Result {
                let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(readTimeout * 1_000_000_000)
                let header = try readExact(count: 4, from: accepted, deadline: deadline)
                let size = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                guard size > 0, size <= 128 * 1024 else { throw NetworkPlinkServerError.invalidFrame }
                return try readExact(count: Int(size), from: accepted, deadline: deadline)
            }
            lock.lock()
            client = -1
            Darwin.close(accepted)
            lock.unlock()
            if !isStopped { onMessage(result) }
        }
    }

    private func readExact(count: Int, from fd: Int32, deadline: UInt64) throws -> Data {
        var output = Data(count: count)
        var offset = 0
        while offset < count {
            if isStopped { throw FoundationPlinkServerError.stopped }
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw FoundationPlinkServerError.timedOut }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let wait = Int32(min(100, max(1, (deadline - now) / 1_000_000)))
            let ready = Darwin.poll(&descriptor, 1, wait)
            if ready < 0 { if errno == EINTR { continue }; throw FoundationPlinkServerError.readFailed }
            if ready == 0 { continue }
            let read = output.withUnsafeMutableBytes {
                Darwin.recv(fd, $0.baseAddress!.advanced(by: offset), count - offset, MSG_DONTWAIT)
            }
            if read < 0 && (errno == EAGAIN || errno == EINTR) { continue }
            guard read > 0 else { throw FoundationPlinkServerError.readFailed }
            offset += read
        }
        return output
    }
}

public final class FoundationSecurePlinkServer: PlinkEventReceiver, @unchecked Sendable {
    private let server: FoundationLengthPrefixedMessageServer
    private let codec: EncryptedFrameCodec
    private let replayProtector: ReplayProtector
    private let stateStore: any FrameStateStoring
    private let expectedSourceDeviceId: String?
    private let expectedTargetDeviceId: String?

    public init(port: UInt16, codec: EncryptedFrameCodec,
                replayProtector: ReplayProtector = ReplayProtector(),
                expectedSourceDeviceId: String? = nil, expectedTargetDeviceId: String? = nil,
                stateStore: any FrameStateStoring = FileFrameStateStore.applicationDefault,
                readTimeout: TimeInterval = 5) {
        server = FoundationLengthPrefixedMessageServer(port: port, readTimeout: readTimeout)
        self.codec = codec
        self.replayProtector = replayProtector
        self.stateStore = stateStore
        self.expectedSourceDeviceId = expectedSourceDeviceId
        self.expectedTargetDeviceId = expectedTargetDeviceId
    }
    public func start(onEnvelope: @escaping @Sendable (Result<PlinkEnvelope, Error>) -> Void) throws {
        try server.start { result in
            onEnvelope(result.flatMap { data in Result {
                let frame = try PlinkJSON.decoder().decode(EncryptedPlinkFrame.self, from: data)
                return try self.codec.open(frame, replayProtector: self.replayProtector,
                    expectedSourceDeviceId: self.expectedSourceDeviceId, expectedTargetDeviceId: self.expectedTargetDeviceId,
                    stateStore: self.stateStore)
            } })
        }
    }
    public func stop() { server.stop() }
}

public enum FoundationPlinkServerError: Error, Equatable {
    case socketSetupFailed
    case bindFailed
    case listenFailed
    case acceptFailed
    case readFailed
    case timedOut
    case stopped
}
