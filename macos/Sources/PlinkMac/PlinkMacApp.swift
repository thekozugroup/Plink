import AppKit
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
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let notificationBridge = NotificationBridge()
    let pairingMachine = PairingStateMachine()
    let pairingStore = InMemoryPairingStore()
    let replyTransport: any PlinkTransport = InMemoryPlinkTransport()
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
                    try await self?.replyTransport.send(reply)
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
    }

    func showPairingWindow() {
        if pairingWindow == nil {
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
            }))
            pairingWindow = window
        }
        pairingWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
    }

    func confirmDemoPairing() {
        _ = pairingMachine.receive(
            PairingOffer(
                deviceId: "pixel-demo",
                deviceName: "Pixel",
                platform: "android",
                endpoint: "192.168.1.24:45731",
                nonce: "demo-nonce"
            )
        )
        if case .paired(let device) = try? pairingMachine.confirm() {
            pairingStore.save(device)
        }
    }
}

struct PairingView: View {
    private let emoji = EmojiPairing.derive(sourceDeviceId: "pixel-demo", targetDeviceId: "mac-demo", nonce: "demo-nonce")
    var onConfirm: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Plink")
                .font(.largeTitle.weight(.semibold))
            Text("Match this code on your Pixel before confirming.")
                .font(.title3)
            Text("\(emoji.0)  \(emoji.1)")
                .font(.system(size: 52, weight: .bold, design: .rounded))
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
