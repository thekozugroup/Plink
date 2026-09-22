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
    // Retain the original public record only to present/retry incomplete cleanup after restart.
    // No secret is stored here. Completed markers remain authoritative over stale preferences.
    private struct Revocation: Codable {
        let device: PairedDevice
        var cleanupComplete: Bool
        var externalCleanupComplete: Bool = false
        var endpointRetained: Bool = false
    }
    public enum Failure: Error { case pendingRecovery, keyConflict, rollbackFailed, invalidLocalIdentity, staleRecord, revoked }
    private static let lock = NSRecursiveLock()
    // Every read/write holds Self.lock; the flag keeps mutations exclusive while
    // that lock is released for synchronous Keychain IO so metadata reads can proceed.
    nonisolated(unsafe) private static var secretMutationInFlight = false
    private let devices: any PairingStore
    private let secrets: any PairingSecretStore
    private let directory: URL
    private var pendingJournal: Journal?
    private var journalURL: URL { directory.appendingPathComponent("pending.json") }
    private var selectionURL: URL { directory.appendingPathComponent("active.json") }
    private var revocationsURL: URL { directory.appendingPathComponent("revoked.json") }

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
        let revoked = try readRevocations()
        return try devices.all().first { device in
            device.id == selection.deviceId && device.sessionId == selection.sessionId && device.trusted && device.securityVersion == 2
                && !revoked.contains(where: { $0.device.id == device.id && $0.device.sessionId == device.sessionId })
        }
    }

    public func save(_ device: PairedDevice, key: Data, localDeviceID: String) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard localDeviceID != "mac-demo", localDeviceID.hasPrefix("mac-"),
              UUID(uuidString: String(localDeviceID.dropFirst(4))) != nil else { throw Failure.invalidLocalIdentity }
        try requireIdle()
        guard try !isRevoked(device) else { throw Failure.revoked }
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
        guard !Self.secretMutationInFlight else { throw Failure.pendingRecovery }
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
        guard !Self.secretMutationInFlight else { throw Failure.pendingRecovery }
        if FileManager.default.fileExists(atPath: journalURL.path) {
            try FileManager.default.removeItem(at: journalURL)
        } else if pendingJournal == nil { return }
        try syncDirectory()
        pendingJournal = nil
    }

    public func isRevoked(_ device: PairedDevice) throws -> Bool {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return try readRevocations().contains { $0.device.id == device.id && $0.device.sessionId == device.sessionId }
    }

    public func pendingRemovals() throws -> [PairedDevice] {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return try readRevocations().filter { !$0.cleanupComplete }.map(\.device)
    }

    /// Called on the owned background operation, before retiring a healthy current selection.
    public func loadSelection(_ expected: PairedDevice, localDeviceID: String) throws -> Data {
        Self.lock.lock()
        do { try requireSelectable(expected, localDeviceID: localDeviceID) }
        catch { Self.lock.unlock(); throw error }
        Self.lock.unlock()
        guard let key = try secrets.load(sessionId: expected.sessionId), key.count == 32 else { throw Failure.keyConflict }
        Self.lock.lock(); defer { Self.lock.unlock() }
        try requireSelectable(expected, localDeviceID: localDeviceID)
        return key
    }

    public func select(_ expected: PairedDevice, localDeviceID: String) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        try requireSelectable(expected, localDeviceID: localDeviceID)
        try prepareDirectory()
        try writeSelection(Selection(deviceId: expected.id, sessionId: expected.sessionId, localDeviceId: localDeviceID))
    }

    private func requireSelectable(_ expected: PairedDevice, localDeviceID: String) throws {
        try requireIdle()
        guard localDeviceID.hasPrefix("mac-"), UUID(uuidString: String(localDeviceID.dropFirst(4))) != nil else {
            throw Failure.invalidLocalIdentity
        }
        guard expected.trusted, expected.securityVersion == 2,
              try devices.all().contains(expected) else { throw Failure.staleRecord }
        guard try !isRevoked(expected) else { throw Failure.revoked }
    }

    private func requireIdle() throws {
        guard !Self.secretMutationInFlight, pendingJournal == nil,
              !FileManager.default.fileExists(atPath: journalURL.path) else { throw Failure.pendingRecovery }
    }

    public func revoke(_ expected: PairedDevice) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        try requireIdle()
        var entries = try readRevocations()
        if entries.contains(where: { $0.device.id == expected.id && $0.device.sessionId == expected.sessionId }) {
            try requireRemovalCurrent(expected)
            try writeRevocations(entries) // Retry durability if an earlier atomic replacement failed to sync.
            return
        }
        guard try devices.all().contains(expected) else { throw Failure.staleRecord }
        entries.append(Revocation(device: expected, cleanupComplete: false))
        try writeRevocations(entries) // Must succeed before selection/metadata/secret mutation.
    }

    public func requireRemovalCurrent(_ expected: PairedDevice) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        try requireIdle()
        guard try isRevoked(expected) else { throw Failure.staleRecord }
        if let current = try devices.all().first(where: { $0.id == expected.id }), current != expected {
            throw Failure.staleRecord
        }
    }

    public func clearSelectionForRemoval(_ expected: PairedDevice) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        try requireRemovalCurrent(expected)
        if let selection = try readSelection(), selection.deviceId == expected.id, selection.sessionId == expected.sessionId {
            try writeSelection(nil)
        }
    }

    public func needsExternalCleanup(_ expected: PairedDevice) throws -> Bool {
        Self.lock.lock(); defer { Self.lock.unlock() }
        try requireRemovalCurrent(expected)
        return try readRevocations().first { $0.device.id == expected.id && $0.device.sessionId == expected.sessionId }?.externalCleanupComplete != true
    }

    public func markExternalCleanupComplete(_ expected: PairedDevice, endpointRetained: Bool = false) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        try requireRemovalCurrent(expected)
        var entries = try readRevocations()
        guard let index = entries.firstIndex(where: { $0.device.id == expected.id && $0.device.sessionId == expected.sessionId }) else {
            throw Failure.staleRecord
        }
        entries[index].externalCleanupComplete = true
        entries[index].endpointRetained = endpointRetained
        try writeRevocations(entries)
    }

    public func retainsEndpoint(_ expected: PairedDevice) throws -> Bool {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return try readRevocations().first { $0.device.id == expected.id && $0.device.sessionId == expected.sessionId }?.endpointRetained == true
    }

    /// Caller first removes the exact endpoint and Plink Bluetooth association.
    public func finishRemoval(_ expected: PairedDevice) throws {
        Self.lock.lock()
        let deleteSecret: Bool
        do {
            try requireRemovalCurrent(expected)
            try clearSelectionForRemoval(expected)
            try devices.remove(deviceId: expected.id)
            deleteSecret = try !devices.all().contains(where: { $0.sessionId == expected.sessionId })
            Self.secretMutationInFlight = true
        } catch { Self.lock.unlock(); throw error }
        Self.lock.unlock()
        do {
            if deleteSecret { try secrets.remove(sessionId: expected.sessionId) }
        } catch {
            Self.lock.lock(); Self.secretMutationInFlight = false; Self.lock.unlock()
            throw error
        }
        Self.lock.lock(); defer { Self.lock.unlock() }
        Self.secretMutationInFlight = false
        try requireRemovalCurrent(expected)
        var entries = try readRevocations()
        guard let index = entries.firstIndex(where: { $0.device.id == expected.id && $0.device.sessionId == expected.sessionId }) else {
            throw Failure.staleRecord
        }
        entries[index].cleanupComplete = true
        try writeRevocations(entries)
    }

    private func readRevocations() throws -> [Revocation] {
        guard FileManager.default.fileExists(atPath: revocationsURL.path) else { return [] }
        return try JSONDecoder().decode([Revocation].self, from: Data(contentsOf: revocationsURL))
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    private func writeRevocations(_ entries: [Revocation]) throws {
        try prepareDirectory()
        try JSONEncoder().encode(entries).write(to: revocationsURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: revocationsURL.path)
        let handle = try FileHandle(forWritingTo: revocationsURL)
        defer { try? handle.close() }
        try handle.synchronize()
        try syncDirectory()
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
