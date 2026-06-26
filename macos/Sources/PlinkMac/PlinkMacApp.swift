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
final class AppDelegate: NSObject, NSApplicationDelegate, @preconcurrency NetServiceDelegate, ObservableObject, @unchecked Sendable {
    let notificationBridge = NotificationBridge()
    let pairingMachine = PairingStateMachine()
    let pairingStore = UserDefaultsPairingStore(
        domainName: "com.thekozugroup.plink.mac"
    )
    let pairingSecretStore = KeychainPairingSecretStore()
    private let localMacDeviceId = "mac-demo"
    private let receiverPort: UInt16 = 45731
    private let demoPixelPrivateKey = P256.KeyAgreement.PrivateKey()
    private var activeTransport: (any PlinkTransport)?
    private var receiver: (any PlinkEventReceiver)?
    private var pendingManualOffer: PairingOffer?
    private var pendingManualConfirmation: PairingConfirmation?
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
    private var allowsTermination = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        ProcessInfo.processInfo.disableAutomaticTermination("Plink keeps the paired Pixel receiver and menu bar companion active.")
        ProcessInfo.processInfo.disableSuddenTermination()
        NSApplication.shared.setActivationPolicy(.regular)
        notificationBridge.configure()
        notificationBridge.onAuthorizationChanged = { [weak self] granted, error in
            Task { @MainActor in
                self?.lastDeliveryState = granted
                    ? "Notifications enabled"
                    : (error?.localizedDescription ?? "Notifications denied")
            }
        }
        notificationBridge.onDeliveryError = { [weak self] _, error in
            Task { @MainActor in
                self?.lastDeliveryState = error.localizedDescription
            }
        }
        notificationBridge.onTextReply = { [weak self] context, text in
            Task {
                do {
                    let reply = try ReplyRouter.makeReplyEnvelope(context: context, text: text)
                    guard let transport = await MainActor.run(body: { self?.activeTransport }) else {
                        throw AppDeliveryError.transportUnavailable
                    }
                    try await transport.send(reply)
                    await MainActor.run {
                        self?.lastReply = "Sent: \(text)"
                    }
                } catch {
                    await MainActor.run {
                        self?.lastReply = "Reply failed"
                        self?.lastDeliveryState = error.localizedDescription
                    }
                }
            }
        }
        showDashboardWindow()
        if restoreDebugEnvironmentPairing() {
            stopPairingAdvertiser()
            stopPairingConfirmationReceiver()
        } else {
            startNearbyPairing()
            restoreSavedPairingAsync()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        allowsTermination ? .terminateNow : .terminateCancel
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showDashboardWindow()
        return true
    }

    func quit() {
        allowsTermination = true
        NSApplication.shared.terminate(nil)
    }

    func simulateCall() {
        notificationBridge.showCall(caller: "Alex Morgan", handle: "+1 555 123 4567")
    }

    func simulateMessage() {
        notificationBridge.showMessage(sender: "Alex Morgan", preview: "Can you send the deck?")
    }

