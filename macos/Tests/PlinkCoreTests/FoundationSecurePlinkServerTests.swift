import Darwin
import Foundation
import PlinkCore
import Testing

@Test
func foundationSecureServerReceivesAndroidCompatibleFrame() throws {
    let port = UInt16.random(in: 48_000...52_000)
    let sessionKey = Data("foundation-server-secret".utf8)
    let expectedEnvelope = clipboardEnvelope()
    let server = FoundationSecurePlinkServer(
        port: port,
        codec: EncryptedFrameCodec(sessionKey: sessionKey),
        expectedSourceDeviceId: "pixel",
        expectedTargetDeviceId: "mac"
    )
    let results = ResultCollector(expectedCount: 1)

    try server.start { result in
        results.append(result)
    }
    defer { server.stop() }
    usleep(100_000)

    try sendRawFrame(
        try encryptedPayload(for: expectedEnvelope, sessionKey: sessionKey, sequence: 1, nonce: "server-success"),
        to: port
    )

    #expect(results.wait())
    guard case .success(let envelope) = results.values.first else {
        Issue.record("Expected successful envelope")
        return
    }
    #expect(envelope == expectedEnvelope)
}

@Test
func foundationSecureServerRejectsWrongDeviceId() throws {
    let port = UInt16.random(in: 52_001...56_000)
    let sessionKey = Data("foundation-server-secret".utf8)
    let server = FoundationSecurePlinkServer(
        port: port,
        codec: EncryptedFrameCodec(sessionKey: sessionKey),
        expectedSourceDeviceId: "other-pixel",
        expectedTargetDeviceId: "mac"
    )
    let results = ResultCollector(expectedCount: 1)

    try server.start { result in
        results.append(result)
    }
    defer { server.stop() }
    usleep(100_000)

    try sendRawFrame(
        try encryptedPayload(for: clipboardEnvelope(), sessionKey: sessionKey, sequence: 1, nonce: "wrong-device"),
        to: port
    )

    #expect(results.wait())
    guard case .failure(let error) = results.values.first else {
        Issue.record("Expected device mismatch failure")
        return
    }
    #expect(error as? PayloadPolicyError == .deviceMismatch)
}

@Test
func foundationSecureServerRejectsReplay() throws {
    let port = UInt16.random(in: 56_001...60_000)
    let sessionKey = Data("foundation-server-secret".utf8)
    let server = FoundationSecurePlinkServer(
        port: port,
        codec: EncryptedFrameCodec(sessionKey: sessionKey),
        expectedSourceDeviceId: "pixel",
        expectedTargetDeviceId: "mac"
    )
    let results = ResultCollector(expectedCount: 2)
    let payload = try encryptedPayload(
        for: clipboardEnvelope(),
        sessionKey: sessionKey,
        sequence: 1,
        nonce: "replay"
    )

    try server.start { result in
        results.append(result)
    }
    defer { server.stop() }
    usleep(100_000)

    try sendRawFrame(payload, to: port)
    try sendRawFrame(payload, to: port)

    #expect(results.wait())
    #expect(results.values.count == 2)
    guard case .failure(let error) = results.values.last else {
        Issue.record("Expected replay failure")
        return
    }
    #expect(error as? PayloadPolicyError == .replayDetected)
}

private final class ResultCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private let expectedCount: Int
    private var storage: [Result<PlinkEnvelope, Error>] = []

    init(expectedCount: Int) {
        self.expectedCount = expectedCount
    }

    func append(_ result: Result<PlinkEnvelope, Error>) {
        lock.lock()
        storage.append(result)
        let shouldSignal = storage.count >= expectedCount
        lock.unlock()
        if shouldSignal {
            semaphore.signal()
        }
    }

    func wait() -> Bool {
        semaphore.wait(timeout: .now() + 3) == .success
    }

    var values: [Result<PlinkEnvelope, Error>] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private func clipboardEnvelope() -> PlinkEnvelope {
    PlinkEnvelope(
        id: "evt-clipboard",
        type: .clipboardUpdated,
        sentAt: Date(timeIntervalSince1970: 1_782_000_000),
        sourceDeviceId: "pixel",
        targetDeviceId: "mac",
        payload: ["text": .string("hello from pixel")]
    )
}

private func encryptedPayload(
    for envelope: PlinkEnvelope,
    sessionKey: Data,
    sequence: Int64,
    nonce: String
) throws -> Data {
    let frame = try EncryptedFrameCodec(sessionKey: sessionKey).seal(
        envelope,
        sequence: sequence,
        nonce: nonce,
        issuedAt: .now,
        iv: Data(repeating: UInt8(sequence), count: 12)
    )
    return try LengthPrefixedFrameCodec.encode(PlinkJSON.encoder().encode(frame))
}

private func sendRawFrame(_ payload: Data, to port: UInt16) throws {
    let clientSocket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    #expect(clientSocket >= 0)
    defer { Darwin.close(clientSocket) }

    var address = sockaddr_in(
        sin_len: UInt8(MemoryLayout<sockaddr_in>.size),
        sin_family: sa_family_t(AF_INET),
        sin_port: port.bigEndian,
        sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")),
        sin_zero: (0, 0, 0, 0, 0, 0, 0, 0)
    )

    var connected: Int32 = -1
    for attempt in 0..<50 {
        connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockAddress in
                Darwin.connect(clientSocket, sockAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connected == 0 || attempt == 49 {
            break
        }
        usleep(20_000)
    }
    #expect(connected == 0)

    try payload.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else { return }
        var totalWritten = 0
        while totalWritten < payload.count {
            let written = Darwin.write(
                clientSocket,
                baseAddress.advanced(by: totalWritten),
                payload.count - totalWritten
            )
            if written <= 0 {
                throw FoundationPlinkServerError.readFailed
            }
            totalWritten += written
        }
    }
}
