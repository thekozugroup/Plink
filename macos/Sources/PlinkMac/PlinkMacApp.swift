import AppKit
import CoreGraphics
import CryptoKit
import Network
import OSLog
import PlinkCore
import Security
import SwiftUI
import UserNotifications

private struct ReconnectPathSignature: Equatable, Sendable {
    let status: String
    let interfaces: [String]
    let supportsIPv4: Bool
    let localInterfaces: Set<ReconnectInterfaceSnapshot>
}

struct StartupRecoveryState: Sendable {
    enum Failure: Equatable, Sendable {
        case rollback, metadata, identity, selection, missingKey, invalidKey
        case accessCancelled, accessDenied, accessUnavailable, keyUnreadable, listener

        var message: String {
            switch self {
            case .rollback: return "Plink couldn’t restore your saved connection. Quit and reopen Plink to try again."
            case .metadata: return "Plink couldn’t restore your saved connection."
            case .identity: return "Plink couldn’t restore your saved connection."
            case .selection: return "Plink couldn’t restore your saved connection."
            case .missingKey: return "Part of your saved connection is missing."
            case .invalidKey: return "Plink couldn’t restore your saved connection."
            case .accessCancelled: return "Access to your saved connection was cancelled. Quit and reopen Plink to try again."
            case .accessDenied: return "Plink wasn’t allowed to access your saved connection. Quit and reopen Plink to try again."
            case .accessUnavailable: return "Access to your saved connection is unavailable. If macOS asks for permission, review the request. Quit and reopen Plink to try again."
            case .keyUnreadable: return "Plink couldn’t restore your saved connection."
            case .listener: return "Plink couldn’t start the phone connection. Quit and reopen Plink to try again."
            }
        }
    }

    enum Phase: Equatable, Sendable {
        case restoring, keyAccess, restoringConnection, unpaired, needsPairing, ready
        case failed(Failure)
    }

    private(set) var phase: Phase = .restoring
    private(set) var isDelayed = false
    var isRestoring: Bool {
        switch phase {
        case .restoring, .keyAccess, .restoringConnection: return true
        default: return false
        }
    }
    var showsProgress: Bool { isRestoring && !isDelayed }
    mutating func markDelayed() {
        if isRestoring { isDelayed = true }
    }
    mutating func clearDelayed() { isDelayed = false }
    var complete: Bool {
        switch phase {
        case .unpaired, .needsPairing, .ready: return true
        default: return false
        }
    }
    var error: String? {
        if case .failed(let failure) = phase { return failure.message }
        return nil
    }
    var detail: String {
        if isDelayed {
            return "Restoring your saved connection is taking longer than expected. Plink is still trying. You can wait, or quit and reopen Plink."
        }
        switch phase {
        case .restoring: return "Restoring your saved connection…"
        case .keyAccess: return "Checking your saved connection. If macOS asks for permission, review the request."
        case .restoringConnection: return "Restoring your saved connection…"
        case .unpaired: return "Pair your phone to get started."
        case .needsPairing: return "Pair your phone again to choose it."
        case .ready: return "Your phone is paired."
        case .failed(let failure): return failure.message
        }
    }
    var menuStatus: String {
        if isDelayed { return "Still restoring your saved connection" }
        switch phase {
        case .restoring, .keyAccess, .restoringConnection: return "Restoring your saved connection…"
        case .failed: return "Saved connection needs attention"
        case .unpaired: return "No phone paired"
        case .needsPairing: return "Choose your phone again"
        case .ready: return "Your phone is paired."
        }
    }

    @discardableResult
    mutating func publish(_ phase: Phase, expectedAttempt: UUID, currentAttempt: UUID, terminating: Bool) -> Bool {
        guard expectedAttempt == currentAttempt, !terminating else { return false }
        self.phase = phase
        if !isRestoring { clearDelayed() }
        return true
    }

    static func keyFailure(_ key: Data?) -> Failure? {
        guard let key else { return .missingKey }
        return key.count == 32 ? nil : .invalidKey
    }

    static func keychainFailure(_ error: Error) -> Failure {
        guard let error = error as? KeychainSecretStoreError,
              case .status(let status) = error else { return .keyUnreadable }
        switch status {
        case errSecUserCanceled: return .accessCancelled
        case errSecAuthFailed: return .accessDenied
        case errSecInteractionNotAllowed, errSecNotAvailable: return .accessUnavailable
        default: return .keyUnreadable
        }
    }
}

/// Owns the existing startup worker until it actually returns; the timer is presentation only.
@MainActor
final class StartupRecoveryOperation {
    private var operationID: UUID?
    private(set) var watchdogTask: Task<Void, Never>?
    private let sleep: @Sendable (ContinuousClock.Instant) async throws -> Void
    var isRunning: Bool { operationID != nil }

    init(sleep: @escaping @Sendable (ContinuousClock.Instant) async throws -> Void = {
        try await ContinuousClock().sleep(until: $0)
    }) { self.sleep = sleep }

    @discardableResult
    func start(isCurrent: @escaping @MainActor () -> Bool,
               onSlow: @escaping @MainActor () -> Void,
               onFinish: @escaping @MainActor () -> Void,
               work: @escaping @Sendable () async -> Void) -> Task<Void, Never>? {
        guard operationID == nil, isCurrent() else { return nil }
        let id = UUID()
        operationID = id
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        watchdogTask = Task {
            do { try await sleep(deadline) } catch { return }
            guard !Task.isCancelled, operationID == id, isCurrent() else { return }
            onSlow()
        }
        return Task.detached {
            await work()
            await self.finished(id: id, isCurrent: isCurrent, onFinish: onFinish)
        }
    }

