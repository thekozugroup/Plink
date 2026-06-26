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
let semaphore = DispatchSemaphore(value: 0)
let exitState = ExitState()

let codec = EncryptedFrameCodec(sessionKey: sessionKey)
let server: PlinkEventReceiver = if receiverMode == "network" {
    try SecureNetworkPlinkServer(
        port: port,
        codec: codec,
        expectedSourceDeviceId: pairedDeviceId,
        expectedTargetDeviceId: targetDeviceId
    )
} else {
    FoundationSecurePlinkServer(
        port: port,
        codec: codec,
        expectedSourceDeviceId: pairedDeviceId,
        expectedTargetDeviceId: targetDeviceId
    )
}

try server.start { result in
    switch result {
    case .success(let envelope):
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
        return
    }
    semaphore.signal()
}

print("listening mode=\(receiverMode) port=\(port) expectedSource=\(pairedDeviceId) expectedTarget=\(targetDeviceId)")
semaphore.wait()
server.stop()
exit(exitState.code)
