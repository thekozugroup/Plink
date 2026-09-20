import Foundation
import PlinkCore
import Testing

@Test func durableFrameStateSurvivesRecreationAndAcceptsReordering() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = FileFrameStateStore(directory: directory)
    #expect(try first.reserveSequence(scope: "peer-a") == 1)
    #expect(try FileFrameStateStore(directory: directory).reserveSequence(scope: "peer-a") == 2)
    try first.accept(scope: "peer-a", sequence: 2, nonce: "two")
    try FileFrameStateStore(directory: directory).accept(scope: "peer-a", sequence: 1, nonce: "one")
    #expect(throws: PayloadPolicyError.replayDetected) {
        try FileFrameStateStore(directory: directory).accept(scope: "peer-a", sequence: 1, nonce: "one")
    }
    try first.accept(scope: "peer-b", sequence: 1, nonce: "one")
}

@Test func durableFrameStateFailsClosedOnCorruption() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FileFrameStateStore(directory: directory)
    _ = try store.reserveSequence(scope: "test")
    for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
        try Data("broken".utf8).write(to: file)
    }
    #expect(throws: (any Error).self) { _ = try store.reserveSequence(scope: "test") }
}

@Test func codecPersistsOnlyFullyAuthenticatedFramesAndBindsScope() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let codec = EncryptedFrameCodec(sessionKey: Data("synthetic".utf8))
    let now = Date(timeIntervalSince1970: 1_900_000_000)
    let envelope = PlinkEnvelope(id: "test", type: .clipboardUpdated, sentAt: now,
        sourceDeviceId: "pixel", targetDeviceId: "mac", payload: ["text": .string("synthetic")])
    let frame = try codec.seal(envelope, sequence: 1, issuedAt: now)
    let store = FileFrameStateStore(directory: directory)
    var invalid = frame
    invalid.signature = "invalid"
    #expect(throws: PayloadPolicyError.invalidSignature) { _ = try codec.open(invalid, now: now, stateStore: store) }
    #expect(try codec.open(frame, now: now, stateStore: store) == envelope)
    #expect(throws: PayloadPolicyError.replayDetected) {
        _ = try codec.open(frame, now: now, stateStore: FileFrameStateStore(directory: directory))
    }
    #expect(codec.stateScope(sourceDeviceId: "a|b", targetDeviceId: "c") != codec.stateScope(sourceDeviceId: "a", targetDeviceId: "b|c"))
    #expect(codec.stateScope(sourceDeviceId: "a", targetDeviceId: "b") != codec.stateScope(sourceDeviceId: "b", targetDeviceId: "a"))
    #expect(codec.stateScope(sourceDeviceId: "a", targetDeviceId: "b") != EncryptedFrameCodec(sessionKey: Data("other".utf8)).stateScope(sourceDeviceId: "a", targetDeviceId: "b"))
}

@Test func replayWindowKeepsDuplicateRejectionAfterEviction() throws {
    let state = InMemoryFrameStateStore()
    try state.accept(scope: "test", sequence: 1, nonce: "one")
    try state.accept(scope: "test", sequence: 4097, nonce: "new")
    #expect(throws: PayloadPolicyError.replayDetected) { try state.accept(scope: "test", sequence: 1, nonce: "one") }
    try state.accept(scope: "test", sequence: 4096, nonce: "reordered")
    #expect(throws: PayloadPolicyError.replayDetected) { try state.accept(scope: "test", sequence: 4096, nonce: "reordered") }
}

@Test func parallelReservationsAcrossStoreInstancesAreUnique() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let results = ReservationResults()
    DispatchQueue.concurrentPerform(iterations: 32) { _ in
        do { results.add(try FileFrameStateStore(directory: directory).reserveSequence(scope: "peer")) }
        catch { Issue.record("Reservation failed: \(error)") }
    }
    #expect(results.values == Set(Int64(1)...Int64(32)))
}
private final class ReservationResults: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Set<Int64> = []
    func add(_ value: Int64) { lock.lock(); stored.insert(value); lock.unlock() }
    var values: Set<Int64> { lock.lock(); defer { lock.unlock() }; return stored }
}

@Test func persistenceFailurePreventsAuthenticatedDispatch() throws {
    let codec = EncryptedFrameCodec(sessionKey: Data("synthetic".utf8))
    let now = Date.now
    let envelope = PlinkEnvelope(id: "test", type: .clipboardUpdated, sentAt: now,
        sourceDeviceId: "pixel", targetDeviceId: "mac", payload: ["text": .string("synthetic")])
    let frame = try codec.seal(envelope, sequence: 1, issuedAt: now)
    #expect(throws: POSIXError.self) { _ = try codec.open(frame, now: now, stateStore: FailingStateStore()) }
}
private struct FailingStateStore: FrameStateStoring {
    func reserveSequence(scope: String) throws -> Int64 { throw POSIXError(.EIO) }
    func accept(scope: String, sequence: Int64, nonce: String) throws { throw POSIXError(.EIO) }
}
