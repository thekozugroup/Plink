import Foundation
import Testing
@testable import PlinkMac

@MainActor
struct ClipboardSyncControllerTests {
    @Test func syncDoesNotReplayInactiveContentAndSuppressesOnlyRemoteRevision() async throws {
        let (defaults, suiteName) = testDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let pasteboard = ClipboardPasteboardSpy(text: "before setup")
        let controller = makeController(defaults: defaults, pasteboard: pasteboard)
        let recorder = ClipboardSendRecorder()
        controller.onTextChanged = { recorder.sent.append($0) }

        controller.pollOnce()
        #expect(pasteboard.readCount == 0)
        #expect(pasteboard.changeCountReadCount == 0)

        controller.setEnabled(true)
        #expect(defaults.bool(forKey: ClipboardSyncController.enabledKey))
        controller.setConnected(true)
        controller.pollOnce()
        #expect(pasteboard.readCount == 0)
        #expect(recorder.sent.isEmpty)

        pasteboard.replaceLocally(with: "local")
        controller.pollOnce()
        try await eventually { recorder.sent == ["local"] }
        #expect(recorder.sent == ["local"])

        #expect(controller.receive("remote"))
        controller.pollOnce()
        await settleMainActor()
        #expect(recorder.sent == ["local"])

        pasteboard.replaceLocally(with: "remote")
        controller.pollOnce()
        try await eventually { recorder.sent == ["local", "remote"] }
        #expect(recorder.sent == ["local", "remote"])

        controller.setConnected(false)
        pasteboard.replaceLocally(with: "while disconnected")
        controller.pollOnce()
        controller.setConnected(true)
        controller.pollOnce()
        #expect(recorder.sent == ["local", "remote"])

        let readsBeforeLock = pasteboard.readCount
        let changeCountReadsBeforeLock = pasteboard.changeCountReadCount
        pasteboard.unlocked = false
        pasteboard.replaceLocally(with: "while locked")
        controller.pollOnce()
        #expect(pasteboard.readCount == readsBeforeLock)
        #expect(pasteboard.changeCountReadCount == changeCountReadsBeforeLock)
        pasteboard.unlocked = true
        controller.pollOnce()
        #expect(recorder.sent == ["local", "remote"])

        controller.setEnabled(false)
        #expect(!controller.receive("disabled"))
        controller.setEnabled(true)
        #expect(controller.receive("enabled"))
        controller.setConnected(false)
        #expect(!controller.receive("disconnected"))
        controller.setConnected(true)
        pasteboard.unlocked = false
        #expect(!controller.receive("locked"))
        #expect(pasteboard.writeCount == 2)
    }

    @Test func concealedBlankAndOversizedTextAreRefused() async {
        let (defaults, suiteName) = testDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let pasteboard = ClipboardPasteboardSpy(text: "baseline")
        let controller = makeController(defaults: defaults, pasteboard: pasteboard)
        let recorder = ClipboardSendRecorder()
        controller.onTextChanged = { recorder.sent.append($0) }
        controller.setEnabled(true)
        controller.setConnected(true)
        controller.pollOnce()

        pasteboard.replaceLocally(
            with: "secret",
            typeNames: ["org.nspasteboard.ConcealedType"]
        )
        controller.pollOnce()

        pasteboard.replaceLocally(with: " \n\t ")
        controller.pollOnce()
        await settleMainActor()
        #expect(recorder.sent.isEmpty)
        #expect(!controller.receive(String(repeating: "x", count: 32_769)))
        #expect(pasteboard.writeCount == 0)
    }

    @Test func changedRevisionDiscardsRacedSnapshotAndRemoteWrite() async throws {
        let (defaults, suiteName) = testDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let pasteboard = ClipboardPasteboardSpy(text: "baseline")
        let controller = makeController(defaults: defaults, pasteboard: pasteboard)
        let recorder = ClipboardSendRecorder()
        controller.onTextChanged = { recorder.sent.append($0) }
        controller.setEnabled(true)
        controller.setConnected(true)
        controller.pollOnce()

        pasteboard.replaceLocally(with: "stale")
        pasteboard.afterRead = { pasteboard.replaceLocally(with: "latest") }
        controller.pollOnce()
        await settleMainActor()
        #expect(recorder.sent.isEmpty)

        controller.pollOnce()
        try await eventually { recorder.sent == ["latest"] }

        pasteboard.afterWrite = { pasteboard.replaceLocally(with: "local overwrite") }
        #expect(!controller.receive("remote"))
        controller.pollOnce()
        try await eventually { recorder.sent == ["latest", "local overwrite"] }
    }

    @Test func deferredSendRechecksUnlockedState() async {
        let (defaults, suiteName) = testDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let pasteboard = ClipboardPasteboardSpy(text: "baseline")
        let controller = makeController(defaults: defaults, pasteboard: pasteboard)
        let recorder = ClipboardSendRecorder()
        controller.onTextChanged = { recorder.sent.append($0) }
        controller.setEnabled(true)
        controller.setConnected(true)
        controller.pollOnce()

        pasteboard.replaceLocally(with: "must not send")
        controller.pollOnce()
        pasteboard.unlocked = false
        await settleMainActor()

        #expect(recorder.sent.isEmpty)
    }

