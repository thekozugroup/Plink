import Foundation
import XCTest
@testable import PlinkCore

final class SavedPhoneManagementTests: XCTestCase {
    private let local = "mac-00000000-0000-0000-0000-000000000001"
    private func phone(_ id: String, session: String? = nil) -> PairedDevice {
        PairedDevice(id: id, name: "Phone", platform: "android", endpoint: "127.0.0.1:45731",
            sessionId: session ?? id, peerPublicKey: "peer", localPublicKey: "local", trusted: true, securityVersion: 2)
    }
    func testExplicitSelectionRequiresExistingKeyAndIdentityAndNeverChangesKey() throws {
        let devices = InMemoryPairingStore(), keys = InMemoryPairingSecretStore()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MacPairingFinalization(devices: devices, secrets: keys, directory: dir)
        let a = phone("a"), b = phone("b")
        try store.save(a, key: Data(repeating: 1, count: 32), localDeviceID: local); try store.commit()
        devices.save(b)
        XCTAssertThrowsError(try store.loadSelection(b, localDeviceID: local))
        XCTAssertEqual(try store.selectedDevice(localDeviceID: local), a)
        keys.save(sessionKey: Data(repeating: 2, count: 32), sessionId: b.sessionId)
        XCTAssertThrowsError(try store.loadSelection(b, localDeviceID: "mac-demo"))
        XCTAssertEqual(try store.loadSelection(b, localDeviceID: local), Data(repeating: 2, count: 32))
        try store.select(b, localDeviceID: local)
        XCTAssertEqual(try store.selectedDevice(localDeviceID: local), b)
        XCTAssertEqual(keys.load(sessionId: b.sessionId), Data(repeating: 2, count: 32))
    }
    func testInactiveRemovalSurvivesRestartAndKeepsOtherSelectionAndSharedKey() throws {
        let devices = InMemoryPairingStore(), keys = InMemoryPairingSecretStore()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MacPairingFinalization(devices: devices, secrets: keys, directory: dir)
        let a = phone("oneplus", session: "shared"), b = phone("pixel", session: "shared")
        let key = Data(repeating: 1, count: 32)
        try store.save(a, key: key, localDeviceID: local); try store.commit()
        try store.save(b, key: key, localDeviceID: local); try store.commit()
        try store.revoke(a)
        let restarted = MacPairingFinalization(devices: devices, secrets: keys, directory: dir)
        XCTAssertEqual(try restarted.selectedDevice(localDeviceID: local), b)
        XCTAssertThrowsError(try restarted.loadSelection(a, localDeviceID: local))
        try restarted.clearSelectionForRemoval(a)
        try restarted.finishRemoval(a)
        XCTAssertEqual(try restarted.selectedDevice(localDeviceID: local), b)
        XCTAssertEqual(keys.load(sessionId: "shared"), key)
        devices.save(a) // Simulate stale preferences reappearing after a crash.
        XCTAssertTrue(try restarted.isRevoked(a))
        XCTAssertThrowsError(try restarted.save(a, key: key, localDeviceID: local))
        XCTAssertThrowsError(try restarted.select(a, localDeviceID: local))
    }
    func testRevocationFailsBeforeMutationAndStaleCleanupCannotRemoveReplacement() throws {
        let devices = InMemoryPairingStore(), keys = InMemoryPairingSecretStore()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = phone("a")
        devices.save(old); keys.save(sessionKey: Data(repeating: 1, count: 32), sessionId: old.sessionId)
        try Data().write(to: dir) // Directory cannot be created: marker persistence fails.
        let store = MacPairingFinalization(devices: devices, secrets: keys, directory: dir)
        XCTAssertThrowsError(try store.revoke(old))
        XCTAssertEqual(devices.all(), [old]); XCTAssertNotNil(keys.load(sessionId: old.sessionId))
        try FileManager.default.removeItem(at: dir)
        try store.revoke(old)
        let replacement = phone("a", session: "new")
        devices.save(replacement)
        XCTAssertThrowsError(try store.finishRemoval(old))
        XCTAssertEqual(devices.all(), [replacement])
        XCTAssertFalse(try store.isRevoked(replacement))
    }
    func testActiveRevocationBlocksRestoreBeforeCleanupAndPreservesPendingRetry() throws {
        let devices = InMemoryPairingStore(), keys = RemovalFailingSecretStore()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MacPairingFinalization(devices: devices, secrets: keys, directory: dir)
        let a = phone("a")
        try store.save(a, key: Data(repeating: 1, count: 32), localDeviceID: local); try store.commit()
        try store.revoke(a)
        XCTAssertNil(try store.selectedDevice(localDeviceID: local))
        try store.clearSelectionForRemoval(a)
        keys.failRemoval = true
        XCTAssertThrowsError(try store.finishRemoval(a))
        let restarted = MacPairingFinalization(devices: devices, secrets: keys, directory: dir)
        XCTAssertNil(try restarted.selectedDevice(localDeviceID: local))
        XCTAssertEqual(try restarted.pendingRemovals(), [a])
        keys.failRemoval = false
        try restarted.finishRemoval(a)
        XCTAssertTrue(try restarted.pendingRemovals().isEmpty)
        XCTAssertTrue(try restarted.isRevoked(a))
        XCTAssertNil(try keys.load(sessionId: a.sessionId))
    }

