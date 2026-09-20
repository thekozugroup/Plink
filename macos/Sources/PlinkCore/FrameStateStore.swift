import CryptoKit
import Darwin
import Foundation

public protocol FrameStateStoring: Sendable {
    func reserveSequence(scope: String) throws -> Int64
    func accept(scope: String, sequence: Int64, nonce: String) throws
}

private struct FrameState: Codable {
    var sent: Int64 = 0
    var highest: Int64 = 0
    var received: [Int64: String] = [:]

    mutating func accept(sequence: Int64, nonce: String) throws {
        guard sequence > 0, !nonce.isEmpty, sequence > highest - 4096,
              received[sequence] == nil, !received.values.contains(nonce) else {
            throw PayloadPolicyError.replayDetected
        }
        highest = max(highest, sequence)
        received[sequence] = nonce
        received = received.filter { $0.key > highest - 4096 }
    }
}

/// State belongs to the durable key and directional peers, never to a socket.
/// Keep this directory for as long as the corresponding pairing key exists.
public final class FileFrameStateStore: FrameStateStoring, @unchecked Sendable {
    public static let applicationDefault = FileFrameStateStore(directory:
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.thekozugroup.plink/transport-state"))
    private let directory: URL
    // flock serializes separate instances/processes; this lock also protects threads.
    private static let lock = NSLock()
    public init(directory: URL) { self.directory = directory }

    public func reserveSequence(scope: String) throws -> Int64 {
        try update(scope: scope) { state in
            guard state.sent < Int64.max else { throw PayloadPolicyError.replayDetected }
            state.sent += 1
            return state.sent
        }
    }
    public func accept(scope: String, sequence: Int64, nonce: String) throws {
        try update(scope: scope) { try $0.accept(sequence: sequence, nonce: nonce) }
    }
    private func update<T>(scope: String, _ body: (inout FrameState) throws -> T) throws -> T {
        Self.lock.lock(); defer { Self.lock.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let name = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
        let lockFD = Darwin.open(directory.appendingPathComponent(name + ".lock").path, O_CREAT | O_RDWR, 0o600)
        guard lockFD >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(lockFD) }
        guard flock(lockFD, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
        defer { flock(lockFD, LOCK_UN) }
        let file = directory.appendingPathComponent(name + ".json")
        var state = FrameState()
        if FileManager.default.fileExists(atPath: file.path) {
            state = try JSONDecoder().decode(FrameState.self, from: Data(contentsOf: file))
        }
        let result = try body(&state)
        try JSONEncoder().encode(state).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let fd = Darwin.open(file.path, O_RDONLY)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(fd) }
        guard fsync(fd) == 0 else { throw POSIXError(.EIO) }
        let dirFD = Darwin.open(directory.path, O_RDONLY)
        guard dirFD >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(dirFD) }
        guard fsync(dirFD) == 0 else { throw POSIXError(.EIO) }
        return result
    }
}

public final class InMemoryFrameStateStore: FrameStateStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var states: [String: FrameState] = [:]
    public init() {}
    public func reserveSequence(scope: String) throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        var state = states[scope] ?? FrameState()
        guard state.sent < Int64.max else { throw PayloadPolicyError.replayDetected }
        state.sent += 1
        states[scope] = state
        return state.sent
    }
    public func accept(scope: String, sequence: Int64, nonce: String) throws {
        lock.lock(); defer { lock.unlock() }
        var state = states[scope] ?? FrameState()
        try state.accept(sequence: sequence, nonce: nonce)
        states[scope] = state
    }
}