    func openSettings() {
        NSApplication.shared.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    func showDashboardWindow() {
        if dashboardWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 520),
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

    func startNearbyPairing() {
        receiver?.stop()
        receiver = nil
        activeTransport = nil
        let offer = pendingManualOffer ?? prepareManualPairing()
        publishPairingOffer(offer)
        startPairingConfirmationReceiver()
        pairingStatusText = "Open Plink on your Pixel. This Mac should appear automatically."
        pairingVerificationCode = nil
        pairingPeerName = "Pixel"
        canConfirmPairing = false
    }

    @discardableResult
    func prepareDemoPairing() -> PairingVerificationCode {
        let status = pairingMachine.receive(demoPairingOffer())
        if case .showingCode(_, _, _, let code) = status {
            return code
        }
        return PairingTranscript.verificationCode(transcript: "plink-demo")
    }

    func confirmDemoPairing() {
        if case .showingCode = pairingMachine.status {} else {
            _ = pairingMachine.receive(demoPairingOffer())
        }
        if case .paired(let device) = try? pairingMachine.confirm() {
            try? pairingStore.save(device)
            guard let sessionKey = pairingMachine.lastSessionKey else { return }
            let sessionKeyData = data(from: sessionKey)
            try? pairingSecretStore.save(sessionKey: sessionKeyData, sessionId: device.sessionId)
            activeTransport = makeTransport(for: device, sessionKey: sessionKeyData)
            startReceiver(sessionKey: sessionKeyData, pairedDeviceId: device.id)
        }
    }

    @discardableResult
    func prepareManualPairing() -> PairingOffer {
        let offer = pairingMachine.makeOffer(
            deviceId: localMacDeviceId,
            deviceName: Host.current().localizedName ?? "Mac",
            endpoint: localMacEndpoint()
        )
        pendingManualOffer = offer
        pendingManualConfirmation = nil
        return offer
    }

    func previewManualResponse(_ payload: String) throws -> PairingVerificationCode {
        guard let offer = pendingManualOffer else {
            throw AppDeliveryError.pairingOfferUnavailable
        }
        let confirmation = try PairingPayloadCodec.decodeConfirmation(payload)
        pendingManualConfirmation = confirmation
        return pairingMachine.verificationCode(for: offer, confirmation: confirmation)
    }

    func receiveNearbyConfirmation(_ payload: String) {
        do {
            let code = try previewManualResponse(payload)
            pairingPeerName = pendingManualConfirmation?.deviceName ?? "Pixel"
            pairingVerificationCode = code
            pairingStatusText = "\(pairingPeerName) is ready. Confirm only if the code matches on both devices."
            canConfirmPairing = true
            lastDeliveryState = "Pairing code ready"
            showPairingWindow()
        } catch {
            pairingStatusText = error.localizedDescription
            lastDeliveryState = "Pairing confirmation failed"
        }
    }

    func confirmManualPairing() throws {
        guard let offer = pendingManualOffer else {
            throw AppDeliveryError.pairingOfferUnavailable
        }
        guard let confirmation = pendingManualConfirmation else {
            throw AppDeliveryError.pairingResponseUnavailable
        }
        if case .paired(let device) = try pairingMachine.accept(confirmation, for: offer) {
            try pairingStore.save(device)
            guard let sessionKey = pairingMachine.lastSessionKey else { return }
            let sessionKeyData = data(from: sessionKey)
            try pairingSecretStore.save(sessionKey: sessionKeyData, sessionId: device.sessionId)
            activeTransport = makeTransport(for: device, sessionKey: sessionKeyData)
            startReceiver(sessionKey: sessionKeyData, pairedDeviceId: device.id)
            stopPairingAdvertiser()
            stopPairingConfirmationReceiver()
            pairingStatusText = "Paired with \(device.name)."
            canConfirmPairing = false
            lastDeliveryState = "Paired with \(device.name)"
        }
    }

    @discardableResult
    private func restoreSavedPairing() -> Bool {
        let devices: [PairedDevice]
        do {
            devices = try pairingStore.all()
        } catch {
            NSLog("Plink restore pairing failed to load devices: \(error.localizedDescription)")
            return false
        }
        guard let device = devices.first else {
            NSLog("Plink restore pairing found no saved devices")
            return false
        }
        let storedSessionKey: Data?
        do {
            storedSessionKey = try pairingSecretStore.load(sessionId: device.sessionId)
        } catch {
            NSLog("Plink restore pairing failed to load session key: \(error.localizedDescription)")
            return false
        }
        guard let sessionKey = storedSessionKey else { return false }
        NSLog("Plink restore pairing loaded \(device.id); starting receiver")
        activeTransport = makeTransport(for: device, sessionKey: sessionKey)
        startReceiver(sessionKey: sessionKey, pairedDeviceId: device.id)
        stopPairingAdvertiser()
        stopPairingConfirmationReceiver()
        return true
    }

    private func restoreSavedPairingAsync() {
        Task.detached { [domainName = "com.thekozugroup.plink.mac"] in
            let store = UserDefaultsPairingStore(domainName: domainName)
            let secretStore = KeychainPairingSecretStore()
            let devices: [PairedDevice]
            do {
                devices = try store.all()
            } catch {
                NSLog("Plink async restore failed to load devices: \(error.localizedDescription)")
                return
            }
            guard let device = devices.first else {
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
                self.applyRestoredPairing(device: device, sessionKey: sessionKey)
            }
        }
    }

    private func applyRestoredPairing(device: PairedDevice, sessionKey: Data) {
        guard canConfirmPairing == false else { return }
        activeTransport = makeTransport(for: device, sessionKey: sessionKey)
        startReceiver(sessionKey: sessionKey, pairedDeviceId: device.id)
        stopPairingAdvertiser()
        stopPairingConfirmationReceiver()
        lastDeliveryState = "Paired with \(device.name)"
    }

    private func restoreDebugEnvironmentPairing() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard
            let sessionKeyBase64 = environment["PLINK_DEBUG_SESSION_KEY_BASE64"],
            let sessionKey = Data(base64Encoded: sessionKeyBase64),
            let pairedDeviceId = environment["PLINK_DEBUG_PAIRED_DEVICE_ID"]
        else {
            return false
        }
        let device = PairedDevice(
            id: pairedDeviceId,
            name: environment["PLINK_DEBUG_PAIRED_DEVICE_NAME"] ?? "Pixel",
            platform: "android",
            endpoint: environment["PLINK_DEBUG_PAIRED_ENDPOINT"] ?? "127.0.0.1:45731",
            sessionId: environment["PLINK_DEBUG_SESSION_ID"] ?? "debug-session",
            peerPublicKey: "debug-pixel-public-key",
            localPublicKey: "debug-mac-public-key",
            trusted: true
        )
        NSLog("Plink debug restore loaded \(device.id); starting receiver")
        activeTransport = makeTransport(for: device, sessionKey: sessionKey)
        startReceiver(sessionKey: sessionKey, pairedDeviceId: device.id)
        return true
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

    private func makeTransport(for device: PairedDevice, sessionKey: Data) -> (any PlinkTransport)? {
        guard
            let separator = device.endpoint.lastIndex(of: ":"),
            let port = UInt16(device.endpoint[device.endpoint.index(after: separator)...])
        else { return nil }

        let host = String(device.endpoint[..<separator])
        return SecureNetworkPlinkClient(
            host: host,
            port: port,
            codec: EncryptedFrameCodec(sessionKey: sessionKey)
        )
    }

    private func startReceiver(sessionKey: Data, pairedDeviceId: String) {
        receiver?.stop()
        do {
            let server = FoundationSecurePlinkServer(
                port: receiverPort,
                codec: EncryptedFrameCodec(sessionKey: sessionKey),
                expectedSourceDeviceId: pairedDeviceId,
                expectedTargetDeviceId: localMacDeviceId
            )
            try server.start { [weak self] result in
                Task { @MainActor in
                    self?.handleInbound(result)
                }
            }
            receiver = server
            lastDeliveryState = "Receiver listening"
            NSLog("Plink receiver listening on \(receiverPort)")
        } catch {
            lastDeliveryState = error.localizedDescription
            NSLog("Plink receiver failed: \(error.localizedDescription)")
        }
    }

    private func localMacEndpoint() -> String {
        let address = Host.current().addresses.first {
            $0.contains(".") && !$0.hasPrefix("127.") && !$0.hasPrefix("169.254.")
        } ?? "127.0.0.1"
        return "\(address):\(receiverPort)"
    }

    private func handleInbound(_ result: Result<PlinkEnvelope, Error>) {
        switch result {
        case .success(let envelope):
            if let action = HandoffPlanner.action(for: envelope) {
                perform(action)
            }
            notificationBridge.show(envelope: envelope)
            lastDeliveryState = "Received \(envelope.type.rawValue)"
        case .failure(let error):
            lastDeliveryState = error.localizedDescription
        }
    }

    private func perform(_ action: HandoffAction) {
        switch action.kind {
        case .clipboard(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case .openURL(let url):
            NSWorkspace.shared.open(url)
        case .fileOffer:
            break
        }
    }

    private func data(from key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }

    private func demoPairingOffer() -> PairingOffer {
        PairingOffer(
            deviceId: "pixel-demo",
            deviceName: "Pixel",
            platform: "android",
            endpoint: "192.168.1.24:45731",
            nonce: "demo-nonce",
            publicKey: demoPixelPrivateKey.publicKey.derRepresentation.base64EncodedString(),
            targetDeviceId: localMacDeviceId
        )
    }
}

struct DashboardWindow: View {
    @ObservedObject var appDelegate: AppDelegate

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: "link.circle.fill")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Plink")
                        .font(.largeTitle.weight(.semibold))
                    Text("Pixel + Mac continuity")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 12) {
                StatusRow(title: "Status", value: appDelegate.lastDeliveryState, symbol: "dot.radiowaves.left.and.right")
                StatusRow(title: "Last reply", value: appDelegate.lastReply, symbol: "arrowshape.turn.up.left")
            }
            .padding(14)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))

            VStack(spacing: 12) {
                Button {
                    appDelegate.showPairingWindow()
                } label: {
                    Label("Pair Pixel", systemImage: "iphone.gen3.radiowaves.left.and.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                HStack(spacing: 12) {
                    Button {
                        appDelegate.simulateCall()
                    } label: {
                        Label("Simulate Call", systemImage: "phone")
                            .frame(maxWidth: .infinity)
                    }

                    Button {
                        appDelegate.simulateMessage()
                    } label: {
                        Label("Simulate Message", systemImage: "message")
                            .frame(maxWidth: .infinity)
                    }
                }

                HStack(spacing: 12) {
                    Button {
                        appDelegate.openSettings()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                            .frame(maxWidth: .infinity)
                    }

                    Button(role: .destructive) {
                        appDelegate.quit()
                    } label: {
                        Label("Quit", systemImage: "power")
                            .frame(maxWidth: .infinity)
                    }
                }
            }

            Spacer()
        }
        .padding(24)
        .frame(minWidth: 380, minHeight: 460)
    }
}

