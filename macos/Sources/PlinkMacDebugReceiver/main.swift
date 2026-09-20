import AppKit
import Foundation
import PlinkCore

enum DebugReceiverError: Error {
    case missingEnvironment(String)
    case invalidSessionKey
}

final class ExitState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCode: Int32 = 0

    func fail() {
        lock.lock()
        storedCode = 1
        lock.unlock()
    }

    var code: Int32 {
        lock.lock()
        defer { lock.unlock() }
        return storedCode
    }
}

func environment(_ key: String) throws -> String {
    guard let value = ProcessInfo.processInfo.environment[key], !value.isEmpty else {
        throw DebugReceiverError.missingEnvironment(key)
    }
    return value
}

let sessionKeyBase64 = try environment("PLINK_DEBUG_SESSION_KEY_BASE64")
guard let sessionKey = Data(base64Encoded: sessionKeyBase64) else {
    throw DebugReceiverError.invalidSessionKey
}

let pairedDeviceId = try environment("PLINK_DEBUG_PAIRED_DEVICE_ID")
let targetDeviceId = ProcessInfo.processInfo.environment["PLINK_DEBUG_TARGET_DEVICE_ID"] ?? "mac-demo"
let port = UInt16(ProcessInfo.processInfo.environment["PLINK_DEBUG_RECEIVER_PORT"] ?? "45731") ?? 45731
let receiverMode = ProcessInfo.processInfo.environment["PLINK_DEBUG_RECEIVER_MODE"] ?? "foundation"
let roundtrip = receiverMode == "roundtrip"
let replyPort = UInt16(ProcessInfo.processInfo.environment["PLINK_DEBUG_REPLY_PORT"] ?? "0") ?? 0
if roundtrip && (pairedDeviceId != "test-pixel" || targetDeviceId != "test-mac" || replyPort == 0) {
    throw DebugReceiverError.missingEnvironment("Isolated test identities and reply port are required")
}
let semaphore = DispatchSemaphore(value: 0)
let exitState = ExitState()

let codec = EncryptedFrameCodec(sessionKey: sessionKey)
let frameState = InMemoryFrameStateStore()
let server: PlinkEventReceiver = if receiverMode == "network" {
    try SecureNetworkPlinkServer(
        port: port,
        codec: codec,
        expectedSourceDeviceId: pairedDeviceId,
        expectedTargetDeviceId: targetDeviceId,
        stateStore: frameState
    )
} else {
    FoundationSecurePlinkServer(
        port: port,
        codec: codec,
        expectedSourceDeviceId: pairedDeviceId,
        expectedTargetDeviceId: targetDeviceId,
        stateStore: frameState
    )
}

try server.start { result in
    switch result {
    case .success(let envelope):
        if roundtrip {
            if let context = ReplyRouter.context(from: envelope) {
                Task {
                    do {
                        let reply = try ReplyRouter.makeReplyEnvelope(context: context,
                            text: "Plink encrypted roundtrip ✓", id: "mac-roundtrip-reply")
                        try await SecureNetworkPlinkClient(host: "127.0.0.1", port: replyPort,
                            codec: codec, stateStore: frameState).send(reply)
                        print("roundtrip: authenticated Android message; Swift reply sent")
                    } catch {
                        fputs("roundtrip reply failed: \(error)\n", stderr)
                        exitState.fail()
                        semaphore.signal()
                    }
                }
            } else if envelope.type == .ack,
                      envelope.payload["eventId"]?.stringValue == "mac-roundtrip-reply",
                      envelope.payload["status"]?.stringValue == "executed" {
                print("ROUNDTRIP PASSED: Android RemoteInput execution acknowledged over encrypted transport")
                semaphore.signal()
            } else {
                fputs("roundtrip: unexpected event \(envelope.type)\n", stderr)
                exitState.fail()
                semaphore.signal()
            }
            return
        }
        if let action = HandoffPlanner.action(for: envelope) {
            switch action.kind {
            case .clipboard(let text):
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            case .openURL, .fileOffer:
                break
            }
        }
        print("received type=\(envelope.type.rawValue) source=\(envelope.sourceDeviceId) target=\(envelope.targetDeviceId)")
    case .failure(let error):
        fputs("receiver error: \(error)\n", stderr)
        // Port forwarding may probe with an empty connection. Production receivers
        // likewise discard invalid clients and continue accepting authenticated frames.
        return
    }
    semaphore.signal()
}

print("listening mode=\(receiverMode) port=\(port) expectedSource=\(pairedDeviceId) expectedTarget=\(targetDeviceId)")
if semaphore.wait(timeout: .now() + 30) == .timedOut {
    fputs("receiver timed out\n", stderr)
    exitState.fail()
}
server.stop()
exit(exitState.code)
