import SwiftUI

struct PairingView: View {
    @ObservedObject var appDelegate: AppDelegate

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                LucideIcon(name: appDelegate.pairingCompleted ? .circleCheck : .smartphone, size: 36)
                    .foregroundStyle(appDelegate.pairingCompleted ? Color.green : Color.accentColor)
                VStack(alignment: .leading, spacing: 5) {
                    Text(appDelegate.pairingCompleted ? "Phone paired" : "Connect your phone")
                        .font(.title.weight(.semibold))
                    Text(appDelegate.pairingCompleted ? "Bluetooth for calls." : "Wi-Fi for sharing. Bluetooth for calls.")
                        .foregroundStyle(.secondary)
                }
            }

            if appDelegate.pairingCompleted {
                CallingSetupStep(controller: appDelegate.calling, phoneName: appDelegate.pairedPhoneName ?? "your phone",
                                 finish: appDelegate.finishSetup)
            } else if let code = appDelegate.pairingVerificationCode {
                Text("Do these match your phone?").font(.headline)
                VStack(spacing: 14) {
                    Text(code.emoji.joined(separator: "  ")).font(.system(size: 40))
                    Text(code.numeric).font(.system(size: 32, weight: .semibold, design: .rounded).monospacedDigit())
                    Text(code.labels.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(22)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
                Text(appDelegate.pairingStatusText)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Cancel") { appDelegate.cancelPairing(); appDelegate.finishSetup() }
                    Spacer()
                    if appDelegate.pairingInFlight { ProgressView().controlSize(.small) }
                    Button("Codes Match — Connect") {
                        Task {
                            do { try await appDelegate.confirmManualPairing() }
                            catch { appDelegate.pairingStatusText = "Couldn’t finish pairing. Try again on both devices." }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!appDelegate.canConfirmPairing)
                }
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    Label { Text("Open Plink on your phone") } icon: { LucideIcon(name: .smartphone) }
                    Label { Text("Choose this Mac") } icon: { LucideIcon(name: .laptop) }
                    Label { Text("Confirm the matching code") } icon: { LucideIcon(name: .shieldCheck) }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                HStack(spacing: 10) {
                    if appDelegate.isPairing { ProgressView().controlSize(.small) }
                    Text(appDelegate.pairingStatusText).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Cancel") { appDelegate.cancelPairing(); appDelegate.finishSetup() }
                    Spacer()
                    Button("Try Again") { appDelegate.startNearbyPairing() }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(28).frame(width: 500, height: 490)
        .background(.ultraThinMaterial)
    }
}

private struct CallingSetupStep: View {
    @ObservedObject var controller: BluetoothCallController
    let phoneName: String
    let finish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label { Text("\(phoneName) is paired with Plink") } icon: { LucideIcon(name: .circleCheck) }
                .foregroundStyle(.green)
            if controller.bluetoothPaired {
                Label { Text("Bluetooth paired") } icon: { LucideIcon(name: .circleCheck) }
                    .foregroundStyle(.green)
                Text(controller.serviceConnected ? "Calls connected. Your phone can now report incoming calls." : "Calls are disconnected. Reconnect when your phone is nearby.")
            } else {
                Text("Select the same phone in the Bluetooth window. Confirm any code shown on both devices.")
            }
            if controller.busy { ProgressView("Connecting calls…") }
            Text(controller.status).font(.callout).foregroundStyle(.secondary)
            HStack {
                if !controller.serviceConnected {
                    Button(controller.bluetoothPaired ? "Reconnect Calls" : "Connect Calls") { controller.beginSetup(phoneName: phoneName) }
                        .disabled(controller.busy || controller.blocked)
                }
                if controller.bluetoothPaired {
                    Button("Done", action: finish).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                } else {
                    Button("Not Now", action: finish)
                }
            }
        }
    }
}