    @Test func pendingSendIsCanceledByLatestTextAndEveryOffState() async throws {
        let (defaults, suiteName) = testDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let pasteboard = ClipboardPasteboardSpy(text: "baseline")
        let controller = makeController(defaults: defaults, pasteboard: pasteboard)
        let recorder = ClipboardSendRecorder()
        controller.onTextChanged = { text in try await recorder.block(text) }
        controller.setEnabled(true)
        controller.setConnected(true)
        controller.pollOnce()

        pasteboard.replaceLocally(with: "first")
        controller.pollOnce()
        try await eventually { recorder.started.contains("first") }
        pasteboard.replaceLocally(with: "latest")
        controller.pollOnce()
        try await eventually { recorder.cancelled.contains("first") && recorder.started.contains("latest") }

        pasteboard.replaceLocally(with: "  \n")
        controller.pollOnce()
        try await eventually { recorder.cancelled.contains("latest") }

        pasteboard.replaceLocally(with: "receive pending")
        controller.pollOnce()
        try await eventually { recorder.started.contains("receive pending") }
        #expect(controller.receive("remote"))
        try await eventually { recorder.cancelled.contains("receive pending") }

        pasteboard.replaceLocally(with: "disable")
        controller.pollOnce()
        try await eventually { recorder.started.contains("disable") }
        controller.setEnabled(false)
        try await eventually { recorder.cancelled.contains("disable") }

        controller.setEnabled(true)
        controller.pollOnce()
        pasteboard.replaceLocally(with: "disconnect")
        controller.pollOnce()
        try await eventually { recorder.started.contains("disconnect") }
        controller.setConnected(false)
        try await eventually { recorder.cancelled.contains("disconnect") }

        controller.setConnected(true)
        controller.pollOnce()
        pasteboard.replaceLocally(with: "lock")
        controller.pollOnce()
        try await eventually { recorder.started.contains("lock") }
        pasteboard.unlocked = false
        controller.pollOnce()
        try await eventually { recorder.cancelled.contains("lock") }

        pasteboard.unlocked = true
        controller.pollOnce()
        pasteboard.replaceLocally(with: "stop")
        controller.pollOnce()
        try await eventually { recorder.started.contains("stop") }
        controller.stop()
        try await eventually { recorder.cancelled.contains("stop") }
    }

    private func makeController(
        defaults: UserDefaults,
        pasteboard: ClipboardPasteboardSpy
    ) -> ClipboardSyncController {
        ClipboardSyncController(
            defaults: defaults,
            isUnlocked: { pasteboard.unlocked },
            changeCount: { pasteboard.readChangeCount() },
            readContent: { pasteboard.read() },
            writeText: { text in pasteboard.write(text) }
        )
    }

    private func testDefaults() -> (UserDefaults, String) {
        let suiteName = "ClipboardSyncControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}

@MainActor
private final class ClipboardPasteboardSpy {
    var changeCount = 1
    var text: String
    var typeNames: Set<String> = []
    var unlocked = true
    var readCount = 0
    var changeCountReadCount = 0
    var writeCount = 0
    var afterRead: (() -> Void)?
    var afterWrite: (() -> Void)?

    init(text: String) {
        self.text = text
    }

    func replaceLocally(with text: String, typeNames: Set<String> = []) {
        self.text = text
        self.typeNames = typeNames
        changeCount += 1
    }

    func readChangeCount() -> Int {
        changeCountReadCount += 1
        return changeCount
    }

    func read() -> ClipboardSyncController.PasteboardContent {
        readCount += 1
        let content = ClipboardSyncController.PasteboardContent(
            text: text,
            typeNames: typeNames
        )
        let action = afterRead
        afterRead = nil
        action?()
        return content
    }

    func write(_ text: String) -> (success: Bool, changeCount: Int) {
        self.text = text
        typeNames = []
        writeCount += 1
        changeCount += 1
        let writtenChangeCount = changeCount
        let action = afterWrite
        afterWrite = nil
        action?()
        return (true, writtenChangeCount)
    }
}

@MainActor
private final class ClipboardSendRecorder {
    var sent: [String] = []
    var started: [String] = []
    var cancelled: [String] = []

    func block(_ text: String) async throws {
        started.append(text)
        do {
            try await Task.sleep(for: .seconds(60))
        } catch {
            cancelled.append(text)
            throw error
        }
    }
}

@MainActor
private func settleMainActor() async {
    for _ in 0..<5 {
        await Task.yield()
    }
}

@MainActor
private func eventually(
    timeout: Duration = .seconds(1),
    _ condition: @escaping @MainActor () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        guard clock.now < deadline else { throw CancellationError() }
        await Task.yield()
    }
}
