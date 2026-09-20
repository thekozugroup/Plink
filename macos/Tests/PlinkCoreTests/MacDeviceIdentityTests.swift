import XCTest
@testable import PlinkCore

final class MacDeviceIdentityTests: XCTestCase {
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
