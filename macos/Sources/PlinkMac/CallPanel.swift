import AppKit
import OSLog
import PlinkCore
import SwiftUI

/// Presentation only. The HFP controller remains the authority for every action.
struct CallPanelPresentation {
    private(set) var call = MacCallSession()
    private(set) var visible = false
    private var hiddenContext: MacCallContext?
    private(set) var activeSince: ContinuousClock.Instant?
    var context: MacCallContext? { call.context }
    var caller: String { call.number.flatMap { $0.isEmpty ? nil : $0 } ?? "Unknown caller" }
    var status: String {
        switch call.phase {
        case .ringing: return "Incoming call"
        case .answering: return "Answering…"
        case .active: return "Call active"
        case .ending: return "Ending call…"
        case .idle: return "No active call"
        }
    }
    var audioConnected: Bool { visible && call.stateIsCertain && !call.hasWaitingCall && call.audio == .scoConnectedUnverified }
    var audioLabel: String {
        if audioConnected { return "Bluetooth audio connected" }
        if call.audio == .phone { return "Audio on phone" }
        if call.audio == .requestedComputer { return "Connecting Mac audio…" }
        return "Bluetooth audio unavailable"
    }

    func elapsed(at now: ContinuousClock.Instant = .now) -> String? {
        guard call.phase == .active, call.stateIsCertain, let activeSince else { return nil }
        let seconds = max(0, activeSince.duration(to: now).components.seconds)
        return String(format: "%02lld:%02lld", seconds / 60, seconds % 60)
    }

    mutating func update(call: MacCallSession, serviceConnected: Bool, allowed: Bool,
                         now: ContinuousClock.Instant = .now) {
        let previous = self.call.context
        self.call = call
        if previous != call.context { hiddenContext = nil; activeSince = nil }
        if serviceConnected, call.stateIsCertain, call.context != nil, call.phase == .active, activeSince == nil {
            activeSince = now
        }
        if !serviceConnected || call.context == nil { activeSince = nil }
        let log = Logger(subsystem: "com.thekozugroup.plink.mac", category: "bluetooth-calling")
        guard allowed else { log.notice("calls.panel.hidden.environment"); visible = false; return }
        guard serviceConnected else { log.notice("calls.panel.hidden.service_disconnected"); visible = false; return }
        guard call.stateIsCertain else { log.notice("calls.panel.hidden.uncertain"); visible = false; return }
        guard !call.hasWaitingCall else { log.notice("calls.panel.hidden.multiple_calls"); visible = false; return }
        guard let context = call.context else { log.notice("calls.panel.hidden.no_context"); visible = false; return }
        guard hiddenContext != context else { log.notice("calls.panel.hidden.dismissed"); visible = false; return }
        switch call.phase {
        case .ringing, .active: visible = true
        case .answering, .ending: visible = visible && previous == context
        case .idle: visible = false
        }
    }

    mutating func close() { hiddenContext = context; visible = false }

    func permits(_ action: MacCallAction, context: MacCallContext, current: MacCallSession,
                 serviceConnected: Bool, busy: Bool, blocked: Bool) -> Bool {
        visible && self.context == context && serviceConnected && !busy && !blocked &&
            current.permits(action, context: context)
    }
}

@MainActor
final class CallPanelController: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var presentation = CallPanelPresentation()
    @Published private(set) var phoneName: String?
    private let calling: BluetoothCallController
    private var panel: NSPanel?

    init(calling: BluetoothCallController) { self.calling = calling; super.init() }

    /// AppDelegate supplies fresh session/lock eligibility and the current HFP snapshot.
    func update(call: MacCallSession, phoneName: String?, presentationAllowed: Bool) {
        self.phoneName = phoneName
        presentation.update(call: call, serviceConnected: calling.serviceConnected, allowed: presentationAllowed)
        Logger(subsystem: "com.thekozugroup.plink.mac", category: "bluetooth-calling").notice("calls.panel.state visible=\(self.presentation.visible, privacy: .public) ringing=\(call.phase == .ringing, privacy: .public) active=\(call.phase == .active, privacy: .public) busy=\(self.calling.busy, privacy: .public) blocked=\(self.calling.blocked, privacy: .public) audioConnected=\(self.presentation.audioConnected, privacy: .public)")
        guard presentation.visible else { panel?.orderOut(nil); return }
        if panel == nil {
            let window = CallWindow(contentRect: NSRect(x: 0, y: 0, width: 363, height: 142),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.title = "Plink Call"
            window.isReleasedWhenClosed = false
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.level = .normal
            window.hidesOnDeactivate = false
            window.isMovableByWindowBackground = true
            window.delegate = self
            window.contentView = NSHostingView(rootView: CallPanelView(panel: self, calling: calling))
            if let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main {
                let frame = screen.visibleFrame
                window.setFrameOrigin(NSPoint(x: frame.maxX - 387, y: frame.maxY - 166))
            }
            panel = window
        }
        // Nonactivating and normal window level: no focus stealing or security-UI overlay.
        panel?.orderFront(nil)
    }

    func dismiss() { presentation.close(); panel?.orderOut(nil) }
    func windowWillClose(_ notification: Notification) { presentation.close() }

    func perform(_ action: MacCallAction, context: MacCallContext) {
        guard presentation.permits(action, context: context, current: calling.call,
            serviceConnected: calling.serviceConnected, busy: calling.busy, blocked: calling.blocked) else { return }
        calling.perform(action, context: context)
    }
}

