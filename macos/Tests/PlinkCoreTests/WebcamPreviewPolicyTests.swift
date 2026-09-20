import PlinkCore
import Testing

@Test
func webcamPolicyRequiresPermissionSelectionAndExplicitStart() throws {
    var policy = WebcamPreviewPolicy()
    #expect(policy.state == .permissionNeeded)
    let startResult1 = policy.start() == nil
    #expect(startResult1)

    _ = policy.replaceAvailableDeviceIDs(["external-a"])
    let selectDeviceResult1 = !policy.selectDevice(uniqueID: "external-a")
    #expect(selectDeviceResult1)
    #expect(policy.selectedDeviceID == "external-a")
    #expect(!policy.canStart)

    _ = policy.updateAuthorization(.authorized)
    #expect(policy.state == .ready)
    let startResult2 = policy.start()
    let generation = try #require(startResult2)
    #expect(policy.state == .starting)
    #expect(generation == 1)
}

@Test
func webcamPolicyUsesOnlyCurrentExternalUniqueIDAndStopsOnSelectionChange() throws {
    var policy = WebcamPreviewPolicy()
    _ = policy.updateAuthorization(.authorized)
    _ = policy.replaceAvailableDeviceIDs(["external-a", "external-b"])

    let selectDeviceResult2 = !policy.selectDevice(uniqueID: "built-in-camera")
    #expect(selectDeviceResult2)
    #expect(policy.selectedDeviceID == nil)
    let selectDeviceResult3 = !policy.selectDevice(uniqueID: "external-a")
    #expect(selectDeviceResult3)
    let startResult3 = policy.start()
    let generation = try #require(startResult3)

    let selectDeviceResult4 = policy.selectDevice(uniqueID: "external-b")
    #expect(selectDeviceResult4)
    #expect(policy.state == .stopping)
    #expect(policy.selectedDeviceID == "external-b")
    let acceptFirstSampleResult1 = !policy.acceptFirstSample(generation: generation)
    #expect(acceptFirstSampleResult1)
    let completeTeardownResult1 = policy.completeTeardown()
    #expect(completeTeardownResult1)
    #expect(policy.state == .stopped)
    #expect(policy.canStart)
}

@Test
func webcamPolicyWatchdogInvalidatesLateSamplesUntilTeardownCompletes() throws {
    var policy = WebcamPreviewPolicy()
    _ = policy.updateAuthorization(.authorized)
    _ = policy.replaceAvailableDeviceIDs(["external-a"])
    _ = policy.selectDevice(uniqueID: "external-a")
    let startResult4 = policy.start()
    let generation = try #require(startResult4)

    #expect(WebcamPreviewPolicy.noSampleTimeoutSeconds == 5)
    let watchdogExpiredResult1 = policy.watchdogExpired(generation: generation)
    #expect(watchdogExpiredResult1)
    #expect(policy.state == .stopping)
    #expect(!policy.canStart)
    let acceptFirstSampleResult2 = !policy.acceptFirstSample(generation: generation)
    #expect(acceptFirstSampleResult2)
    let completeTeardownResult2 = policy.completeTeardown()
    #expect(completeTeardownResult2)
    #expect(policy.state == .stopped)
    #expect(policy.canStart)
}

@Test
func webcamPolicyInvalidatesAQueuedStartBeforeNativeConfiguration() throws {
    var policy = WebcamPreviewPolicy()
    _ = policy.updateAuthorization(.authorized)
    _ = policy.replaceAvailableDeviceIDs(["external-a"])
    _ = policy.selectDevice(uniqueID: "external-a")
    let startResult5 = policy.start()
    let generation = try #require(startResult5)

    let stopResult1 = policy.stop(reason: .userRequested)
    #expect(stopResult1)
    #expect(!policy.acceptsConfiguration(generation: generation))
    #expect(!policy.isCurrentCapture(generation: generation))
    let completeTeardownResult3 = policy.completeTeardown()
    #expect(completeTeardownResult3)
    #expect(policy.state == .stopped)
}

@Test
func webcamPolicyFailsClosedWhenSelectedDeviceDisappears() throws {
    var policy = WebcamPreviewPolicy()
    _ = policy.updateAuthorization(.authorized)
    _ = policy.replaceAvailableDeviceIDs(["external-a"])
    _ = policy.selectDevice(uniqueID: "external-a")
    let startResult6 = policy.start()
    let generation = try #require(startResult6)

    let replaceAvailableDeviceIDsResult1 = policy.replaceAvailableDeviceIDs([])
    #expect(replaceAvailableDeviceIDsResult1)
    #expect(policy.state == .stopping)
    #expect(policy.selectedDeviceID == nil)
    #expect(!policy.acceptsConfiguration(generation: generation))
    let completeTeardownResult4 = policy.completeTeardown()
    #expect(completeTeardownResult4)
    #expect(policy.state == .noDevice)
}

