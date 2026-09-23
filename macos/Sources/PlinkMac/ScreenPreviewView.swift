import PlinkCore
import SwiftUI

struct ScreenPreviewView: View {
    @ObservedObject var controller: ScreenPreviewController
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Phone Screen").font(.title2)
            Text("View your phone after approving screen sharing in Plink. Protected content may be hidden.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Start Preview") { controller.start() }.disabled(!controller.canStart)
                Button("Stop") { controller.stop(reason: .user) }.disabled(!isActive)
                Spacer()
            }
            ZStack {
                Color.black
                if let image = controller.image {
                    Image(decorative: image, scale: 1)
                        .resizable().scaledToFit()
                        .opacity(controller.snapshot?.isStale == true ? 0.45 : 1)
                } else {
                    Label { Text("No shared screen") } icon: { LucideIcon(name: .monitorOff) }
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(controller.image == nil ? "No shared phone screen" : "Shared phone screen; view only")
            Text(controller.statusText).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("View only. No audio or recording. Switching apps or hiding this window stops sharing.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .padding(.top, 20)
        .background {
            Group {
                if reduceTransparency { Color(nsColor: .windowBackgroundColor) }
                else { FrostedWindowBackground() }
            }.ignoresSafeArea()
        }
        .frame(minWidth: 440, minHeight: 520)
    }

    private var isActive: Bool {
        switch controller.snapshot?.phase {
        case .requesting, .needsConsent, .streaming: return true
        default: return false
        }
    }
}
