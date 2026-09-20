import Foundation

/// Pure state policy for the native external-camera preview. AVFoundation owns
/// device discovery and capture; this policy prevents it from starting or
/// restarting without a current selection and an explicit user action.
public struct WebcamPreviewPolicy: Sendable {
    public static let noSampleTimeoutSeconds = 5

    public enum State: String, Equatable, Sendable {
        case permissionNeeded = "permission_needed"
        case denied
        case noDevice = "no_device"
        case ready
        case starting
        case previewing
        case stopping
        case stopped
        case interrupted
        case error
    }

    public enum Authorization: Equatable, Sendable {
        case notDetermined
        case authorized
        case denied
        case restricted
    }

    public enum StopReason: String, Equatable, Sendable {
        case userRequested = "user_requested"
        case selectionChanged = "selection_changed"
        case deviceUnavailable = "device_unavailable"
        case interruption
        case captureError = "capture_error"
        case authorizationLost = "authorization_lost"
        case noSample = "no_sample"
        case windowHidden = "window_hidden"
        case windowClosed = "window_closed"
        case applicationResigned = "application_resigned"
        case sessionResigned = "session_resigned"
        case displaySleep = "display_sleep"
        case systemSleep = "system_sleep"
        case quit
    }

    public struct Device: Identifiable, Hashable, Sendable {
        public let uniqueID: String
        public let localizedName: String
        public let transport: String?

        public init(uniqueID: String, localizedName: String, transport: String?) {
            self.uniqueID = uniqueID
            self.localizedName = localizedName
            self.transport = transport
        }

        public var id: String { uniqueID }

        public var displayName: String {
            guard let transport, !transport.isEmpty else { return localizedName }
            return "\(localizedName) (\(transport))"
        }
    }

    public private(set) var state: State
    public private(set) var authorization: Authorization
    public private(set) var selectedDeviceID: String?
    public private(set) var availableDeviceIDs: Set<String>
    public private(set) var generation: UInt64
    private var terminalState: State

    public init(
        state: State = .permissionNeeded,
        authorization: Authorization = .notDetermined,
        selectedDeviceID: String? = nil,
        availableDeviceIDs: Set<String> = [],
        generation: UInt64 = 0
    ) {
        self.state = state
        self.authorization = authorization
        self.selectedDeviceID = selectedDeviceID
        self.availableDeviceIDs = availableDeviceIDs
        self.generation = generation
        terminalState = .stopped
    }

    /// A true value permits only a future explicit `start()` call.
    public var canStart: Bool {
        guard authorization == .authorized,
              let selectedDeviceID,
              availableDeviceIDs.contains(selectedDeviceID) else { return false }
        return state != .starting && state != .previewing && state != .stopping
    }

    public var isCapturing: Bool {
        state == .starting || state == .previewing
    }

    @discardableResult
    public mutating func updateAuthorization(_ authorization: Authorization) -> Bool {
        self.authorization = authorization
        if isCapturing, authorization != .authorized {
            return beginStop(reason: .authorizationLost)
        }
        refreshIdleState()
        return false
    }

    /// Returns true only when a currently active capture must be torn down.
    @discardableResult
    public mutating func replaceAvailableDeviceIDs(_ deviceIDs: Set<String>) -> Bool {
        availableDeviceIDs = deviceIDs
        let selectedDeviceIsGone = selectedDeviceID.map { !deviceIDs.contains($0) } ?? false
        if selectedDeviceIsGone {
            selectedDeviceID = nil
        }
        if isCapturing, selectedDeviceIsGone {
            return beginStop(reason: .deviceUnavailable)
        }
        refreshIdleState()
        return false
    }

    /// Selects only a currently discovered external-camera unique ID.
    /// Returns true when changing selection requires native teardown.
    @discardableResult
    public mutating func selectDevice(uniqueID: String) -> Bool {
        guard !uniqueID.isEmpty, availableDeviceIDs.contains(uniqueID) else { return false }
        let changed = selectedDeviceID != uniqueID
        selectedDeviceID = uniqueID
        guard changed else {
            refreshIdleState()
            return false
        }
        if isCapturing {
            return beginStop(reason: .selectionChanged)
        }
        refreshIdleState()
        return false
    }

    /// Starts a new generation only when the caller explicitly requests it.
    public mutating func start() -> UInt64? {
        guard canStart else { return nil }
        generation &+= 1
        terminalState = .stopped
        state = .starting
        return generation
    }

    public func acceptsConfiguration(generation: UInt64) -> Bool {
        self.generation == generation && (state == .starting || state == .previewing)
    }

    public func isCurrentCapture(generation: UInt64) -> Bool {
        self.generation == generation && isCapturing
    }

    /// The capture queue calls this only for the first valid timestamp of a generation.
    @discardableResult
    public mutating func acceptFirstSample(generation: UInt64) -> Bool {
        guard self.generation == generation, state == .starting else { return false }
        state = .previewing
        return true
    }

    /// The independent watchdog asks for teardown after five seconds without a new timestamp.
    @discardableResult
    public mutating func watchdogExpired(generation: UInt64) -> Bool {
        guard self.generation == generation, isCapturing else { return false }
        return beginStop(reason: .noSample)
    }

