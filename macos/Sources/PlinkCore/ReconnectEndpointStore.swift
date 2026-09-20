import CryptoKit
import Darwin
import Foundation

public struct ReconnectEndpointRecord: Codable, Equatable, Sendable {
    public let version: Int
    public let localID: String
    public let peerID: String
    public let sessionID: String
    public let endpoint: String
    public let proofID: String
    public let tag: String

    public init(
        version: Int = 1,
        localID: String,
        peerID: String,
        sessionID: String,
        endpoint: String,
        proofID: String,
        tag: String
    ) {
        self.version = version
        self.localID = localID
        self.peerID = peerID
        self.sessionID = sessionID
        self.endpoint = endpoint
        self.proofID = proofID
        self.tag = tag
    }
}

public enum ReconnectEndpointStoreError: Error, Equatable, Sendable {
    case invalidRecord
    case staleLifecycle
    case storageFailure(Int32)
}

final class ReconnectCandidateCommitAuthority: @unchecked Sendable {
    fileprivate let id = UUID()
    fileprivate weak var owner: ReconnectCommitAuthority?

    fileprivate init(owner: ReconnectCommitAuthority) { self.owner = owner }

    func invalidate() { owner?.invalidate(candidateID: id) }
}

/// One reconnect attempt owns this token. Invalidation and the sidecar rename
/// linearize on the same lock, so a cancelled attempt cannot rename afterward.
public final class ReconnectCommitAuthority: @unchecked Sendable {
    private let lock = NSLock()
    private let deadline: ContinuousClock.Instant?
    private var current = true
    private var candidates: [UUID: ContinuousClock.Instant] = [:]

    public init(deadline: ContinuousClock.Instant? = nil) {
        self.deadline = deadline
    }

    public func invalidate() {
        lock.withLock {
            current = false
            candidates.removeAll()
        }
    }

    func makeCandidate(deadline candidateDeadline: ContinuousClock.Instant) throws -> ReconnectCandidateCommitAuthority {
        try lock.withLock {
            let now = ContinuousClock.now
            guard current, now < candidateDeadline, deadline.map({ now < $0 }) ?? true else {
                throw ReconnectEndpointStoreError.staleLifecycle
            }
            let candidate = ReconnectCandidateCommitAuthority(owner: self)
            candidates[candidate.id] = candidateDeadline
            return candidate
        }
    }

    fileprivate func invalidate(candidateID: UUID) {
        lock.withLock { candidates.removeValue(forKey: candidateID) }
    }

    func withCurrent<T>(
        candidate: ReconnectCandidateCommitAuthority? = nil,
        deadline operationDeadline: ContinuousClock.Instant? = nil,
        _ body: () throws -> T
    ) throws -> T {
        try lock.withLock {
            let now = ContinuousClock.now
            guard current, deadline.map({ now < $0 }) ?? true,
                  operationDeadline.map({ now < $0 }) ?? true else {
                throw ReconnectEndpointStoreError.staleLifecycle
            }
            if let candidate {
                guard candidate.owner === self, let candidateDeadline = candidates[candidate.id],
                      now < candidateDeadline else { throw ReconnectEndpointStoreError.staleLifecycle }
            }
            return try body()
        }
    }
}

protocol ReconnectEndpointCommitting: Sendable {
    @discardableResult
    func commit(
        localID: String,
        peerID: String,
        sessionID: String,
        endpoint: IPv4Endpoint,
        proofID: String,
        sessionKey: Data,
        authority: ReconnectCommitAuthority,
        candidateAuthority: ReconnectCandidateCommitAuthority?,
        deadline: ContinuousClock.Instant?
    ) throws -> ReconnectEndpointRecord
}

