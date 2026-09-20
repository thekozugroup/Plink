import Foundation

@main
struct PreferenceSmoke {
    static func main() throws {
        guard let bundleID = Bundle.main.bundleIdentifier,
              bundleID.hasPrefix("com.thekozugroup.plink.preferences-smoke.") else {
            fatalError("This check requires its own temporary app bundle.")
        }
        let defaults = UserDefaults.standard
        defer {
            defaults.removePersistentDomain(forName: bundleID)
            _ = defaults.synchronize()
        }
        let namedSuiteIsNil = UserDefaults(suiteName: bundleID) == nil
        let first = try MacDeviceIdentity.resolve(defaults: defaults, hasSavedPairings: false)
        let restored = try MacDeviceIdentity.resolve(defaults: defaults, hasSavedPairings: false)
        guard namedSuiteIsNil, first == restored, first.hasPrefix("mac-") else {
            fatalError("Preference-domain regression check failed.")
        }
        print("PASS: own-bundle named suite is nil; standard defaults create and restore one stable identity.")
    }
}
