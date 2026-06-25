import Foundation
import Security

public protocol PairingStore: Sendable {
    func save(_ device: PairedDevice) throws
    func all() throws -> [PairedDevice]
    func remove(deviceId: String) throws
}

public protocol PairingSecretStore: Sendable {
    func save(sessionKey: Data, sessionId: String) throws
    func load(sessionId: String) throws -> Data?
    func remove(sessionId: String) throws
}

public final class InMemoryPairingStore: PairingStore, @unchecked Sendable {
    private let lock = NSLock()
    private var devices: [String: PairedDevice] = [:]

    public init() {}

    public func save(_ device: PairedDevice) {
        lock.withLock { devices[device.id] = device }
    }

    public func all() -> [PairedDevice] {
        lock.withLock { Array(devices.values).sorted { $0.name < $1.name } }
    }

    public func remove(deviceId: String) {
        lock.withLock { _ = devices.removeValue(forKey: deviceId) }
    }
}

public final class UserDefaultsPairingStore: PairingStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "app.plink.pairedDevices") {
        self.defaults = defaults
        self.key = key
    }

    public func save(_ device: PairedDevice) throws {
        var devices = try all()
        devices.removeAll { $0.id == device.id }
        devices.append(device)
        try persist(devices)
    }

    public func all() throws -> [PairedDevice] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return try JSONDecoder().decode([PairedDevice].self, from: data)
    }

    public func remove(deviceId: String) throws {
        let devices = try all().filter { $0.id != deviceId }
        try persist(devices)
    }

    private func persist(_ devices: [PairedDevice]) throws {
        let data = try JSONEncoder().encode(devices)
        defaults.set(data, forKey: key)
    }
}

public final class InMemoryPairingSecretStore: PairingSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: Data] = [:]

    public init() {}

    public func save(sessionKey: Data, sessionId: String) {
        lock.withLock { secrets[sessionId] = sessionKey }
    }

    public func load(sessionId: String) -> Data? {
        lock.withLock { secrets[sessionId] }
    }

    public func remove(sessionId: String) {
        lock.withLock { _ = secrets.removeValue(forKey: sessionId) }
    }
}

public final class KeychainPairingSecretStore: PairingSecretStore, @unchecked Sendable {
    private let service: String

    public init(service: String = "com.thekozugroup.plink.session") {
        self.service = service
    }

    public func save(sessionKey: Data, sessionId: String) throws {
        try remove(sessionId: sessionId)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: sessionId,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: sessionKey
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainSecretStoreError.status(status) }
    }

    public func load(sessionId: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: sessionId,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainSecretStoreError.status(status) }
        return result as? Data
    }

    public func remove(sessionId: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: sessionId
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainSecretStoreError.status(status)
        }
    }
}

public enum KeychainSecretStoreError: Error, Equatable {
    case status(OSStatus)
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
