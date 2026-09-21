import AppKit
import CoreGraphics
import CryptoKit
import Network
import PlinkCore
import SwiftUI
import UserNotifications

private struct ReconnectPathSignature: Equatable, Sendable {
    let status: String
    let interfaces: [String]
    let supportsIPv4: Bool
    let localInterfaces: Set<ReconnectInterfaceSnapshot>
}

@main
struct PlinkMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel(appDelegate: appDelegate, reconnect: appDelegate.reconnect, calling: appDelegate.calling)
        } label: {
            LucideIcon.menuBarLink.accessibilityLabel("Plink")
        }
        .menuBarExtraStyle(.menu)

        Settings {
            PlinkSettingsContent(appDelegate: appDelegate)
                .padding(24)
                .frame(width: 460)
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
    private let reconnectEndpointStore = ReconnectEndpointStore.applicationDefault
    private var activeTransport: SerializedPlinkSender?
    private var retiringTransport: SerializedPlinkSender?
    private var pairLifetime: PairSessionLifetime?
    private var reconnectListener: ReconnectListener?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAuthority: ReconnectCommitAuthority?
    private var reconnectAttempt = UUID()
    private var reconnectDeadline: ContinuousClock.Instant?
    private var reconnectDeadlineTask: Task<Void, Never>?
    private var pendingManualOffer: PairingOffer?
    private var pendingManualConfirmation: PairingConfirmation?
    private var pendingConsent: PairingConsent?
    private var consentDeadline: ContinuousClock.Instant?
    private var consentIsFresh: Bool { consentDeadline.map { ContinuousClock.now < $0 } ?? false }
    private var activePairing: (device: PairedDevice, key: Data)?
    private var priorPairing: (device: PairedDevice, key: Data)?
    @Published private(set) var pairingRecoveryComplete = false
    @Published private(set) var pairingRecoveryError: String?
    @Published private(set) var pairedPhoneName: String?
    @Published private(set) var isPairing = false
    @Published private(set) var pairingCompleted = false
    private lazy var pairingFinalization = MacPairingFinalization(devices: pairingStore, secrets: pairingSecretStore)
    @Published private(set) var pairingInFlight = false
    private var pairingAttempt = UUID()
    private var pairingExpiryTask: Task<Void, Never>?
    let calling = BluetoothCallController()
    let clipboard = ClipboardSyncController()
    let files = FileTransferController()
    let reconnect = ReconnectController()
    @Published var deviceStatus: MacDeviceStatus?
    @Published var mediaState: MacMediaState?
    @Published var mediaSessions: [String: MacMediaState] = [:]
    @Published var commandStatus = "No command pending"
    @Published var pairedPeerID: String? {
        didSet { clipboard.setConnected(pairedPeerID != nil) }
    }
    @Published var lastPeerActivity: Date?
    @Published var sharingURL = ""
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
    @Published var lastDeliveryState: String = "No phone connected"
    @Published private(set) var notificationsEnabled = false
    @Published private(set) var notificationStatus = "Checking notification access…"
    @Published var pairingStatusText: String = "Looking for your Pixel."
    @Published var pairingVerificationCode: PairingVerificationCode?
    @Published var pairingPeerName: String = "Pixel"
    @Published var canConfirmPairing: Bool = false
    private var dashboardWindow: NSWindow?
    private var pairingWindow: NSWindow?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var sessionObservers: [NSObjectProtocol] = []
    private let recoveryPolicy = ReconnectRecoveryPolicy()
    private var reconnectSystemAwake = true
    private var reconnectScreenAwake = true
    private var reconnectSessionActive = true
    private var reconnectSessionUnlocked = true
    private var reconnectPathEligible = false
    private var terminationPending = false
    private var terminationReplied = false
    private var terminationWatchdog: Task<Void, Never>?
    private let reconnectPathMonitor = NWPathMonitor()
    private let reconnectPathQueue = DispatchQueue(label: "com.thekozugroup.plink.reconnect-path")
    private var reconnectPathSignature: ReconnectPathSignature?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installReconnectLifecycleObservers()
        startReconnectPathMonitor()
        reconnect.onDiscoveryStart = { [weak self] in self?.startReconnectAttempt() ?? false }
        reconnect.onManualConnect = { [weak self] in
            guard let self else { return }
            self.cancelPendingAutomaticRecovery()
            self.recoveryPolicy.resumeByUser()
            if self.reconnectAuthority != nil { self.cancelReconnect() }
        }
        reconnect.onDiscoveredCandidates = { [weak self] candidates in
            self?.continueReconnect(candidates: candidates)
        }
        reconnect.onCandidate = { [weak self] candidate in
            guard let self, self.startReconnectAttempt() else { return }
            self.continueReconnect(candidates: [candidate])
        }
        reconnect.onCancel = { [weak self] in
            self?.recoveryPolicy.cancelByUser()
            self?.cancelReconnect()
        }
        ProcessInfo.processInfo.disableAutomaticTermination("Plink keeps the paired Pixel receiver and menu bar companion active.")
        ProcessInfo.processInfo.disableSuddenTermination()
        NSApplication.shared.setActivationPolicy(.regular)
        notificationBridge.onAuthorizationChanged = { [weak self] granted, error in
            Task { @MainActor in
                self?.notificationsEnabled = granted
                self?.notificationStatus = granted
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
        notificationBridge.configure()
        clipboard.onTextChanged = { [weak self] text in
            guard let self, let peer = self.pairedPeerID,
                  let transport = self.activeTransport, self.clipboard.enabled else { return }
            let envelope = PlinkEnvelope(id: "clipboard_\(UUID().uuidString)", type: .clipboardUpdated,
                sentAt: .now, sourceDeviceId: self.localMacDeviceId, targetDeviceId: peer,
                payload: ["text": .string(text), "localOnly": .bool(false), "automatic": .bool(true)])
            try Task.checkCancellation()
            try await transport.send(envelope)
        }
        clipboard.start()
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
        clipboard.stop()
        cancelReconnect()
        let reconnectCleanup = reconnectTask
        terminationWatchdog = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            self?.replyToTermination()
        }
        Task { [weak self] in
            guard let self else { return }
            await reconnectCleanup?.value
            reconnectListener?.stop()
            reconnectListener = nil
            pairLifetime?.invalidate()
            pairLifetime = nil
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
        terminationPending = true
        cancelPendingAutomaticRecovery()
        reconnect.stopDiscoveryForLifecycle()
        reconnectPathMonitor.cancel()
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        sessionObservers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        sessionObservers.removeAll()
        files.reset()
        housekeeping?.cancel()
        reconnectTask?.cancel()
        reconnectListener?.stop()
        reconnectListener = nil
        pairLifetime?.invalidate()
        pairLifetime = nil
        clearPairingAttempt() // Prevent a suspended final send from establishing trust.
        connectionGeneration = UUID()
        stopPairingAdvertiser()
        stopPairingConfirmationReceiver()
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
                contentRect: NSRect(x: 0, y: 0, width: 540, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.center()
            window.title = "Plink"
            window.titlebarAppearsTransparent = false
            window.backgroundColor = .windowBackgroundColor
            window.isOpaque = false
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: DashboardWindow(appDelegate: self))
            dashboardWindow = window
        }
        dashboardWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
    }

    func showPairingWindow() {
        if pendingManualOffer == nil && !isPairing { startNearbyPairing() }
        if pairingWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 490),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.center()
            window.title = "Connect Your Phone"
            window.titlebarAppearsTransparent = false
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: PairingView(appDelegate: self))
            pairingWindow = window
        }
        pairingWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
    }

    func finishSetup() {
        pairingWindow?.orderOut(nil)
        showDashboardWindow()
    }

    func setUpCalls() {
        guard let pairedPhoneName else { return }
        calling.beginSetup(phoneName: pairedPhoneName)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !terminationPending else { return }
        notificationBridge.refreshAuthorization()
        schedulePendingAutomaticRecovery()
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === pairingWindow, isPairing { cancelPairing() }
    }

    private func installReconnectLifecycleObservers() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if name == NSWorkspace.willSleepNotification { self.reconnectSystemAwake = false }
                    if name == NSWorkspace.screensDidSleepNotification { self.reconnectScreenAwake = false }
                    if name == NSWorkspace.sessionDidResignActiveNotification { self.reconnectSessionActive = false }
                    self.invalidateReconnectForEnvironmentChange(
                        "Reconnect is required after the Mac sleeps or locks."
                    )
                }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if name == NSWorkspace.didWakeNotification { self.reconnectSystemAwake = true }
                    if name == NSWorkspace.screensDidWakeNotification { self.reconnectScreenAwake = true }
                    if name == NSWorkspace.sessionDidBecomeActiveNotification { self.reconnectSessionActive = true }
                    self.schedulePendingAutomaticRecovery()
                }
            })
        }
        // These are hints only: a fresh system session/lock read gates every attempt.
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            sessionObservers.append(DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name(name), object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if name == "com.apple.screenIsLocked" {
                        self.reconnectSessionUnlocked = false
                        self.invalidateReconnectForEnvironmentChange("Reconnect is required after the Mac locks.")
                    } else {
                        self.reconnectSessionUnlocked = true
                        self.schedulePendingAutomaticRecovery()
                    }
                }
            })
        }
    }

    private func startReconnectPathMonitor() {
        reconnectPathMonitor.pathUpdateHandler = { [weak self] path in
            let signature = ReconnectPathSignature(status: String(describing: path.status),
                interfaces: path.availableInterfaces.map(\.name).sorted(), supportsIPv4: path.supportsIPv4,
                localInterfaces: Set(ReconnectCandidatePolicy.currentInterfaces()))
            let pathEligible = path.status == .satisfied && path.supportsIPv4
            Task { @MainActor in
                guard let self, !self.terminationPending else { return }
                let previous = self.reconnectPathSignature
                self.reconnectPathSignature = signature
                self.reconnectPathEligible = pathEligible
                guard let previous else {
                    self.schedulePendingAutomaticRecovery()
                    return
                }
                guard previous != signature else { return }
                self.invalidateReconnectForEnvironmentChange(
                    "The local network changed. Reconnect to verify the new path."
                )
            }
        }
        reconnectPathMonitor.start(queue: reconnectPathQueue)
    }

    private func invalidateReconnectForEnvironmentChange(_ message: String) {
        guard !terminationPending else { return }
        cancelPendingAutomaticRecovery()
        reconnect.stopDiscoveryForLifecycle()
        if reconnectAuthority != nil || pairLifetime?.ordinaryAdmission() != nil {
            reconnect.setFailed(message)
            lastDeliveryState = message
            cancelReconnect()
        }
        recoveryPolicy.request()
        schedulePendingAutomaticRecovery()
    }

    private var reconnectEnvironmentEligible: Bool {
        guard reconnectSystemAwake, reconnectScreenAwake, reconnectSessionActive, reconnectSessionUnlocked,
              reconnectPathEligible, ClipboardSyncController.systemIsUnlocked(),
              let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              session[kCGSessionOnConsoleKey as String] as? Bool == true else { return false }
        return ReconnectCandidatePolicy.currentInterfaces().contains {
            $0.up && $0.broadcast && !$0.loopback && !$0.pointToPoint && !$0.vpn &&
                $0.index > 0 && !$0.name.isEmpty && (1...30).contains($0.prefixLength) &&
                (try? IPv4Endpoint(address: $0.localIPv4, port: receiverPort)) != nil
        }
    }

    private func cancelPendingAutomaticRecovery() {
        recoveryPolicy.invalidate()
    }

    private func schedulePendingAutomaticRecovery() {
        guard recoveryPolicy.pending,
              pairingRecoveryComplete, !terminationPending, !isPairing, !pairingInFlight,
              reconnectEnvironmentEligible, let lifetime = pairLifetime, lifetime.isCurrent,
              let pairing = activePairing, pairing.device.id == lifetime.peerID,
              pairing.device.sessionId == lifetime.sessionID, reconnectListener != nil,
              reconnectAuthority == nil, pairedPeerID == nil, lifetime.ordinaryAdmission() == nil else { return }
        let attempt = reconnectAttempt
        let pairingToken = pairingAttempt
        recoveryPolicy.schedule(eligible: { [weak self, weak lifetime] in
            guard let self, let lifetime, self.pairLifetime === lifetime, lifetime.isCurrent,
                  self.reconnectAttempt == attempt, self.pairingAttempt == pairingToken,
                  self.activePairing?.device.id == lifetime.peerID,
                  self.activePairing?.device.sessionId == lifetime.sessionID,
                  self.pairingRecoveryComplete, !self.terminationPending,
                  !self.isPairing, !self.pairingInFlight, self.reconnectListener != nil else { return false }
            return self.reconnectEnvironmentEligible
        }, connected: { [weak self, weak lifetime] in
            guard let self, let lifetime else { return true }
            return self.pairedPeerID != nil || lifetime.ordinaryAdmission() != nil
        }, attempting: { [weak self] in
            guard let self else { return true }
            return self.reconnectAuthority != nil
        }, start: { [weak self] in
            // beginDiscovery starts the existing 30-second authority before awaiting retirement.
            self?.reconnect.beginDiscovery(automatically: true)
        })
    }

    private func clearTransport() {
        clipboard.setConnected(false)
        let previous = activeTransport ?? retiringTransport
        previous?.invalidate()
        activeTransport = nil
        if let previous {
            retiringTransport = previous
            Task { [weak self] in
                await previous.shutdown()
                guard let self, self.retiringTransport === previous else { return }
                self.retiringTransport = nil
            }
        }
    }

    private func stopPairLifetime() {
        cancelPendingAutomaticRecovery()
        reconnect.stopDiscoveryForLifecycle()
        reconnectAuthority?.invalidate()
        reconnectAuthority = nil
        reconnectDeadlineTask?.cancel()
        reconnectDeadlineTask = nil
        reconnectDeadline = nil
        reconnectListener?.stop()
        reconnectListener = nil
        pairLifetime?.invalidate()
        pairLifetime = nil
    }

    private func preparePairLifetimeReplacement() async -> UUID? {
        cancelPendingAutomaticRecovery()
        reconnect.stopDiscoveryForLifecycle()
        clipboard.setConnected(false)
        let previous = reconnectTask
        reconnectAuthority?.invalidate()
        reconnectDeadlineTask?.cancel()
        reconnectDeadlineTask = nil
        reconnectDeadline = nil
        previous?.cancel()
        reconnectAttempt = UUID()
        let token = reconnectAttempt
        pairLifetime?.closeOrdinaryAdmission()
        let ownedTransport = activeTransport ?? retiringTransport
        ownedTransport?.invalidate()
        activeTransport = nil
        if let ownedTransport { retiringTransport = ownedTransport }
        await previous?.value
        guard !Task.isCancelled, reconnectAttempt == token else { return nil }
        await files.suspendAndAwait()
        guard !Task.isCancelled, reconnectAttempt == token else { return nil }
        if let ownedTransport {
            await ownedTransport.shutdown()
            guard !Task.isCancelled, reconnectAttempt == token else { return nil }
            if retiringTransport === ownedTransport { retiringTransport = nil }
        }
        reconnectTask = nil
        return token
    }

    @discardableResult
    private func startPairLifetime(device: PairedDevice, sessionKey: Data, lifecycleToken: UUID) -> Bool {
        guard reconnectAttempt == lifecycleToken, reconnectTask == nil else { return false }
        stopPairLifetime()
        clearTransport()
        pairedPeerID = nil
        connectionGeneration = UUID()
        let lifetime = PairSessionLifetime(localID: localMacDeviceId, peerID: device.id,
            sessionID: device.sessionId, sessionKey: sessionKey, stateStore: frameStateStore)
        let listener = ReconnectListener(port: receiverPort, lifetime: lifetime) { [weak self, weak lifetime] result, generation in
            guard let lifetime, lifetime.isCurrent else { return }
            switch result {
            case .success(let envelope) where ScreenPreviewPayloadPolicy.eventTypes.contains(envelope.type):
                // Screen sharing is unavailable; discard frames before scheduling UI work.
                return
            case .failure:
                return
            default:
                Task { @MainActor in
                    guard let self, self.pairLifetime === lifetime,
                          self.connectionGeneration == generation else { return }
                    self.handleInbound(result)
                }
            }
        }
        do {
            try listener.start()
            pairLifetime = lifetime
            reconnectListener = listener
            reconnect.configure(peerID: device.id, pairedName: device.name)
            lastDeliveryState = "Paired with \(device.name). Connecting…"
            return true
        } catch {
            lifetime.invalidate()
            listener.stop()
            lastDeliveryState = "Reconnect listener failed: \(error.localizedDescription)"
            reconnect.setFailed("The local reconnect listener could not start.")
            return false
        }
    }

    private func scheduleAutomaticReconnect(device: PairedDevice, sessionKey: Data) {
        guard let lifetime = pairLifetime, lifetime.peerID == device.id, lifetime.sessionID == device.sessionId else { return }
        guard !recoveryPolicy.suppressed else { return }
        guard reconnectEnvironmentEligible, !isPairing, !pairingInFlight else {
            recoveryPolicy.request()
            return
        }
        guard startReconnectAttempt() else { return }
        let stored = try? reconnectEndpointStore.load(
            localID: localMacDeviceId,
            peerID: device.id,
            sessionID: device.sessionId,
            sessionKey: sessionKey
        )
        var endpointTexts: [String] = []
        if let stored { endpointTexts.append(stored.endpoint) }
        endpointTexts.append(device.endpoint)
        let interfaces = ReconnectCandidatePolicy.currentInterfaces()
        let candidate = endpointTexts.lazy.compactMap { endpoint in
            interfaces.compactMap { ReconnectCandidatePolicy.candidate(endpoint: endpoint, interface: $0) }.first
        }.first
        guard let candidate else {
            NSLog("Plink reconnect automatic: no eligible candidate")
            continueReconnect(candidates: [])
            return
        }
        NSLog("Plink reconnect automatic: candidate selected")
        continueReconnect(candidates: [candidate])
    }

    private func startReconnectAttempt() -> Bool {
        cancelPendingAutomaticRecovery()
        guard !terminationPending, !isPairing, !pairingInFlight, reconnectEnvironmentEligible else { return false }
        guard let lifetime = pairLifetime, lifetime.isCurrent, reconnectListener != nil,
              let pairing = activePairing, pairing.device.id == lifetime.peerID,
              pairing.device.sessionId == lifetime.sessionID else {
            reconnect.setFailed("No active paired phone.")
            return false
        }
        let previous = reconnectTask
        reconnectAuthority?.invalidate()
        reconnectDeadlineTask?.cancel()
        previous?.cancel()
        reconnectAttempt = UUID()
        let token = reconnectAttempt
        let deadline = ReconnectRecoveryPolicy.attemptDeadline(from: .now)
        let authority = ReconnectCommitAuthority(deadline: deadline)
        reconnectAuthority = authority
        reconnectDeadline = deadline
        NSLog("Plink reconnect attempt started; deadline 30 seconds")
        lifetime.closeOrdinaryAdmission()
        pairedPeerID = nil
        connectionGeneration = UUID()
        commands.removeAll()
        notificationBridge.clearContexts()
        deviceStatus = nil
        mediaState = nil
        mediaSessions.removeAll()
        lastPeerActivity = nil
        let ownedTransport = activeTransport ?? retiringTransport
        ownedTransport?.invalidate()
        activeTransport = nil
        if let ownedTransport { retiringTransport = ownedTransport }
        reconnect.setDisconnecting()
        reconnectTask = Task { [weak self] in
            await previous?.value
            guard let self, self.reconnectAttempt == token,
                  self.reconnectAuthority === authority else { return }
            await self.files.suspendAndAwait()
            guard self.reconnectAttempt == token, self.reconnectAuthority === authority else { return }
            if let ownedTransport {
                await ownedTransport.shutdown()
                guard self.reconnectAttempt == token, self.reconnectAuthority === authority else { return }
                if self.retiringTransport === ownedTransport { self.retiringTransport = nil }
            }
        }
        reconnectDeadlineTask = Task { [weak self, weak authority] in
            do { try await ContinuousClock().sleep(until: deadline) } catch { return }
            guard let self, let authority, self.reconnectAttempt == token,
                  self.reconnectAuthority === authority else { return }
            NSLog("Plink reconnect deadline expired")
            authority.invalidate()
            self.pairLifetime?.closeOrdinaryAdmission()
            self.reconnectTask?.cancel()
            self.reconnect.setDisconnecting()
        }
        return true
    }

    private func continueReconnect(candidates: [ReconnectCandidate]) {
        guard let deadline = reconnectDeadline, let authority = reconnectAuthority else { return }
        let token = reconnectAttempt
        let cleanup = reconnectTask
        let boundedCandidates = Array(candidates.prefix(4))
        func transientCategory(_ error: Error) -> String? {
            guard let error = error as? ReconnectSessionError else { return nil }
            switch error {
            case .timedOut: return "timeout"
            case .socketFailure(let code):
                switch code {
                case ECONNREFUSED: return "connection_refused"
                case ECONNRESET, ECONNABORTED, EPIPE: return "connection_reset"
                case ETIMEDOUT: return "socket_timeout"
                default: return nil
                }
            default: return nil
            }
        }
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await ReconnectRecoveryPolicy.afterCleanup(cleanup, deadline: deadline, isCurrent: {
                    self.reconnectAttempt == token && self.reconnectAuthority === authority
                })
                guard !boundedCandidates.isEmpty else { throw ReconnectSessionError.invalidCandidate }
                let retryDelays: [Duration] = [.milliseconds(500), .seconds(1), .seconds(2)]
                var lastError: Error = ReconnectSessionError.invalidCandidate
                for pass in 0...retryDelays.count {
                    for candidate in boundedCandidates {
                        try Task.checkCancellation()
                        guard self.reconnectAttempt == token,
                              self.reconnectAuthority === authority else { throw CancellationError() }
                        guard ContinuousClock.now < deadline else { throw ReconnectSessionError.timedOut }
                        NSLog("Plink reconnect handshake pass %d", pass + 1)
                        do {
                            // Observe each candidate's error before another can hide a terminal failure.
                            try await self.performReconnect(candidates: [candidate], token: token,
                                                            deadline: deadline, authority: authority)
                            NSLog("Plink reconnect handshake completed")
                            return
                        } catch {
                            try Task.checkCancellation()
                            guard self.reconnectAttempt == token,
                                  self.reconnectAuthority === authority else { throw CancellationError() }
                            guard let category = transientCategory(error) else { throw error }
                            NSLog("Plink reconnect transient failure: %@", category)
                            lastError = error
                        }
                    }
                    guard pass < retryDelays.count else { throw lastError }
                    let retryAt = ContinuousClock.now.advanced(by: retryDelays[pass])
                    guard retryAt < deadline else { throw lastError }
                    NSLog("Plink reconnect waiting before retry")
                    try await ContinuousClock().sleep(until: retryAt)
                }
            } catch {
                authority.invalidate()
                guard self.reconnectAttempt == token, self.reconnectAuthority === authority else { return }
                let category = transientCategory(error) ?? (error is CancellationError ? "cancelled" :
                    error is ReconnectEndpointStoreError ? "endpoint_store" : "non_transient")
                NSLog("Plink reconnect stopped: %@", category)
                self.pairLifetime?.closeOrdinaryAdmission()
                self.pairedPeerID = nil
                self.reconnectDeadlineTask?.cancel()
                self.reconnectDeadlineTask = nil
                self.reconnectDeadline = nil
                self.reconnectAuthority = nil
                self.reconnectTask = nil
                let failure: Error = ContinuousClock.now >= deadline ? ReconnectSessionError.timedOut : error
                self.reconnect.setFailed(self.reconnectFailureMessage(failure))
                self.lastDeliveryState = "Reconnect failed. The saved pairing was preserved."
            }
        }
    }

    private func cancelReconnect() {
        cancelPendingAutomaticRecovery()
        reconnect.stopDiscoveryForLifecycle()
        let previous = reconnectTask
        reconnectAuthority?.invalidate()
        reconnectAuthority = nil
        reconnectDeadlineTask?.cancel()
        reconnectDeadlineTask = nil
        reconnectDeadline = nil
        reconnectAttempt = UUID()
        let token = reconnectAttempt
        previous?.cancel()
        pairLifetime?.closeOrdinaryAdmission()
        pairedPeerID = nil
        connectionGeneration = UUID()
        commands.removeAll()
        notificationBridge.clearContexts()
        deviceStatus = nil
        mediaState = nil
        mediaSessions.removeAll()
        lastPeerActivity = nil
        let ownedTransport = activeTransport ?? retiringTransport
        ownedTransport?.invalidate()
        activeTransport = nil
        if let ownedTransport { retiringTransport = ownedTransport }
        reconnectTask = Task { [weak self] in
            await previous?.value
            guard let self, self.reconnectAttempt == token else { return }
            await self.files.suspendAndAwait()
            guard self.reconnectAttempt == token else { return }
            if let ownedTransport {
                await ownedTransport.shutdown()
                guard self.reconnectAttempt == token else { return }
                if self.retiringTransport === ownedTransport { self.retiringTransport = nil }
            }
            if self.reconnectAttempt == token { self.reconnectTask = nil }
        }
    }

    private func performReconnect(
        candidates: [ReconnectCandidate],
        token: UUID,
        deadline: ContinuousClock.Instant,
        authority: ReconnectCommitAuthority
    ) async throws {
        guard let lifetime = pairLifetime, let listener = reconnectListener,
              let pairing = activePairing, pairing.device.id == lifetime.peerID,
              reconnectAuthority === authority else { throw CancellationError() }
        var lastError: Error = ReconnectSessionError.invalidCandidate
        for candidate in candidates {
            try ReconnectRecoveryPolicy.requireCurrent(deadline: deadline, isCurrent:
                reconnectEnvironmentEligible && !terminationPending && !isPairing && !pairingInFlight &&
                reconnectAttempt == token && pairLifetime === lifetime && reconnectAuthority === authority &&
                activePairing?.device.id == pairing.device.id)
            reconnect.setVerifying()
            let candidateDeadline = min(deadline, ContinuousClock.now.advanced(by: .seconds(8)))
            do {
                let result = try await ReconnectInitiator(lifetime: lifetime, listener: listener,
                    commitAuthority: authority,
                    endpointStore: reconnectEndpointStore, listenerPort: receiverPort,
                    onCandidateExpired: { [weak self] in
                        Task { @MainActor [weak self] in
                            guard let self, self.reconnectAttempt == token,
                                  self.reconnectAuthority === authority else { return }
                            self.reconnect.setDisconnecting()
                        }
                    })
                    .attempt(candidate: candidate, deadline: candidateDeadline)
                try ReconnectRecoveryPolicy.requireCurrent(deadline: deadline, isCurrent:
                    reconnectEnvironmentEligible && !terminationPending && !isPairing && !pairingInFlight &&
                    reconnectAttempt == token && pairLifetime === lifetime && reconnectAuthority === authority &&
                    activePairing?.device.id == pairing.device.id)
                let generation = try lifetime.openOrdinaryAdmission(binding: result.binding)
                let sender = SerializedPlinkSender(transport: BoundSecureNetworkPlinkClient(
                    lifetime: lifetime, binding: result.binding, generation: generation))
                activeTransport = sender
                connectionGeneration = generation
                pairedPeerID = pairing.device.id
                files.bind(localID: localMacDeviceId, peerID: pairing.device.id, transport: sender)
                reconnect.setConnected()
                lastDeliveryState = "Connected to \(pairing.device.name) on the local network."
                authority.invalidate()
                reconnectDeadlineTask?.cancel()
                reconnectDeadlineTask = nil
                reconnectDeadline = nil
                reconnectAuthority = nil
                reconnectTask = nil
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                if ContinuousClock.now >= deadline { throw ReconnectSessionError.timedOut }
            }
        }
        throw lastError
    }

    private func reconnectFailureMessage(_ error: Error) -> String {
        if let reconnectError = error as? ReconnectSessionError {
            switch reconnectError {
            case .invalidCandidate:
                return "No eligible phone address is available on this local network."
            case .unavailableNetworkOrPermission:
                return "The selected interface cannot be bound safely."
            case .authenticationFailed, .wrongPhase:
                return "The paired phone could not be authenticated on this path."
            case .timedOut:
                return "The phone did not complete reconnect in time or uses an incompatible version."
            default:
                break
            }
        }
        if let payloadError = error as? PayloadPolicyError {
            switch payloadError {
            case .invalidSignature, .deviceMismatch:
                return "The paired phone could not be authenticated on this path."
            default:
                break
            }
        }
        if error is ReconnectEndpointStoreError {
            return "The verified endpoint could not be saved safely."
        }
        return "Reconnect did not complete. Check both devices and retry."
    }

    func startNearbyPairing() {
        guard pairingRecoveryComplete else { pairingStatusText = "Waiting for saved pairing recovery."; return }
        guard calling.call.context == nil, !calling.busy else {
            pairingStatusText = "Finish the current call before pairing another phone."
            return
        }
        guard !pairingInFlight else { return }
        files.reset()
        if pendingManualOffer == nil { priorPairing = activePairing }
        stopPairingConfirmationReceiver()
        stopPairingAdvertiser()
        stopPairLifetime()
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
        cancelPendingAutomaticRecovery()
        recoveryPolicy.resumeByUser()
        reconnect.stopDiscoveryForLifecycle()
        isPairing = true
        pairingCompleted = false
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
        pairingStatusText = "Finishing pairing…"
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
            guard let lifecycleToken = await preparePairLifetimeReplacement() else { throw CancellationError() }
            guard pairingAttempt == attempt, pairingInFlight, consentIsFresh else { throw CancellationError() }
            // Journal prior metadata before touching the independent durable stores.
            // Keep the journal until the reconnect listener is active.
            try pairingFinalization.save(device, key: sessionKey, localDeviceID: localMacDeviceId)
            try MacPairingFinalization.activateAndCommit(activate: {
                transport.invalidate()
                retiringTransport = transport
                guard startPairLifetime(device: device, sessionKey: sessionKey,
                                        lifecycleToken: lifecycleToken) else {
                    throw AppDeliveryError.transportUnavailable
                }
            }, commit: {
                try pairingFinalization.commit()
            }, invalidate: {
                invalidateActiveSession()
            })
            activePairing = (device, sessionKey)
            pairedPhoneName = device.name
            pairingCompleted = true
            pairingRecoveryError = nil
            calling.configurePairedPhone(peerID: device.id)
            priorPairing = nil
            clearPairingAttempt()
            scheduleAutomaticReconnect(device: device, sessionKey: sessionKey)
            pairingStatusText = "Paired with \(device.name)."
            Task { @MainActor [weak self] in self?.setUpCalls() }
        } catch {
            // Cancel/restart may have already restored the old session. Never roll
            // back a subsequent attempt from this suspended send's completion.
            guard pairingAttempt == attempt else { throw error }
            invalidateActiveSession()
            do { try pairingFinalization.rollback() }
            catch {
                pairingRecoveryComplete = false
                pairingRecoveryError = "Pairing recovery failed. Restart Plink before pairing again."
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
        let attempt = pairingAttempt
        Task { [weak self] in
            await self?.applyRestoredPairing(device: previous.device, sessionKey: previous.key,
                                             expectedPairingAttempt: attempt)
        }
    }

    private func invalidateActiveSession() {
        reconnectAttempt = UUID()
        reconnectAuthority?.invalidate()
        reconnectTask?.cancel()
        stopPairLifetime()
        files.reset()
        connectionGeneration = UUID()
        clearTransport()
        activePairing = nil
        pairedPhoneName = nil
        pairedPeerID = nil
        commands.removeAll()
        notificationBridge.clearContexts()
        deviceStatus = nil
        mediaState = nil
        mediaSessions.removeAll()
        lastPeerActivity = nil
    }

    private func clearPairingAttempt() {
        isPairing = false
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
            NSLog("Plink startup pairing recovery started")
            let store = UserDefaultsPairingStore(domainName: domainName)
            let secretStore = KeychainPairingSecretStore()
            let finalization = MacPairingFinalization(devices: store, secrets: secretStore)
            do {
                try finalization.rollback()
            } catch {
                NSLog("Plink startup pairing rollback failed: \(error.localizedDescription)")
                await MainActor.run {
                    self.pairingRecoveryError = "Saved pairing recovery failed. Pairing is disabled until recovery succeeds."
                    self.lastDeliveryState = "Saved pairing recovery failed. Pairing is disabled until recovery succeeds."
                }
                return
            }
            let devices: [PairedDevice]
            do {
                devices = try store.all()
            } catch {
                NSLog("Plink startup pairing store read failed: \(error.localizedDescription)")
                await MainActor.run {
                    self.pairingRecoveryError = "Saved pairing data could not be read. Device identity was not changed."
                    self.lastDeliveryState = "Saved pairing data could not be read. Device identity was not changed."
                }
                return
            }
            let identity: String
            do {
                // App identity uses the app's standard defaults domain.
                identity = try MacDeviceIdentity.resolve(defaults: UserDefaults.standard, hasSavedPairings: !devices.isEmpty)
            } catch {
                NSLog("Plink startup device identity recovery failed: \(error)")
                await MainActor.run {
                    self.pairingRecoveryError = "Device identity could not be restored. Existing pairing data was preserved."
                    self.lastDeliveryState = "Device identity could not be restored. Existing pairing data was preserved."
                }
                return
            }
            await MainActor.run {
                self.localMacDeviceId = identity
                self.pairingRecoveryError = nil
            }
            let selected: PairedDevice?
            do { selected = try finalization.selectedDevice(localDeviceID: identity) }
            catch {
                NSLog("Plink startup selected device read failed: \(error.localizedDescription)")
                await MainActor.run {
                    self.pairingRecoveryError = "Saved phone selection could not be read. Existing pairing records were preserved."
                    self.lastDeliveryState = "Saved phone selection could not be read. Existing pairing records were preserved."
                }
                return
            }
            NSLog("Plink startup pairing recovery ready")
            guard let device = selected else {
                await MainActor.run { self.pairingRecoveryComplete = true }
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
                await MainActor.run {
                    self.pairingRecoveryError = "Saved pairing key could not be read. Existing pairing records were preserved."
                }
                return
            }
            guard let sessionKey = storedSessionKey else {
                await MainActor.run {
                    self.pairingRecoveryError = "Saved pairing key is unavailable. Unlock your keychain and restart Plink."
                }
                return
            }
            await self.applyRestoredPairing(device: device, sessionKey: sessionKey,
                                            expectedPairingAttempt: attempt)
            await MainActor.run {
                self.pairingRecoveryComplete = true
                self.schedulePendingAutomaticRecovery()
            }
        }
    }

    private func applyRestoredPairing(
        device: PairedDevice,
        sessionKey: Data,
        expectedPairingAttempt: UUID
    ) async {
        guard pairingAttempt == expectedPairingAttempt, pendingManualOffer == nil else { return }
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
        guard let lifecycleToken = await preparePairLifetimeReplacement() else { return }
        guard pairingAttempt == expectedPairingAttempt, pendingManualOffer == nil else { return }
        activePairing = (device, sessionKey)
        pairedPhoneName = device.name
        calling.configurePairedPhone(peerID: device.id)
        stopPairingAdvertiser()
        stopPairingConfirmationReceiver()
        guard startPairLifetime(device: device, sessionKey: sessionKey,
                                lifecycleToken: lifecycleToken) else { return }
        scheduleAutomaticReconnect(device: device, sessionKey: sessionKey)
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

    private func localMacEndpoint() -> String {
        let address = Host.current().addresses.first {
            $0.contains(".") && !$0.hasPrefix("127.") && !$0.hasPrefix("169.254.")
        } ?? "127.0.0.1"
        return "\(address):\(receiverPort)"
    }

    func handleInbound(_ result: Result<PlinkEnvelope, Error>) {
        switch result {
        case .success(let envelope) where ScreenPreviewPayloadPolicy.eventTypes.contains(envelope.type):
            return
        case .failure(let error) where error is AuthenticatedScreenProtocolRejection:
            return
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
            let result = clipboard.receive(text)
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

struct BluetoothCallingView: View {
    @ObservedObject var controller: BluetoothCallController
    var phoneName: String?
    var body: some View {
        GroupBox("Cellular calls") {
            VStack(alignment: .leading, spacing: 10) {
                Text(controller.status).textSelection(.enabled)
                if controller.bluetoothPaired {
                    Label { Text("Bluetooth paired") } icon: { LucideIcon(name: .bluetooth) }
                }
                if controller.busy { ProgressView("Connecting calls…") }
                if controller.serviceConnected {
                    Label {
                        Text("Calls connected")
                    } icon: {
                        LucideIcon(name: .circleCheck)
                    }
                    .foregroundStyle(.green)
                    Button("Disconnect Calls") { controller.disconnect() }
                        .disabled(controller.busy || controller.blocked)
                } else if let phoneName {
                    Text("Calls disconnected").foregroundStyle(.secondary)
                    Button(controller.bluetoothPaired ? "Reconnect Calls" : "Connect Calls") { controller.beginSetup(phoneName: phoneName) }
                        .buttonStyle(.borderedProminent).disabled(controller.busy || controller.blocked)
                } else {
                    Text("Pair your phone to set up calls.").foregroundStyle(.secondary)
                }
                if controller.serviceConnected, let context = controller.call.context {
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
                         ? "Bluetooth audio is connected."
                         : "Choose where you want call audio to play.")
                    .font(.caption).foregroundStyle(.secondary)
                }
                Text("Calls use Bluetooth. Allow microphone access when you choose Mac audio.")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }
    private func callButton(_ title: String, _ action: MacCallAction, _ context: MacCallContext) -> some View {
        Button(title) { controller.perform(action, context: context) }
            .disabled(!controller.serviceConnected || controller.busy || controller.blocked || !controller.call.permits(action, context: context))
    }
}

struct ContinuityPanel: View {
    @ObservedObject var appDelegate: AppDelegate
    var body: some View {
        GroupBox("Phone continuity") {
            VStack(alignment: .leading, spacing: 12) {
                TimelineView(.periodic(from: .now, by: 10)) { timeline in
                    if let battery = appDelegate.deviceStatus {
                        Label {
                            Text("\(battery.batteryLevel)%\(battery.charging ? " · Charging" : "") · \(battery.network)")
                        } icon: {
                            LucideIcon(name: battery.charging ? .batteryCharging : .battery)
                        }
                        Text("Last received \(battery.receivedAt.formatted(date: .omitted, time: .shortened))\(timeline.date.timeIntervalSince(battery.receivedAt) > 120 ? " · May be stale" : "")")
                            .font(.caption).foregroundStyle(.secondary)
                    } else { Text("Battery status has not arrived.").foregroundStyle(.secondary) }
                    if let media = appDelegate.mediaState {
                        if appDelegate.mediaSessions.count > 1 {
                            Picker("Media source", selection: Binding(get: { media.sessionID }, set: { appDelegate.selectMediaSession($0) })) {
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
                    } else { Text("No phone media is playing.").foregroundStyle(.secondary) }
                }
                Divider()
                HStack {
                    TextField("https://example.com", text: $appDelegate.sharingURL).textFieldStyle(.roundedBorder)
                    Button("Open on Phone") { appDelegate.sendURL() }.disabled(appDelegate.pairedPeerID == nil)
                }
                if appDelegate.commandStatus != "No command pending" {
                    Text(appDelegate.commandStatus).font(.caption).textSelection(.enabled)
                }
                if appDelegate.lastReply != "None" {
                    Text(appDelegate.lastReply).font(.caption)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
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
