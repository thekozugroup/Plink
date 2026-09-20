import SwiftUI

struct ReconnectView: View {
    @ObservedObject var controller: ReconnectController
    var showsStatusAndActions = true

    var body: some View {
        GroupBox("Reconnect \(controller.pairedName)") {
            VStack(alignment: .leading, spacing: 10) {
                if showsStatusAndActions {
                    Text(controller.state.status)
                        .font(.callout)
                        .textSelection(.enabled)
                    HStack {
                        Button("Reconnect") { controller.beginDiscovery() }
                            .disabled(isBusy)
                        if isBusy {
                            ProgressView().controlSize(.small)
                            Button("Cancel") { controller.cancel() }
                        }
                    }
                }
                Text("Keep both devices on the same Wi-Fi, then choose Reconnect.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                DisclosureGroup("Connection help") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("If reconnecting does not work, enter the numeric address shown in Plink on your phone.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            TextField("Phone address", text: $controller.manualIPv4)
                                .textFieldStyle(.roundedBorder)
                            Button("Reconnect with Address") { controller.reconnectManually() }
                                .disabled(isBusy || controller.manualIPv4.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        if !controller.currentAddresses.isEmpty {
                            Text("This Mac: \(controller.currentAddresses.joined(separator: ", "))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    private var isBusy: Bool {
        switch controller.state {
        case .finding, .verifying, .disconnecting: return true
        default: return false
        }
    }
}