public final class ReconnectEndpointStore: ReconnectEndpointCommitting, @unchecked Sendable {
    public static let applicationDefault = ReconnectEndpointStore(directory:
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.thekozugroup.plink/reconnect-endpoints", isDirectory: true))

    private static let lock = NSLock()
    private let directory: URL

    public init(directory: URL) { self.directory = directory }

    public static func authenticationInput(for record: ReconnectEndpointRecord) -> Data {
        let fields = [String(record.version), record.localID, record.peerID, record.sessionID,
                      record.endpoint, record.proofID]
        return Data(fields.map { "\($0.utf8.count):\($0)" }.joined().utf8)
    }

    public static func authenticationTag(for record: ReconnectEndpointRecord, sessionKey: Data) -> String {
        Data(HMAC<SHA256>.authenticationCode(
            for: authenticationInput(for: record), using: authenticationKey(sessionKey))).base64EncodedString()
    }

    public static func fileName(localID: String, peerID: String, sessionKey: Data) -> String {
        let scope = EncryptedFrameCodec(sessionKey: sessionKey).stateScope(
            sourceDeviceId: localID, targetDeviceId: peerID)
        return SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined() + ".json"
    }

    public func load(
        localID: String,
        peerID: String,
        sessionID: String,
        sessionKey: Data
    ) throws -> ReconnectEndpointRecord? {
        try Self.lock.withLock {
            guard Self.validID(localID), Self.validID(peerID), Self.validID(sessionID) else { return nil }
            let file = fileURL(localID: localID, peerID: peerID, sessionKey: sessionKey)
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            let data = try Data(contentsOf: file, options: .mappedIfSafe)
            guard data.count <= 2_048,
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let raw = object as? [String: Any],
                  Set(raw.keys) == ["version", "localID", "peerID", "sessionID", "endpoint", "proofID", "tag"],
                  let version = raw["version"] as? Int, version == 1,
                  let storedLocal = raw["localID"] as? String, storedLocal == localID,
                  let storedPeer = raw["peerID"] as? String, storedPeer == peerID,
                  let storedSession = raw["sessionID"] as? String, storedSession == sessionID,
                  let endpoint = raw["endpoint"] as? String, (try? IPv4Endpoint(endpoint)) != nil,
                  let proofID = raw["proofID"] as? String, Self.validProofID(proofID),
                  let tag = raw["tag"] as? String,
                  let tagData = Data(base64Encoded: tag) else { return nil }
            let record = ReconnectEndpointRecord(localID: localID, peerID: peerID, sessionID: sessionID,
                endpoint: endpoint, proofID: proofID, tag: tag)
            guard HMAC<SHA256>.isValidAuthenticationCode(
                tagData,
                authenticating: Self.authenticationInput(for: record),
                using: Self.authenticationKey(sessionKey)
            ) else { return nil }
            return record
        }
    }

    @discardableResult
    public func commit(
        localID: String,
        peerID: String,
        sessionID: String,
        endpoint: IPv4Endpoint,
        proofID: String,
        sessionKey: Data,
        authority: ReconnectCommitAuthority,
        deadline: ContinuousClock.Instant? = nil
    ) throws -> ReconnectEndpointRecord {
        try commit(localID: localID, peerID: peerID, sessionID: sessionID, endpoint: endpoint,
            proofID: proofID, sessionKey: sessionKey, authority: authority,
            candidateAuthority: nil, deadline: deadline)
    }

    @discardableResult
    func commit(
        localID: String,
        peerID: String,
        sessionID: String,
        endpoint: IPv4Endpoint,
        proofID: String,
        sessionKey: Data,
        authority: ReconnectCommitAuthority,
        candidateAuthority: ReconnectCandidateCommitAuthority?,
        deadline: ContinuousClock.Instant? = nil
    ) throws -> ReconnectEndpointRecord {
        try Self.lock.withLock {
            guard Self.validID(localID), Self.validID(peerID), Self.validID(sessionID),
                  Self.validProofID(proofID) else { throw ReconnectEndpointStoreError.invalidRecord }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            var record = ReconnectEndpointRecord(localID: localID, peerID: peerID, sessionID: sessionID,
                endpoint: endpoint.description, proofID: proofID, tag: "")
            let tag = Self.authenticationTag(for: record, sessionKey: sessionKey)
            record = ReconnectEndpointRecord(localID: localID, peerID: peerID, sessionID: sessionID,
                endpoint: endpoint.description, proofID: proofID, tag: tag)
            let data = try PlinkJSON.encoder(sortedKeys: true).encode(record)
            guard data.count <= 2_048 else { throw ReconnectEndpointStoreError.invalidRecord }

            let destination = fileURL(localID: localID, peerID: peerID, sessionKey: sessionKey)
            let temporary = directory.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
            let descriptor = Darwin.open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { throw ReconnectEndpointStoreError.storageFailure(errno) }
            var removeTemporary = true
            defer {
                Darwin.close(descriptor)
                if removeTemporary { try? FileManager.default.removeItem(at: temporary) }
            }
            try writeAll(data, descriptor: descriptor)
            guard Darwin.fsync(descriptor) == 0 else { throw ReconnectEndpointStoreError.storageFailure(errno) }
            try authority.withCurrent(candidate: candidateAuthority, deadline: deadline) {
                guard Darwin.rename(temporary.path, destination.path) == 0 else {
                    throw ReconnectEndpointStoreError.storageFailure(errno)
                }
            }
            removeTemporary = false
            let directoryDescriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY)
            guard directoryDescriptor >= 0 else { throw ReconnectEndpointStoreError.storageFailure(errno) }
            defer { Darwin.close(directoryDescriptor) }
            guard Darwin.fsync(directoryDescriptor) == 0 else {
                throw ReconnectEndpointStoreError.storageFailure(errno)
            }
            return record
        }
    }

    public func remove(localID: String, peerID: String, sessionKey: Data) throws {
        try Self.lock.withLock {
            let file = fileURL(localID: localID, peerID: peerID, sessionKey: sessionKey)
            guard FileManager.default.fileExists(atPath: file.path) else { return }
            try FileManager.default.removeItem(at: file)
            let descriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY)
            guard descriptor >= 0 else { throw ReconnectEndpointStoreError.storageFailure(errno) }
            defer { Darwin.close(descriptor) }
            guard Darwin.fsync(descriptor) == 0 else { throw ReconnectEndpointStoreError.storageFailure(errno) }
        }
    }

    private func fileURL(localID: String, peerID: String, sessionKey: Data) -> URL {
        directory.appendingPathComponent(Self.fileName(localID: localID, peerID: peerID, sessionKey: sessionKey))
    }

    private static func authenticationKey(_ sessionKey: Data) -> SymmetricKey {
        let material = HMAC<SHA256>.authenticationCode(
            for: Data("plink-reconnect-endpoint-v1".utf8), using: SymmetricKey(data: sessionKey))
        return SymmetricKey(data: Data(material))
    }

    private static func validID(_ value: String) -> Bool {
        (1...128).contains(value.utf8.count)
    }

    private static func validProofID(_ value: String) -> Bool {
        value.utf8.count == 43 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) ||
                ($0 >= 97 && $0 <= 122) || $0 == 45 || $0 == 95
        }
    }

    private func writeAll(_ data: Data, descriptor: Int32) throws {
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { bytes in
                Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), data.count - offset)
            }
            if written < 0, errno == EINTR { continue }
            guard written > 0 else { throw ReconnectEndpointStoreError.storageFailure(errno) }
            offset += written
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
