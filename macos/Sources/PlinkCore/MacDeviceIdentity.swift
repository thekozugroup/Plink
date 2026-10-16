import Foundation

public enum MacDeviceIdentity {
    public static let defaultsKey = "app.plink.localMacDeviceId"
    private static let lock = NSLock()
    public enum Failure: Error { case invalidStoredIdentity, persistenceFailed }

    public static func bluetoothAddress(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let address = raw.replacingOccurrences(of: "-", with: ":").uppercased()
        let bytes = Array(address.utf8)
        guard bytes.count == 17, bytes.enumerated().allSatisfy({ index, byte in
            index % 3 == 2 ? byte == 58 : (48...57).contains(byte) || (65...70).contains(byte)
        }), !["00:00:00:00:00:00", "FF:FF:FF:FF:FF:FF", "02:00:00:00:00:00"].contains(address)
        else { return nil }
        return address
    }

    /// Invoke only after saved-pairing recovery/read succeeds. A read failure is
    /// not evidence of a fresh installation. Legacy records remain inactive;
    /// fresh offers use a unique identity and active selection binds that identity.
    public static func resolve(defaults: UserDefaults, hasSavedPairings: Bool) throws -> String {
        lock.lock(); defer { lock.unlock() }
        if let value = defaults.object(forKey: defaultsKey) {
            guard let id = value as? String,
                  id == "mac-demo" || (id.hasPrefix("mac-") && UUID(uuidString: String(id.dropFirst(4))) != nil)
            else { throw Failure.invalidStoredIdentity }
            if id != "mac-demo" {
                guard defaults.synchronize() else { throw Failure.persistenceFailed }
                return id
            }
        }
        let id = "mac-\(UUID().uuidString.lowercased())"
        defaults.set(id, forKey: defaultsKey)
        guard defaults.synchronize() else { throw Failure.persistenceFailed }
        return id
    }
}
