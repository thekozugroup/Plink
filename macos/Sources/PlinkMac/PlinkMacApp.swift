import AppKit
import CryptoKit
import PlinkCore
import SwiftUI
import UserNotifications

@main
struct PlinkMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Plink", systemImage: "link") {
            Label("Pixel ready", systemImage: "iphone.gen3")
            Text("Last reply: \(appDelegate.lastReply)")
            Text(appDelegate.lastDeliveryState)
            Divider()
            Button("Show Pairing") {
                appDelegate.showPairingWindow()
            }
            Button("Simulate Call") {
                appDelegate.notificationBridge.showCall(caller: "Alex Morgan", handle: "+1 555 123 4567")
            }
            Button("Simulate Message") {
                appDelegate.notificationBridge.showMessage(sender: "Alex Morgan", preview: "Can you send the deck?")
            }
            Divider()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        Settings {
            PairingView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject, @unchecked Sendable {
    let notificationBridge = NotificationBridge()
    let pairingMachine = PairingStateMachine()
    let pairingStore = UserDefaultsPairingStore()
    let pairingSecretStore = KeychainPairingSecretStore()
    private let localMacDeviceId = "mac-demo"
    private let receiverPort: UInt16 = 45731
    private let demoPixelPrivateKey = P256.KeyAgreement.PrivateKey()
    private var activeTransport: (any PlinkTransport)?
    private var receiver: (any PlinkEventReceiver)?
    @Published var lastReply: String = "None"
    @Published var lastDeliveryState: String = "Notifications pending"
    private var pairingWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        restoreSavedPairing()
    }

    func showPairingWindow() {
        if pairingWindow == nil {
            let verificationCode = prepareDemoPairing()
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 360),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.center()
            window.title = "Pair Pixel"
            window.contentView = NSHostingView(rootView: PairingView(onConfirm: { [weak self] in
                self?.confirmDemoPairing()
            }, verificationCode: verificationCode))
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

    private func restoreSavedPairing() {
        guard let device = try? pairingStore.all().first else { return }
        let storedSessionKey: Data?
        do {
            storedSessionKey = try pairingSecretStore.load(sessionId: device.sessionId)
        } catch {
            return
        }
        guard let sessionKey = storedSessionKey else { return }
        activeTransport = makeTransport(for: device, sessionKey: sessionKey)
        startReceiver(sessionKey: sessionKey, pairedDeviceId: device.id)
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
            let server = try SecureNetworkPlinkServer(
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
        } catch {
            lastDeliveryState = error.localizedDescription
        }
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

struct PairingView: View {
    var onConfirm: () -> Void = {}
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

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Plink")
                .font(.largeTitle.weight(.semibold))
            Text("Match this code on your Pixel before confirming.")
                .font(.title3)
            Text(verificationCode.emoji.joined(separator: "  "))
                .font(.system(size: 52, weight: .bold, design: .rounded))
            Text("Code \(verificationCode.numeric)")
                .font(.title3.monospacedDigit())
            VStack(alignment: .leading, spacing: 8) {
                Label("Calls appear as Mac notifications", systemImage: "phone")
                Label("Messages can reply from notification actions", systemImage: "message")
                Label("Clipboard, files, links, battery, and media are event driven", systemImage: "bolt.horizontal")
            }
            .foregroundStyle(.secondary)
            Button("Confirm Pairing") {
                onConfirm()
            }
            .keyboardShortcut(.defaultAction)
            Spacer()
        }
        .padding(28)
        .frame(width: 420, height: 360)
    }
}

enum AppDeliveryError: LocalizedError {
    case transportUnavailable

    var errorDescription: String? {
        switch self {
        case .transportUnavailable:
            return "No paired Pixel transport is available."
        }
    }
}
