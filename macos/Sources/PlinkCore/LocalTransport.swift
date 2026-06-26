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
    private let lock = NSLock()
    private var sequence: Int64 = 0

    public init(host: String, port: UInt16, codec: EncryptedFrameCodec) {
        self.host = NWEndpoint.Host(host)
        self.port = NWEndpoint.Port(rawValue: port) ?? NWEndpoint.Port(rawValue: 45731)!
        self.codec = codec
    }

    public func send(_ envelope: PlinkEnvelope) async throws {
        let nextSequence = lock.withLock {
            sequence += 1
            return sequence
        }
        let frame = try codec.seal(envelope, sequence: nextSequence)
        let payload = try LengthPrefixedFrameCodec.encode(PlinkJSON.encoder().encode(frame))
        let connection = NWConnection(host: host, port: port, using: .tcp)
        connection.start(queue: .global(qos: .utility))
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: payload, completion: .contentProcessed { error in
                connection.cancel()
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            })
        }
    }
}

public final class SecureNetworkPlinkServer: PlinkEventReceiver, @unchecked Sendable {
    private let listener: NWListener
    private let codec: EncryptedFrameCodec
    private let replayProtector: ReplayProtector
    private let expectedSourceDeviceId: String?
    private let expectedTargetDeviceId: String?
    private let queue = DispatchQueue(label: "app.plink.secure-network-server", qos: .utility)

    public init(
        port: UInt16,
        codec: EncryptedFrameCodec,
        replayProtector: ReplayProtector = ReplayProtector(),
        expectedSourceDeviceId: String? = nil,
        expectedTargetDeviceId: String? = nil
    ) throws {
        guard let port = NWEndpoint.Port(rawValue: port) else {
            throw NetworkPlinkServerError.invalidPort
        }
        self.listener = try NWListener(using: .tcp, on: port)
        self.codec = codec
        self.replayProtector = replayProtector
        self.expectedSourceDeviceId = expectedSourceDeviceId
        self.expectedTargetDeviceId = expectedTargetDeviceId
    }

    public func start(onEnvelope: @escaping @Sendable (Result<PlinkEnvelope, Error>) -> Void) throws {
        listener.newConnectionHandler = { connection in
            connection.start(queue: self.queue)
            self.receiveFrame(from: connection, buffer: Data(), onEnvelope: onEnvelope)
        }
        listener.start(queue: queue)
    }

    public func stop() {
        listener.cancel()
    }

    private func receiveFrame(
        from connection: NWConnection,
        buffer: Data,
        onEnvelope: @escaping @Sendable (Result<PlinkEnvelope, Error>) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, isComplete, error in
            if let error {
                connection.cancel()
                onEnvelope(.failure(error))
                return
            }
            guard let data, !data.isEmpty else {
                if isComplete {
                    connection.cancel()
                    onEnvelope(.failure(NetworkPlinkServerError.emptyPayload))
                } else {
                    self.receiveFrame(from: connection, buffer: buffer, onEnvelope: onEnvelope)
                }
                return
            }

            var nextBuffer = buffer
            nextBuffer.append(data)
            do {
                if let expectedLength = try LengthPrefixedFrameCodec.expectedTotalLength(nextBuffer),
                   nextBuffer.count >= expectedLength {
                    let payload = try LengthPrefixedFrameCodec.decode(nextBuffer.prefix(expectedLength))
                    let frame = try PlinkJSON.decoder().decode(EncryptedPlinkFrame.self, from: payload)
                    let envelope = try self.codec.open(
                        frame,
                        replayProtector: self.replayProtector,
                        expectedSourceDeviceId: self.expectedSourceDeviceId,
                        expectedTargetDeviceId: self.expectedTargetDeviceId
                    )
                    connection.cancel()
                    onEnvelope(.success(envelope))
                    return
                }
                if isComplete {
                    connection.cancel()
                    onEnvelope(.failure(NetworkPlinkServerError.invalidFrame))
                    return
                }
                self.receiveFrame(from: connection, buffer: nextBuffer, onEnvelope: onEnvelope)
            } catch {
                connection.cancel()
                onEnvelope(.failure(error))
            }
        }
    }
}

