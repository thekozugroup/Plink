import AppKit
import PlinkCore
import SwiftUI
import UserNotifications

@main
struct PlinkMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Plink", systemImage: "link") {
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
final class AppDelegate: NSObject, NSApplicationDelegate {
    let notificationBridge = NotificationBridge()
    private var pairingWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        notificationBridge.configure()
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
            window.contentView = NSHostingView(rootView: PairingView())
            pairingWindow = window
        }
        pairingWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
    }
}

struct PairingView: View {
    private let emoji = EmojiPairing.derive(sourceDeviceId: "pixel-demo", targetDeviceId: "mac-demo", nonce: "demo-nonce")

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
            Spacer()
        }
        .padding(28)
        .frame(width: 420, height: 360)
    }
}
