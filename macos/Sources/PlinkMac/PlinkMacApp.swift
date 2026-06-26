import AppKit
import CryptoKit
import PlinkCore
import SwiftUI
import UserNotifications

@main
struct PlinkMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Plink") {
            DashboardWindow(appDelegate: appDelegate)
        }
        .defaultSize(width: 420, height: 520)

        MenuBarExtra {
            MenuBarPanel(appDelegate: appDelegate)
        } label: {
            Label("Plink", systemImage: "link.circle.fill")
        }
        .menuBarExtraStyle(.window)

        Settings {
            PairingView()
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
    @Published var lastReply: String = "None"
    @Published var lastDeliveryState: String = "Notifications pending"
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
        if restoreSavedPairing() == false {
            publishPairingOffer(prepareManualPairing())
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        allowsTermination ? .terminateNow : .terminateCancel
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

    func showPairingWindow() {
        if pairingWindow == nil {
            let offer = pendingManualOffer ?? prepareManualPairing()
            publishPairingOffer(offer)
            let offerPayload = (try? PairingPayloadCodec.encodeOffer(offer)) ?? ""
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.center()
            window.title = "Pair Pixel"
            window.contentView = NSHostingView(rootView: PairingView(onConfirm: { [weak self] in
                try? self?.confirmManualPairing()
            }, onPreviewResponse: { [weak self] payload in
                guard let self else { throw AppDeliveryError.pairingOfferUnavailable }
                return try self.previewManualResponse(payload)
            }, offerPayload: offerPayload))
            pairingWindow = window
        }
        pairingWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
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
            lastDeliveryState = "Paired with \(device.name)"
        }
    }

    @discardableResult
    private func restoreSavedPairing() -> Bool {
        if restoreDebugEnvironmentPairing() {
            stopPairingAdvertiser()
            return true
        }
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
        return true
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
    var onConfirm: () -> Void = {}
    var onPreviewResponse: (String) throws -> PairingVerificationCode = { _ in
        PairingTranscript.verificationCode(transcript: "plink-demo")
    }
    var offerPayload: String = ""
    var verificationCode: PairingVerificationCode = PairingTranscript.verificationCode(
        transcript: PairingTranscript.canonical(
            sourceDeviceId: "pixel-demo",
            targetDeviceId: "mac-demo",
            endpoint: "192.168.1.24:45731",
            nonce: "demo-nonce",
            sourcePublicKey: "pixel-demo-public-key",
            targetPublicKey: "mac-demo-public-key",
            protocolVersion: 1
        )
    )
    @State private var responsePayload = ""
    @State private var previewCode: PairingVerificationCode?
    @State private var statusText = "Copy this offer to your Pixel."

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Plink")
                .font(.largeTitle.weight(.semibold))
            Text(statusText)
                .font(.title3)
            VStack(alignment: .leading, spacing: 8) {
                Text("Mac offer")
                    .font(.headline)
                Text(offerPayload)
                    .font(.caption.monospaced())
                    .lineLimit(4)
                    .textSelection(.enabled)
                Button("Copy Offer") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(offerPayload, forType: .string)
                    statusText = "Offer copied. Paste it into Plink on your Pixel."
                }
            }
            TextField("Pixel pairing response", text: $responsePayload, axis: .vertical)
                .lineLimit(3...5)
            Button("Preview Response Code") {
                do {
                    previewCode = try onPreviewResponse(responsePayload)
                    statusText = "Confirm only if this matches your Pixel."
                } catch {
                    statusText = error.localizedDescription
                }
            }
            .disabled(responsePayload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            let code = previewCode ?? verificationCode
            Text(code.emoji.joined(separator: "  "))
                .font(.system(size: 44, weight: .bold, design: .rounded))
            Text("Code \(code.numeric)")
                .font(.title3.monospacedDigit())
            VStack(alignment: .leading, spacing: 8) {
                Label("Calls appear as Mac notifications", systemImage: "phone")
                Label("Messages can reply from notification actions", systemImage: "message")
                Label("Clipboard, files, links, battery, and media are event driven", systemImage: "bolt.horizontal")
            }
            .foregroundStyle(.secondary)
            Button("Finish Pairing") {
                onConfirm()
                statusText = "Pairing saved. Receiver is listening."
            }
            .keyboardShortcut(.defaultAction)
            .disabled(previewCode == nil)
            Spacer()
        }
        .padding(28)
        .frame(width: 520, height: 560)
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
