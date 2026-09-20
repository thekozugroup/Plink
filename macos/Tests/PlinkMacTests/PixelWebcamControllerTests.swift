import AVFoundation
import Foundation
import PlinkCore
import Testing
@testable import PlinkMac

@MainActor
struct PixelWebcamControllerTests {
    @Test func constructionIsInertUntilExplicitActivation() async {
        let driver = WebcamCaptureDriverSpy()
        let authorization = WebcamAuthorizationSpy(.authorized)
        let controller = PixelWebcamController(
            captureCoordinator: driver,
            authorizationProvider: { authorization.value }
        )

        #expect(driver.discoveryCount == 0)
        #expect(driver.startCount == 0)
        #expect(authorization.readCount == 0)

        controller.beginShutdown()
        await controller.shutdown()
        #expect(driver.teardownCount == 0)
    }

    @Test func duplicateTeardownCannotClearOrUncancelReplacementStart() async throws {
        let driver = WebcamCaptureDriverSpy()
        let authorization = WebcamAuthorizationSpy(.authorized)
        let controller = try await configuredController(driver: driver, authorization: authorization)
        defer { driver.releaseAll() }

        driver.blockNextStart()
        controller.start()
        try await eventually { driver.startCount == 1 }
        controller.stop(reason: .userRequested)
        #expect(controller.state == .stopping)
        driver.releaseOneStart()
        try await eventually { controller.state == .stopped }

        driver.blockNextStart()
        controller.start()
        try await eventually { driver.startCount == 2 }
        #expect(controller.state == .starting)
        let replacementLayer = AVCaptureVideoPreviewLayer()
        let replacementGeneration = try #require(driver.startGeneration(at: 1))
        driver.emit(.configured(
            generation: replacementGeneration,
            previewLayer: PixelWebcamPreviewLayerBox(replacementLayer)
        ))
        try await eventually { controller.previewLayer === replacementLayer }
        #expect(driver.emitDuplicateTeardown())
        await settleMainActor()
        #expect(controller.state == .starting)
        #expect(controller.selectedDeviceID == "external-a")
        #expect(controller.previewLayer === replacementLayer)

        controller.stop(reason: .userRequested)
        driver.releaseOneStart()
        try await eventually { controller.state == .stopped }
        #expect(driver.nativeAdmissions == [.cancelled, .cancelled])
        #expect(driver.nativeInputOrStartCount == 0)
        await controller.shutdown()
    }

    @Test func beginShutdownClosesStartGateAndAsyncShutdownWaitsForTeardown() async throws {
        let driver = WebcamCaptureDriverSpy()
        let authorization = WebcamAuthorizationSpy(.authorized)
        let controller = try await configuredController(driver: driver, authorization: authorization)
        defer { driver.releaseAll() }

        driver.blockNextStart()
        driver.blockNextTeardown()
        controller.start()
        try await eventually { driver.startCount == 1 }
        let generation = try #require(driver.startGeneration(at: 0))
        let layer = AVCaptureVideoPreviewLayer()
        driver.emit(.configured(generation: generation, previewLayer: PixelWebcamPreviewLayerBox(layer)))
        try await eventually { controller.previewLayer === layer }

        controller.beginShutdown()
        #expect(controller.state == .stopping)
        #expect(!controller.canStart)
        #expect(controller.previewLayer == nil)
        controller.start()
        #expect(driver.startCount == 1)

        let completion = ShutdownCompletion()
        let shutdownTask = Task { @MainActor in
            await controller.shutdown()
            completion.markFinished()
        }
        await settleMainActor()
        driver.releaseOneStart()
        try await eventually { driver.teardownCount == 1 }
        await settleMainActor()
        #expect(!completion.finished)

        driver.releaseOneTeardown()
        await shutdownTask.value
        #expect(completion.finished)
        #expect(controller.state == .stopped)
        #expect(driver.nativeAdmissions == [.cancelled])
    }

    @Test func selectedDisconnectInvalidatesImmediatelyAndReplugNeverRestarts() async throws {
        let driver = WebcamCaptureDriverSpy()
        let authorization = WebcamAuthorizationSpy(.authorized)
        let controller = try await configuredController(driver: driver, authorization: authorization)
        defer { driver.releaseAll() }

        driver.blockNextStart()
        controller.start()
        try await eventually { driver.startCount == 1 }
        let generation = try #require(driver.startGeneration(at: 0))
        let layer = AVCaptureVideoPreviewLayer()
        driver.emit(.configured(generation: generation, previewLayer: PixelWebcamPreviewLayerBox(layer)))
        try await eventually { controller.previewLayer === layer }

        controller.deviceDisconnected(uniqueID: "external-a")
        #expect(controller.state == .stopping)
        #expect(controller.selectedDeviceID == nil)
        #expect(controller.previewLayer == nil)
        #expect(!controller.canStart)

        driver.releaseOneStart()
        try await eventually { controller.state == .noDevice }
        try await eventually { driver.discoveryCount == 2 }
        let replugDiscovery = try #require(driver.discoveryGeneration(at: 1))
        driver.emit(.devices(discovery: replugDiscovery, [externalDevice("external-a"), externalDevice("external-b")]))
        try await eventually { controller.devices.count == 2 }
        #expect(controller.selectedDeviceID == nil)
        #expect(!controller.canStart)
        #expect(driver.startCount == 1)

        controller.selectDevice(uniqueID: "external-a")
        #expect(controller.selectedDeviceID == "external-a")
        #expect(controller.state == .ready)
        controller.deviceDisconnected(uniqueID: "external-b")
        #expect(controller.selectedDeviceID == "external-a")
        #expect(controller.state == .ready)
        #expect(driver.teardownCount == 1)
        await controller.shutdown()
    }

