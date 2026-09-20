@preconcurrency import AVFoundation
import Combine
import CoreMedia
import Foundation
import PlinkCore

@MainActor
final class PixelWebcamController: NSObject, ObservableObject, @unchecked Sendable {
    @Published private(set) var state: WebcamPreviewPolicy.State = .permissionNeeded
    @Published private(set) var selectedDeviceID: String?
    @Published private(set) var canStart = false
    @Published private(set) var devices: [WebcamPreviewPolicy.Device] = []
    @Published private(set) var statusText = "Allow camera access, then select an external camera."
    @Published private(set) var previewLayer: AVCaptureVideoPreviewLayer?

    private var policy = WebcamPreviewPolicy()
    private let captureQueue: DispatchQueue
    private let watchdog: PixelWebcamSampleWatchdog
    private var captureCoordinator: (any PixelWebcamCaptureDriving)?
    private var deviceObserverTokens: [NSObjectProtocol] = []
    private weak var previewHost: PixelWebcamPreviewHost?
    private var permissionRequest = UUID()
    private var discoveryGeneration: UInt64 = 0
    private var activeStartRequest: WebcamPreviewStartRequest?
    private var captureGate = WebcamCaptureEventGate()
    private let suppliedCaptureCoordinator: PixelWebcamCaptureDriving?
    private let authorizationProvider: @Sendable () -> WebcamPreviewPolicy.Authorization
    private var isActive = false
    private var isShutdown = false
    private var shutdownComplete = false
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []

    override init() {
        let queue = DispatchQueue(label: "com.thekozugroup.plink.pixel-webcam.capture")
        let watchdog = PixelWebcamSampleWatchdog()
        captureQueue = queue
        self.watchdog = watchdog
        suppliedCaptureCoordinator = nil
        authorizationProvider = { PixelWebcamAuthorization.current() }
        super.init()

        installWatchdogHandler()
    }

    /// The production coordinator and deterministic test coordinator share this
    /// event boundary. Supplying a coordinator never starts discovery, capture,
    /// or an authorization prompt.
    init(
        captureCoordinator: PixelWebcamCaptureDriving,
        authorizationProvider: @escaping @Sendable () -> WebcamPreviewPolicy.Authorization
    ) {
        let queue = DispatchQueue(label: "com.thekozugroup.plink.pixel-webcam.capture")
        let watchdog = PixelWebcamSampleWatchdog()
        captureQueue = queue
        self.watchdog = watchdog
        suppliedCaptureCoordinator = captureCoordinator
        self.authorizationProvider = authorizationProvider
        super.init()

        installWatchdogHandler()
    }

    private func installWatchdogHandler() {
        watchdog.setTimeoutHandler { [weak self] generation in
            Task { @MainActor [weak self] in
                self?.watchdogExpired(generation: generation)
            }
        }
    }

    /// Called by the native webcam view only after its window becomes visible.
    /// It performs discovery but never starts capture or requests permission.
    func activate() {
        guard !isShutdown, !isActive else { return }
        isActive = true
        _ = ensureCaptureCoordinator()
        installDeviceObservers()
        applyAuthorization(authorizationProvider())
        refreshDevices()
    }

    /// Stops foreground-only preview work when the webcam view leaves its window.
    func deactivate() {
        guard !isShutdown else { return }
        isActive = false
        permissionRequest = UUID()
        discoveryGeneration &+= 1
        removeDeviceObservers()
        stop(reason: .windowHidden)
    }

    /// Selects a discovered external camera by its AVFoundation unique ID only.
    func selectDevice(uniqueID: String) {
        guard !isShutdown, isActive else { return }
        if policy.selectDevice(uniqueID: uniqueID) {
            beginNativeTeardown()
        } else {
            publishPolicy()
        }
    }