    func cancelWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = nil
    }

    private func finished(id: UUID, isCurrent: @MainActor () -> Bool, onFinish: @MainActor () -> Void) {
        guard operationID == id else { return }
        cancelWatchdog()
        operationID = nil
        if isCurrent() { onFinish() }
    }
}

/// The app's accepted handoff: actor-atomic checks/retirement, then owned cleanup.
@MainActor
final class ConditionalReconnectHandoff {
    let admission: ConditionalReconnectAdmission
    let authority: ReconnectCommitAuthority
    let deadline: ContinuousClock.Instant
    private let now: () -> ContinuousClock.Instant
    private let isCurrent: () -> Bool
    private let retire: () -> Void
    private let cleanup: () async -> Void
    private var cleaned = false

    init(admission: ConditionalReconnectAdmission, authority: ReconnectCommitAuthority,
         deadline: ContinuousClock.Instant, now: @escaping () -> ContinuousClock.Instant = { .now },
         isCurrent: @escaping () -> Bool, retire: @escaping () -> Void, cleanup: @escaping () async -> Void) {
        self.admission = admission
        self.authority = authority
        self.deadline = deadline
        self.now = now
        self.isCurrent = isCurrent
        self.retire = retire
        self.cleanup = cleanup
    }

    func requireCurrent() throws {
        try ReconnectRecoveryPolicy.requireCurrent(deadline: deadline, now: now(), isCurrent: isCurrent())
        try admission.requireCurrent()
    }

    func accept() async throws {
        try requireCurrent()
        try admission.retire()
        retire()
        await cleanup()
        try requireCurrent()
        cleaned = true
    }

    func publish(binding: VerifiedNetworkBinding) throws -> UUID {
        try requireCurrent()
        guard cleaned else { throw ReconnectSessionError.wrongPhase }
        return try admission.openOrdinaryAdmission(binding: binding)
    }

