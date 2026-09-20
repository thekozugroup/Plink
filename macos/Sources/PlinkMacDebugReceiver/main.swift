import AppKit
import Foundation
import PlinkCore

setbuf(stdout, nil)

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
let fileRoundtrip = receiverMode == "files"
let screenRoundtrip = receiverMode == "screen"
let reconnectRoundtrip = receiverMode == "reconnect"
let replyPort = UInt16(ProcessInfo.processInfo.environment["PLINK_DEBUG_REPLY_PORT"] ?? "0") ?? 0
if (roundtrip || fileRoundtrip || screenRoundtrip || reconnectRoundtrip) &&
    (pairedDeviceId != "test-pixel" || targetDeviceId != "test-mac" || replyPort == 0) {
    throw DebugReceiverError.missingEnvironment("Isolated test identities and reply port are required")
}
if reconnectRoundtrip {
    Task.detached {
        do {
            try await ReconnectRoundtrip.run(sessionKey: sessionKey, pairedDeviceID: pairedDeviceId,
                targetDeviceID: targetDeviceId, receiverPort: port, replyPort: replyPort)
            exit(0)
        } catch {
            fputs("reconnect roundtrip failed: \(error)\n", stderr)
            exit(1)
        }
    }
    dispatchMain()
}
let semaphore = DispatchSemaphore(value: 0)
let exitState = ExitState()

let codec = EncryptedFrameCodec(sessionKey: sessionKey)
let frameState = InMemoryFrameStateStore()
let screenHarness = screenRoundtrip ? ScreenRoundtripHarness(codec: codec, frameState: frameState,
    replyPort: replyPort, evidenceDirectory: URL(fileURLWithPath: try environment("PLINK_DEBUG_SCREEN_EVIDENCE_DIR"))) { passed in
        if !passed { exitState.fail() }
        semaphore.signal()
    } : nil
let fileHarness = fileRoundtrip ? FileRoundtripHarness(codec: codec, frameState: frameState, replyPort: replyPort) { passed in
    if !passed { exitState.fail() }
    semaphore.signal()
} : nil
fileHarness?.start()
screenHarness?.start()
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
        if let screenHarness { screenHarness.receive(envelope); return }
        if let fileHarness { fileHarness.receive(envelope); return }
        if roundtrip {
            if let context = ReplyRouter.context(from: envelope) {
                Task {
                    do {
                        let reply = try ReplyRouter.makeReplyEnvelope(context: context,
                            text: "\t  Plink encrypted roundtrip ✓\nCafe\u{0301} 👩‍💻\n  ", id: "mac-roundtrip-reply")
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
if semaphore.wait(timeout: .now() + (fileRoundtrip ? 920 : screenRoundtrip ? 95 : 30)) == .timedOut {
    fputs("receiver timed out\n", stderr)
    exitState.fail()
}
server.stop()
fileHarness?.stop()
screenHarness?.stop()
exit(exitState.code)