    /// Requests video authorization without starting capture.
    func requestCameraPermission() {
        guard !isShutdown, isActive else { return }
        let authorization = authorizationProvider()
        guard authorization == .notDetermined else {
            applyAuthorization(authorization)
            refreshDevices()
            return
        }

        applyAuthorization(.notDetermined)
        let request = UUID()
        permissionRequest = request
        AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isShutdown, self.isActive, self.permissionRequest == request else { return }
                self.applyAuthorization(self.authorizationProvider())
                self.refreshDevices()
            }
        }
    }

    /// Begins capture only after explicit user action, current authorization, and a current external-device selection.
    func start() {
        guard !isShutdown, isActive else { return }
        if policy.updateAuthorization(authorizationProvider()) {
            beginNativeTeardown()
            return
        }
        guard let uniqueID = policy.selectedDeviceID,
              let generation = policy.start() else {
            publishPolicy()
            return
        }

        publishPolicy()
        let request = WebcamPreviewStartRequest(generation: generation)
        guard captureGate.beginCapture(generation: generation) else {
            _ = policy.stop(reason: .captureError)
            beginNativeTeardown(status: "Camera release is still pending.")
            return
        }
        activeStartRequest = request
        watchdog.arm(generation: generation)
        let coordinator = ensureCaptureCoordinator()
        captureQueue.async {
            coordinator.start(uniqueID: uniqueID, request: request)
        }
    }

    /// Clears the visible preview now and queues idempotent native teardown without waiting on the capture queue.
    func stop(reason: WebcamPreviewPolicy.StopReason) {
        guard !shutdownComplete else { return }
        let needsTeardown = policy.stop(reason: reason)
        guard needsTeardown || captureGate.activeGeneration != nil else {
            if isShutdown { finishShutdownIfNeeded() }
            return
        }
        beginNativeTeardown()
    }

    /// Marks this owner terminal before another owner begins its shutdown wait.
    /// It invalidates pending authorization/discovery work, clears preview now,
    /// and queues native teardown without awaiting the capture queue.
    func beginShutdown() {
        guard !isShutdown, !shutdownComplete else { return }
        isShutdown = true
        isActive = false
        permissionRequest = UUID()
        discoveryGeneration &+= 1
        removeDeviceObservers()
        clearVisiblePreview()
        stop(reason: .quit)
    }

    /// Returns only after the serial capture queue has completed its teardown.
    func shutdown() async {
        guard !shutdownComplete else { return }
        beginShutdown()
        guard !shutdownComplete else { return }
        await withCheckedContinuation { continuation in
            if shutdownComplete {
                continuation.resume()
            } else {
                shutdownWaiters.append(continuation)
            }
        }
    }

    func attachPreviewHost(_ host: PixelWebcamPreviewHost) {
        if previewHost !== host {
            previewHost?.setPreviewLayer(nil)
            previewHost = host
        }
        host.setPreviewLayer(previewLayer)
    }

    private func refreshDevices() {
        guard !isShutdown, isActive, let coordinator = captureCoordinator else { return }
        discoveryGeneration &+= 1
        let generation = discoveryGeneration
        captureQueue.async {
            coordinator.discoverDevices(generation: generation)
        }
    }

    private func ensureCaptureCoordinator() -> any PixelWebcamCaptureDriving {
        if let captureCoordinator { return captureCoordinator }
        let coordinator: any PixelWebcamCaptureDriving
        if let suppliedCaptureCoordinator {
            coordinator = suppliedCaptureCoordinator
        } else {
            coordinator = PixelWebcamCaptureCoordinator(
                captureQueue: captureQueue,
                watchdog: watchdog,
                authorizationProvider: authorizationProvider
            )
        }
        coordinator.onEvent = { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event)
            }
        }
        captureCoordinator = coordinator
        return coordinator
    }

    private func installDeviceObservers() {
        let center = NotificationCenter.default
        deviceObserverTokens = [
            center.addObserver(
                forName: AVCaptureDevice.wasConnectedNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshDevices()
                }
            },
            center.addObserver(
                forName: AVCaptureDevice.wasDisconnectedNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let uniqueID = (notification.object as? AVCaptureDevice)?.uniqueID
                Task { @MainActor [weak self] in
                    self?.deviceDisconnected(uniqueID: uniqueID)
                }
            }
        ]
    }

    private func removeDeviceObservers() {
        let center = NotificationCenter.default
        deviceObserverTokens.forEach(center.removeObserver)
        deviceObserverTokens.removeAll()
    }

    private func applyAuthorization(_ authorization: WebcamPreviewPolicy.Authorization) {
        if policy.updateAuthorization(authorization) {
            beginNativeTeardown()
        } else {
            publishPolicy()
        }
    }

    private func watchdogExpired(generation: UInt64) {
        guard !isShutdown, captureGate.acceptsEvent(generation: generation),
              policy.watchdogExpired(generation: generation) else { return }
        beginNativeTeardown()
    }

    private func beginNativeTeardown(status: String? = nil) {
        guard let teardown = captureGate.beginTeardown() else {
            guard !captureGate.hasPendingTeardown else { return }
            _ = policy.completeTeardown()
            publishPolicy(status: status)
            if isShutdown { finishShutdownIfNeeded() }
            return
        }
        if activeStartRequest?.generation == teardown.generation {
            activeStartRequest?.cancel()
            activeStartRequest = nil
        }
        clearVisiblePreview()
        watchdog.cancel(generation: teardown.generation)
        publishPolicy(status: status)
        guard let coordinator = captureCoordinator else {
            completeTeardown(teardown, status: status)
            return
        }
        captureQueue.async {
            coordinator.teardown(teardown: teardown)
        }
    }

    private func completeTeardown(_ teardown: WebcamCaptureEventGate.Teardown, status: String? = nil) {
        guard captureGate.completeTeardown(teardown) else { return }
        if activeStartRequest?.generation == teardown.generation {
            activeStartRequest = nil
        }
        clearVisiblePreview()
        let completed = policy.completeTeardown()
        publishPolicy(status: status)
        if completed || isShutdown { finishShutdownIfNeeded() }
    }

    func deviceDisconnected(uniqueID: String?) {
        guard !isShutdown, isActive else { return }
        guard let uniqueID else {
            refreshDevices()
            return
        }
        devices.removeAll { $0.uniqueID == uniqueID }
        if policy.selectedDeviceDisconnected(uniqueID: uniqueID) {
            beginNativeTeardown()
        } else {
            publishPolicy()
        }
        refreshDevices()
    }

    private func clearVisiblePreview() {
        previewHost?.setPreviewLayer(nil)
        previewLayer = nil
    }

    private func handle(_ event: PixelWebcamCaptureEvent) {
        switch event {
        case .devices(let discovery, let devices):
            guard !isShutdown, isActive, discovery == discoveryGeneration else { return }
            self.devices = devices
            let authorizationNeedsTeardown = policy.updateAuthorization(authorizationProvider())
            let deviceNeedsTeardown = policy.replaceAvailableDeviceIDs(Set(devices.map(\.uniqueID)))
            if authorizationNeedsTeardown || deviceNeedsTeardown {
                beginNativeTeardown()
            } else {
                publishPolicy()
            }

        case .configured(let generation, let previewLayer):
            guard !isShutdown, isActive, captureGate.acceptsEvent(generation: generation),
                  policy.acceptsConfiguration(generation: generation) else { return }
            let layer = previewLayer.layer
            self.previewLayer = layer
            previewHost?.setPreviewLayer(layer)

        case .firstSample(let generation):
            guard !isShutdown, isActive, captureGate.acceptsEvent(generation: generation),
                  policy.acceptFirstSample(generation: generation) else { return }
            publishPolicy()

        case .interrupted(let generation):
            guard !isShutdown, isActive, captureGate.acceptsEvent(generation: generation),
                  policy.isCurrentCapture(generation: generation) else { return }
            _ = policy.stop(reason: .interruption)
            beginNativeTeardown()

        case .failed(let generation, let message):
            guard !isShutdown, isActive, captureGate.acceptsEvent(generation: generation),
                  policy.isCurrentCapture(generation: generation) else { return }
            _ = policy.stop(reason: .captureError)
            beginNativeTeardown(status: message)

        case .deviceUnavailable(let generation):
            guard !isShutdown, isActive, captureGate.acceptsEvent(generation: generation),
                  policy.selectedDeviceBecameUnavailable(generation: generation) else { return }
            beginNativeTeardown()
            refreshDevices()

        case .authorizationLost(let generation, let authorization):
            guard !isShutdown, isActive, captureGate.acceptsEvent(generation: generation),
                  policy.isCurrentCapture(generation: generation) else { return }
            _ = policy.updateAuthorization(authorization)
            beginNativeTeardown()

        case .teardownComplete(let teardown):
            completeTeardown(teardown)
        }
    }

    private func finishShutdownIfNeeded() {
        guard isShutdown, !shutdownComplete else { return }
        shutdownComplete = true
        let waiters = shutdownWaiters
        shutdownWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func publishPolicy(status: String? = nil) {
        state = policy.state
        selectedDeviceID = policy.selectedDeviceID
        canStart = !isShutdown && isActive && policy.canStart
        statusText = status ?? Self.statusText(for: policy.state, selectedDeviceID: policy.selectedDeviceID)
    }

    private static func statusText(for state: WebcamPreviewPolicy.State, selectedDeviceID: String?) -> String {
        switch state {
        case .permissionNeeded:
            return "Allow camera access, then select an external camera."
        case .denied:
            return "Camera access is unavailable. Enable Camera access for Plink in System Settings."
        case .noDevice:
            return "No external camera is available. Set the Pixel USB connection to Webcam, then reconnect it."
        case .ready:
            return selectedDeviceID == nil
                ? "Select an external camera before starting preview."
                : "Ready to preview the selected external camera."
        case .starting:
            return "Starting the selected external camera preview."
        case .previewing:
            return "Previewing the selected external camera."
        case .stopping:
            return "Releasing the selected external camera."
        case .stopped:
            return "Camera released. Select Start Preview to use it again."
        case .interrupted:
            return "Camera was interrupted. Select Start Preview to try again."
        case .error:
            return "Camera preview failed. Select Start Preview to retry."
        }
    }
}

