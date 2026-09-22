import AppKit
import SwiftUI
import OSLog

struct DashboardPresentation {
    enum Action: Equatable {
        case pair, continuePairing, connect, cancel, setUpCalls, connectCalls, disconnect
        var title: String {
            switch self {
            case .pair: return "Pair Phone"
            case .continuePairing: return "Continue Pairing"
            case .connect: return "Connect"
            case .cancel: return "Cancel"
            case .setUpCalls: return "Set Up Calls"
            case .connectCalls: return "Connect Calls"
            case .disconnect: return "Disconnect"
            }
        }
    }
    let recovered: Bool
    let delayed: Bool
    let recoveryError: Bool
    let pairing: Bool
    let connected: Bool
    let reconnecting: Bool
    let disconnecting: Bool
    let hasPhone: Bool
    let bluetoothPaired: Bool
    let callsConnected: Bool

    var title: String {
        if !recovered {
            if delayed { return "Still restoring your saved connection" }
            return recoveryError ? "Saved connection needs attention" : "Restoring your saved connection…"
        }
        if disconnecting { return "Disconnecting…" }
        if pairing { return "Finish pairing your phone" }
        if connected { return "Wi-Fi connected" }
        if reconnecting { return "Connecting…" }
        return hasPhone ? "Phone disconnected" : "Connect your phone"
    }
    var callsStatus: String {
        Self.callsStatus(connected: callsConnected, paired: bluetoothPaired, blocked: false)
    }
    static func callsStatus(connected: Bool, paired: Bool, blocked: Bool,
                            pairedLabel: String = "Calls disconnected") -> String {
        if blocked { return "Calls unavailable" }
        return connected ? "Calls connected" : (paired ? pairedLabel : "Calls need setup")
    }
    static func callsRecoveryDetail(blocked: Bool) -> String? {
        blocked ? "Restart Plink to use calls again." : nil
    }
    static func callsSetupDisabled(busy: Bool, blocked: Bool) -> Bool {
        busy || blocked
    }
    var showsProgress: Bool { (!recovered && !delayed && !recoveryError) || (recovered && (reconnecting || disconnecting)) }
    var primary: Action? {
        guard recovered, !disconnecting else { return nil }
        if pairing { return .continuePairing }
        if connected {
            if !callsConnected { return bluetoothPaired ? .connectCalls : .setUpCalls }
            return .disconnect
        }
        if reconnecting { return .cancel }
        return hasPhone ? .connect : .pair
    }
}

