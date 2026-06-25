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
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payload = try LengthPrefixedFrameCodec.encode(encoder.encode(frame))
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
    private let queue = DispatchQueue(label: "app.plink.secure-network-server", qos: .utility)

    public init(port: UInt16, codec: EncryptedFrameCodec, replayProtector: ReplayProtector = ReplayProtector()) throws {
        guard let port = NWEndpoint.Port(rawValue: port) else {
            throw NetworkPlinkServerError.invalidPort
        }
        self.listener = try NWListener(using: .tcp, on: port)
        self.codec = codec
        self.replayProtector = replayProtector
    }

    public func start(onEnvelope: @escaping @Sendable (Result<PlinkEnvelope, Error>) -> Void) throws {
        listener.newConnectionHandler = { connection in
            connection.start(queue: self.queue)
            connection.receive(minimumIncompleteLength: 4, maximumLength: 128 * 1024 + 4) { data, _, _, error in
                defer { connection.cancel() }
                if let error {
                    onEnvelope(.failure(error))
                    return
                }
                guard let data else {
                    onEnvelope(.failure(NetworkPlinkServerError.emptyPayload))
                    return
                }
                do {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    let payload = try LengthPrefixedFrameCodec.decode(data)
                    let frame = try decoder.decode(EncryptedPlinkFrame.self, from: payload)
                    onEnvelope(.success(try self.codec.open(frame, replayProtector: self.replayProtector)))
                } catch {
                    onEnvelope(.failure(error))
                }
            }
        }
        listener.start(queue: queue)
    }

    public func stop() {
        listener.cancel()
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