    func cancel() {
        authority.invalidate()
        admission.cancel()
    }
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
    private var conditionalReconnectTask: Task<Void, Never>?
    private var conditionalHandoff: ConditionalReconnectHandoff?
    private var pendingManualOffer: PairingOffer?
    private var pendingManualConfirmation: PairingConfirmation?
    private var pendingConsent: PairingConsent?
    private var consentDeadline: ContinuousClock.Instant?
    private var consentIsFresh: Bool { consentDeadline.map { ContinuousClock.now < $0 } ?? false }
    private var activePairing: (device: PairedDevice, key: Data)?
    private var priorPairing: (device: PairedDevice, key: Data)?
    @Published private(set) var pairingRecoveryComplete = false
    @Published private(set) var pairingRecoveryError: String?
    @Published private(set) var startupRecovery = StartupRecoveryState()
    private let startupOperation = StartupRecoveryOperation()
    @Published private(set) var savedPhones: [PairedDevice] = []
    @Published private(set) var selectedPhoneID: String?
    @Published private(set) var phoneManagementBusy = false
    @Published private(set) var phoneManagementStatus: String?
    private var phoneManagementID: UUID?
    private var phoneManagementAffectsCurrentPeer = false
    private var revokedPhoneSessions: Set<String> = []
    private func revocationID(_ device: PairedDevice) -> String { "\(device.id.utf8.count):\(device.id)\(device.sessionId)" }
    @Published private(set) var pairedPhoneName: String?
    @Published private(set) var isPairing = false
    @Published private(set) var pairingCompleted = false
    private lazy var pairingFinalization = MacPairingFinalization(devices: pairingStore, secrets: pairingSecretStore)
    @Published private(set) var pairingInFlight = false
    private var pairingAttempt = UUID() {
        didSet {
            startupOperation.cancelWatchdog()
            startupRecovery.clearDelayed()
        }
    }
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
    private var terminationPending = false {
        didSet {
            if terminationPending { startupOperation.cancelWatchdog() }
        }
    }
    private var terminationReplied = false
    private var terminationWatchdog: Task<Void, Never>?
    private let reconnectPathMonitor = NWPathMonitor()
    private let reconnectPathQueue = DispatchQueue(label: "com.thekozugroup.plink.reconnect-path")
    private var reconnectPathSignature: ReconnectPathSignature?
    private let observationLog = Logger(subsystem: "com.thekozugroup.plink.mac", category: "reconnect-observation")

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
        NSApplication.shared.setActivationPolicy(.accessory)
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
        notificationBridge.notificationActionsAllowed = { [weak self] generation in
            guard let self else { return false }
            return self.connectionGeneration == generation && self.activeTransport != nil &&
                self.callNotificationEnvironmentEligible
        }
        notificationBridge.onActionInfo = { [weak self] message in self?.commandStatus = message }
        notificationBridge.onOpenNotification = { [weak self] in self?.showDashboardWindow() }
        notificationBridge.onNotificationAction = { [weak self] envelope, generation in
            guard let self, self.connectionGeneration == generation,
                  self.pairedPeerID == envelope.targetDeviceId, let transport = self.activeTransport,
                  self.callNotificationEnvironmentEligible else { return }
            Task { @MainActor [weak self] in
                guard let self, self.connectionGeneration == generation,
                      self.pairedPeerID == envelope.targetDeviceId, self.callNotificationEnvironmentEligible else { return }
                do { try await transport.send(envelope) }
                catch { self.notificationBridge.actionTransportFailed(envelope.id, generation: generation) }
            }
        }
        notificationBridge.callActionsAllowed = { [weak self] in
            guard let self else { return false }
            return self.callNotificationEnvironmentEligible && self.ownsSelectedCallPeer && self.calling.serviceConnected &&
                !self.calling.busy && !self.calling.blocked
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
        calling.onCallChanged = { [weak self] _ in
            self?.refreshCallNotifications()
        }
        refreshCallNotifications()
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
        restoreSavedPairingAsync()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationReplied else { return .terminateNow }
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        refreshCallNotifications()
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
        phoneManagementID = nil
        notificationBridge.updateCall(calling.call, presentNotification: false)
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
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 820),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.center()
            window.title = "Plink"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.backgroundColor = .clear
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
        let log = Logger(subsystem: "com.thekozugroup.plink.mac", category: "bluetooth-calling")
        log.notice("calls.setup.app_delegate.enter")
        guard !phoneManagementBusy else { log.notice("calls.setup.app_delegate.rejected.management_busy"); return }
        guard !startupOperation.isRunning else { log.notice("calls.setup.app_delegate.rejected.startup_running"); return }
        guard !terminationPending else { log.notice("calls.setup.app_delegate.rejected.terminating"); return }
        guard let pairing = activePairing else { log.notice("calls.setup.app_delegate.rejected.no_active_pairing"); return }
        guard let pairedPhoneName else { log.notice("calls.setup.app_delegate.rejected.no_phone_name"); return }
        let selected: PairedDevice?
        do { selected = try pairingFinalization.selectedDevice(localDeviceID: localMacDeviceId) }
        catch { log.notice("calls.setup.app_delegate.rejected.selection_read_failed"); return }
        guard let selected else { log.notice("calls.setup.app_delegate.rejected.no_selected_device"); return }
        guard selected.id == pairing.device.id else { log.notice("calls.setup.app_delegate.rejected.peer_mismatch"); return }
        guard selected.sessionId == pairing.device.sessionId else { log.notice("calls.setup.app_delegate.rejected.session_mismatch"); return }
        log.notice("calls.setup.app_delegate.accepted")
        calling.cancelInitialSetup()
        calling.beginSetup(phoneName: pairedPhoneName)
    }

    private var callNotificationEnvironmentEligible: Bool {
        guard !terminationPending, !(phoneManagementBusy && phoneManagementAffectsCurrentPeer),
              !isPairing, !pairingInFlight,
              activePairing != nil,
              reconnectSystemAwake, reconnectScreenAwake, reconnectSessionActive, reconnectSessionUnlocked,
              ClipboardSyncController.systemIsUnlocked(),
              (CGSessionCopyCurrentDictionary() as? [String: Any])?[kCGSessionOnConsoleKey as String] as? Bool == true else { return false }
        return true
    }

    private var ownsSelectedCallPeer: Bool {
        activePairing.map { calling.ownsPeer($0.device.id) } ?? false
    }

    private func refreshCallNotifications() {
        // An unavailable HFP worker must not hide authenticated Wi-Fi call notices.
        // Retain an owned call context for dedup even during pending/uncertain phases.
        notificationBridge.updateCall(ownsSelectedCallPeer ? calling.call : MacCallSession(),
            presentNotification: callNotificationEnvironmentEligible,
            hfpControlsAvailable: ownsSelectedCallPeer && calling.serviceConnected && !calling.blocked,
            audioUnavailableReason: calling.computerAudioUnavailableReason)
    }

    func refreshSavedPhones() {
        guard !startupOperation.isRunning, !phoneManagementBusy else { return }
        do {
            let pending = try pairingFinalization.pendingRemovals()
            let stored = try pairingStore.all()
            var revoked: Set<String> = []
            for device in stored + pending where try pairingFinalization.isRevoked(device) {
                revoked.insert(revocationID(device))
            }
            revokedPhoneSessions = revoked
            savedPhones = (stored.filter { !revoked.contains(revocationID($0)) } + pending.filter { old in
                !stored.contains(where: { $0.id == old.id && $0.sessionId != old.sessionId })
            }).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            selectedPhoneID = try pairingFinalization.selectedDevice(localDeviceID: localMacDeviceId)?.id
        } catch { phoneManagementStatus = "Saved phones could not be read. Restart Plink and try again." }
    }

    private var phoneManagementUnavailableReason: String? {
        if terminationPending { return "Plink is closing." }
        if startupOperation.isRunning || !pairingRecoveryComplete { return "Wait for saved connection recovery." }
        if phoneManagementBusy || pairingInFlight || pendingManualOffer != nil || isPairing {
            return "Finish the current setup first."
        }
        return nil
    }

    func savedPhoneSelectionUnavailableReason(_ id: String) -> String? {
        if let reason = phoneManagementUnavailableReason { return reason }
        guard let device = savedPhones.first(where: { $0.id == id }) else { return "This phone is no longer saved." }
        if revokedPhoneSessions.contains(revocationID(device)) { return "This connection was removed. Finish its cleanup first." }
        if !device.trusted || device.securityVersion != 2 { return "Pair this phone again." }
        return calling.managementUnavailableReason
    }

    func savedPhoneRemovalUnavailableReason(_ id: String) -> String? {
        if let reason = phoneManagementUnavailableReason { return reason }
        guard savedPhones.contains(where: { $0.id == id }) else { return "This phone is no longer saved." }
        if activePairing?.device.id == id || selectedPhoneID == id || calling.ownsPeer(id) {
            return calling.managementUnavailableReason
        }
        return nil
    }

    private func managementIsCurrent(_ id: UUID) -> Bool {
        phoneManagementID == id && !terminationPending
    }

    private func finishPhoneManagement(_ id: UUID) {
        guard phoneManagementID == id else { return }
        phoneManagementID = nil
        phoneManagementBusy = false
        phoneManagementAffectsCurrentPeer = false
        refreshSavedPhones()
        refreshCallNotifications()
        schedulePendingAutomaticRecovery()
    }

    private func retirePhoneForManagement(_ id: UUID) async -> Bool {
        calling.cancelInitialSetup()
        notificationBridge.updateCall(calling.call, presentNotification: false)
        pairingAttempt = UUID()
        connectionGeneration = UUID()
        pairedPeerID = nil
        commands.removeAll()
        notificationBridge.clearContexts()
        conditionalHandoff?.cancel()
        conditionalReconnectTask?.cancel()
        guard await preparePairLifetimeReplacement() != nil, managementIsCurrent(id) else { return false }
        stopPairLifetime()
        guard await calling.retireConfiguredPeer(), managementIsCurrent(id) else { return false }
        activePairing = nil; priorPairing = nil; pairedPhoneName = nil
        deviceStatus = nil; mediaState = nil; mediaSessions.removeAll(); lastPeerActivity = nil
        return true
    }

    func selectSavedPhone(_ id: String) {
        if let reason = savedPhoneSelectionUnavailableReason(id) { phoneManagementStatus = reason; return }
        guard let device = savedPhones.first(where: { $0.id == id }) else { return }
        let operation = UUID(), finalization = pairingFinalization, localID = localMacDeviceId
        phoneManagementID = operation; phoneManagementBusy = true
        phoneManagementAffectsCurrentPeer = true
        phoneManagementStatus = "Selecting phone…"
        Task {
            defer { finishPhoneManagement(operation) }
            do {
                let key = try await Task.detached { try finalization.loadSelection(device, localDeviceID: localID) }.value
                guard managementIsCurrent(operation), calling.managementUnavailableReason == nil,
                      try pairingStore.all().contains(device), try !finalization.isRevoked(device) else { throw CancellationError() }
                guard await retirePhoneForManagement(operation) else { throw CancellationError() }
                try finalization.select(device, localDeviceID: localID)
                recoveryPolicy.resumeByUser()
                let attempt = pairingAttempt
                let phase = await applyRestoredPairing(device: device, sessionKey: key, expectedPairingAttempt: attempt)
                guard managementIsCurrent(operation) else { return }
                phoneManagementStatus = phase == .ready ? "Selected \(device.name)." : "Phone selected. Connect again to continue."
            } catch { if managementIsCurrent(operation) { phoneManagementStatus = "Could not finish selecting this phone. Check the selected phone and try Connect again." } }
        }
    }

    func unpairSavedPhone(_ id: String) {
        if let reason = savedPhoneRemovalUnavailableReason(id) { phoneManagementStatus = reason; return }
        guard let device = savedPhones.first(where: { $0.id == id }) else { return }
        let operation = UUID(), finalization = pairingFinalization, localID = localMacDeviceId
        let association = calling.association(peerID: id)
        let ownsRuntime = activePairing?.device.id == id || selectedPhoneID == id || calling.ownsPeer(id)
        phoneManagementID = operation; phoneManagementBusy = true
        phoneManagementAffectsCurrentPeer = ownsRuntime
        phoneManagementStatus = "Removing this Mac connection…"
        Task {
            defer { finishPhoneManagement(operation) }
            do {
                if ownsRuntime, !(await retirePhoneForManagement(operation)) { throw CancellationError() }
                guard managementIsCurrent(operation) else { return }
                try finalization.revoke(device)
                try finalization.clearSelectionForRemoval(device)
                if try finalization.needsExternalCleanup(device) {
                    let secrets = pairingSecretStore, endpoints = reconnectEndpointStore
                    let endpointRetained = try await Task.detached {
                        try finalization.requireRemovalCurrent(device)
                        guard let key = try secrets.load(sessionId: device.sessionId) else { return true }
                        guard key.count == 32 else { throw MacPairingFinalization.Failure.keyConflict }
                        try endpoints.remove(localID: localID, peerID: device.id, sessionKey: key)
                        return false
                    }.value
                    guard managementIsCurrent(operation) else { return }
                    try finalization.requireRemovalCurrent(device)
                    guard calling.removeAssociation(peerID: id, expectedAddress: association) else {
                        throw MacPairingFinalization.Failure.staleRecord
                    }
                    try finalization.markExternalCleanupComplete(device, endpointRetained: endpointRetained)
                }
                try await Task.detached { try finalization.finishRemoval(device) }.value
                guard managementIsCurrent(operation) else { return }
                phoneManagementStatus = try finalization.retainsEndpoint(device)
                    ? "Connection removed. An unused connection record remains; Bluetooth pairing was kept."
                    : "Removed this Mac connection. Bluetooth pairing was kept."
            } catch {
                if managementIsCurrent(operation) {
                    phoneManagementStatus = (try? finalization.isRevoked(device)) == true
                        ? "Connection revoked; cleanup is pending. Choose Unpair again to retry."
                        : "Could not remove this connection. Try again."
                }
            }
        }
    }

    func disconnectSelectedPhone() {
        guard phoneManagementUnavailableReason == nil, calling.managementUnavailableReason == nil else { return }
        let operation = UUID()
        phoneManagementID = operation; phoneManagementBusy = true
        phoneManagementAffectsCurrentPeer = true
        recoveryPolicy.cancelByUser()
        Task {
            defer { finishPhoneManagement(operation) }
            let pairing = activePairing
            if await retirePhoneForManagement(operation), managementIsCurrent(operation) {
                // Retain saved selection; explicit Connect can prepare a fresh listener on this key.
                if let pairing {
                    activePairing = pairing; pairedPhoneName = pairing.device.name
                    calling.configurePairedPhone(peerID: pairing.device.id)
                    _ = startPairLifetime(device: pairing.device, sessionKey: pairing.key, lifecycleToken: reconnectAttempt)
                }
                reconnect.setFailed("Disconnected. Choose Connect when you are ready.")
                phoneManagementStatus = "Disconnected."
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !terminationPending else { return }
        notificationBridge.refreshAuthorization()
        refreshCallNotifications()
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
                    self.refreshCallNotifications()
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
                    self.refreshCallNotifications()
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
                        self.refreshCallNotifications()
                        self.invalidateReconnectForEnvironmentChange("Reconnect is required after the Mac locks.")
                    } else {
                        self.reconnectSessionUnlocked = true
                        self.refreshCallNotifications()
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
                    self.refreshCallNotifications()
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
        reconnect.stopObservingSelectedPeer()
        cancelConditionalReconnect()
        recoveryPolicy.invalidate()
    }

    private func cancelConditionalReconnect() {
        conditionalReconnectTask?.cancel()
        conditionalHandoff?.cancel()
        conditionalReconnectTask = nil
        conditionalHandoff = nil
    }

    private func schedulePendingAutomaticRecovery() {
        refreshSelectedPeerObservation()
        guard recoveryPolicy.pending,
              pairingRecoveryComplete, !terminationPending, !isPairing, !pairingInFlight,
              reconnectEnvironmentEligible, let lifetime = pairLifetime, lifetime.isCurrent,
              let pairing = activePairing, pairing.device.id == lifetime.peerID,
              pairing.device.sessionId == lifetime.sessionID, reconnectListener != nil,
              reconnectAuthority == nil, conditionalReconnectTask == nil,
              pairedPeerID == nil, lifetime.ordinaryAdmission() == nil else { return }
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

    // Tests inject only the entry action/clock; production and tests use this same dispatch gate.
    static func conditionalReturnHandler(isCurrent: @escaping () -> Bool,
        now: @escaping () -> ContinuousClock.Instant = { .now },
        start: @escaping (ReconnectCandidate, ContinuousClock.Instant) -> Bool
    ) -> (ReconnectCandidate, ContinuousClock.Instant) -> Bool {
        { candidate, deadline in
            guard !Task.isCancelled, now() < deadline, isCurrent() else { return false }
            return start(candidate, deadline)
        }
    }

    private func refreshSelectedPeerObservation() {
        guard pairingRecoveryComplete else {
            observationLog.notice("observer.refresh.blocked.startup"); reconnect.stopObservingSelectedPeer(); return
        }
        guard !recoveryPolicy.suppressed else {
            observationLog.notice("observer.refresh.blocked.cancel"); reconnect.stopObservingSelectedPeer(); return
        }
        guard !terminationPending else {
            observationLog.notice("observer.refresh.blocked.termination"); reconnect.stopObservingSelectedPeer(); return
        }
        guard !isPairing, !pairingInFlight else {
            observationLog.notice("observer.refresh.blocked.pairing"); reconnect.stopObservingSelectedPeer(); return
        }
        guard reconnectEnvironmentEligible else {
            observationLog.notice("observer.refresh.blocked.environment"); reconnect.stopObservingSelectedPeer(); return
        }
        guard reconnectTask == nil, reconnectAuthority == nil, conditionalReconnectTask == nil else {
            observationLog.notice("observer.refresh.blocked.busy"); reconnect.stopObservingSelectedPeer(); return
        }
        guard retiringTransport == nil else {
            observationLog.notice("observer.refresh.blocked.cleanup"); reconnect.stopObservingSelectedPeer(); return
        }
        guard let lifetime = pairLifetime, lifetime.isCurrent else {
            observationLog.notice("observer.refresh.blocked.lifetime"); reconnect.stopObservingSelectedPeer(); return
        }
        guard let listener = reconnectListener else {
            observationLog.notice("observer.refresh.blocked.listener"); reconnect.stopObservingSelectedPeer(); return
        }
        guard let pairing = activePairing else {
            observationLog.notice("observer.refresh.blocked.pair_missing"); reconnect.stopObservingSelectedPeer(); return
        }
        guard pairing.device.id == lifetime.peerID, pairing.device.sessionId == lifetime.sessionID else {
            observationLog.notice("observer.refresh.blocked.pair_mismatch"); reconnect.stopObservingSelectedPeer(); return
        }
        let epoch = recoveryPolicy.token
        let pairingToken = pairingAttempt
        let attempt = reconnectAttempt
        let generation = connectionGeneration
        let path = reconnectPathSignature
        let current: () -> Bool = { [weak self, weak lifetime] in
            guard let self, let lifetime else { return false }
            return self.pairingRecoveryComplete && !self.recoveryPolicy.suppressed &&
                !self.terminationPending && !self.isPairing && !self.pairingInFlight &&
                self.reconnectEnvironmentEligible && self.reconnectPathSignature == path &&
                self.pairLifetime === lifetime && lifetime.isCurrent && self.reconnectListener === listener &&
                self.activePairing?.device.id == lifetime.peerID &&
                self.activePairing?.device.sessionId == lifetime.sessionID &&
                self.pairingAttempt == pairingToken && self.reconnectAttempt == attempt &&
                self.recoveryPolicy.token == epoch && self.connectionGeneration == generation &&
                self.reconnectTask == nil && self.reconnectAuthority == nil &&
                self.conditionalReconnectTask == nil && self.retiringTransport == nil
        }
        let saved = try? reconnectEndpointStore.load(localID: localMacDeviceId, peerID: lifetime.peerID,
            sessionID: lifetime.sessionID, sessionKey: pairing.key)
        reconnect.observeSelectedPeer(pairKey: "\(lifetime.peerID):\(lifetime.sessionID)", epoch: epoch,
            preferredEndpoint: saved?.endpoint ?? pairing.device.endpoint, isCurrent: current,
            onReturn: Self.conditionalReturnHandler(isCurrent: current, start: { [weak self] candidate, deadline in
                self?.reconnectConditionally(candidate: candidate, deadline: deadline) != nil
            }))
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
        guard reconnectEnvironmentEligible, !(phoneManagementBusy && phoneManagementAffectsCurrentPeer), !isPairing, !pairingInFlight else {
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
        guard !terminationPending, !(phoneManagementBusy && phoneManagementAffectsCurrentPeer), !isPairing, !pairingInFlight, reconnectEnvironmentEligible else { return false }
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

    /// One selected-return candidate/Hello with the deadline captured before resolution.
    @discardableResult
    func reconnectConditionally(candidate: ReconnectCandidate, deadline: ContinuousClock.Instant) -> Task<Void, Never>? {
        guard conditionalReconnectTask == nil, reconnectTask == nil, reconnectAuthority == nil,
              retiringTransport == nil, !recoveryPolicy.suppressed,
              pairingRecoveryComplete, ContinuousClock.now < deadline,
              !terminationPending, !isPairing, !pairingInFlight, reconnectEnvironmentEligible,
              let lifetime = pairLifetime, let listener = reconnectListener,
              let pairing = activePairing, pairing.device.id == lifetime.peerID,
              pairing.device.sessionId == lifetime.sessionID else { return nil }
        let authority = ReconnectCommitAuthority(deadline: deadline)
        guard let admission = try? lifetime.beginConditionalReconnect(authority: authority) else { return nil }
        let generation = connectionGeneration
        let retiredGeneration = UUID()
        let pairingToken = pairingAttempt
        let recoveryToken = recoveryPolicy.token
        let path = reconnectPathSignature
        let ownedTransport = activeTransport
        let current: () -> Bool = { [weak self, weak lifetime] in
            guard let self, let lifetime else { return false }
            return self.pairLifetime === lifetime && self.reconnectListener === listener &&
                self.pairingAttempt == pairingToken && self.recoveryPolicy.token == recoveryToken &&
                self.pairingRecoveryComplete && !self.recoveryPolicy.suppressed && !self.terminationPending &&
                self.reconnectPathSignature == path &&
                !self.isPairing && !self.pairingInFlight && self.reconnectEnvironmentEligible &&
                self.activePairing?.device.id == pairing.device.id &&
                self.activePairing?.device.sessionId == pairing.device.sessionId &&
                (self.connectionGeneration == generation || self.connectionGeneration == retiredGeneration)
        }
        let handoff = ConditionalReconnectHandoff(admission: admission, authority: authority,
            deadline: deadline, isCurrent: current, retire: { [weak self] in
                guard let self else { return }
                self.connectionGeneration = retiredGeneration
                self.pairedPeerID = nil
                self.commands.removeAll()
                self.notificationBridge.clearContexts()
                self.deviceStatus = nil
                self.mediaState = nil
                self.mediaSessions.removeAll()
                self.lastPeerActivity = nil
                ownedTransport?.invalidate()
                self.activeTransport = nil
                self.retiringTransport = ownedTransport
                self.reconnect.setDisconnecting()
                self.observationLog.notice("Plink conditional reconnect accepted")
            }, cleanup: { [weak self] in
                // Before touching the shared file controller, recheck actor-owned state.
                if let self, current() { await self.files.suspendAndAwait() }
                await ownedTransport?.shutdown()
                if let self, self.retiringTransport === ownedTransport { self.retiringTransport = nil }
            })
        conditionalHandoff = handoff
        let task = Task { [weak self] in
            guard let self else { handoff.cancel(); return }
            defer {
                handoff.cancel()
                if self.conditionalHandoff === handoff {
                    self.conditionalHandoff = nil
                    self.conditionalReconnectTask = nil
                    self.reconnect.stopObservingSelectedPeer()
                    self.refreshSelectedPeerObservation()
                }
            }
            do {
                let result = try await ReconnectInitiator(lifetime: lifetime, listener: listener,
                    commitAuthority: authority, endpointStore: self.reconnectEndpointStore, listenerPort: self.receiverPort)
                    .attemptConditional(candidate: candidate, deadline: deadline, admission: admission,
                        authorize: { try await handoff.requireCurrent() }, accepted: { try await handoff.accept() })
                let nextGeneration = try handoff.publish(binding: result.binding)
                let sender = SerializedPlinkSender(transport: BoundSecureNetworkPlinkClient(
                    lifetime: lifetime, binding: result.binding, generation: nextGeneration))
                self.activeTransport = sender
                self.connectionGeneration = nextGeneration
                self.pairedPeerID = pairing.device.id
                self.files.bind(localID: self.localMacDeviceId, peerID: pairing.device.id, transport: sender)
                self.reconnect.setConnected()
                self.lastDeliveryState = "Connected to \(pairing.device.name) on the local network."
                self.observationLog.notice("Plink conditional reconnect completed")
            } catch {
                // A rejected preflight must not clear a healthy connection or publish an error over it.
                if self.conditionalHandoff === handoff, current(), self.connectionGeneration == retiredGeneration {
                    self.reconnect.setFailed("The phone could not reconnect. Try Reconnect again.")
                }
                NSLog("Plink conditional reconnect ended without publication")
            }
        }
        conditionalReconnectTask = task
        return task
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
                self.refreshSelectedPeerObservation()
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
            if self.reconnectAttempt == token {
                self.reconnectTask = nil
                self.refreshSelectedPeerObservation()
            }
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
                refreshSelectedPeerObservation()
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
        guard pairingRecoveryComplete, !startupOperation.isRunning, !phoneManagementBusy else { pairingStatusText = "Waiting for saved pairing recovery."; return }
        calling.cancelInitialSetup()
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
        guard !phoneManagementBusy, !startupOperation.isRunning, !pairingInFlight, canConfirmPairing,
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
            let setupAttempt = pairingAttempt
            let setupLifetime = pairLifetime
            let setupIsCurrent: () -> Bool = { [weak self, weak setupLifetime] in
                guard let self, let setupLifetime else { return false }
                guard !self.terminationPending, !self.phoneManagementBusy, !self.startupOperation.isRunning,
                      !self.isPairing, !self.pairingInFlight, self.pairingCompleted,
                      self.pairingAttempt == setupAttempt, self.pairLifetime === setupLifetime,
                      setupLifetime.isCurrent, self.activePairing?.device.id == device.id,
                      self.activePairing?.device.sessionId == device.sessionId,
                      let selected = try? self.pairingFinalization.selectedDevice(localDeviceID: self.localMacDeviceId)
                else { return false }
                return selected.id == device.id && selected.sessionId == device.sessionId
            }
            BluetoothCallSetup.afterPairingCommit(isCurrent: setupIsCurrent, setup: { [weak self] in
                self?.calling.requestInitialSetup(id: setupAttempt, peerID: device.id,
                    phoneName: device.name, isCurrent: setupIsCurrent)
            })
            refreshSavedPhones()
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
        calling.cancelInitialSetup()
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
        calling.cancelInitialSetup()
        notificationBridge.updateCall(calling.call, presentNotification: false)
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

    @discardableResult
    private func publishStartupRecovery(_ phase: StartupRecoveryState.Phase, attempt: UUID) -> Bool {
        let wasRestoring = startupRecovery.isRestoring
        var next = startupRecovery
        guard next.publish(phase, expectedAttempt: attempt, currentAttempt: pairingAttempt,
                           terminating: terminationPending) else { return false }
        startupRecovery = next
        if !next.isRestoring { startupOperation.cancelWatchdog() }
        pairingRecoveryComplete = startupRecovery.complete
        pairingRecoveryError = startupRecovery.error
        // A restored pairing may already be reconnecting; keep its connection feedback.
        if phase != .ready { lastDeliveryState = startupRecovery.detail }
        if wasRestoring && (phase == .unpaired || phase == .needsPairing) { showDashboardWindow() }
        return true
    }

    private func restoreSavedPairingAsync() {
        let attempt = pairingAttempt
        startupOperation.start(isCurrent: { [weak self] in
            guard let self else { return false }
            return self.pairingAttempt == attempt && !self.terminationPending
        }, onSlow: { [weak self] in
            guard let self else { return }
            self.startupRecovery.markDelayed()
            if self.startupRecovery.isDelayed { self.lastDeliveryState = self.startupRecovery.detail }
        }, onFinish: { [weak self] in
            self?.startupRecovery.clearDelayed()
            self?.refreshSavedPhones()
        }, work: { [domainName = "com.thekozugroup.plink.mac"] in
            guard await self.publishStartupRecovery(.restoring, attempt: attempt) else { return }
            NSLog("Plink startup pairing recovery started")
            let store = UserDefaultsPairingStore(domainName: domainName)
            let secretStore = KeychainPairingSecretStore()
            let finalization = MacPairingFinalization(devices: store, secrets: secretStore)
            do {
                try finalization.rollback()
            } catch {
                NSLog("Plink startup pairing rollback failed: \(error.localizedDescription)")
                await self.publishStartupRecovery(.failed(.rollback), attempt: attempt)
                return
            }
            let devices: [PairedDevice]
            do {
                devices = try store.all()
            } catch {
                NSLog("Plink startup pairing store read failed: \(error.localizedDescription)")
                await self.publishStartupRecovery(.failed(.metadata), attempt: attempt)
                return
            }
            let identity: String
            do {
                // App identity uses the app's standard defaults domain.
                identity = try MacDeviceIdentity.resolve(defaults: UserDefaults.standard, hasSavedPairings: !devices.isEmpty)
            } catch {
                NSLog("Plink startup device identity recovery failed: \(error)")
                await self.publishStartupRecovery(.failed(.identity), attempt: attempt)
                return
            }
            let identityIsCurrent = await MainActor.run {
                guard self.pairingAttempt == attempt, !self.terminationPending else { return false }
                self.localMacDeviceId = identity
                return true
            }
            guard identityIsCurrent else { return }
            let selected: PairedDevice?
            do { selected = try finalization.selectedDevice(localDeviceID: identity) }
            catch {
                NSLog("Plink startup selected device read failed: \(error.localizedDescription)")
                await self.publishStartupRecovery(.failed(.selection), attempt: attempt)
                return
            }
            guard let device = selected else {
                guard await self.publishStartupRecovery(devices.isEmpty ? .unpaired : .needsPairing,
                                                        attempt: attempt) else { return }
                NSLog("Plink startup recovery completed without an active phone selection")
                return
            }
            guard await self.publishStartupRecovery(.keyAccess, attempt: attempt) else { return }
            NSLog("Plink startup saved pairing access started")
            let storedSessionKey: Data?
            do {
                storedSessionKey = try secretStore.load(sessionId: device.sessionId)
            } catch {
                NSLog("Plink async restore failed to load session key: \(error.localizedDescription)")
                await self.publishStartupRecovery(.failed(StartupRecoveryState.keychainFailure(error)), attempt: attempt)
                return
            }
            NSLog("Plink startup saved pairing access returned")
            if let failure = StartupRecoveryState.keyFailure(storedSessionKey) {
                await self.publishStartupRecovery(.failed(failure), attempt: attempt)
                return
            }
            guard let sessionKey = storedSessionKey,
                  await self.publishStartupRecovery(.restoringConnection, attempt: attempt),
                  let outcome = await self.applyRestoredPairing(device: device, sessionKey: sessionKey,
                                                               expectedPairingAttempt: attempt) else { return }
            await MainActor.run {
                guard self.publishStartupRecovery(outcome, attempt: attempt) else { return }
                if outcome == .ready {
                    NSLog("Plink startup saved pairing restored")
                    self.refreshCallNotifications()
                    self.schedulePendingAutomaticRecovery()
                }
            }
        })
    }

    @discardableResult
    private func applyRestoredPairing(
        device: PairedDevice,
        sessionKey: Data,
        expectedPairingAttempt: UUID
    ) async -> StartupRecoveryState.Phase? {
        guard pairingAttempt == expectedPairingAttempt, !terminationPending, pendingManualOffer == nil else { return nil }
        guard device.trusted, device.securityVersion == 2 else {
            lastDeliveryState = "Pair your phone again to continue."
            return .needsPairing
        }
        let selected: PairedDevice?
        do { selected = try pairingFinalization.selectedDevice(localDeviceID: localMacDeviceId) }
        catch {
            lastDeliveryState = StartupRecoveryState.Failure.selection.message
            return .failed(.selection)
        }
        guard let selected,
              selected.id == device.id, selected.sessionId == device.sessionId else {
            lastDeliveryState = "Pair your phone again to choose it."
            return .needsPairing
        }
        guard !canConfirmPairing else { return nil }
        if let failure = StartupRecoveryState.keyFailure(sessionKey) {
            lastDeliveryState = failure.message
            return .failed(failure)
        }
        guard let lifecycleToken = await preparePairLifetimeReplacement() else { return nil }
        guard pairingAttempt == expectedPairingAttempt, !terminationPending, pendingManualOffer == nil else { return nil }
        activePairing = (device, sessionKey)
        pairedPhoneName = device.name
        calling.configurePairedPhone(peerID: device.id)
        stopPairingAdvertiser()
        stopPairingConfirmationReceiver()
        guard startPairLifetime(device: device, sessionKey: sessionKey,
                                lifecycleToken: lifecycleToken) else { return .failed(.listener) }
        scheduleAutomaticReconnect(device: device, sessionKey: sessionKey)
        return .ready
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
            if activeTransport != nil, let peer = pairedPeerID {
                notificationBridge.bindActionAdmission(localID: localMacDeviceId, peerID: peer, generation: connectionGeneration)
            }
            if notificationBridge.handleActionControl(envelope) { return }
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
                if envelope.type == .callRinging || envelope.type == .callEnded { refreshCallNotifications() }
                notificationBridge.show(envelope: envelope,
                    pairedPhoneName: activePairing?.device.id == envelope.sourceDeviceId ? pairedPhoneName : nil)
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
                if controller.call.context == nil, let reason = DashboardPresentation.callsRecoveryDetail(
                    blocked: controller.blocked, connected: controller.serviceConnected,
                    audioUnavailableReason: controller.computerAudioUnavailableReason) {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
                if controller.bluetoothPaired {
                    Label { Text("Bluetooth paired") } icon: { LucideIcon(name: .bluetooth) }
                }
                if controller.busy { ProgressView("Connecting calls…") }
                if controller.serviceConnected {
                    let showConnected = DashboardPresentation.callsShowConnected(connected: controller.serviceConnected,
                        blocked: controller.blocked, audioUnavailableReason: controller.computerAudioUnavailableReason)
                    Label {
                        Text(DashboardPresentation.callsStatus(connected: controller.serviceConnected,
                            paired: controller.bluetoothPaired, blocked: controller.blocked,
                            audioUnavailableReason: controller.computerAudioUnavailableReason))
                    } icon: {
                        LucideIcon(name: showConnected ? .circleCheck : .bluetooth)
                    }
                    .foregroundStyle(showConnected ? Color.green : Color.secondary)
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
                        callButton("Answer", .answer, context)
                        callButton("Decline", .decline, context)
                        callButton("End Call", .hangUp, context)
                    }
                    HStack {
                        callButton("Audio on Mac", .computerAudio, context)
                        callButton("Audio on Phone", .phoneAudio, context)
                        callButton(controller.call.muted ? "Unmute" : "Mute", .toggleMute, context)
                    }
                    Text(DashboardPresentation.callsRecoveryDetail(blocked: controller.blocked,
                         connected: controller.serviceConnected, audioUnavailableReason: controller.computerAudioUnavailableReason)
                         ?? (controller.call.audio == .scoConnectedUnverified
                         ? "Bluetooth audio is connected."
                         : "Choose where you want call audio to play."))
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
