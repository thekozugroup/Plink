import Foundation
import Network

public protocol PlinkTransport: Sendable {
    func send(_ envelope: PlinkEnvelope) async throws
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