final class PixelWebcamPreviewLayerBox: @unchecked Sendable {
    let layer: AVCaptureVideoPreviewLayer

    init(_ layer: AVCaptureVideoPreviewLayer) {
        self.layer = layer
    }
}

enum PixelWebcamCaptureEvent: Sendable {
    case devices(discovery: UInt64, [WebcamPreviewPolicy.Device])
    case configured(generation: UInt64, previewLayer: PixelWebcamPreviewLayerBox)
    case firstSample(generation: UInt64)
    case interrupted(generation: UInt64)
    case failed(generation: UInt64, message: String)
    case deviceUnavailable(generation: UInt64)
    case authorizationLost(generation: UInt64, WebcamPreviewPolicy.Authorization)
    case teardownComplete(WebcamCaptureEventGate.Teardown)
}

protocol PixelWebcamCaptureDriving: AnyObject, Sendable {
    var onEvent: (@Sendable (PixelWebcamCaptureEvent) -> Void)? { get set }
    func discoverDevices(generation: UInt64)
    func start(uniqueID: String, request: WebcamPreviewStartRequest)
    func teardown(teardown: WebcamCaptureEventGate.Teardown)
}

private final class PixelWebcamCaptureCoordinator: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, PixelWebcamCaptureDriving, @unchecked Sendable {
    var onEvent: (@Sendable (PixelWebcamCaptureEvent) -> Void)?

