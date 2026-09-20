import Foundation
import Darwin

/// A write-ahead rollback record covers the separate metadata and Keychain stores.
/// The journal contains no secret key. An unfinished save is rolled back on launch.
public final class MacPairingFinalization: @unchecked Sendable {
    public static let defaultDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.thekozugroup.plink/pairing-finalization")
    private struct Journal: Codable {
        let replacement: PairedDevice
        let previous: PairedDevice?
        let keyAlreadyExisted: Bool
        let previousSelection: Selection?
    }
    private struct Selection: Codable {
        let deviceId: String
        let sessionId: String
        let localDeviceId: String?
    }
    public enum Failure: Error { case pendingRecovery, keyConflict, rollbackFailed, invalidLocalIdentity }
    private static let lock = NSRecursiveLock()
    private let devices: any PairingStore
    private let secrets: any PairingSecretStore
    private let directory: URL
    private var pendingJournal: Journal?
    private var journalURL: URL { directory.appendingPathComponent("pending.json") }
    private var selectionURL: URL { directory.appendingPathComponent("active.json") }

    public init(devices: any PairingStore, secrets: any PairingSecretStore, directory: URL = defaultDirectory) {
        self.devices = devices; self.secrets = secrets; self.directory = directory
    }

    /// Live resources must be invalidated before durable rollback, even on first pairing.
    public static func activateAndCommit(activate: () throws -> Void, commit: () throws -> Void,
                                         invalidate: () -> Void) throws {
        do { try activate(); try commit() }
        catch { invalidate(); throw error }
    }

    /// No first-record fallback: even one legacy record needs explicit selection
    /// through pairing. Bind selection to its session to reject stale replacement.
    public func selectedDevice(localDeviceID: String) throws -> PairedDevice? {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard pendingJournal == nil, !FileManager.default.fileExists(atPath: journalURL.path),
              localDeviceID != "mac-demo", !localDeviceID.isEmpty,
              let selection = try readSelection(), selection.localDeviceId == localDeviceID else { return nil }
        return try devices.all().first {
            $0.id == selection.deviceId && $0.sessionId == selection.sessionId && $0.trusted && $0.securityVersion == 2
        }
    }

    public func save(_ device: PairedDevice, key: Data, localDeviceID: String) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard localDeviceID != "mac-demo", localDeviceID.hasPrefix("mac-"),
              UUID(uuidString: String(localDeviceID.dropFirst(4))) != nil else { throw Failure.invalidLocalIdentity }
        guard pendingJournal == nil, !FileManager.default.fileExists(atPath: journalURL.path) else { throw Failure.pendingRecovery }
        let previous = try devices.all().first { $0.id == device.id }
        let existingKey = try secrets.load(sessionId: device.sessionId)
        guard key.count == 32, existingKey == nil || existingKey == key else { throw Failure.keyConflict }
        let journal = Journal(replacement: device, previous: previous, keyAlreadyExisted: existingKey != nil,
                              previousSelection: try readSelection())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
        let handle = try FileHandle(forWritingTo: journalURL)
        defer { try? handle.close() }
        try handle.synchronize()
        try syncDirectory()
        pendingJournal = journal
        do {
            if existingKey == nil { try secrets.save(sessionKey: key, sessionId: device.sessionId) }
            try devices.save(device)
            try writeSelection(Selection(deviceId: device.id, sessionId: device.sessionId, localDeviceId: localDeviceID))
        } catch {
            do { try rollback() } catch { throw Failure.rollbackFailed }
            throw error
        }
    }

    public func rollback() throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let journal: Journal
        if let pendingJournal { journal = pendingJournal }
        else if FileManager.default.fileExists(atPath: journalURL.path) {
            journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journalURL))
        } else { return }
        // Re-establish recovery data if commit unlinked it before fsync failed.
        if !FileManager.default.fileExists(atPath: journalURL.path) {
            try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
            let handle = try FileHandle(forWritingTo: journalURL)
            defer { try? handle.close() }
            try handle.synchronize()
            try syncDirectory()
        }
        if let previous = journal.previous { try devices.save(previous) }
        else { try devices.remove(deviceId: journal.replacement.id) }
        if !journal.keyAlreadyExisted { try secrets.remove(sessionId: journal.replacement.sessionId) }
        try writeSelection(journal.previousSelection)
        try commit()
    }

    public func commit() throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        if FileManager.default.fileExists(atPath: journalURL.path) {
            try FileManager.default.removeItem(at: journalURL)
        } else if pendingJournal == nil { return }
        try syncDirectory()
        pendingJournal = nil
    }

    private func syncDirectory() throws {
        let fd = Darwin.open(directory.path, O_RDONLY)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(fd) }
        guard fsync(fd) == 0 else { throw POSIXError(.EIO) }
    }

    private func readSelection() throws -> Selection? {
        guard FileManager.default.fileExists(atPath: selectionURL.path) else { return nil }
        return try JSONDecoder().decode(Selection.self, from: Data(contentsOf: selectionURL))
    }

    private func writeSelection(_ selection: Selection?) throws {
        if let selection {
            try JSONEncoder().encode(selection).write(to: selectionURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: selectionURL.path)
            let handle = try FileHandle(forWritingTo: selectionURL)
            defer { try? handle.close() }
            try handle.synchronize()
        } else if FileManager.default.fileExists(atPath: selectionURL.path) {
            try FileManager.default.removeItem(at: selectionURL)
        }
        try syncDirectory()
    }
}
