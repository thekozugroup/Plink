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

public final class NetworkPlinkClient: PlinkTransport, @unchecked Sendable {
    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port

    public init(host: String, port: UInt16) {
        self.host = NWEndpoint.Host(host)
        self.port = NWEndpoint.Port(rawValue: port) ?? NWEndpoint.Port(rawValue: 45731)!
    }

    public func send(_ envelope: PlinkEnvelope) async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payload = try encoder.encode(envelope)
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

public final class NetworkPlinkServer: PlinkEventReceiver, @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "app.plink.network-server", qos: .utility)

    public init(port: UInt16) throws {
        guard let port = NWEndpoint.Port(rawValue: port) else {
            throw NetworkPlinkServerError.invalidPort
        }
        self.listener = try NWListener(using: .tcp, on: port)
    }

    public func start(onEnvelope: @escaping @Sendable (Result<PlinkEnvelope, Error>) -> Void) throws {
        listener.newConnectionHandler = { connection in
            connection.start(queue: self.queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 128 * 1024) { data, _, _, error in
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
                    onEnvelope(.success(try decoder.decode(PlinkEnvelope.self, from: data)))
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
}