    private let captureQueue: DispatchQueue
    private let watchdog: PixelWebcamSampleWatchdog
    private var captureSession: AVCaptureSession?
    private var captureInput: AVCaptureDeviceInput?
    private var captureOutput: AVCaptureVideoDataOutput?
    private var sessionObserverTokens: [NSObjectProtocol] = []
    private var activeGeneration: UInt64?
    private var firstSamplePublished = false
    private var lastSampleTimestamp = CMTime.invalid

    private let authorizationProvider: @Sendable () -> WebcamPreviewPolicy.Authorization

    init(
        captureQueue: DispatchQueue,
        watchdog: PixelWebcamSampleWatchdog,
        authorizationProvider: @escaping @Sendable () -> WebcamPreviewPolicy.Authorization
    ) {
        self.captureQueue = captureQueue
        self.watchdog = watchdog
        self.authorizationProvider = authorizationProvider
        super.init()
    }

    func discoverDevices(generation: UInt64) {
        publish(.devices(discovery: generation, Self.externalDevices().map(Self.description(for:)).sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }))
    }

    func start(uniqueID: String, request: WebcamPreviewStartRequest) {
        let generation = request.generation
        guard admitNativeCall(request) else { return }
        guard captureSession == nil else {
            publish(.failed(generation: generation, message: "Camera release is still pending."))
            return
        }
        guard let device = Self.externalDevices().first(where: { $0.uniqueID == uniqueID }) else {
            if !request.isCancelled {
                publish(.deviceUnavailable(generation: generation))
            }
            return
        }
        let input: AVCaptureDeviceInput
        // Current authorization is checked on the capture queue immediately
        // before creating the native input.
        guard admitNativeCall(request) else { return }
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            if !request.isCancelled {
                publish(.failed(generation: generation, message: "The selected external camera could not be opened."))
            }
            return
        }
        guard admitNativeCall(request) else { return }

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        let session = AVCaptureSession()
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            if !request.isCancelled {
                publish(.failed(generation: generation, message: "The selected external camera cannot be configured."))
            }
            return
        }
        session.addInput(input)
        session.addOutput(output)
        if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        } else if session.canSetSessionPreset(.vga640x480) {
            session.sessionPreset = .vga640x480
        } else {
            session.removeOutput(output)
            session.removeInput(input)
            session.commitConfiguration()
            if !request.isCancelled {
                publish(.failed(generation: generation, message: "The selected external camera does not support 720p or VGA preview."))
            }
            return
        }
        session.commitConfiguration()

        guard admitNativeCall(request) else {
            releaseUnstarted(session: session, input: input, output: output)
            return
        }

        captureSession = session
        captureInput = input
        captureOutput = output
        activeGeneration = generation
        firstSamplePublished = false
        lastSampleTimestamp = .invalid
        output.setSampleBufferDelegate(self, queue: captureQueue)
        installSessionObservers(for: session, generation: generation)

        guard admitNativeCall(request) else {
            releaseStartedCapture()
            return
        }

        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspect
        publish(.configured(generation: generation, previewLayer: PixelWebcamPreviewLayerBox(previewLayer)))

        // Recheck after setup and directly before the synchronous native start.
        guard admitNativeCall(request) else {
            releaseStartedCapture()
            return
        }
        session.startRunning()
        if !admitNativeCall(request) {
            releaseStartedCapture()
        }
    }

    func teardown(teardown: WebcamCaptureEventGate.Teardown) {
        watchdog.cancel(generation: teardown.generation)
        releaseStartedCapture()
        publish(.teardownComplete(teardown))
    }

    private func releaseStartedCapture() {
        activeGeneration = nil
        firstSamplePublished = false
        lastSampleTimestamp = .invalid

        let session = captureSession
        let input = captureInput
        let output = captureOutput
        captureSession = nil
        captureInput = nil
        captureOutput = nil

        session?.stopRunning()
        if let session {
            session.beginConfiguration()
            if let output, session.outputs.contains(where: { $0 === output }) {
                session.removeOutput(output)
            }
            if let input, session.inputs.contains(where: { $0 === input }) {
                session.removeInput(input)
            }
            session.commitConfiguration()
        }
        output?.setSampleBufferDelegate(nil, queue: nil)
        let center = NotificationCenter.default
        sessionObserverTokens.forEach(center.removeObserver)
        sessionObserverTokens.removeAll()
    }

    /// Runs on the serial capture queue at each native resource boundary.
    private func admitNativeCall(_ request: WebcamPreviewStartRequest) -> Bool {
        switch WebcamCaptureEventGate.nativeAdmission(
            request: request,
            authorization: authorizationProvider()
        ) {
        case .admitted:
            return true
        case .cancelled:
            return false
        case .authorizationLost(let authorization):
            publish(.authorizationLost(generation: request.generation, authorization))
            return false
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard output === captureOutput,
              let generation = activeGeneration else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard timestamp.isValid,
              !lastSampleTimestamp.isValid || CMTimeCompare(timestamp, lastSampleTimestamp) > 0 else { return }
        lastSampleTimestamp = timestamp
        watchdog.noteSample(generation: generation)
        guard !firstSamplePublished else { return }
        firstSamplePublished = true
        publish(.firstSample(generation: generation))
    }

    private func installSessionObservers(for session: AVCaptureSession, generation: UInt64) {
        let center = NotificationCenter.default
        sessionObserverTokens = [
            center.addObserver(
                forName: AVCaptureSession.wasInterruptedNotification,
                object: session,
                queue: nil
            ) { [weak self] _ in
                self?.publish(.interrupted(generation: generation))
            },
            center.addObserver(
                forName: AVCaptureSession.runtimeErrorNotification,
                object: session,
                queue: nil
            ) { [weak self] _ in
                self?.publish(.failed(generation: generation, message: "AVFoundation reported a capture-session error."))
            }
        ]
    }

    private func releaseUnstarted(
        session: AVCaptureSession,
        input: AVCaptureDeviceInput,
        output: AVCaptureVideoDataOutput
    ) {
        session.beginConfiguration()
        if session.outputs.contains(where: { $0 === output }) {
            session.removeOutput(output)
        }
        if session.inputs.contains(where: { $0 === input }) {
            session.removeInput(input)
        }
        session.commitConfiguration()
        output.setSampleBufferDelegate(nil, queue: nil)
    }

    private func publish(_ event: PixelWebcamCaptureEvent) {
        onEvent?(event)
    }

    private static func externalDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: .video,
            position: .unspecified
        ).devices.filter { !$0.isContinuityCamera }
    }

}