struct DashboardWindow: View {
    @ObservedObject var appDelegate: AppDelegate
    @State private var section = "Home"
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(spacing: 0) {
            ConnectionHeader(appDelegate: appDelegate, reconnect: appDelegate.reconnect, calling: appDelegate.calling)
                .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 22)
            Picker("View", selection: $section) {
                ForEach(["Home", "Calls", "Settings"], id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(.horizontal, 28).padding(.bottom, 18)
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
                .padding(.horizontal, 28).padding(.bottom, 28)
            }
        }
        .background {
            if reduceTransparency { Color(nsColor: .windowBackgroundColor) }
            else { FrostedWindowBackground() }
        }
        .frame(minWidth: 420, idealWidth: 460, minHeight: 720, idealHeight: 820)
        .onAppear { appDelegate.refreshSavedPhones() }
    }

    @ViewBuilder private var home: some View {
        if appDelegate.pairingRecoveryComplete {
            if appDelegate.pairedPeerID != nil {
                ContinuityPanel(appDelegate: appDelegate)
                FileTransferPanel(controller: appDelegate.files)
            } else {
                NativeSettingsCard("Get connected") {
                    Label {
                        Text(appDelegate.pairedPhoneName == nil ? "Open Plink on your phone and choose this Mac." : "Open Plink on your phone and keep both devices on the same Wi-Fi.")
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: { LucideIcon(name: .smartphone) }
                    .font(.callout).foregroundStyle(.secondary)
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
    private var presentation: DashboardPresentation {
        DashboardPresentation(recovered: appDelegate.pairingRecoveryComplete,
            delayed: appDelegate.startupRecovery.isDelayed, recoveryError: appDelegate.pairingRecoveryError != nil,
            pairing: appDelegate.isPairing, connected: connected,
            reconnecting: reconnect.state == .finding || reconnect.state == .verifying,
            disconnecting: reconnect.state == .disconnecting, hasPhone: appDelegate.pairedPhoneName != nil,
            bluetoothPaired: calling.bluetoothPaired, callsConnected: calling.serviceConnected)
    }
    private var detail: String {
        if !appDelegate.pairingRecoveryComplete { return appDelegate.startupRecovery.detail }
        if appDelegate.isPairing { return "Compare the code on both devices." }
        if appDelegate.phoneManagementBusy { return appDelegate.phoneManagementStatus ?? "Updating your phone connection…" }
        if connected && !calling.serviceConnected {
            if calling.blocked { return calling.status }
            if calling.busy { return "Finishing Bluetooth setup…" }
            return calling.bluetoothPaired ? "Your Bluetooth pairing is saved. Connect calls when you’re ready." : "Finish Bluetooth setup to answer your phone’s calls on this Mac."
        }
        if connected { return "Connected for calls and sharing." }
        if case .failed(let reason) = reconnect.state { return reason }
        if presentation.reconnecting { return "Keep Plink open on your phone." }
        if appDelegate.startupRecovery.phase == .needsPairing { return appDelegate.startupRecovery.detail }
        return presentation.hasPhone ? "Your pairing is saved. Keep both devices on the same Wi-Fi." : "Notifications, clipboard and files, together on your Mac."
    }

    var body: some View {
        VStack(spacing: compact ? 12 : 18) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(connected ? 0.07 : 0.035))
                Circle().strokeBorder(Color.primary.opacity(0.055), lineWidth: 1)
                    .padding(10)
                Circle().strokeBorder(connected ? Color.accentColor.opacity(0.75) : Color.primary.opacity(0.09), lineWidth: 2)
                LucideIcon(name: .smartphone, size: compact ? 54 : 84)
                    .foregroundStyle(connected ? Color.accentColor : Color.secondary)
                VStack {
                    Spacer()
                    if presentation.showsProgress {
                        ProgressView().controlSize(.small).padding(10)
                            .background(.regularMaterial, in: Circle())
                            .accessibilityLabel(presentation.title)
                    } else if connected {
                        Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white).frame(width: 28, height: 28)
                            .background(Color.accentColor, in: Circle())
                            .accessibilityHidden(true)
                    }
                }.offset(y: 7)
            }
            .frame(width: compact ? 120 : 180, height: compact ? 120 : 180)
            .accessibilityElement(children: .ignore).accessibilityLabel(presentation.title)

            VStack(spacing: 6) {
                Text(appDelegate.pairedPhoneName ?? "Your phone, connected.")
                    .font(.system(size: compact ? 22 : 26, weight: .semibold, design: .rounded))
                    .multilineTextAlignment(.center)
                if !appDelegate.pairingRecoveryComplete || appDelegate.isPairing || presentation.reconnecting || presentation.disconnecting {
                    Text(presentation.title).font(.callout.weight(.medium)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                HStack(spacing: 10) {
                    statusChip(!appDelegate.pairingRecoveryComplete ? "Wi-Fi · Waiting" : (connected ? "Wi-Fi connected" : "Wi-Fi disconnected"),
                               icon: connected ? .wifi : .wifiOff, active: connected)
                    statusChip(!appDelegate.pairingRecoveryComplete ? "Calls · Waiting" : DashboardPresentation.callsStatus(
                        connected: calling.serviceConnected, paired: calling.bluetoothPaired, blocked: calling.blocked, pairedLabel: "Bluetooth paired"),
                               icon: .bluetooth, active: calling.serviceConnected)
                }.padding(.top, 3)
                if let battery = appDelegate.deviceStatus, connected {
                    Label { Text("\(battery.batteryLevel)%\(battery.charging ? " · Charging" : "")").monospacedDigit() }
                        icon: { LucideIcon(name: battery.charging ? .batteryCharging : .battery, size: 14) }
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityLabel("Battery \(battery.batteryLevel) percent\(battery.charging ? ", charging" : "")")
                }
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 345)
            }
            if let action = presentation.primary {
                Button(action.title) { perform(action) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(appDelegate.phoneManagementBusy || primaryBlocked(action))
                    .help(action == .disconnect && calling.call.context != nil ? "End the call before disconnecting." : action.title)
            }
        }.frame(maxWidth: .infinity)
    }

    private func statusChip(_ title: String, icon: LucideIcon.Name, active: Bool) -> some View {
        Label { Text(title) } icon: { LucideIcon(name: icon, size: 13) }
            .font(.caption).foregroundStyle(active ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.primary.opacity(0.035), in: Capsule())
    }

    private func primaryBlocked(_ action: DashboardPresentation.Action) -> Bool {
        if action == .setUpCalls || action == .connectCalls {
            return DashboardPresentation.callsSetupDisabled(busy: calling.busy, blocked: calling.blocked)
        }
        if action == .disconnect { return calling.call.context != nil || !calling.call.stateIsCertain || calling.busy || calling.blocked }
        return false
    }
    private func perform(_ action: DashboardPresentation.Action) {
        switch action {
        case .pair, .continuePairing: appDelegate.showPairingWindow()
        case .connect: reconnect.beginDiscovery()
        case .cancel: reconnect.cancel()
        case .setUpCalls, .connectCalls:
            Logger(subsystem: "com.thekozugroup.plink.mac", category: "bluetooth-calling").notice("calls.setup.dashboard.enter")
            appDelegate.setUpCalls()
        case .disconnect: appDelegate.disconnectSelectedPhone()
        }
    }
}

private struct SavedPhonesView: View {
    @ObservedObject var appDelegate: AppDelegate
    @State private var unpairID: String?
    @State private var unpairName = ""
    var body: some View {
        NativeSettingsCard("Your phones") {
            if appDelegate.savedPhones.isEmpty {
                Text("No saved phones").foregroundStyle(.secondary).font(.callout)
            }
            ForEach(appDelegate.savedPhones, id: \.id) { phone in
                HStack(alignment: .top, spacing: 12) {
                    LucideIcon(name: .smartphone, size: 22).frame(width: 24).padding(.top, 3)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(phone.name).font(.callout.weight(.medium))
                        Text(phone.id == appDelegate.selectedPhoneID ? "Selected phone" : "Saved phone")
                            .font(.caption).foregroundStyle(.secondary)
                        if let reason = appDelegate.savedPhoneSelectionUnavailableReason(phone.id), phone.id != appDelegate.selectedPhoneID {
                            Text(reason).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 4)
                    Menu {
                        if phone.id != appDelegate.selectedPhoneID {
                            Button("Select Phone") { appDelegate.selectSavedPhone(phone.id) }
                                .disabled(appDelegate.savedPhoneSelectionUnavailableReason(phone.id) != nil)
                        }
                        Button("Unpair…", role: .destructive) { unpairID = phone.id; unpairName = phone.name }
                            .disabled(appDelegate.savedPhoneRemovalUnavailableReason(phone.id) != nil)
                    } label: { Text("Manage").font(.caption) }
                    .menuStyle(.borderlessButton).fixedSize()
                    .accessibilityLabel("Manage \(phone.name)")
                    .disabled(appDelegate.phoneManagementBusy || !appDelegate.pairingRecoveryComplete)
                }.padding(.vertical, 5)
                if phone.id != appDelegate.savedPhones.last?.id { Divider() }
            }
            if let status = appDelegate.phoneManagementStatus {
                Text(status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Button { appDelegate.showPairingWindow() } label: {
                Text("Pair Another Phone")
            }.buttonStyle(.borderless)
                .disabled(appDelegate.phoneManagementBusy || !appDelegate.pairingRecoveryComplete)
        }
        .confirmationDialog("Unpair \(unpairName)?", isPresented: Binding(
            get: { unpairID != nil }, set: { if !$0 { unpairID = nil } }), titleVisibility: .visible) {
            if let id = unpairID {
                Button("Unpair", role: .destructive) {
                    appDelegate.unpairSavedPhone(id)
                    unpairID = nil
                }
            }
            Button("Cancel", role: .cancel) { unpairID = nil }
        } message: {
            Text("This removes this Mac’s saved connection to the phone. Its macOS Bluetooth pairing is kept.")
        }
    }
}

struct PlinkSettingsContent: View {
    @ObservedObject var appDelegate: AppDelegate
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SavedPhonesView(appDelegate: appDelegate)
            NativeSettingsCard("Notifications") {
                HStack(spacing: 12) {
                    LucideIcon(name: .bell, size: 20).foregroundStyle(.secondary).frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(appDelegate.notificationsEnabled ? "Notifications enabled" : "Notifications are off").font(.callout.weight(.medium))
                        Text("Phone notifications appear in Notification Center.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                if !appDelegate.notificationsEnabled {
                    Text(appDelegate.notificationStatus).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Enable Notifications") { appDelegate.notificationBridge.requestAuthorization() }
                        Button("Open System Settings…") {
                            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
                        }
                    }.controlSize(.small)
                }
            }
            NativeSettingsCard("Sharing") {
                ClipboardSyncSettings(controller: appDelegate.clipboard)
                Divider()
                Toggle(isOn: $appDelegate.receiveURLs) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Open links from phone").font(.callout.weight(.medium))
                        Text("Open shared links in your Mac’s browser.").font(.caption).foregroundStyle(.secondary)
                    }
                }.toggleStyle(.switch).controlSize(.small)
            }
            DisclosureGroup("Connection help") {
                Text(appDelegate.lastDeliveryState).font(.caption).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                if appDelegate.pairedPhoneName != nil && !appDelegate.isPairing {
                    ReconnectView(controller: appDelegate.reconnect, showsStatusAndActions: false)
                }
            }.font(.callout)
        }
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
            Text(appDelegate.startupRecovery.menuStatus)
            if appDelegate.startupRecovery.isDelayed { Text(appDelegate.startupRecovery.detail) }
        } else {
            Text(appDelegate.pairedPhoneName ?? appDelegate.startupRecovery.menuStatus)
            Text(appDelegate.pairedPeerID == nil ? "Wi-Fi disconnected" : "Wi-Fi connected")
            Text(DashboardPresentation.callsStatus(connected: calling.serviceConnected,
                paired: calling.bluetoothPaired, blocked: calling.blocked))
            if let detail = DashboardPresentation.callsRecoveryDetail(blocked: calling.blocked) { Text(detail) }
        }
        Divider()
        if appDelegate.pairedPeerID != nil {
            if !calling.serviceConnected {
                Button(calling.bluetoothPaired ? "Connect Calls" : "Set Up Calls") {
                    Logger(subsystem: "com.thekozugroup.plink.mac", category: "bluetooth-calling").notice("calls.setup.menu.enter")
                    appDelegate.setUpCalls()
                }
                    .disabled(DashboardPresentation.callsSetupDisabled(busy: calling.busy, blocked: calling.blocked) || appDelegate.phoneManagementBusy)
            }
            FileTransferMenu(controller: appDelegate.files, openDashboard: { appDelegate.showDashboardWindow() })
        } else if appDelegate.isPairing {
            Button("Continue Pairing…") { appDelegate.showPairingWindow() }
        } else if appDelegate.pairedPhoneName != nil {
            Button("Connect Phone") { reconnect.beginDiscovery() }
                .disabled(!appDelegate.pairingRecoveryComplete || appDelegate.phoneManagementBusy || reconnect.state == .finding || reconnect.state == .verifying || reconnect.state == .disconnecting)
        } else {
            Button("Pair Phone…") { appDelegate.showPairingWindow() }
                .disabled(!appDelegate.pairingRecoveryComplete || appDelegate.phoneManagementBusy)
        }
        Divider()
        Button("Quit Plink") { appDelegate.quit() }.keyboardShortcut("q")
    }
}

private struct ClipboardSyncSettings: View {
    @ObservedObject var controller: ClipboardSyncController
    var body: some View {
        Toggle(isOn: Binding(get: { controller.enabled }, set: controller.setEnabled)) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Clipboard sync").font(.callout.weight(.medium))
                Text("Copy text on one device and paste on the other. Enable this on your phone too.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.toggleStyle(.switch).controlSize(.small)
    }
}

private struct NativeSettingsCard<Content: View>: View {
    let title: String
    let content: Content
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if reduceTransparency { RoundedRectangle(cornerRadius: 18).fill(Color(nsColor: .controlBackgroundColor)) }
            else { RoundedRectangle(cornerRadius: 18).fill(.regularMaterial) }
        }
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.primary.opacity(contrast == .increased ? 0.3 : 0.06)))
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