struct MenuBarPanel: View {
    @ObservedObject var appDelegate: AppDelegate

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "link.circle.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Plink")
                        .font(.title2.weight(.semibold))
                    Text("Pixel + Mac continuity")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 10) {
                StatusRow(title: "Status", value: appDelegate.lastDeliveryState, symbol: "dot.radiowaves.left.and.right")
                StatusRow(title: "Last reply", value: appDelegate.lastReply, symbol: "arrowshape.turn.up.left")
            }

            Divider()

            VStack(spacing: 10) {
                Button {
                    appDelegate.showPairingWindow()
                } label: {
                    Label("Pair Pixel", systemImage: "iphone.gen3.radiowaves.left.and.right")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)

                HStack(spacing: 10) {
                    Button {
                        appDelegate.simulateCall()
                    } label: {
                        Label("Call", systemImage: "phone")
                            .frame(maxWidth: .infinity)
                    }

                    Button {
                        appDelegate.simulateMessage()
                    } label: {
                        Label("Message", systemImage: "message")
                            .frame(maxWidth: .infinity)
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        appDelegate.openSettings()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                            .frame(maxWidth: .infinity)
                    }

                    Button(role: .destructive) {
                        appDelegate.quit()
                    } label: {
                        Label("Quit", systemImage: "power")
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(18)
        .frame(width: 340)
    }
}

private struct StatusRow: View {
    var title: String
    var value: String
    var symbol: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.callout)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
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
                Button("Restart Discovery") {
                    appDelegate.startNearbyPairing()
                }
                Button("Confirm Pairing") {
                    do {
                        try appDelegate.confirmManualPairing()
                    } catch {
                        appDelegate.pairingStatusText = error.localizedDescription
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
