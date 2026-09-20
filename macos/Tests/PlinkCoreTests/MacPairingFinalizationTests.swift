import XCTest
@testable import PlinkCore

final class MacPairingFinalizationTests: XCTestCase {
    private let localID = "mac-00000000-0000-0000-0000-000000000001"
    func testLegacyV2RecordCannotActivateAfterFailedFreshPairing() throws {
        let stores = InMemoryPairingStore()
        let secrets = InMemoryPairingSecretStore()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var legacy = device(session: "legacy"); legacy.securityVersion = 2
        stores.save(legacy)
        secrets.save(sessionKey: Data(repeating: 1, count: 32), sessionId: legacy.sessionId)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let oldSelection = Data("{\"deviceId\":\"pixel\",\"sessionId\":\"legacy\",\"localDeviceId\":\"mac-demo\"}".utf8)
        try oldSelection.write(to: directory.appendingPathComponent("active.json"))
        let transaction = MacPairingFinalization(devices: stores, secrets: secrets, directory: directory)
        XCTAssertNil(try transaction.selectedDevice(localDeviceID: localID))
        XCTAssertNil(try transaction.selectedDevice(localDeviceID: "mac-demo"))
        try transaction.save(device(session: "fresh"), key: Data(repeating: 2, count: 32), localDeviceID: localID)
        try transaction.rollback()
        XCTAssertEqual(stores.all(), [legacy])
        XCTAssertNotNil(secrets.load(sessionId: legacy.sessionId))
        XCTAssertNil(secrets.load(sessionId: "fresh"))
        let restarted = MacPairingFinalization(devices: stores, secrets: secrets, directory: directory)
        XCTAssertNil(try restarted.selectedDevice(localDeviceID: localID))
        // Older selections lacking a local binding also require explicit re-pair.
        try Data("{\"deviceId\":\"pixel\",\"sessionId\":\"legacy\"}".utf8)
            .write(to: directory.appendingPathComponent("active.json"))
        XCTAssertNil(try restarted.selectedDevice(localDeviceID: localID))
        XCTAssertEqual(stores.all(), [legacy])
    }
    func testPairingDifferentPhoneRestoresExplicitLatestSelection() throws {
        let stores = InMemoryPairingStore()
        let secrets = InMemoryPairingSecretStore()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transaction = MacPairingFinalization(devices: stores, secrets: secrets, directory: directory)
        var a = device(session: "A"); a.id = "pixelA"; a.securityVersion = 2
        var b = device(session: "B"); b.id = "pixelB"; b.securityVersion = 2
        try transaction.save(a, key: Data(repeating: 1, count: 32), localDeviceID: localID); try transaction.commit()
        try transaction.save(b, key: Data(repeating: 2, count: 32), localDeviceID: localID); try transaction.commit()
        let restarted = MacPairingFinalization(devices: stores, secrets: secrets, directory: directory)
        XCTAssertEqual(try restarted.selectedDevice(localDeviceID: localID), b)
        XCTAssertEqual(Set(stores.all().map(\.id)), [a.id, b.id])
        XCTAssertNotNil(secrets.load(sessionId: a.sessionId))
        var replaced = b; replaced.sessionId = "unexpected-replacement"
        stores.save(replaced)
        XCTAssertNil(try restarted.selectedDevice(localDeviceID: localID), "An ID match without a session match is not selection")
        var revoked = b; revoked.trusted = false
        stores.save(revoked)
        XCTAssertNil(try restarted.selectedDevice(localDeviceID: localID), "Revoked B must never fall back to A")
        stores.remove(deviceId: b.id)
        XCTAssertNil(try restarted.selectedDevice(localDeviceID: localID), "Missing B must never silently fall back to A")
    }

    func testInterruptedDifferentPhonePairingRestoresPreviousSelection() throws {
        let stores = InMemoryPairingStore()
        let secrets = InMemoryPairingSecretStore()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transaction = MacPairingFinalization(devices: stores, secrets: secrets, directory: directory)
        var a = device(session: "A"); a.id = "pixelA"; a.securityVersion = 2
        var b = device(session: "B"); b.id = "pixelB"; b.securityVersion = 2
        try transaction.save(a, key: Data(repeating: 1, count: 32), localDeviceID: localID); try transaction.commit()
        try transaction.save(b, key: Data(repeating: 2, count: 32), localDeviceID: localID)
        let restarted = MacPairingFinalization(devices: stores, secrets: secrets, directory: directory)
        XCTAssertNil(try restarted.selectedDevice(localDeviceID: localID), "Uncommitted selection must not activate")
        try restarted.rollback()
        XCTAssertEqual(try restarted.selectedDevice(localDeviceID: localID), a)
        XCTAssertNil(secrets.load(sessionId: b.sessionId))
    }

