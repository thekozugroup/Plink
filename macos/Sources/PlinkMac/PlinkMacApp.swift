import AppKit
import CryptoKit
import PlinkCore
import SwiftUI
import UserNotifications

@main
struct PlinkMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel(appDelegate: appDelegate)
        } label: {
            Label("Plink", systemImage: "link.circle.fill")
        }
        .menuBarExtraStyle(.window)

        Settings {
            PairingView(appDelegate: appDelegate)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, @preconcurrency NetServiceDelegate, ObservableObject, @unchecked Sendable {
    let notificationBridge = NotificationBridge()
    let pairingMachine = PairingStateMachine()
    let pairingStore = UserDefaultsPairingStore(
        domainName: "com.thekozugroup.plink.mac"
    )
    let pairingSecretStore = KeychainPairingSecretStore()
    // Resolved after durable pairing recovery; unavailable identity blocks setup.
    private var localMacDeviceId = ""
    private let receiverPort: UInt16 = 45731
    private let frameStateStore: any FrameStateStoring = FileFrameStateStore.applicationDefault
    private var activeTransport: SerializedPlinkSender?
    private var retiringTransport: SerializedPlinkSender?
    private var receiver: (any PlinkEventReceiver)?
    private var pendingManualOffer: PairingOffer?
    private var pendingManualConfirmation: PairingConfirmation?
    private var pendingConsent: PairingConsent?
    private var consentDeadline: ContinuousClock.Instant?
    private var consentIsFresh: Bool { consentDeadline.map { ContinuousClock.now < $0 } ?? false }
    private var activePairing: (device: PairedDevice, key: Data)?
    private var priorPairing: (device: PairedDevice, key: Data)?
    @Published private(set) var pairingRecoveryComplete = false
    private lazy var pairingFinalization = MacPairingFinalization(devices: pairingStore, secrets: pairingSecretStore)
    private var pairingInFlight = false
    private var pairingAttempt = UUID()
    private var pairingExpiryTask: Task<Void, Never>?
    let calling = BluetoothCallController()
    let files = FileTransferController()
    let screen = ScreenPreviewController()
    let webcam = PixelWebcamController()
    private let screenIngress = ScreenPreviewIngress()
    @Published var screenPreviewEnabled = true {
        didSet { screen.setEnabled(screenPreviewEnabled) }
    }
    @Published var deviceStatus: MacDeviceStatus?
    @Published var mediaState: MacMediaState?
    @Published var mediaSessions: [String: MacMediaState] = [:]
    @Published var commandStatus = "No command pending"
    @Published var pairedPeerID: String?
    @Published var lastPeerActivity: Date?
    @Published var sharingURL = ""
    @Published var receiveClipboard = UserDefaults.standard.bool(forKey: "plink.receiveClipboard") {
        didSet { UserDefaults.standard.set(receiveClipboard, forKey: "plink.receiveClipboard") }
    }
    @Published var receiveURLs = UserDefaults.standard.bool(forKey: "plink.receiveURLs") {
        didSet { UserDefaults.standard.set(receiveURLs, forKey: "plink.receiveURLs") }
    }
    private var commands = MacCommandTracker()
    private var housekeeping: Task<Void, Never>?
    private var latestCommandID: String?
    private var latestReplyID: String?
    private var connectionGeneration = UUID()
    private var pairingAdvertiser: NetService?
    private var pairingConfirmationReceiver: (any LengthPrefixedMessageReceiver)?
    @Published var lastReply: String = "None"
    @Published var lastDeliveryState: String = "Notifications pending"
    @Published var pairingStatusText: String = "Looking for your Pixel."
    @Published var pairingVerificationCode: PairingVerificationCode?
    @Published var pairingPeerName: String = "Pixel"
    @Published var canConfirmPairing: Bool = false
    private var dashboardWindow: NSWindow?
    private var pairingWindow: NSWindow?
    private var screenWindow: NSWindow?
    private var webcamWindow: NSWindow?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var terminationPending = false
    private var terminationReplied = false
    private var terminationWatchdog: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installPreviewLifecycleObservers()
        ProcessInfo.processInfo.disableAutomaticTermination("Plink keeps the paired Pixel receiver and menu bar companion active.")
        ProcessInfo.processInfo.disableSuddenTermination()
        NSApplication.shared.setActivationPolicy(.regular)
        notificationBridge.configure()
        notificationBridge.onAuthorizationChanged = { [weak self] granted, error in
            Task { @MainActor in
                self?.lastDeliveryState = granted
                    ? "Notifications enabled"
                    : (error?.localizedDescription ?? "Notifications are not enabled. If access was denied, open System Settings → Notifications → Plink and enable Allow Notifications. Asking again does not reset a denial.")
            }
        }
        notificationBridge.onDeliveryError = { [weak self] _, error in
            Task { @MainActor in
                self?.lastDeliveryState = error.localizedDescription
            }
        }
        notificationBridge.onTextReply = { [weak self] context, text in
            guard let self, context.pairedDeviceId == self.pairedPeerID else { return }
            do { self.sendCommand(try ReplyRouter.makeReplyEnvelope(context: context, text: text)) }
            catch { self.lastReply = "Reply failed: invalid reply context." }
        }
        notificationBridge.onCallAction = { [weak self] action, context in
            self?.calling.perform(action, context: context)
        }
        notificationBridge.onStaleAction = { [weak self] in
            self?.lastDeliveryState = "That action expired. Use the latest notification."
        }
        notificationBridge.onInvalidReply = { [weak self] in
            self?.lastReply = "Reply failed: the message is empty or too long."
        }
        calling.onCallChanged = { [weak self] call in self?.notificationBridge.updateCall(call) }
        housekeeping = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self else { return }
                self.notificationBridge.expireContexts()
                for result in self.commands.expire() { self.showCommandResult(result) }
                self.mediaSessions = self.mediaSessions.filter { Date().timeIntervalSince($0.value.receivedAt) <= 120 }
                if let selected = self.mediaState, self.mediaSessions[selected.sessionID] == nil {
                    self.mediaState = self.mediaSessions.values.sorted { $0.sessionID < $1.sessionID }.first
                }
            }
        }
        showDashboardWindow()
        restoreSavedPairingAsync()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationReplied else { return .terminateNow }
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        screen.beginShutdown()
        webcam.beginShutdown()
        terminationWatchdog = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            self?.replyToTermination()
        }
        Task { [weak self] in
            guard let self else { return }
            await screen.shutdown()
            await webcam.shutdown()
            replyToTermination()
        }
        return .terminateLater
    }

    private func replyToTermination() {
        guard terminationPending, !terminationReplied else { return }
        terminationReplied = true
        terminationWatchdog?.cancel()
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        files.reset()
        housekeeping?.cancel()
        clearPairingAttempt() // Prevent a suspended final send from establishing trust.
        connectionGeneration = UUID()
        stopPairingAdvertiser()
        stopPairingConfirmationReceiver()
        receiver?.stop()
        receiver = nil
        clearTransport()
        pairedPeerID = nil
        calling.shutdown()
        notificationBridge.shutdown()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showDashboardWindow()
        return true
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    func openSettings() {
        NSApplication.shared.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    func showDashboardWindow() {
        if dashboardWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 760),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.center()
            window.title = "Plink"
            window.contentView = NSHostingView(rootView: DashboardWindow(appDelegate: self))
            dashboardWindow = window
        }
        dashboardWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
    }

    func showPairingWindow() {
        if pairingWindow == nil {
            if pendingManualOffer == nil {
                startNearbyPairing()
            }
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 430),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.center()
            window.title = "Pair Pixel"
            window.contentView = NSHostingView(rootView: PairingView(appDelegate: self))
            pairingWindow = window
        } else {
            if pendingManualOffer == nil {
                startNearbyPairing()
            }
        }
        pairingWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
    }

    func showScreenWindow() {
        guard !terminationPending else { return }
        if screenWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 760),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Phone Screen"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: ScreenPreviewView(controller: screen))
            window.center()
            screenWindow = window
        }
        screenWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        screen.setVisible(true)
    }

    func showWebcamWindow() {
        guard !terminationPending else { return }
        if webcamWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 620),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Pixel USB Webcam"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: PixelWebcamView(controller: webcam))
            window.center()
            webcamWindow = window
        }
        webcamWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        webcam.activate()
    }

    func applicationDidResignActive(_ notification: Notification) {
        screen.setVisible(false)
        webcam.deactivate()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !terminationPending else { return }
        if screenWindow?.isKeyWindow == true { screen.setVisible(true) }
        if webcamWindow?.isKeyWindow == true { webcam.activate() }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard !terminationPending, NSApp.isActive, let window = notification.object as? NSWindow else { return }
        if window === screenWindow { screen.setVisible(true) }
        if window === webcamWindow { webcam.activate() }
    }

    func windowDidResignKey(_ notification: Notification) { stopHiddenPreview(notification) }
    func windowWillClose(_ notification: Notification) { stopHiddenPreview(notification) }
    func windowDidMiniaturize(_ notification: Notification) { stopHiddenPreview(notification) }
    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if !window.occlusionState.contains(.visible) { stopHiddenPreview(notification) }
        else if window.isKeyWindow && NSApp.isActive { windowDidBecomeKey(notification) }
    }

    private func stopHiddenPreview(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === screenWindow { screen.setVisible(false) }
        if window === webcamWindow { webcam.deactivate() }
    }

    private func installPreviewLifecycleObservers() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.screen.stop(reason: .locked)
                    self?.screen.setVisible(false)
                    self?.webcam.deactivate()
                }
            })
        }
    }

    private func clearTransport() {
        screen.unbind()
        let previous = activeTransport
        previous?.invalidate()
        activeTransport = nil
        if let previous {
            retiringTransport = previous
            Task { await previous.shutdown() }
        }
    }

    func startNearbyPairing() {
        guard pairingRecoveryComplete else { pairingStatusText = "Waiting for saved pairing recovery."; return }
        guard !pairingInFlight else { return }
        files.reset()
        if pendingManualOffer == nil { priorPairing = activePairing }
        stopPairingConfirmationReceiver()
        stopPairingAdvertiser()
        receiver?.stop()
        receiver = nil
        clearTransport()
        pairedPeerID = nil
        connectionGeneration = UUID()
        commands.removeAll()
        deviceStatus = nil; mediaState = nil; mediaSessions.removeAll(); lastPeerActivity = nil
        notificationBridge.clearContexts()
        let offer = prepareManualPairing()
        publishPairingOffer(offer)
        startPairingConfirmationReceiver()
        pairingStatusText = "Open Plink on your Pixel and select this Mac."
    }

    @discardableResult
    func prepareManualPairing() -> PairingOffer {
        pairingAttempt = UUID()
        pendingManualConfirmation = nil
        pendingConsent = nil
        canConfirmPairing = false
        pairingVerificationCode = nil
        pairingPeerName = "Pixel"
        let offer = pairingMachine.makeOffer(deviceId: localMacDeviceId,
            deviceName: Host.current().localizedName ?? "Mac", endpoint: localMacEndpoint())
        pendingManualOffer = offer
        consentDeadline = ContinuousClock.now.advanced(by: .seconds(120))
        pairingExpiryTask?.cancel()
        let attempt = pairingAttempt
        pairingExpiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled, let self, self.pairingAttempt == attempt, !self.pairingInFlight else { return }
            self.cancelPairing()
            self.pairingStatusText = "Pairing expired. Start a new attempt."
        }
        return offer
    }

    func previewManualResponse(_ payload: String) throws -> PairingVerificationCode {
        guard !pairingInFlight, let offer = pendingManualOffer, consentIsFresh else {
            throw AppDeliveryError.pairingOfferUnavailable
        }
        let consent = try PairingConsent.decode(payload)
        let confirmation = consent.confirmation
        guard confirmation.offerNonce == offer.nonce,
              confirmation.targetDeviceId == localMacDeviceId,
              confirmation.protocolVersion == offer.protocolVersion,
              confirmation.protocolVersion == 1, confirmation.platform == "android",
              !confirmation.deviceId.isEmpty, confirmation.deviceId != localMacDeviceId,
              !confirmation.endpoint.isEmpty else { throw PairingPayloadError.invalidPayload }
        if let pinned = pendingManualConfirmation, pinned != confirmation { throw PairingPayloadError.invalidPayload }
        // A confirmed stage cannot be downgraded by a delayed preview.
        if pendingConsent?.stage == .confirmed && consent.stage == .preview {
            return pairingMachine.verificationCode(for: offer, confirmation: confirmation)
        }
        if consent.stage == .confirmed {
            guard pendingManualConfirmation != nil,
                  case .paired = try pairingMachine.accept(confirmation, for: offer),
                  let key = pairingMachine.lastSessionKey,
                  try consent.verified(using: data(from: key)) else { throw PairingPayloadError.invalidPayload }
        }
        pendingManualConfirmation = confirmation
        pendingConsent = consent
        canConfirmPairing = consent.stage == .confirmed
        return pairingMachine.verificationCode(for: offer, confirmation: confirmation)
    }

    func receiveNearbyConfirmation(_ payload: String) {
        do {
            pairingVerificationCode = try previewManualResponse(payload)
            pairingPeerName = pendingManualConfirmation?.deviceName ?? "Pixel"
            pairingStatusText = canConfirmPairing
                ? "Pixel confirmed. Confirm here only if both codes match."
                : "Compare both codes, then confirm on your Pixel first."
            showPairingWindow()
        } catch {
            lastDeliveryState = "Pairing response rejected. The current attempt was not changed."
        }
    }

    func confirmManualPairing() async throws {
        guard !pairingInFlight, canConfirmPairing,
              let offer = pendingManualOffer, let consent = pendingConsent,
              let confirmation = pendingManualConfirmation, consent.confirmation == confirmation,
              consent.stage == .confirmed, consentIsFresh,
              case .paired(let device) = try pairingMachine.accept(confirmation, for: offer),
              let key = pairingMachine.lastSessionKey else { throw PairingPayloadError.invalidPayload }
        let sessionKey = data(from: key)
        guard try consent.verified(using: sessionKey),
              let transport = makeTransport(for: device, sessionKey: sessionKey) else { throw PairingPayloadError.invalidPayload }
        let attempt = pairingAttempt
        pairingInFlight = true
        canConfirmPairing = false
        pairingExpiryTask?.cancel()
        stopPairingConfirmationReceiver()
        stopPairingAdvertiser()
        let final = PlinkEnvelope(id: "pairing_\(UUID().uuidString)", type: .pairingConfirm, sentAt: .now,
            sourceDeviceId: localMacDeviceId, targetDeviceId: device.id,
            payload: ["sessionId": .string(device.sessionId), "offerNonce": .string(offer.nonce), "status": .string("confirmed")])
        do {
            try await transport.send(final)
            try Task.checkCancellation()
            guard pairingAttempt == attempt, pairingInFlight, consentIsFresh else { throw CancellationError() }
            // Journal prior metadata before touching the independent durable stores.
            // Keep the journal until receiver activation succeeds.
            try pairingFinalization.save(device, key: sessionKey, localDeviceID: localMacDeviceId)
            try MacPairingFinalization.activateAndCommit(activate: {
                activeTransport = transport
                guard startReceiver(sessionKey: sessionKey, pairedDeviceId: device.id) else {
                    throw AppDeliveryError.transportUnavailable
                }
            }, commit: {
                try pairingFinalization.commit()
            }, invalidate: {
                invalidateActiveSession()
            })
            activePairing = (device, sessionKey)
            priorPairing = nil
            clearPairingAttempt()
            pairingStatusText = "Paired with \(device.name)."
        } catch {
            // Cancel/restart may have already restored the old session. Never roll
            // back a subsequent attempt from this suspended send's completion.
            guard pairingAttempt == attempt else { throw error }
            invalidateActiveSession()
            do { try pairingFinalization.rollback() }
            catch {
                pairingRecoveryComplete = false
                lastDeliveryState = "Pairing recovery failed. Restart Plink before pairing again."
            }
            clearPairingAttempt()
            restorePriorPairing()
            _ = pairingMachine.reject("Final confirmation failed")
            pairingStatusText = "Pairing did not finish; prior pairing was preserved. Start a new attempt on both devices."
            throw error
        }
    }

    func cancelPairing() {
        stopPairingConfirmationReceiver()
        stopPairingAdvertiser()
        clearPairingAttempt() // Invalidates any suspended final send before it can save.
        restorePriorPairing()
        _ = pairingMachine.reject("Cancelled")
        pairingStatusText = "Pairing cancelled."
    }

    private func restorePriorPairing() {
        let previous = priorPairing
        priorPairing = nil
        guard let previous else { return }
        activePairing = previous
        applyRestoredPairing(device: previous.device, sessionKey: previous.key)
    }

    private func invalidateActiveSession() {
        files.reset()
        connectionGeneration = UUID()
        receiver?.stop()
        receiver = nil
        clearTransport()
        activePairing = nil
        pairedPeerID = nil
        commands.removeAll()
        notificationBridge.clearContexts()
        deviceStatus = nil
        mediaState = nil
        mediaSessions.removeAll()
        lastPeerActivity = nil
    }

    private func clearPairingAttempt() {
        pairingExpiryTask?.cancel()
        pairingAttempt = UUID()
        pendingManualOffer = nil
        pendingManualConfirmation = nil
        pendingConsent = nil
        consentDeadline = nil
        pairingVerificationCode = nil
        canConfirmPairing = false
        pairingInFlight = false
    }

    private func restoreSavedPairingAsync() {
        let attempt = pairingAttempt
        Task.detached { [domainName = "com.thekozugroup.plink.mac"] in
            let store = UserDefaultsPairingStore(domainName: domainName)
            let secretStore = KeychainPairingSecretStore()
            let finalization = MacPairingFinalization(devices: store, secrets: secretStore)
            do {
                try finalization.rollback()
            } catch {
                await MainActor.run {
                    self.lastDeliveryState = "Saved pairing recovery failed. Pairing is disabled until recovery succeeds."
                }
                return
            }
            let devices: [PairedDevice]
            do {
                devices = try store.all()
            } catch {
                NSLog("Plink async restore failed to load devices: \(error.localizedDescription)")
                await MainActor.run { self.lastDeliveryState = "Saved pairing data could not be read. Device identity was not changed." }
                return
            }
            let identity: String
            do {
                guard let defaults = UserDefaults(suiteName: domainName) else { throw MacDeviceIdentity.Failure.persistenceFailed }
                identity = try MacDeviceIdentity.resolve(defaults: defaults, hasSavedPairings: !devices.isEmpty)
            } catch {
                await MainActor.run { self.lastDeliveryState = "Device identity could not be restored. Existing pairing data was preserved." }
                return
            }
            await MainActor.run {
                self.localMacDeviceId = identity
                self.pairingRecoveryComplete = true
            }
            let selected: PairedDevice?
            do { selected = try finalization.selectedDevice(localDeviceID: identity) }
            catch {
                await MainActor.run { self.lastDeliveryState = "Saved phone selection could not be read. Existing pairing records were preserved." }
                return
            }
            guard let device = selected else {
                if !devices.isEmpty {
                    await MainActor.run {
                        self.lastDeliveryState = devices.contains(where: { $0.trusted && $0.securityVersion == 2 })
                            ? "Pair your intended phone again to select it. Saved phones were preserved."
                            : "Pair again to enable updated transport security."
                    }
                }
                NSLog("Plink async restore found no saved devices")
                return
            }
            let storedSessionKey: Data?
            do {
                storedSessionKey = try secretStore.load(sessionId: device.sessionId)
            } catch {
                NSLog("Plink async restore failed to load session key: \(error.localizedDescription)")
                return
            }
            guard let sessionKey = storedSessionKey else { return }
            await MainActor.run {
                guard self.pairingAttempt == attempt, self.pendingManualOffer == nil else { return }
                self.applyRestoredPairing(device: device, sessionKey: sessionKey)
            }
        }
    }

    private func applyRestoredPairing(device: PairedDevice, sessionKey: Data) {
        guard device.trusted, device.securityVersion == 2 else {
            lastDeliveryState = "Pair again to enable updated transport security."
            return
        }
        guard let selected = try? pairingFinalization.selectedDevice(localDeviceID: localMacDeviceId),
              selected.id == device.id, selected.sessionId == device.sessionId else {
            lastDeliveryState = "Pair your intended phone again to select it. Saved phones were preserved."
            return
        }
        guard canConfirmPairing == false, sessionKey.count == 32 else { return }
        activePairing = (device, sessionKey)
        activeTransport = makeTransport(for: device, sessionKey: sessionKey)
        guard activeTransport != nil else { lastDeliveryState = "Saved phone endpoint is invalid."; return }
        stopPairingAdvertiser()
        stopPairingConfirmationReceiver()
        if startReceiver(sessionKey: sessionKey, pairedDeviceId: device.id) {
            lastDeliveryState = "Paired with \(device.name); waiting for phone traffic."
        }
    }

    private func publishPairingOffer(_ offer: PairingOffer) {
        stopPairingAdvertiser()
        let service = NetService(
            domain: PairingBonjour.domain,
            type: PairingBonjour.serviceType,
            name: "Plink \(offer.deviceName)",
            port: Int32(receiverPort)
        )
        service.delegate = self
        service.setTXTRecord(NetService.data(fromTXTRecord: PairingBonjour.txtRecord(for: offer)))
        service.publish()
        pairingAdvertiser = service
        lastDeliveryState = "Pairing discoverable"
    }

    private func stopPairingAdvertiser() {
        pairingAdvertiser?.stop()
        pairingAdvertiser = nil
    }

    private func startPairingConfirmationReceiver() {
        guard pairingConfirmationReceiver == nil else { return }
        let server = FoundationLengthPrefixedMessageServer(port: receiverPort)
        pairingConfirmationReceiver = server
        do {
            try server.start { [weak self] result in
                Task { @MainActor in
                    switch result {
                    case .success(let data):
                        guard let payload = String(data: data, encoding: .utf8) else {
                            self?.lastDeliveryState = "Pairing confirmation unreadable"
                            return
                        }
                        self?.receiveNearbyConfirmation(payload)
                    case .failure(let error):
                        self?.lastDeliveryState = error.localizedDescription
                    }
                }
            }
        } catch {
            pairingConfirmationReceiver = nil
            lastDeliveryState = error.localizedDescription
        }
    }

    private func stopPairingConfirmationReceiver() {
        pairingConfirmationReceiver?.stop()
        pairingConfirmationReceiver = nil
    }

    func netServiceDidPublish(_ sender: NetService) {
        lastDeliveryState = "Pairing discoverable"
        NSLog("Plink Bonjour published \(sender.name) \(sender.type)")
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        lastDeliveryState = "Pairing discovery failed"
        NSLog("Plink Bonjour publish failed: \(errorDict)")
    }

    private func makeTransport(for device: PairedDevice, sessionKey: Data) -> SerializedPlinkSender? {
        guard
            let separator = device.endpoint.lastIndex(of: ":"),
            let port = UInt16(device.endpoint[device.endpoint.index(after: separator)...]), port > 0,
            separator != device.endpoint.startIndex
        else { return nil }

        let host = String(device.endpoint[..<separator])
        guard !host.contains(where: { $0.isWhitespace }), !host.contains("/") else { return nil }
        return SerializedPlinkSender(transport: SecureNetworkPlinkClient(
            host: host,
            port: port,
            codec: EncryptedFrameCodec(sessionKey: sessionKey),
            stateStore: frameStateStore
        ), previousSender: activeTransport ?? retiringTransport)
    }

    @discardableResult
    private func startReceiver(sessionKey: Data, pairedDeviceId: String) -> Bool {
        files.reset()
        screen.unbind()
        stopPairingConfirmationReceiver()
        receiver?.stop()
        pairedPeerID = pairedDeviceId
        connectionGeneration = UUID()
        let generation = connectionGeneration
        let localID = localMacDeviceId
        let ingress = screenIngress
        let previewAdmission = screen.admissionGeneration
        commands.removeAll()
        notificationBridge.clearContexts()
        do {
            let server = FoundationSecurePlinkServer(
                port: receiverPort,
                codec: EncryptedFrameCodec(sessionKey: sessionKey),
                expectedSourceDeviceId: pairedDeviceId,
                expectedTargetDeviceId: localMacDeviceId,
                stateStore: frameStateStore
            )
            try server.start { [weak self] result in
                switch result {
                case .success(let envelope) where ScreenPreviewPayloadPolicy.eventTypes.contains(envelope.type):
                    guard let previewGeneration = previewAdmission.current(),
                          let admission = ingress.admit(envelope, expectedSourceDeviceID: pairedDeviceId,
                        expectedTargetDeviceID: localID, connectionGeneration: generation) else { return }
                    Task { @MainActor in
                        guard let self, self.connectionGeneration == generation else { admission.release(); return }
                        self.screen.receive(envelope, admission: admission, previewGeneration: previewGeneration)
                    }
                    return
                case .failure(let error) where error is AuthenticatedScreenProtocolRejection:
                    guard let previewGeneration = previewAdmission.current(),
                          let rejection = error as? AuthenticatedScreenProtocolRejection,
                          let admission = ingress.admit(rejection, expectedPeerDeviceID: pairedDeviceId,
                                                        connectionGeneration: generation) else { return }
                    Task { @MainActor in
                        guard let self, self.connectionGeneration == generation else { admission.release(); return }
                        self.screen.receive(rejection, admission: admission, previewGeneration: previewGeneration)
                    }
                    return
                case .failure:
                    // Unauthenticated/malformed traffic is not a user event. Drop
                    // it here so a network flood cannot enqueue MainActor work.
                    return
                default: break
                }
                Task { @MainActor in
                    guard self?.connectionGeneration == generation else { return }
                    self?.handleInbound(result)
                }
            }
            receiver = server
            if let activeTransport { files.bind(localID: localMacDeviceId, peerID: pairedDeviceId, transport: activeTransport) }
            if let sender = activeTransport {
                screen.bind(localID: localID, peerID: pairedDeviceId, generation: generation, sender: sender)
            }
            lastDeliveryState = "Receiver listening"
            NSLog("Plink receiver listening on \(receiverPort)")
            return true
        } catch {
            receiver = nil
            clearTransport()
            pairedPeerID = nil
            lastDeliveryState = error.localizedDescription
            NSLog("Plink receiver failed: \(error.localizedDescription)")
            return false
        }
    }

    private func localMacEndpoint() -> String {
        let address = Host.current().addresses.first {
            $0.contains(".") && !$0.hasPrefix("127.") && !$0.hasPrefix("169.254.")
        } ?? "127.0.0.1"
        return "\(address):\(receiverPort)"
    }

    func handleInbound(_ result: Result<PlinkEnvelope, Error>) {
        switch result {
        case .success(let envelope):
            guard envelope.sourceDeviceId == pairedPeerID, envelope.targetDeviceId == localMacDeviceId else { return }
            lastPeerActivity = .now
            if FileTransferPayloadPolicy.eventTypes.contains(envelope.type) {
                files.receive(envelope)
                return
            }
            if let result = commands.resolve(envelope) { showCommandResult(result); return }
            switch envelope.type {
            case .deviceStatus:
                guard let state = MacDeviceStatus(envelope: envelope) else { lastDeliveryState = "Invalid device status ignored."; return }
                deviceStatus = state
            case .mediaState:
                guard let state = MacMediaState(envelope: envelope) else { lastDeliveryState = "Invalid media state ignored."; return }
                let removed = state.title.isEmpty && state.artist.isEmpty && !state.playing &&
                    !["play", "pause", "next", "previous"].contains(where: state.allows)
                if removed { mediaSessions.removeValue(forKey: state.sessionID) }
                else if !state.sessionID.isEmpty { mediaSessions[state.sessionID] = state }
                if mediaState?.sessionID == state.sessionID { mediaState = removed ? nil : state }
                if mediaState == nil { mediaState = mediaSessions.values.sorted { $0.sessionID < $1.sessionID }.first }
            case .clipboardUpdated, .webOpen:
                let executed = HandoffPlanner.action(for: envelope).map(perform) ?? false
                if envelope.requiresAck { sendOutcome(for: envelope, executed: executed) }
                return
            default:
                notificationBridge.show(envelope: envelope)
            }
            lastDeliveryState = "Received \(envelope.type.rawValue)"
        case .failure(let error):
            lastDeliveryState = error.localizedDescription
        }
    }

    private func perform(_ action: HandoffAction) -> Bool {
        switch action.kind {
        case .clipboard(let text):
            guard receiveClipboard, text.utf8.count <= 32_768 else { lastDeliveryState = "Clipboard receiving is off or text is too large."; return false }
            NSPasteboard.general.clearContents()
            let result = NSPasteboard.general.setString(text, forType: .string)
            lastDeliveryState = result ? "Copied text from phone." : "Could not write clipboard."
            return result
        case .openURL(let url):
            guard receiveURLs else { lastDeliveryState = "Link receiving is off."; return false }
            let result = NSWorkspace.shared.open(url)
            lastDeliveryState = result ? "Opened link from phone." : "Could not open link."
            return result
        case .fileOffer:
            lastDeliveryState = "Open Files to review the pending offer."
            return false
        }
    }

    private func sendOutcome(for original: PlinkEnvelope, executed: Bool) {
        guard let transport = activeTransport else { return }
        let payload: [String: PayloadValue] = executed
            ? ["eventId": .string(original.id), "status": .string("executed"), "action": .string(original.type.rawValue)]
            : ["eventId": .string(original.id), "code": .string("handoff_unavailable"), "message": .string("Receiving is disabled or this action is unavailable.")]
        let envelope = PlinkEnvelope(id: "result_\(UUID().uuidString)", type: executed ? .ack : .error, sentAt: .now,
            sourceDeviceId: localMacDeviceId, targetDeviceId: original.sourceDeviceId, payload: payload)
        Task { do { try await transport.send(envelope) } catch { lastDeliveryState = "Could not report handoff outcome." } }
    }

    func sendCommand(_ envelope: PlinkEnvelope) {
        guard envelope.targetDeviceId == pairedPeerID, let transport = activeTransport else {
            commandStatus = "Pair your phone before sending."; return
        }
        let generation = connectionGeneration
        commands.begin(envelope)
        latestCommandID = envelope.id
        commandStatus = "Sending request…"
        if envelope.type == .messageReply {
            latestReplyID = envelope.id
            lastReply = "Waiting for Android reply execution…"
        }
        Task {
            do {
                try await transport.send(envelope)
                guard generation == connectionGeneration else { return }
                // A fast ack may already have resolved this request. Never overwrite it.
                if latestCommandID == envelope.id && commandStatus == "Sending request…" { commandStatus = "Sent to transport; waiting for Android execution." }
            } catch {
                guard generation == connectionGeneration else { return }
                commands.remove(envelope.id)
                let failure = "Transport failed. Execution was not confirmed."
                if latestCommandID == envelope.id,
                   commandStatus == "Sending request…" || commandStatus == "Sent to transport; waiting for Android execution." {
                    commandStatus = failure
                }
                if latestReplyID == envelope.id, lastReply == "Waiting for Android reply execution…" { lastReply = failure }
            }
        }
    }

    private func showCommandResult(_ result: MacCommandResult) {
        guard result.eventID == latestCommandID || result.eventID == latestReplyID else { return }
        let status: String
        switch result.status {
        case .executed:
            status = result.action == .messageReply ? "Android executed the reply action; recipient delivery is not confirmed." : "Android executed the action."
        case .awaitingUser:
            status = "Ready on Pixel; tap the notification. The action has not been applied."
        case .failed(let code): status = "Phone could not execute the action (\(code))."
        case .unconfirmed: status = "No execution confirmation. Check the phone before retrying."
        }
        if result.eventID == latestCommandID { commandStatus = status }
        if result.eventID == latestReplyID { lastReply = status }
    }

    private func send(_ type: EventType, payload: [String: PayloadValue]) {
        guard let peer = pairedPeerID else { commandStatus = "Pair your phone first."; return }
        sendCommand(PlinkEnvelope(id: "command_\(UUID().uuidString)", type: type, sentAt: .now,
            sourceDeviceId: localMacDeviceId, targetDeviceId: peer, requiresAck: true, payload: payload))
    }

    func sendClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty, text.utf8.count <= 32_768 else {
            commandStatus = "Copy text first (up to 32 KB)."; return
        }
        send(.clipboardUpdated, payload: ["text": .string(text), "localOnly": .bool(false)])
    }

    func sendURL() {
        let value = sharingURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= 8192, PayloadPolicy.isAllowedURL(value),
              let url = URL(string: value), url.host != nil else { commandStatus = "Enter an http or https link."; return }
        send(.webOpen, payload: ["url": .string(value)])
    }

    func selectMediaSession(_ id: String) { mediaState = mediaSessions[id] }

    func mediaCommand(_ command: String) {
        guard let media = mediaState, media.allows(command), Date().timeIntervalSince(media.receivedAt) <= 120 else {
            commandStatus = "Media state is stale or the command is unavailable."; return
        }
        send(.mediaCommand, payload: ["sessionId": .string(media.sessionID), "command": .string(command)])
    }

    private func data(from key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }


}