    func testSelectionAndMetadataCleanupFailuresRemainRevokedAcrossRestart() throws {
        let devices = RemovalFailingDeviceStore(), keys = InMemoryPairingSecretStore()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MacPairingFinalization(devices: devices, secrets: keys, directory: dir)
        let a = phone("a")
        try store.save(a, key: Data(repeating: 1, count: 32), localDeviceID: local); try store.commit()
        try store.revoke(a)
        // A malformed selection prevents cleanup; it must never bypass the durable revocation.
        try Data("invalid".utf8).write(to: dir.appendingPathComponent("active.json"))
        XCTAssertThrowsError(try store.clearSelectionForRemoval(a))
        XCTAssertTrue(try store.isRevoked(a))
        try FileManager.default.removeItem(at: dir.appendingPathComponent("active.json"))
        devices.failRemoval = true
        XCTAssertThrowsError(try store.finishRemoval(a))
        let restarted = MacPairingFinalization(devices: devices, secrets: keys, directory: dir)
        XCTAssertThrowsError(try restarted.loadSelection(a, localDeviceID: local))
        XCTAssertEqual(try restarted.pendingRemovals(), [a])
        XCTAssertNotNil(keys.load(sessionId: a.sessionId))
    }

    func testExternalCleanupCheckpointSurvivesRestartAndPendingSaveBlocksManagement() throws {
        let devices = InMemoryPairingStore(), keys = InMemoryPairingSecretStore()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MacPairingFinalization(devices: devices, secrets: keys, directory: dir)
        let a = phone("a")
        try store.save(a, key: Data(repeating: 1, count: 32), localDeviceID: local)
        XCTAssertThrowsError(try store.revoke(a))
        XCTAssertThrowsError(try store.loadSelection(a, localDeviceID: local))
        try store.commit()
        try store.revoke(a)
        XCTAssertTrue(try store.needsExternalCleanup(a))
        // Failed external cleanup leaves this false checkpoint unset and revocation authoritative.
        XCTAssertNil(try store.selectedDevice(localDeviceID: local))
        try store.markExternalCleanupComplete(a)
        let restarted = MacPairingFinalization(devices: devices, secrets: keys, directory: dir)
        XCTAssertFalse(try restarted.needsExternalCleanup(a))
        try restarted.finishRemoval(a)
        XCTAssertNil(keys.load(sessionId: a.sessionId))
        XCTAssertTrue(try restarted.isRevoked(a))
    }

    func testBlockedSecretLoadDoesNotBlockSelectionReadsAndRejectsStaleRecord() throws {
        let devices = InMemoryPairingStore(), keys = HeldSecretStore()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MacPairingFinalization(devices: devices, secrets: keys, directory: dir)
        let a = phone("a"), b = phone("b"), identity = local
        try store.save(b, key: Data(repeating: 2, count: 32), localDeviceID: identity); try store.commit()
        devices.save(a); try keys.save(sessionKey: Data(repeating: 1, count: 32), sessionId: a.sessionId)
        keys.holdLoad = true
        let done = expectation(description: "stale load returns")
        DispatchQueue.global().async {
            defer { done.fulfill() }
            do {
                _ = try store.loadSelection(a, localDeviceID: identity)
                XCTFail("Stale selection must be rejected")
            } catch { /* Expected rejection after the record was removed. */ }
        }
        XCTAssertEqual(keys.entered.wait(timeout: .now() + 2), .success)
        let read = expectation(description: "metadata read while key load held")
        DispatchQueue.global().async {
            defer { read.fulfill() }
            do {
                let selected = try store.selectedDevice(localDeviceID: identity)
                XCTAssertEqual(selected, b)
            } catch { XCTFail("Metadata read failed while secret load was held: \(error)") }
        }
        wait(for: [read], timeout: 2)
        devices.remove(deviceId: a.id)
        keys.release.signal()
        wait(for: [done], timeout: 2)
    }