    @Test func configuredAfterFirstSampleAttachesButStoppedGenerationCannotAttach() async throws {
        let driver = WebcamCaptureDriverSpy()
        let authorization = WebcamAuthorizationSpy(.authorized)
        let controller = try await configuredController(driver: driver, authorization: authorization)

        controller.start()
        try await eventually { driver.startCount == 1 }
        let firstGeneration = try #require(driver.startGeneration(at: 0))
        let firstLayer = AVCaptureVideoPreviewLayer()
        driver.emit(.firstSample(generation: firstGeneration))
        try await eventually { controller.state == .previewing }
        driver.emit(.configured(generation: firstGeneration, previewLayer: PixelWebcamPreviewLayerBox(firstLayer)))
        try await eventually { controller.previewLayer === firstLayer }

        controller.stop(reason: .userRequested)
        try await eventually { controller.state == .stopped }
        controller.start()
        try await eventually { driver.startCount == 2 }
        let stoppedGeneration = try #require(driver.startGeneration(at: 1))
        driver.emit(.firstSample(generation: stoppedGeneration))
        try await eventually { controller.state == .previewing }
        controller.stop(reason: .userRequested)
        try await eventually { controller.state == .stopped }

        let lateLayer = AVCaptureVideoPreviewLayer()
        driver.emit(.configured(generation: stoppedGeneration, previewLayer: PixelWebcamPreviewLayerBox(lateLayer)))
        await settleMainActor()
        #expect(controller.previewLayer == nil)
        await controller.shutdown()
    }

    @Test func authorizationLossBehindBlockedDiscoveryPreventsNativeInputOrStart() async throws {
        let authorization = WebcamAuthorizationSpy(.authorized)
        let driver = WebcamCaptureDriverSpy(authorizationProvider: { authorization.value })
        let controller = try await configuredController(driver: driver, authorization: authorization)
        defer { driver.releaseAll() }

        driver.devicesAfterDiscovery = [externalDevice("external-a")]
        driver.blockNextDiscovery()
        // Already-authorized permission action only refreshes discovery; it does
        // not call AVFoundation's authorization prompt in this test seam.
        controller.requestCameraPermission()
        try await eventually { driver.discoveryCount == 2 }
        controller.start()
        #expect(controller.state == .starting)
        authorization.set(.denied)
        driver.releaseOneDiscovery()

        try await eventually { driver.startCount == 1 }
        try await eventually { controller.state == .denied }
        #expect(!controller.canStart)
        #expect(driver.nativeInputOrStartCount == 0)
        #expect(driver.nativeAdmissions.contains(.authorizationLost(.denied)))
        await controller.shutdown()
    }
}

@MainActor
private func configuredController(
    driver: WebcamCaptureDriverSpy,
    authorization: WebcamAuthorizationSpy
) async throws -> PixelWebcamController {
    let controller = PixelWebcamController(
        captureCoordinator: driver,
        authorizationProvider: { authorization.value }
    )
    controller.activate()
    try await eventually { driver.discoveryCount == 1 }
    let discovery = try #require(driver.discoveryGeneration(at: 0))
    driver.emit(.devices(discovery: discovery, [externalDevice("external-a"), externalDevice("external-b")]))
    try await eventually { controller.devices.count == 2 }
    controller.selectDevice(uniqueID: "external-a")
    #expect(controller.canStart)
    return controller
}

@MainActor
private func eventually(
    timeout: Duration = .seconds(1),
    _ condition: @escaping () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        guard clock.now < deadline else { throw WebcamControllerTestTimeout() }
        try await Task.sleep(for: .milliseconds(1))
    }
}

@MainActor
private func settleMainActor() async {
    await Task.yield()
    await Task.yield()
}

private func externalDevice(_ uniqueID: String) -> WebcamPreviewPolicy.Device {
    .init(uniqueID: uniqueID, localizedName: "External Camera", transport: "USB")
}

private struct WebcamControllerTestTimeout: Error {}

private final class WebcamAuthorizationSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: WebcamPreviewPolicy.Authorization
    private var storedReadCount = 0

    init(_ value: WebcamPreviewPolicy.Authorization) {
        storedValue = value
    }

    var value: WebcamPreviewPolicy.Authorization {
        lock.lock()
        storedReadCount += 1
        defer { lock.unlock() }
        return storedValue
    }

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedReadCount
    }

    func set(_ value: WebcamPreviewPolicy.Authorization) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }
}