struct DashboardWindow: View {
    @ObservedObject var appDelegate: AppDelegate
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Plink").font(.largeTitle.bold())
                Text("Pixel + Mac continuity").foregroundStyle(.secondary)
                Text(appDelegate.lastDeliveryState).font(.callout)
                HStack {
                    Button("Pair Phone") { appDelegate.showPairingWindow() }.disabled(!appDelegate.pairingRecoveryComplete)
                    Button("Enable Notifications") { appDelegate.notificationBridge.requestAuthorization() }
                    Spacer()
                    Button("Quit") { appDelegate.quit() }
                }
                Button("Open System Settings for Notifications…") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
                }.help("Open Notifications → Plink and enable Allow Notifications. Requesting access again cannot reset a denial.")
                BluetoothCallingView(controller: appDelegate.calling)
                ContinuityPanel(appDelegate: appDelegate)
                GroupBox("Phone previews") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Allow phone screen preview on this Mac", isOn: $appDelegate.screenPreviewEnabled)
                        Button("Phone Screen…") { appDelegate.showScreenWindow() }
                            .disabled(appDelegate.pairedPeerID == nil || !appDelegate.screenPreviewEnabled)
                        Button("Pixel USB Webcam…") { appDelegate.showWebcamWindow() }
                        Text("Screen sharing needs approval on your phone. USB webcam needs a data cable and camera access.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                FileTransferPanel(controller: appDelegate.files)
            }
            .padding(24)
        }
        .frame(minWidth: 440, minHeight: 620)
    }
}