    func testMissingSecretCanCompleteWithExplicitInertEndpointRetention() throws {
        let devices = InMemoryPairingStore(), keys = InMemoryPairingSecretStore()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MacPairingFinalization(devices: devices, secrets: keys, directory: dir)
        let a = phone("a")
        devices.save(a)
        try store.revoke(a)
        XCTAssertNil(keys.load(sessionId: a.sessionId))
        try store.markExternalCleanupComplete(a, endpointRetained: true)
        try store.finishRemoval(a)
        XCTAssertTrue(devices.all().isEmpty)
        XCTAssertTrue(try store.retainsEndpoint(a))
        XCTAssertTrue(try store.isRevoked(a))
    }

    func testExistingRevocationMustPersistAgainBeforeCleanupRetry() throws {
        let devices = InMemoryPairingStore(), keys = InMemoryPairingSecretStore()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let store = MacPairingFinalization(devices: devices, secrets: keys, directory: dir)
        let a = phone("a")
        devices.save(a); keys.save(sessionKey: Data(repeating: 1, count: 32), sessionId: a.sessionId)
        try store.revoke(a)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        XCTAssertThrowsError(try store.revoke(a))
        XCTAssertEqual(devices.all(), [a])
        XCTAssertNotNil(keys.load(sessionId: a.sessionId))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        try store.revoke(a)
    }

    func testBlockedSecretDeleteAllowsReadsButRejectsCompetingKeyReferenceSave() throws {
        let devices = InMemoryPairingStore(), keys = HeldSecretStore()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MacPairingFinalization(devices: devices, secrets: keys, directory: dir)
        let a = phone("a"), b = phone("b"), c = phone("c", session: "a"), identity = local
        try store.save(a, key: Data(repeating: 1, count: 32), localDeviceID: identity); try store.commit()
        try store.save(b, key: Data(repeating: 2, count: 32), localDeviceID: identity); try store.commit()
        try store.revoke(a)
        keys.holdDelete = true
        let done = expectation(description: "delete returns")
        DispatchQueue.global().async {
            defer { done.fulfill() }
            do { try store.finishRemoval(a) }
            catch { XCTFail("Removal failed: \(error)") }
        }
        XCTAssertEqual(keys.entered.wait(timeout: .now() + 2), .success)
        let read = expectation(description: "read plus mutation rejection while delete held")
        DispatchQueue.global().async {
            defer { read.fulfill() }
            do {
                let selected = try store.selectedDevice(localDeviceID: identity)
                XCTAssertEqual(selected, b)
            } catch { XCTFail("Metadata read failed while secret deletion was held: \(error)") }
            do {
                try store.save(c, key: Data(repeating: 1, count: 32), localDeviceID: identity)
                XCTFail("Competing same-session save must be rejected")
            } catch { /* Expected rejection while secret deletion owns mutation. */ }
        }
        wait(for: [read], timeout: 2)
        keys.release.signal()
        wait(for: [done], timeout: 2)
        XCTAssertEqual(try store.selectedDevice(localDeviceID: identity), b)
    }
}
private final class HeldSecretStore: PairingSecretStore, @unchecked Sendable {
    let backing = InMemoryPairingSecretStore()
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    var holdLoad = false, holdDelete = false
    func save(sessionKey: Data, sessionId: String) throws { backing.save(sessionKey: sessionKey, sessionId: sessionId) }
    func load(sessionId: String) throws -> Data? {
        if holdLoad { entered.signal(); release.wait() }
        return backing.load(sessionId: sessionId)
    }
    func remove(sessionId: String) throws {
        if holdDelete { entered.signal(); release.wait() }
        backing.remove(sessionId: sessionId)
    }
}
private final class RemovalFailingDeviceStore: PairingStore, @unchecked Sendable {
    let backing = InMemoryPairingStore()
    var failRemoval = false
    func save(_ device: PairedDevice) throws { backing.save(device) }
    func all() throws -> [PairedDevice] { backing.all() }
    func remove(deviceId: String) throws {
        if failRemoval { throw CocoaError(.fileWriteUnknown) }
        backing.remove(deviceId: deviceId)
    }
}
private final class RemovalFailingSecretStore: PairingSecretStore, @unchecked Sendable {
    let backing = InMemoryPairingSecretStore()
    var failRemoval = false
    func save(sessionKey: Data, sessionId: String) throws { backing.save(sessionKey: sessionKey, sessionId: sessionId) }
    func load(sessionId: String) throws -> Data? { backing.load(sessionId: sessionId) }
    func remove(sessionId: String) throws {
        if failRemoval { throw CocoaError(.fileWriteUnknown) }
        backing.remove(sessionId: sessionId)
    }
}
