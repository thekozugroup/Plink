import AppKit
import SwiftUI

struct DashboardWindow: View {
    @ObservedObject var appDelegate: AppDelegate
    @State private var section = "Home"

    var body: some View {
        VStack(spacing: 0) {
            ConnectionHeader(appDelegate: appDelegate, reconnect: appDelegate.reconnect, calling: appDelegate.calling)
                .padding(24)
            Picker("View", selection: $section) {
                ForEach(["Home", "Calls", "Settings"], id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 24)
            .padding(.bottom, 18)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch section {
                    case "Calls":
                        BluetoothCallingView(controller: appDelegate.calling, phoneName: appDelegate.pairedPhoneName)
                    case "Settings":
                        PlinkSettingsContent(appDelegate: appDelegate)
                    default:
                        home
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .background(FrostedWindowBackground())
        .frame(minWidth: 480, minHeight: 520)
    }

    @ViewBuilder private var home: some View {
        if appDelegate.pairingRecoveryComplete && appDelegate.pairedPeerID != nil {
            ContinuityPanel(appDelegate: appDelegate)
            FileTransferPanel(controller: appDelegate.files)
        } else if appDelegate.pairingRecoveryComplete {
            VStack(alignment: .leading, spacing: 16) {
                Text(appDelegate.pairedPhoneName == nil ? "Your phone, closer." : "Let’s connect.")
                    .font(.title2.weight(.semibold))
                Text(appDelegate.pairedPhoneName == nil
                     ? "Bring your phone’s notifications, files, and clipboard to your Mac."
                     : "Open Plink on your phone and keep both devices on the same Wi-Fi.")
                    .foregroundStyle(.secondary)
                if appDelegate.pairedPhoneName == nil {
                    Label { Text("Open Plink on your phone") } icon: { LucideIcon(name: .smartphone) }
                    Label { Text("Choose this Mac") } icon: { LucideIcon(name: .laptop) }
                    Label { Text("Confirm the matching code") } icon: { LucideIcon(name: .shieldCheck) }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        }
    }
}

struct PlinkSettingsContent: View {
    @ObservedObject var appDelegate: AppDelegate

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox("Notifications") {
                VStack(alignment: .leading, spacing: 10) {
                    Label {
                        Text(appDelegate.notificationsEnabled ? "Notifications enabled" : "Notifications are off")
                    } icon: {
                        LucideIcon(name: appDelegate.notificationsEnabled ? .circleCheck : .bellOff)
                    }
                    if !appDelegate.notificationsEnabled {
                        Text(appDelegate.notificationStatus)
                            .foregroundStyle(.secondary)
                        Button("Enable Notifications") { appDelegate.notificationBridge.requestAuthorization() }
                        Button("Open System Settings…") {
                            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            GroupBox("Sharing") {
                VStack(alignment: .leading, spacing: 12) {
                    ClipboardSyncSettings(controller: appDelegate.clipboard)
                    Toggle("Open links sent from phone", isOn: $appDelegate.receiveURLs)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            Button("Pair Another Phone…") { appDelegate.showPairingWindow() }
                .disabled(!appDelegate.pairingRecoveryComplete)
            DisclosureGroup("Connection details") {
                Text(appDelegate.lastDeliveryState).font(.caption).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                if appDelegate.pairedPhoneName != nil && !appDelegate.isPairing {
                    ReconnectView(controller: appDelegate.reconnect)
                }
            }
        }
    }
}

struct ConnectionHeader: View {
    @ObservedObject var appDelegate: AppDelegate
    @ObservedObject var reconnect: ReconnectController
    @ObservedObject var calling: BluetoothCallController
    var compact = false

    private var connected: Bool { appDelegate.pairedPeerID != nil }
    private var busy: Bool {
        switch reconnect.state {
        case .finding, .verifying, .disconnecting: return true
        default: return false
        }
    }
    private var title: String {
        if !appDelegate.pairingRecoveryComplete { return appDelegate.pairingRecoveryError == nil ? "Restoring your saved connection…" : "Setup needs attention" }
        if appDelegate.isPairing { return appDelegate.canConfirmPairing ? "Confirm your phone" : "Pairing your phone" }
        if connected { return "Connected" }
        if busy { return "Connecting…" }
        return appDelegate.pairedPhoneName == nil ? "Connect your phone" : "Phone disconnected"
    }
    private var detail: String {
        if let error = appDelegate.pairingRecoveryError { return error }
        if !appDelegate.pairingRecoveryComplete { return appDelegate.startupRecovery.detail }
        if appDelegate.isPairing { return "Compare the code on both devices." }
        if connected { return "Your phone is ready to use." }
        if case .failed(let reason) = reconnect.state { return reason }
        if busy { return "Keep Plink open on your phone." }
        if appDelegate.pairedPhoneName == nil && appDelegate.startupRecovery.phase == .needsPairing {
            return appDelegate.startupRecovery.detail
        }
        return appDelegate.pairedPhoneName == nil ? "Start with a quick, secure pairing." : "Your pairing is saved. Connect when your phone is nearby."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                LucideIcon(name: .smartphone, size: compact ? 28 : 36)
                    .foregroundStyle(connected ? Color.green : Color.accentColor)
                    .frame(width: compact ? 44 : 58, height: compact ? 48 : 64)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 5) {
                    Text(appDelegate.pairedPhoneName ?? "Plink").font(.subheadline).foregroundStyle(.secondary)
                    Text(title).font(compact ? .headline : .title2.weight(.semibold))
                    if !compact { Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: 0)
                if !appDelegate.pairingRecoveryComplete && appDelegate.pairingRecoveryError == nil {
                    ProgressView("Restoring your saved connection…").controlSize(.small).labelsHidden()
                } else if appDelegate.pairingRecoveryComplete && busy && !appDelegate.isPairing {
                    ProgressView().controlSize(.small)
                }
            }
            if !appDelegate.pairingRecoveryComplete, compact {
                Text(detail).font(.caption)
                    .foregroundStyle(appDelegate.pairingRecoveryError == nil ? Color.secondary : Color.red)
            }
            if appDelegate.pairingRecoveryComplete {
                HStack(spacing: 16) {
                    Label {
                        Text(connected ? "Wi-Fi connected" : "Wi-Fi disconnected")
                    } icon: {
                        LucideIcon(name: connected ? .wifi : .wifiOff)
                    }
                        .foregroundStyle(connected ? Color.green : Color.secondary)
                    Label {
                        VStack(alignment: .leading) {
                            Text(calling.bluetoothPaired ? "Bluetooth paired" : "Bluetooth not paired")
                            Text(calling.serviceConnected ? "Calls connected" : "Calls disconnected")
                        }
                    } icon: {
                        LucideIcon(name: .bluetooth)
                    }
                        .foregroundStyle(calling.serviceConnected ? Color.green : Color.secondary)
                }.font(.caption)
            }
            if appDelegate.pairingRecoveryComplete && !connected {
                if appDelegate.isPairing {
                    Button("Continue Pairing") { appDelegate.showPairingWindow() }.buttonStyle(.borderedProminent)
                } else if appDelegate.pairedPhoneName == nil {
                    Button("Pair Phone") { appDelegate.showPairingWindow() }.buttonStyle(.borderedProminent)
                } else if busy {
                    Button("Cancel") { reconnect.cancel() }
                } else {
                    Button("Connect") { reconnect.beginDiscovery() }.buttonStyle(.borderedProminent)
                }
            }
            if let battery = appDelegate.deviceStatus, connected {
                Label {
                    Text("\(battery.batteryLevel)%\(battery.charging ? " · Charging" : "")")
                } icon: {
                    LucideIcon(name: battery.charging ? .batteryCharging : .battery)
                }
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MenuBarPanel: View {
    @ObservedObject var appDelegate: AppDelegate
    @ObservedObject var reconnect: ReconnectController
    @ObservedObject var calling: BluetoothCallController
    var body: some View {
        Button("Open Plink") { appDelegate.showDashboardWindow() }
        Divider()
        if !appDelegate.pairingRecoveryComplete {
            Text(appDelegate.pairingRecoveryError == nil ? "Restoring your saved connection…" : "Saved connection needs attention")
        } else {
            Text(appDelegate.pairedPhoneName ?? appDelegate.startupRecovery.menuStatus)
            Label {
                Text(appDelegate.pairedPeerID == nil ? "Wi-Fi disconnected" : "Wi-Fi connected")
            } icon: {
                LucideIcon(name: appDelegate.pairedPeerID == nil ? .wifiOff : .wifi)
            }
            Text(calling.bluetoothPaired ? "Bluetooth paired" : "Bluetooth not paired")
            Text(calling.serviceConnected ? "Calls connected" : "Calls disconnected")
        }
        Divider()
        if appDelegate.pairedPeerID != nil {
            FileTransferMenu(controller: appDelegate.files, openDashboard: { appDelegate.showDashboardWindow() })
        } else if appDelegate.isPairing {
            Button("Continue Pairing…") { appDelegate.showPairingWindow() }
        } else if appDelegate.pairedPhoneName != nil {
            Button("Connect Phone") { reconnect.beginDiscovery() }
                .disabled(!appDelegate.pairingRecoveryComplete || reconnect.state == .finding || reconnect.state == .verifying || reconnect.state == .disconnecting)
        } else {
            Button("Pair Phone…") { appDelegate.showPairingWindow() }.disabled(!appDelegate.pairingRecoveryComplete)
        }
        Divider()
        Button("Quit Plink") { appDelegate.quit() }.keyboardShortcut("q")
    }
}

private struct ClipboardSyncSettings: View {
    @ObservedObject var controller: ClipboardSyncController

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Toggle("Clipboard sync", isOn: Binding(get: { controller.enabled }, set: controller.setEnabled))
            Text("Copy text on one device and paste on the other. Enable this in Plink on your phone too.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct FrostedWindowBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