struct MenuBarPanel: View {
    @ObservedObject var appDelegate: AppDelegate
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Plink", systemImage: "link.circle.fill").font(.title2)
            Text(appDelegate.lastDeliveryState).font(.callout)
            if let battery = appDelegate.deviceStatus {
                Text("Last phone battery: \(battery.batteryLevel)%\(battery.charging ? " · Charging" : "")")
                Text(battery.receivedAt, style: .relative).font(.caption).foregroundStyle(.secondary)
            }
            Text(appDelegate.lastReply).font(.caption).foregroundStyle(.secondary)
            Button("Open Plink") { appDelegate.showDashboardWindow() }
            Button("Phone Screen…") { appDelegate.showScreenWindow() }
                .disabled(appDelegate.pairedPeerID == nil || !appDelegate.screenPreviewEnabled)
            Button("Pixel USB Webcam…") { appDelegate.showWebcamWindow() }
            Button("Send Clipboard") { appDelegate.sendClipboard() }.disabled(appDelegate.pairedPeerID == nil)
            FileTransferMenu(controller: appDelegate.files, openDashboard: { appDelegate.showDashboardWindow() })
            Button("Quit") { appDelegate.quit() }
        }.padding(18).frame(width: 320)
    }
}

struct BluetoothCallingView: View {
    @ObservedObject var controller: BluetoothCallController
    @State private var selectedPhone = ""
    var body: some View {
        GroupBox("Cellular calls") {
            VStack(alignment: .leading, spacing: 10) {
                Text(controller.status).textSelection(.enabled)
                Picker("Bluetooth phone", selection: $selectedPhone) {
                    Text("Select phone").tag("")
                    ForEach(controller.phones) { phone in Text("\(phone.name) · \(phone.id)").tag(phone.id) }
                }
                HStack {
                    Button("Find Paired Phones") { controller.discover() }
                    Button("Connect") { controller.connect(selectedPhone) }.disabled(selectedPhone.isEmpty || controller.call.context != nil)
                    Button("Disconnect") { controller.disconnect() }
                        .disabled(controller.call.phoneID == nil)
                }.disabled(controller.busy || controller.blocked)
                if let context = controller.call.context {
                    Text(controller.call.number ?? "Unknown caller").font(.headline)
                    Text(controller.call.phase.rawValue.capitalized)
                    HStack {
                        callButton("Answer on Mac", .answer, context)
                        callButton("Decline", .decline, context)
                        callButton("End Call", .hangUp, context)
                    }
                    HStack {
                        callButton("Audio on Mac", .computerAudio, context)
                        callButton("Audio on Phone", .phoneAudio, context)
                        callButton(controller.call.muted ? "Unmute" : "Mute", .toggleMute, context)
                    }
                    Text(controller.call.audio == .scoConnectedUnverified
                         ? "Bluetooth audio is connected. Two-way laptop audio still needs verification."
                         : "Audio: \(controller.call.audio.rawValue)")
                    .font(.caption).foregroundStyle(.secondary)
                }
                Text("Select the same phone you paired with Plink. Bluetooth calling uses a separate Bluetooth connection.")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }
    private func callButton(_ title: String, _ action: MacCallAction, _ context: MacCallContext) -> some View {
        Button(title) { controller.perform(action, context: context) }
            .disabled(controller.busy || controller.blocked || !controller.call.permits(action, context: context))
    }
}

struct ContinuityPanel: View {
    @ObservedObject var appDelegate: AppDelegate
    var body: some View {
        GroupBox("Phone continuity") {
            VStack(alignment: .leading, spacing: 12) {
                TimelineView(.periodic(from: .now, by: 10)) { timeline in
                    if let battery = appDelegate.deviceStatus {
                        Label("\(battery.batteryLevel)%\(battery.charging ? " · Charging" : "") · \(battery.network)", systemImage: battery.charging ? "battery.100percent.bolt" : "battery.100percent")
                        Text("Last received \(battery.receivedAt.formatted(date: .omitted, time: .shortened))\(timeline.date.timeIntervalSince(battery.receivedAt) > 120 ? " · May be stale" : "")")
                            .font(.caption).foregroundStyle(.secondary)
                    } else { Text("Battery status has not arrived.").foregroundStyle(.secondary) }
                    if let media = appDelegate.mediaState {
                        if appDelegate.mediaSessions.count > 1 {
                            Picker("Phone media session", selection: Binding(get: { media.sessionID }, set: { appDelegate.selectMediaSession($0) })) {
                                ForEach(appDelegate.mediaSessions.values.sorted { $0.sessionID < $1.sessionID }, id: \.sessionID) { session in
                                    Text(session.title.isEmpty ? "Phone media" : session.title).tag(session.sessionID)
                                }
                            }
                        }
                        Text(media.title.isEmpty ? "Phone media" : media.title).font(.headline)
                        Text(media.artist).foregroundStyle(.secondary)
                        HStack {
                            ForEach(["previous", media.playing ? "pause" : "play", "next"], id: \.self) { command in
                                Button(command.capitalized) { appDelegate.mediaCommand(command) }
                                    .disabled(!media.allows(command) || timeline.date.timeIntervalSince(media.receivedAt) > 120)
                            }
                        }
                    } else { Text("No active phone media session.").foregroundStyle(.secondary) }
                }
                Divider()
                Button("Send Clipboard to Phone") { appDelegate.sendClipboard() }.disabled(appDelegate.pairedPeerID == nil)
                HStack {
                    TextField("https://example.com", text: $appDelegate.sharingURL).textFieldStyle(.roundedBorder)
                    Button("Open on Phone") { appDelegate.sendURL() }.disabled(appDelegate.pairedPeerID == nil)
                }
                Toggle("Receive clipboard text from phone", isOn: $appDelegate.receiveClipboard)
                Toggle("Open web links received from phone", isOn: $appDelegate.receiveURLs)
                Text(appDelegate.commandStatus).font(.caption).textSelection(.enabled)
                Text("Last reply: \(appDelegate.lastReply)").font(.caption)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }
}

struct PairingView: View {
    @ObservedObject var appDelegate: AppDelegate

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "link.circle.fill")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Pair Pixel")
                        .font(.largeTitle.weight(.semibold))
                    Text("Nearby pairing")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Text(appDelegate.pairingStatusText)
                .font(.title3)

            if let code = appDelegate.pairingVerificationCode {
                VStack(alignment: .leading, spacing: 10) {
                    Text(code.emoji.joined(separator: "  "))
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                    Text("Code \(code.numeric)")
                        .font(.title3.monospacedDigit())
                    Text(code.labels.joined(separator: " + "))
                        .foregroundStyle(.secondary)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 18))
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ProgressView()
                    Text("Waiting for your Pixel to discover this Mac.")
                        .foregroundStyle(.secondary)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 18))
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("Open Plink on your Pixel", systemImage: "iphone.gen3.radiowaves.left.and.right")
                Label("Tap this Mac when it appears", systemImage: "macbook")
                Label("Confirm here only if the code matches", systemImage: "checkmark.shield")
            }
            .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("Cancel") { appDelegate.cancelPairing() }
                Button("Restart Discovery") {
                    appDelegate.startNearbyPairing()
                }
                Button("Confirm Pairing") {
                    Task {
                        do { try await appDelegate.confirmManualPairing() }
                        catch { appDelegate.lastDeliveryState = "Pairing failed: \(error.localizedDescription)" }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(appDelegate.canConfirmPairing == false)
            }
            Spacer()
        }
        .padding(28)
        .frame(width: 500, height: 430)
    }
}

enum AppDeliveryError: LocalizedError {
    case transportUnavailable
    case pairingOfferUnavailable
    case pairingResponseUnavailable

    var errorDescription: String? {
        switch self {
        case .transportUnavailable:
            return "No paired Pixel transport is available."
        case .pairingOfferUnavailable:
            return "No Mac pairing offer is ready."
        case .pairingResponseUnavailable:
            return "Paste and preview the Pixel response first."
        }
    }
}
