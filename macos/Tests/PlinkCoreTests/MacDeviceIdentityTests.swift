import XCTest
@testable import PlinkCore

final class MacDeviceIdentityTests: XCTestCase {
    func testBluetoothAddressNormalizationRejectsUnavailableAndMalformedValues() {
        XCTAssertEqual(MacDeviceIdentity.bluetoothAddress("a4-83-e7-12-34-56"), "A4:83:E7:12:34:56")
        for value in [nil, "", "00:00:00:00:00:00", "FF:FF:FF:FF:FF:FF", "02:00:00:00:00:00",
                      " A4:83:E7:12:34:56", "A4:83:E7:12:34:5G", "A4:83:E7:12:34:56\n"] {
            XCTAssertNil(MacDeviceIdentity.bluetoothAddress(value))
        }
    }

    func testCompanionMetadataPolicyRequiresExactBoundedAddressAndRedactsIt() throws {
        var envelope = PlinkEnvelope(id: "companion", type: .deviceCompanion, sentAt: .now,
            sourceDeviceId: "mac", targetDeviceId: "pixel", payload: ["bluetoothAddress": .string("A4:83:E7:12:34:56")])
        try PayloadPolicy.validate(envelope)
        XCTAssertEqual(PayloadPolicy.redact(envelope).payload["bluetoothAddress"], .string("[redacted]"))
        envelope.payload["bluetoothAddress"] = .string("")
        try PayloadPolicy.validate(envelope)
        for value in [PayloadValue.string("a4:83:e7:12:34:56"), .string("00:00:00:00:00:00"), .bool(true), .string(String(repeating: "A", count: 100))] {
            envelope.payload["bluetoothAddress"] = value
            XCTAssertThrowsError(try PayloadPolicy.validate(envelope))
        }
        envelope.payload = ["bluetoothAddress": .string("A4:83:E7:12:34:56"), "extra": .string("ignored")]
        XCTAssertThrowsError(try PayloadPolicy.validate(envelope))
        envelope.payload.removeValue(forKey: "extra")
        envelope.requiresAck = true
        XCTAssertThrowsError(try PayloadPolicy.validate(envelope))
        envelope.requiresAck = false
        envelope.payload = [:]
        XCTAssertThrowsError(try PayloadPolicy.validate(envelope))
    }

    func testFreshIdentityPersistsAcrossInstances() throws {
        try withDefaults { defaults in
            let first = try MacDeviceIdentity.resolve(defaults: defaults, hasSavedPairings: false)
            XCTAssertTrue(first.hasPrefix("mac-"))
            XCTAssertNotNil(UUID(uuidString: String(first.dropFirst(4))))
            XCTAssertEqual(try MacDeviceIdentity.resolve(defaults: defaults, hasSavedPairings: false), first)
            XCTAssertEqual(try MacDeviceIdentity.resolve(defaults: defaults, hasSavedPairings: true), first)
        }
    }

    func testLegacyPairingGetsDurableFreshOfferIdentity() throws {
        try withDefaults { defaults in
            defaults.set("mac-demo", forKey: MacDeviceIdentity.defaultsKey)
            let id = try MacDeviceIdentity.resolve(defaults: defaults, hasSavedPairings: true)
            XCTAssertNotEqual(id, "mac-demo")
            XCTAssertNotNil(UUID(uuidString: String(id.dropFirst(4))))
            XCTAssertEqual(try MacDeviceIdentity.resolve(defaults: defaults, hasSavedPairings: false), id)
        }
    }

    func testTwoUpgradedMacsHaveDifferentFreshOfferIdentities() throws {
        try withDefaults { first in
            try withDefaults { second in
                first.set("mac-demo", forKey: MacDeviceIdentity.defaultsKey)
                second.set("mac-demo", forKey: MacDeviceIdentity.defaultsKey)
                let firstID = try MacDeviceIdentity.resolve(defaults: first, hasSavedPairings: true)
                let secondID = try MacDeviceIdentity.resolve(defaults: second, hasSavedPairings: true)
                XCTAssertNotEqual(firstID, secondID)
                XCTAssertNotEqual(firstID, "mac-demo")
                XCTAssertNotEqual(secondID, "mac-demo")
                XCTAssertEqual(PairingStateMachine().makeOffer(deviceId: firstID, deviceName: "A", endpoint: "127.0.0.1:45731").deviceId, firstID)
            }
        }
    }

    func testDifferentInstallationsGetDifferentIdentities() throws {
        try withDefaults { first in
            try withDefaults { second in
                XCTAssertNotEqual(try MacDeviceIdentity.resolve(defaults: first, hasSavedPairings: false),
                                  try MacDeviceIdentity.resolve(defaults: second, hasSavedPairings: false))
            }
        }
    }

    func testMalformedPersistedIdentityFailsClosedWithoutReplacement() throws {
        try withDefaults { defaults in
            defaults.set("corrupt", forKey: MacDeviceIdentity.defaultsKey)
            XCTAssertThrowsError(try MacDeviceIdentity.resolve(defaults: defaults, hasSavedPairings: true))
            XCTAssertEqual(defaults.string(forKey: MacDeviceIdentity.defaultsKey), "corrupt")
        }
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "plink-identity-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }
}