    func testUnselectedStoredRecordsNeverChooseFirstPhone() throws {
        let stores = InMemoryPairingStore()
        let secrets = InMemoryPairingSecretStore()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var a = device(session: "A"); a.id = "pixelA"; a.securityVersion = 2
        var b = device(session: "B"); b.id = "pixelB"; b.securityVersion = 2
        stores.save(a); stores.save(b)
        let transaction = MacPairingFinalization(devices: stores, secrets: secrets, directory: directory)
        XCTAssertNil(try transaction.selectedDevice(localDeviceID: localID))
        XCTAssertEqual(stores.all().count, 2)
    }
    func testCommitFailureInvalidatesReplacementBeforeRollback() throws {
        let stores = InMemoryPairingStore()
        let secrets = InMemoryPairingSecretStore()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transaction = MacPairingFinalization(devices: stores, secrets: secrets, directory: directory)
        try transaction.save(device(session: "new"), key: Data(repeating: 2, count: 32), localDeviceID: localID)
        var receiverActive = false
        var canSend = false
        XCTAssertThrowsError(try MacPairingFinalization.activateAndCommit(activate: {
            receiverActive = true; canSend = true
        }, commit: {
            XCTAssertTrue(receiverActive)
            // Model unlink succeeding but the following directory sync failing.
            try FileManager.default.removeItem(at: directory.appendingPathComponent("pending.json"))
            throw CocoaError(.fileWriteUnknown)
        }, invalidate: {
            receiverActive = false; canSend = false
        }))
        XCTAssertFalse(receiverActive)
        XCTAssertFalse(canSend)
        try transaction.rollback()
        XCTAssertTrue(stores.all().isEmpty)
        XCTAssertNil(secrets.load(sessionId: "new"))
        XCTAssertNil(try transaction.selectedDevice(localDeviceID: localID))
    }
    func testPartiallyWrittenMetadataFailureRollsBackBothStores() throws {
        let stores = FailingDeviceStore()
        let secrets = InMemoryPairingSecretStore()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = device(session: "old")
        try stores.save(old)
        let transaction = MacPairingFinalization(devices: stores, secrets: secrets, directory: directory)
        XCTAssertThrowsError(try transaction.save(device(session: "new"), key: Data(repeating: 2, count: 32), localDeviceID: localID))
        XCTAssertEqual(stores.all(), [old])
        XCTAssertNil(secrets.load(sessionId: "new"))
    }
    func testRollbackRestoresPriorDeviceAndRemovesOnlyNewKey() throws {
        let stores = InMemoryPairingStore()
        let secrets = InMemoryPairingSecretStore()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = device(session: "old")
        stores.save(old); secrets.save(sessionKey: Data(repeating: 1, count: 32), sessionId: "old")
        let transaction = MacPairingFinalization(devices: stores, secrets: secrets, directory: directory)
        try transaction.save(device(session: "new"), key: Data(repeating: 2, count: 32), localDeviceID: localID)
        try transaction.rollback()
        XCTAssertEqual(stores.all(), [old])
        XCTAssertNil(secrets.load(sessionId: "new"))
        XCTAssertNotNil(secrets.load(sessionId: "old"))
    }

    func testRecoveryAfterInterruptedSaveRestoresOldTrust() throws {
        let stores = InMemoryPairingStore()
        let secrets = InMemoryPairingSecretStore()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = device(session: "old")
        stores.save(old)
        try MacPairingFinalization(devices: stores, secrets: secrets, directory: directory)
            .save(device(session: "new"), key: Data(repeating: 2, count: 32), localDeviceID: localID)
        try MacPairingFinalization(devices: stores, secrets: secrets, directory: directory).rollback()
        XCTAssertEqual(stores.all(), [old])
        XCTAssertNil(secrets.load(sessionId: "new"))
    }

    func testCommitKeepsNewTrustAndExistingSessionKeyCannotBeOverwritten() throws {
        let stores = InMemoryPairingStore()
        let secrets = InMemoryPairingSecretStore()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transaction = MacPairingFinalization(devices: stores, secrets: secrets, directory: directory)
        try transaction.save(device(session: "new"), key: Data(repeating: 2, count: 32), localDeviceID: localID)
        try transaction.commit()
        try transaction.rollback()
        XCTAssertEqual(stores.all(), [device(session: "new")])
        XCTAssertThrowsError(try transaction.save(device(session: "new"), key: Data(repeating: 3, count: 32), localDeviceID: localID))
        XCTAssertEqual(secrets.load(sessionId: "new"), Data(repeating: 2, count: 32))
    }

    private func device(session: String) -> PairedDevice {
        PairedDevice(id: "pixel", name: "Pixel", platform: "android", endpoint: "127.0.0.1:45731", sessionId: session, peerPublicKey: "peer", localPublicKey: "local", trusted: true)
    }
}

private final class FailingDeviceStore: PairingStore, @unchecked Sendable {
    private let backing = InMemoryPairingStore()
    func save(_ device: PairedDevice) throws {
        backing.save(device)
        if device.sessionId == "new" { throw CocoaError(.fileWriteUnknown) }
    }
    func all() -> [PairedDevice] { backing.all() }
    func remove(deviceId: String) { backing.remove(deviceId: deviceId) }
}