private enum PixelWebcamAuthorization {
    static func current() -> WebcamPreviewPolicy.Authorization {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return .authorized
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        @unknown default:
            return .denied
        }
    }

}

private extension PixelWebcamCaptureCoordinator {
    static func description(for device: AVCaptureDevice) -> WebcamPreviewPolicy.Device {
        WebcamPreviewPolicy.Device(
            uniqueID: device.uniqueID,
            localizedName: device.localizedName,
            transport: transportDescription(for: device)
        )
    }

    static func transportDescription(for device: AVCaptureDevice) -> String? {
        let value = UInt32(bitPattern: device.transportType)
        guard value != 0 else { return nil }
        let bytes = [
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value)
        ]
        guard bytes.allSatisfy({ $0 >= 32 && $0 <= 126 }),
              let text = String(bytes: bytes, encoding: .ascii) else { return nil }
        let transport = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return transport.isEmpty ? nil : transport.uppercased()
    }
}

private final class PixelWebcamSampleWatchdog: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.thekozugroup.plink.pixel-webcam.watchdog")
    private var timer: DispatchSourceTimer?
    private var generation: UInt64?
    private var timeoutHandler: (@Sendable (UInt64) -> Void)?

    func setTimeoutHandler(_ handler: @escaping @Sendable (UInt64) -> Void) {
        queue.async { [weak self] in
            self?.timeoutHandler = handler
        }
    }

    func arm(generation: UInt64) {
        queue.async { [weak self] in
            guard let self else { return }
            self.generation = generation
            self.scheduleTimeout()
        }
    }

    func noteSample(generation: UInt64) {
        queue.async { [weak self] in
            guard let self, self.generation == generation else { return }
            self.scheduleTimeout()
        }
    }

    func cancel(generation: UInt64? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            guard generation == nil || self.generation == generation else { return }
            self.generation = nil
            self.timer?.cancel()
            self.timer = nil
        }
    }

    private func scheduleTimeout() {
        if let timer {
            timer.schedule(deadline: .now() + .seconds(WebcamPreviewPolicy.noSampleTimeoutSeconds))
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in
            self?.timeoutFired()
        }
        self.timer = timer
        timer.schedule(deadline: .now() + .seconds(WebcamPreviewPolicy.noSampleTimeoutSeconds))
        timer.resume()
    }

    private func timeoutFired() {
        guard let generation else { return }
        self.generation = nil
        timer?.cancel()
        timer = nil
        timeoutHandler?(generation)
    }
}