    /// A capture-queue validation found that the selected external device vanished.
    @discardableResult
    public mutating func selectedDeviceBecameUnavailable(generation: UInt64) -> Bool {
        guard self.generation == generation, isCapturing else { return false }
        if let selectedDeviceID {
            availableDeviceIDs.remove(selectedDeviceID)
        }
        selectedDeviceID = nil
        return beginStop(reason: .deviceUnavailable)
    }

    /// Applies an immediate device-disconnect notification. The caller matches
    /// the selected unique ID before invoking this method.
    @discardableResult
    public mutating func selectedDeviceDisconnected(uniqueID: String) -> Bool {
        guard selectedDeviceID == uniqueID else { return false }
        availableDeviceIDs.remove(uniqueID)
        selectedDeviceID = nil
        if isCapturing {
            return beginStop(reason: .deviceUnavailable)
        }
        refreshIdleState()
        return false
    }

    /// Moves to `stopping`; `completeTeardown()` is the only route to a released state.
    @discardableResult
    public mutating func stop(reason: StopReason) -> Bool {
        guard state != .stopping && state != .stopped else { return false }
        return beginStop(reason: reason)
    }

    @discardableResult
    public mutating func completeTeardown() -> Bool {
        guard state == .stopping else { return false }
        state = terminalState
        return true
    }

    private mutating func beginStop(reason: StopReason) -> Bool {
        guard state != .stopping else { return false }
        generation &+= 1
        terminalState = terminalState(for: reason)
        state = .stopping
        return true
    }

    private mutating func refreshIdleState() {
        guard state != .stopping && !isCapturing else { return }
        switch authorization {
        case .notDetermined:
            state = .permissionNeeded
        case .denied, .restricted:
            state = .denied
        case .authorized:
            state = availableDeviceIDs.isEmpty ? .noDevice : .ready
        }
    }

    private func terminalState(for reason: StopReason) -> State {
        switch reason {
        case .authorizationLost:
            return .denied
        case .deviceUnavailable:
            return .noDevice
        case .interruption:
            return .interrupted
        case .captureError:
            return .error
        default:
            return .stopped
        }
    }
}

/// Production-used gate between the serial native capture queue and the
/// MainActor controller. It carries only generation, teardown identity, and
/// native-call admission; AVFoundation resources remain in the macOS target.
public struct WebcamCaptureEventGate: Sendable {
    public struct Teardown: Equatable, Sendable {
        public let id: UUID
        public let generation: UInt64

        fileprivate init(id: UUID = UUID(), generation: UInt64) {
            self.id = id
            self.generation = generation
        }
    }

    public enum NativeAdmission: Equatable, Sendable {
        case admitted
        case cancelled
        case authorizationLost(WebcamPreviewPolicy.Authorization)
    }

    public private(set) var activeGeneration: UInt64?
    public private(set) var watchdogGeneration: UInt64?
    private var pendingTeardown: Teardown?

    public var hasPendingTeardown: Bool {
        pendingTeardown != nil
    }

    public init() {}

    @discardableResult
    public mutating func beginCapture(generation: UInt64) -> Bool {
        guard activeGeneration == nil, pendingTeardown == nil else { return false }
        activeGeneration = generation
        watchdogGeneration = generation
        return true
    }

    public func acceptsEvent(generation: UInt64) -> Bool {
        activeGeneration == generation && pendingTeardown == nil
    }

    /// Starts one teardown for the active generation and immediately marks its
    /// watchdog ineligible. A duplicate or stale caller receives no token.
    public mutating func beginTeardown() -> Teardown? {
        guard let activeGeneration, pendingTeardown == nil else { return nil }
        let teardown = Teardown(generation: activeGeneration)
        pendingTeardown = teardown
        if watchdogGeneration == activeGeneration {
            watchdogGeneration = nil
        }
        return teardown
    }

    /// Consumes only the currently pending teardown. A late completion cannot
    /// alter a newer capture or its watchdog state.
    @discardableResult
    public mutating func completeTeardown(_ teardown: Teardown) -> Bool {
        guard pendingTeardown == teardown else { return false }
        pendingTeardown = nil
        if activeGeneration == teardown.generation {
            activeGeneration = nil
        }
        return true
    }

    /// This exact admission check runs on the native capture queue immediately
    /// before input creation and before `startRunning()`.
    public static func nativeAdmission(
        request: WebcamPreviewStartRequest,
        authorization: WebcamPreviewPolicy.Authorization
    ) -> NativeAdmission {
        guard !request.isCancelled else { return .cancelled }
        guard authorization == .authorized else { return .authorizationLost(authorization) }
        return .admitted
    }
}

/// Lock-protected cancellation token shared by the MainActor controller and
/// the serial native queue. It contains no AVFoundation object or payload.
public final class WebcamPreviewStartRequest: @unchecked Sendable {
    public let generation: UInt64
    private let lock = NSLock()
    private var cancelled = false

    public init(generation: UInt64) {
        self.generation = generation
    }

    @discardableResult
    public func cancel() -> Bool {
        lock.lock()
        let wasCancelled = cancelled
        cancelled = true
        lock.unlock()
        return !wasCancelled
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}
