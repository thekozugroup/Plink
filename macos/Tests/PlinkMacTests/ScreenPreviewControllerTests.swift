import Foundation
import CoreGraphics
import ImageIO
import PlinkCore
import Testing
import UniformTypeIdentifiers
@testable import PlinkMac

@MainActor
struct ScreenPreviewControllerTests {
    @Test func decodedPixelsDisappearImmediatelyWhenPreviewStops() async throws {
        let wire = PreviewTestTransport()
        let sender = SerializedPlinkSender(transport: wire)
        let controller = ScreenPreviewController(isAppActive: { true })
        let generation = UUID(), streamID = UUID().uuidString.lowercased()
        let ingress = ScreenPreviewIngress()
        controller.bind(localID: "mac", peerID: "phone", generation: generation, sender: sender)
        controller.setVisible(true)
        controller.start()
        let requestID = try #require(controller.snapshot?.requestID)
        _ = try await wire.next()
        func receive(_ message: ScreenPreviewMessage) throws {
            let envelope = message.envelope(sourceDeviceID: "phone", targetDeviceID: "mac")
            let admission = try #require(ingress.admit(envelope, expectedSourceDeviceID: "phone",
                expectedTargetDeviceID: "mac", connectionGeneration: generation))
            let previewGeneration = controller.admissionGeneration.current() ?? UUID()
            controller.receive(envelope, admission: admission, previewGeneration: previewGeneration)
        }
        try receive(.started(requestID: requestID, streamID: streamID))
        #expect(try await wire.next().type == .screenPull)
        let jpeg = try syntheticJPEG()
        try receive(.frame(.init(requestID: requestID, streamID: streamID, index: 1,
                                width: 8, height: 8, jpegData: jpeg)))
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while controller.image == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(controller.image?.width == 8)
        #expect(controller.snapshot?.hasPresentedFrame == true)
        controller.stop(reason: .user)
        #expect(controller.image == nil)
        #expect(controller.snapshot?.phase == .stopped(.user))
        // A valid late frame from the terminal stream cannot republish pixels.
        try receive(.frame(.init(requestID: requestID, streamID: streamID, index: 2,
                                width: 8, height: 8, jpegData: jpeg)))
        #expect(controller.image == nil)
        await controller.shutdown()
        await sender.shutdown()
    }

    @Test func hidingStopsSynchronouslyAndReopeningNeedsExplicitStart() async throws {
        let wire = PreviewTestTransport()
        let sender = SerializedPlinkSender(transport: wire)
        let controller = ScreenPreviewController(isAppActive: { true })
        let generation = UUID()
        controller.bind(localID: "mac", peerID: "phone", generation: generation, sender: sender)
        controller.setVisible(true)
        controller.start()
        #expect(controller.snapshot?.phase == .requesting)
        let requestID = try #require(controller.snapshot?.requestID)
        let request = try await wire.next()
        #expect(request.type == .screenRequest)

        let pending = ScreenPreviewMessage.needsConsent(requestID: requestID)
            .envelope(sourceDeviceID: "phone", targetDeviceID: "mac")
        let ingress = ScreenPreviewIngress()
        let token = try #require(ingress.admit(pending, expectedSourceDeviceID: "phone",
            expectedTargetDeviceID: "mac", connectionGeneration: generation))
        controller.receive(pending, admission: token, previewGeneration: try #require(controller.admissionGeneration.current()))
        #expect(controller.snapshot?.phase == .needsConsent)
        controller.setVisible(false)
        #expect(controller.snapshot?.phase == .stopped(.hidden))
        #expect(controller.image == nil)
        #expect(!controller.canStart)
        controller.setVisible(true)
        #expect(controller.snapshot?.requestID == nil)
        #expect(controller.snapshot?.phase == .stopped(.hidden))
        let stop = try await wire.next()
        #expect(stop.type == .screenStop)
        #expect(stop.payload["requestId"]?.stringValue == requestID)
        await controller.shutdown()
        #expect(await wire.remainingCount == 0)
        await sender.shutdown()
    }

    @Test func staleConnectionRejectionCannotEndReplacementPreview() async throws {
        let wire = PreviewTestTransport()
        let sender = SerializedPlinkSender(transport: wire)
        let controller = ScreenPreviewController(isAppActive: { true })
        let oldGeneration = UUID(), currentGeneration = UUID()
        controller.bind(localID: "mac", peerID: "phone", generation: currentGeneration, sender: sender)
        controller.setVisible(true)
        controller.start()
        let requestID = try #require(controller.snapshot?.requestID)
        _ = try await wire.next()
        let rejection = AuthenticatedScreenProtocolRejection(peerDeviceID: "phone", requestID: requestID, streamID: nil)
        let ingress = ScreenPreviewIngress()
        let oldToken = try #require(ingress.admit(rejection, expectedPeerDeviceID: "phone", connectionGeneration: oldGeneration))
        controller.receive(rejection, admission: oldToken, previewGeneration: try #require(controller.admissionGeneration.current()))
        #expect(controller.snapshot?.phase == .requesting)
        let currentToken = try #require(ingress.admit(rejection, expectedPeerDeviceID: "phone", connectionGeneration: currentGeneration))
        controller.receive(rejection, admission: currentToken, previewGeneration: try #require(controller.admissionGeneration.current()))
        #expect(controller.snapshot?.phase == .stopped(.protocolError))
        #expect(controller.image == nil)
        await controller.shutdown()
        await sender.shutdown()
    }

    @Test func disabledOrInactivePreviewCannotStart() async {
        let wire = PreviewTestTransport()
        let sender = SerializedPlinkSender(transport: wire)
        let controller = ScreenPreviewController(isAppActive: { false })
        controller.bind(localID: "mac", peerID: "phone", generation: UUID(), sender: sender)
        controller.setVisible(true)
        controller.start()
        #expect(controller.snapshot?.phase == .idle)
        controller.setEnabled(false)
        #expect(!controller.canStart)
        controller.start()
        #expect(controller.snapshot?.requestID == nil)
        #expect(await wire.remainingCount == 0)
        await controller.shutdown()
        await sender.shutdown()
    }

    @Test func queuedAmbiguousRejectionCannotCrossLocalStartAndQuitIsTerminal() async throws {
        let wire = PreviewTestTransport()
        let sender = SerializedPlinkSender(transport: wire)
        let controller = ScreenPreviewController(isAppActive: { true })
        let connection = UUID()
        controller.bind(localID: "mac", peerID: "phone", generation: connection, sender: sender)
        controller.setVisible(true)
        controller.start()
        _ = try await wire.next()
        let oldEpoch = try #require(controller.admissionGeneration.current())
        let rejection = AuthenticatedScreenProtocolRejection(peerDeviceID: "phone", requestID: nil, streamID: nil)
        let ingress = ScreenPreviewIngress()
        let queued = try #require(ingress.admit(rejection, expectedPeerDeviceID: "phone", connectionGeneration: connection))
        controller.stop(reason: .user)
        _ = try await wire.next()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !controller.canStart && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(controller.canStart)
        controller.start()
        _ = try await wire.next()
        let replacementEpoch = try #require(controller.admissionGeneration.current())
        #expect(replacementEpoch != oldEpoch)
        controller.receive(rejection, admission: queued, previewGeneration: oldEpoch)
        #expect(controller.snapshot?.phase == .requesting)
        controller.beginShutdown()
        #expect(controller.admissionGeneration.current() == nil)
        controller.setVisible(true)
        controller.setEnabled(true)
        controller.start()
        #expect(!controller.canStart)
        #expect(controller.snapshot?.requestID == nil)
        await controller.shutdown()
        await sender.shutdown()
    }
}

private func syntheticJPEG() throws -> Data {
    let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
        bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

private actor PreviewTestTransport: DeadlinePlinkTransport {
    private var messages: [PlinkEnvelope] = []
    var remainingCount: Int { messages.count }
    func send(_ envelope: PlinkEnvelope) { messages.append(envelope) }
    func send(_ envelope: PlinkEnvelope, timeout: TimeInterval) { messages.append(envelope) }

    func next() async throws -> PlinkEnvelope {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while messages.isEmpty {
            if ContinuousClock.now >= deadline { throw PreviewTestTimeout() }
            try await Task.sleep(for: .milliseconds(5))
        }
        return messages.removeFirst()
    }
}

private struct PreviewTestTimeout: Error {}