public enum NetworkPlinkServerError: Error, Equatable {
    case invalidPort
    case emptyPayload
    case invalidFrame
}

public final class FoundationLengthPrefixedMessageServer: LengthPrefixedMessageReceiver, @unchecked Sendable {
    private let port: UInt16
    private let queue = DispatchQueue(label: "app.plink.length-prefixed-message-server", qos: .utility)
    private let lock = NSLock()
    private var listenerSocket: Int32 = -1
    private var isStopped = false

    public init(port: UInt16) {
        self.port = port
    }

    public func start(onMessage: @escaping @Sendable (Result<Data, Error>) -> Void) throws {
        lock.withLock {
            isStopped = false
        }
        queue.async {
            self.run(onMessage: onMessage)
        }
    }

    public func stop() {
        let socket = lock.withLock {
            isStopped = true
            let socket = listenerSocket
            listenerSocket = -1
            return socket
        }
        if socket >= 0 {
            Darwin.shutdown(socket, SHUT_RDWR)
            Darwin.close(socket)
        }
    }

    private func run(onMessage: @escaping @Sendable (Result<Data, Error>) -> Void) {
        let serverSocket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            onMessage(.failure(FoundationPlinkServerError.socketSetupFailed))
            return
        }

        var reuse: Int32 = 1
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in(
            sin_len: UInt8(MemoryLayout<sockaddr_in>.size),
            sin_family: sa_family_t(AF_INET),
            sin_port: port.bigEndian,
            sin_addr: in_addr(s_addr: INADDR_ANY.bigEndian),
            sin_zero: (0, 0, 0, 0, 0, 0, 0, 0)
        )

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockAddress in
                Darwin.bind(serverSocket, sockAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            Darwin.close(serverSocket)
            onMessage(.failure(FoundationPlinkServerError.bindFailed))
            return
        }

        guard Darwin.listen(serverSocket, SOMAXCONN) == 0 else {
            Darwin.close(serverSocket)
            onMessage(.failure(FoundationPlinkServerError.listenFailed))
            return
        }

        lock.withLock {
            listenerSocket = serverSocket
        }

        while !lock.withLock({ isStopped }) {
            let clientSocket = Darwin.accept(serverSocket, nil, nil)
            guard clientSocket >= 0 else {
                if !lock.withLock({ isStopped }) {
                    onMessage(.failure(FoundationPlinkServerError.acceptFailed))
                }
                continue
            }
            receiveOne(clientSocket, onMessage: onMessage)
        }
        Darwin.close(serverSocket)
    }

    private func receiveOne(
        _ clientSocket: Int32,
        onMessage: @escaping @Sendable (Result<Data, Error>) -> Void
    ) {
        defer { Darwin.close(clientSocket) }
        do {
            let header = try readExact(count: 4, from: clientSocket)
            let frameSize = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard frameSize > 0, frameSize <= 128 * 1024 else {
                throw NetworkPlinkServerError.invalidFrame
            }
            onMessage(.success(try readExact(count: Int(frameSize), from: clientSocket)))
        } catch {
            onMessage(.failure(error))
        }
    }

    private func readExact(count: Int, from socket: Int32) throws -> Data {
        var output = Data(count: count)
        var offset = 0
        while offset < count {
            let bytesRead = output.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(socket, rawBuffer.baseAddress!.advanced(by: offset), count - offset)
            }
            guard bytesRead > 0 else {
                throw FoundationPlinkServerError.readFailed
            }
            offset += bytesRead
        }
        return output
    }
}

public final class FoundationSecurePlinkServer: PlinkEventReceiver, @unchecked Sendable {
    private let port: UInt16
    private let codec: EncryptedFrameCodec
    private let replayProtector: ReplayProtector
    private let expectedSourceDeviceId: String?
    private let expectedTargetDeviceId: String?
    private let queue = DispatchQueue(label: "app.plink.foundation-network-server", qos: .utility)
    private let lock = NSLock()
    private var listenerSocket: Int32 = -1
    private var isStopped = false

