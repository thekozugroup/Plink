import Foundation
import Network

public protocol PlinkTransport: Sendable {
    func send(_ envelope: PlinkEnvelope) async throws
}

public protocol PlinkEventReceiver: Sendable {
    func start(onEnvelope: @escaping @Sendable (Result<PlinkEnvelope, Error>) -> Void) throws
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

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