@Test
func webcamPolicyRejectsAStaleDiscoveryResultAfterAStop() throws {
    var policy = WebcamPreviewPolicy()
    _ = policy.updateAuthorization(.authorized)
    _ = policy.replaceAvailableDeviceIDs(["external-a"])
    _ = policy.selectDevice(uniqueID: "external-a")
    let startResult7 = policy.start()
    let generation = try #require(startResult7)

    let stopResult2 = policy.stop(reason: .windowHidden)
    #expect(stopResult2)
    #expect(!policy.isCurrentCapture(generation: generation))
    let selectedDeviceBecameUnavailableResult1 = !policy.selectedDeviceBecameUnavailable(generation: generation)
    #expect(selectedDeviceBecameUnavailableResult1)
    let completeTeardownResult5 = policy.completeTeardown()
    #expect(completeTeardownResult5)
    #expect(policy.state == .stopped)
}

@Test
func webcamPolicyReleasesOnlyAfterAuthorizationLossTeardownCompletes() throws {
    var policy = WebcamPreviewPolicy()
    _ = policy.updateAuthorization(.authorized)
    _ = policy.replaceAvailableDeviceIDs(["external-a"])
    _ = policy.selectDevice(uniqueID: "external-a")
    let startResult8 = policy.start()
    _ = try #require(startResult8)

    let updateAuthorizationResult1 = policy.updateAuthorization(.denied)
    #expect(updateAuthorizationResult1)
    #expect(policy.state == .stopping)
    #expect(!policy.canStart)
    let completeTeardownResult6 = policy.completeTeardown()
    #expect(completeTeardownResult6)
    #expect(policy.state == .denied)
    #expect(!policy.canStart)
}

@Test
func webcamPolicyAcceptsConfiguredAfterFirstSampleForCurrentGenerationOnly() throws {
    var policy = WebcamPreviewPolicy()
    _ = policy.updateAuthorization(.authorized)
    _ = policy.replaceAvailableDeviceIDs(["external-a"])
    _ = policy.selectDevice(uniqueID: "external-a")
    let startResult9 = policy.start()
    let generation = try #require(startResult9)

    let acceptFirstSampleResult3 = policy.acceptFirstSample(generation: generation)
    #expect(acceptFirstSampleResult3)
    #expect(policy.state == .previewing)
    #expect(policy.acceptsConfiguration(generation: generation))
    let stopResult3 = policy.stop(reason: .userRequested)
    #expect(stopResult3)
    #expect(!policy.acceptsConfiguration(generation: generation))
    let completeTeardownResult7 = policy.completeTeardown()
    #expect(completeTeardownResult7)
}

@Test
func webcamCaptureGateConsumesOnlyMatchingTeardownAndPreservesReplacementWatchdog() throws {
    var gate = WebcamCaptureEventGate()
    let beginCaptureResult1 = gate.beginCapture(generation: 1)
    #expect(beginCaptureResult1)
    let beginTeardownResult1 = gate.beginTeardown()
    let teardown = try #require(beginTeardownResult1)
    #expect(gate.watchdogGeneration == nil)
    let completeTeardownResult8 = gate.completeTeardown(teardown)
    #expect(completeTeardownResult8)
    let beginCaptureResult2 = gate.beginCapture(generation: 2)
    #expect(beginCaptureResult2)
    #expect(gate.watchdogGeneration == 2)
    let completeTeardownResult9 = !gate.completeTeardown(teardown)
    #expect(completeTeardownResult9)
    #expect(gate.activeGeneration == 2)
    #expect(gate.watchdogGeneration == 2)
    #expect(gate.acceptsEvent(generation: 2))
}

@Test
func webcamCaptureGateRejectsCancelledAndCurrentAuthorizationLossBeforeNativeCalls() {
    let request = WebcamPreviewStartRequest(generation: 1)
    #expect(WebcamCaptureEventGate.nativeAdmission(request: request, authorization: .authorized) == .admitted)
    _ = request.cancel()
    #expect(WebcamCaptureEventGate.nativeAdmission(request: request, authorization: .authorized) == .cancelled)

    let freshRequest = WebcamPreviewStartRequest(generation: 2)
    #expect(
        WebcamCaptureEventGate.nativeAdmission(request: freshRequest, authorization: .denied)
            == .authorizationLost(.denied)
    )
    #expect(
        WebcamCaptureEventGate.nativeAdmission(request: freshRequest, authorization: .restricted)
            == .authorizationLost(.restricted)
    )
}