    public init(
        port: UInt16,
        codec: EncryptedFrameCodec,
        replayProtector: ReplayProtector = ReplayProtector(),
        expectedSourceDeviceId: String? = nil,
        expectedTargetDeviceId: String? = nil
    ) {
        self.port = port
        self.codec = codec
        self.replayProtector = replayProtector
        self.expectedSourceDeviceId = expectedSourceDeviceId
        self.expectedTargetDeviceId = expectedTargetDeviceId
    }

    public func start(onEnvelope: @escaping @Sendable (Result<PlinkEnvelope, Error>) -> Void) throws {
        lock.withLock {
            isStopped = false
        }
        queue.async {
            self.run(onEnvelope: onEnvelope)
        }
    }

    public func stop() {
        let socket = lock.withLock {
            isStopped = true
            let socket = listenerSocket
            listenerSocket = -1
            return socket
        }
        if socket >= 0 {
            Darwin.shutdown(socket, SHUT_RDWR)
            Darwin.close(socket)
        }
    }

    private func run(onEnvelope: @escaping @Sendable (Result<PlinkEnvelope, Error>) -> Void) {
        let serverSocket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            onEnvelope(.failure(FoundationPlinkServerError.socketSetupFailed))
            return
        }

        var reuse: Int32 = 1
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in(
            sin_len: UInt8(MemoryLayout<sockaddr_in>.size),
            sin_family: sa_family_t(AF_INET),
            sin_port: port.bigEndian,
            sin_addr: in_addr(s_addr: INADDR_ANY.bigEndian),
            sin_zero: (0, 0, 0, 0, 0, 0, 0, 0)
        )

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockAddress in
                Darwin.bind(serverSocket, sockAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            Darwin.close(serverSocket)
            onEnvelope(.failure(FoundationPlinkServerError.bindFailed))
            return
        }

        guard Darwin.listen(serverSocket, SOMAXCONN) == 0 else {
            Darwin.close(serverSocket)
            onEnvelope(.failure(FoundationPlinkServerError.listenFailed))
            return
        }

        lock.withLock {
            listenerSocket = serverSocket
        }

        while !lock.withLock({ isStopped }) {
            let clientSocket = Darwin.accept(serverSocket, nil, nil)
            guard clientSocket >= 0 else {
                if !lock.withLock({ isStopped }) {
                    onEnvelope(.failure(FoundationPlinkServerError.acceptFailed))
                }
                continue
            }
            receiveOne(clientSocket, onEnvelope: onEnvelope)
        }
        Darwin.close(serverSocket)
    }

    private func receiveOne(
        _ clientSocket: Int32,
        onEnvelope: @escaping @Sendable (Result<PlinkEnvelope, Error>) -> Void
    ) {
        defer { Darwin.close(clientSocket) }
        do {
            let header = try readExact(count: 4, from: clientSocket)
            let frameSize = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard frameSize > 0, frameSize <= 128 * 1024 else {
                throw NetworkPlinkServerError.invalidFrame
            }
            let payload = try readExact(count: Int(frameSize), from: clientSocket)
            let frame = try PlinkJSON.decoder().decode(EncryptedPlinkFrame.self, from: payload)
            let envelope = try codec.open(
                frame,
                replayProtector: replayProtector,
                expectedSourceDeviceId: expectedSourceDeviceId,
                expectedTargetDeviceId: expectedTargetDeviceId
            )
            onEnvelope(.success(envelope))
        } catch {
            onEnvelope(.failure(error))
        }
    }

    private func readExact(count: Int, from socket: Int32) throws -> Data {
        var output = Data(count: count)
        var offset = 0
        while offset < count {
            let bytesRead = output.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(socket, rawBuffer.baseAddress!.advanced(by: offset), count - offset)
            }
            guard bytesRead > 0 else {
                throw FoundationPlinkServerError.readFailed
            }
            offset += bytesRead
        }
        return output
    }
}

public enum FoundationPlinkServerError: Error, Equatable {
    case socketSetupFailed
    case bindFailed
    case listenFailed
    case acceptFailed
    case readFailed
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
