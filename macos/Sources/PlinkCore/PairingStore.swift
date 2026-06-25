import Foundation

public protocol PairingStore: Sendable {
    func save(_ device: PairedDevice) throws
    func all() throws -> [PairedDevice]
    func remove(deviceId: String) throws
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

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