private final class WebcamCaptureDriverSpy: PixelWebcamCaptureDriving, @unchecked Sendable {
    private let lock = NSLock()
    private let startPermit = DispatchSemaphore(value: 0)
    private let discoveryPermit = DispatchSemaphore(value: 0)
    private let teardownPermit = DispatchSemaphore(value: 0)
    private var handler: (@Sendable (PixelWebcamCaptureEvent) -> Void)?
    private var startRequests: [WebcamPreviewStartRequest] = []
    private var discoveryRequests: [UInt64] = []
    private var teardownRequests: [WebcamCaptureEventGate.Teardown] = []
    private var storedAdmissions: [WebcamCaptureEventGate.NativeAdmission] = []
    private var storedNativeInputOrStartCount = 0
    private var blockedStarts = 0
    private var blockedDiscoveries = 0
    private var blockedTeardowns = 0
    private var storedDevicesAfterDiscovery: [WebcamPreviewPolicy.Device]?
    private let authorizationProvider: @Sendable () -> WebcamPreviewPolicy.Authorization

    init(
        authorizationProvider: @escaping @Sendable () -> WebcamPreviewPolicy.Authorization = { .authorized }
    ) {
        self.authorizationProvider = authorizationProvider
    }

    var onEvent: (@Sendable (PixelWebcamCaptureEvent) -> Void)? {
        get { withLock { handler } }
        set { withLock { handler = newValue } }
    }

    var startCount: Int { withLock { startRequests.count } }
    var discoveryCount: Int { withLock { discoveryRequests.count } }
    var teardownCount: Int { withLock { teardownRequests.count } }
    var nativeAdmissions: [WebcamCaptureEventGate.NativeAdmission] { withLock { storedAdmissions } }
    var nativeInputOrStartCount: Int { withLock { storedNativeInputOrStartCount } }

    var devicesAfterDiscovery: [WebcamPreviewPolicy.Device]? {
        get { withLock { storedDevicesAfterDiscovery } }
        set { withLock { storedDevicesAfterDiscovery = newValue } }
    }

    func startGeneration(at index: Int) -> UInt64? {
        withLock { startRequests.indices.contains(index) ? startRequests[index].generation : nil }
    }

    func discoveryGeneration(at index: Int) -> UInt64? {
        withLock { discoveryRequests.indices.contains(index) ? discoveryRequests[index] : nil }
    }

    func blockNextStart() {
        withLock { blockedStarts += 1 }
    }

    func blockNextDiscovery() {
        withLock { blockedDiscoveries += 1 }
    }

    func blockNextTeardown() {
        withLock { blockedTeardowns += 1 }
    }

    func releaseOneStart() {
        startPermit.signal()
    }

    func releaseOneDiscovery() {
        discoveryPermit.signal()
    }

    func releaseOneTeardown() {
        teardownPermit.signal()
    }

    func releaseAll() {
        startPermit.signal()
        discoveryPermit.signal()
        teardownPermit.signal()
    }

    func discoverDevices(generation: UInt64) {
        let shouldBlock = withLock { () -> Bool in
            discoveryRequests.append(generation)
            guard blockedDiscoveries > 0 else { return false }
            blockedDiscoveries -= 1
            return true
        }
        if shouldBlock {
            _ = discoveryPermit.wait(timeout: .now() + 1)
        }
        if let devices = devicesAfterDiscovery {
            emit(.devices(discovery: generation, devices))
        }
    }

    func start(uniqueID: String, request: WebcamPreviewStartRequest) {
        let shouldBlock = withLock { () -> Bool in
            startRequests.append(request)
            guard blockedStarts > 0 else { return false }
            blockedStarts -= 1
            return true
        }
        if shouldBlock {
            _ = startPermit.wait(timeout: .now() + 1)
        }
        let admission = WebcamCaptureEventGate.nativeAdmission(
            request: request,
            authorization: authorizationProvider()
        )
        withLock {
            storedAdmissions.append(admission)
            if admission == .admitted {
                storedNativeInputOrStartCount += 1
            }
        }
        if case .authorizationLost(let authorization) = admission {
            emit(.authorizationLost(generation: request.generation, authorization))
        }
    }

    func teardown(teardown: WebcamCaptureEventGate.Teardown) {
        let shouldBlock = withLock { () -> Bool in
            teardownRequests.append(teardown)
            guard blockedTeardowns > 0 else { return false }
            blockedTeardowns -= 1
            return true
        }
        if shouldBlock {
            _ = teardownPermit.wait(timeout: .now() + 1)
        }
        emit(.teardownComplete(teardown))
    }

    @discardableResult
    func emitDuplicateTeardown() -> Bool {
        guard let teardown = withLock({ teardownRequests.last }) else { return false }
        emit(.teardownComplete(teardown))
        return true
    }

    func emit(_ event: PixelWebcamCaptureEvent) {
        onEvent?(event)
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class ShutdownCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var storedFinished = false

    var finished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedFinished
    }

    func markFinished() {
        lock.lock()
        storedFinished = true
        lock.unlock()
    }
}
