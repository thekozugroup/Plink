import AppKit
import AVFoundation
import PlinkCore
import SwiftUI

struct PixelWebcamView: View {
    @ObservedObject private var controller: PixelWebcamController

    init(controller: PixelWebcamController) {
        _controller = ObservedObject(wrappedValue: controller)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Pixel USB Webcam")
                .font(.title2)
            Text("Connect a data cable, choose Use USB for Webcam on the Pixel, then select the external camera that appears here.")
                .fixedSize(horizontal: false, vertical: true)

            Picker("External camera", selection: deviceSelection) {
                Text("Select an external camera").tag("")
                ForEach(controller.devices) { device in
                    Text(device.displayName).tag(device.uniqueID)
                }
            }
            .pickerStyle(.menu)
            .disabled(controller.state == .stopping)
            .accessibilityLabel("External camera")

            if controller.state == .permissionNeeded {
                Button("Allow Camera") {
                    controller.requestCameraPermission()
                }
                .accessibilityLabel("Allow camera access")
            } else if controller.state == .denied {
                Text("Enable Camera access for Plink in System Settings before trying again.")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Start Preview") {
                    controller.start()
                }
                .disabled(!controller.canStart)
                .accessibilityLabel("Start external camera preview")

                Button("Stop") {
                    controller.stop(reason: .userRequested)
                }
                .disabled(!canStop)
                .accessibilityLabel("Stop external camera preview")
            }

            PixelWebcamPreviewHostView(controller: controller, previewLayer: controller.previewLayer)
                .frame(minWidth: 640, minHeight: 360)
                .background(Color.black)
                .accessibilityLabel("External camera preview")

            Text(controller.statusText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .frame(minWidth: 680, minHeight: 560)
        .onAppear {
            controller.activate()
        }
        .onDisappear {
            controller.deactivate()
        }
    }

    private var deviceSelection: Binding<String> {
        Binding(
            get: { controller.selectedDeviceID ?? "" },
            set: { uniqueID in
                guard !uniqueID.isEmpty else { return }
                controller.selectDevice(uniqueID: uniqueID)
            }
        )
    }

    private var canStop: Bool {
        controller.state == .starting || controller.state == .previewing
    }
}

@MainActor
final class PixelWebcamPreviewHost: NSView {
    private var displayedPreviewLayer: AVCaptureVideoPreviewLayer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        nil
    }

    func setPreviewLayer(_ previewLayer: AVCaptureVideoPreviewLayer?) {
        guard displayedPreviewLayer !== previewLayer else { return }
        displayedPreviewLayer?.removeFromSuperlayer()
        displayedPreviewLayer = previewLayer
        guard let previewLayer else { return }
        layer?.addSublayer(previewLayer)
        previewLayer.frame = bounds
    }

    override func layout() {
        super.layout()
        displayedPreviewLayer?.frame = bounds
    }
}

@MainActor
private struct PixelWebcamPreviewHostView: NSViewRepresentable {
    let controller: PixelWebcamController
    let previewLayer: AVCaptureVideoPreviewLayer?

    func makeNSView(context: Context) -> PixelWebcamPreviewHost {
        let host = PixelWebcamPreviewHost(frame: .zero)
        controller.attachPreviewHost(host)
        return host
    }

    func updateNSView(_ nsView: PixelWebcamPreviewHost, context: Context) {
        controller.attachPreviewHost(nsView)
        nsView.setPreviewLayer(previewLayer)
    }
}