private final class CallWindow: NSPanel {
    override var canBecomeKey: Bool { true } // Keyboard controls after an explicit click, never on arrival.
    override var canBecomeMain: Bool { false }
}

private struct CallPanelView: View {
    @ObservedObject var panel: CallPanelController
    @ObservedObject var calling: BluetoothCallController
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            CallPanelContent(state: panel.presentation, phoneName: panel.phoneName,
                elapsed: panel.presentation.elapsed(), enabled: { action, context in
                    panel.presentation.permits(action, context: context, current: calling.call,
                        serviceConnected: calling.serviceConnected, busy: calling.busy, blocked: calling.blocked)
                }, perform: { panel.perform($0, context: $1) }, hide: { panel.dismiss() })
        }
    }
}

/// Also renderable with synthetic snapshots through ImageRenderer; no OS call or window needed.
struct CallPanelContent: View {
    let state: CallPanelPresentation
    let phoneName: String?
    var elapsed: String? = nil
    var enabled: (MacCallAction, MacCallContext) -> Bool = { _, _ in false }
    var perform: (MacCallAction, MacCallContext) -> Void = { _, _ in }
    var hide: () -> Void = {}
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "person.fill")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 30, height: 30)
                    .background(.quaternary, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.caller).font(.callout.weight(.semibold)).lineLimit(1)
                    Text("Plink · \(phoneName.map { "From \($0)" } ?? "From phone")")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: state.audioConnected ? "waveform" : "minus")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(state.audioConnected ? Color.primary : Color.secondary)
                    .frame(width: 54, height: 18)
                    .accessibilityLabel(state.audioLabel)
                    .help(state.audioLabel)
                Button { hide() } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                        .frame(width: 20, height: 24)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel("Hide call panel").help("Hide without ending the call")
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.status).font(.caption)
                    if let elapsed { Text(elapsed).font(.caption.monospacedDigit()).accessibilityLabel("Call elapsed \(elapsed)") }
                }.foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let context = state.context {
                    switch state.call.phase {
                    case .ringing:
                        action("Decline", symbol: "phone.down.fill", color: .red, action: .decline, context: context)
                        action("Answer on Mac", symbol: "phone.fill", color: .green, action: .answer, context: context)
                    case .active:
                        action(state.call.muted ? "Unmute" : "Mute", symbol: state.call.muted ? "mic.slash.fill" : "mic.fill",
                               color: nil, action: .toggleMute, context: context)
                        action(state.audioConnected ? "Audio on Phone" : "Audio on Mac",
                               symbol: state.audioConnected ? "iphone" : "laptopcomputer", color: nil,
                               action: state.audioConnected ? .phoneAudio : .computerAudio, context: context)
                        action("End Call", symbol: "phone.down.fill", color: .red, action: .hangUp, context: context)
                    case .answering, .ending: ProgressView().controlSize(.small).accessibilityLabel(state.status)
                    case .idle: EmptyView()
                    }
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if reduceTransparency || contrast == .increased {
                RoundedRectangle(cornerRadius: 31).fill(Color(nsColor: .windowBackgroundColor))
            } else {
                RoundedRectangle(cornerRadius: 31).fill(.regularMaterial)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 31).strokeBorder(.primary.opacity(contrast == .increased ? 0.35 : 0.09)))
        .padding(5)
        .onExitCommand { hide() }
    }

    private func action(_ title: String, symbol: String, color: Color?, action: MacCallAction, context: MacCallContext) -> some View {
        Button { perform(action, context) } label: {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color == nil ? Color.primary : Color.white)
                .frame(width: 34, height: 34)
                .background(color ?? Color.primary.opacity(0.08), in: Circle())
        }
        .buttonStyle(.plain).help(title).accessibilityLabel(title)
        .disabled(!enabled(action, context))
        .opacity(enabled(action, context) ? 1 : 0.4)
    }
}
