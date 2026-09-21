import Foundation
import PlinkCore
import Security
import Testing
@testable import PlinkMac

struct StartupRecoveryTests {
    @Test func pendingKeyAccessStaysUnknownAndUsesConditionalPromptCopy() {
        var state = StartupRecoveryState()
        let attempt = UUID()
        #expect(!state.complete)
        #expect(state.error == nil)
        #expect(state.menuStatus == "Restoring your saved connection…")
        let accepted = state.publish(.keyAccess, expectedAttempt: attempt, currentAttempt: attempt, terminating: false)
        #expect(accepted)
        #expect(!state.complete)
        #expect(state.detail == "Checking your saved connection. If macOS asks for permission, review the request.")
        #expect(state.menuStatus != "No phone paired")
    }

    @Test func missingAndInvalidFakeKeysCannotProduceReady() {
        #expect(StartupRecoveryState.keyFailure(nil) == .missingKey)
        for size in [0, 16, 31, 33] {
            #expect(StartupRecoveryState.keyFailure(Data(repeating: 7, count: size)) == .invalidKey)
        }
        #expect(StartupRecoveryState.keyFailure(Data(repeating: 7, count: 32)) == nil)
        let attempt = UUID()
        var state = StartupRecoveryState()
        for failure in [StartupRecoveryState.Failure.missingKey, .invalidKey] {
            let accepted = state.publish(.failed(failure), expectedAttempt: attempt, currentAttempt: attempt, terminating: false)
            #expect(accepted)
            #expect(!state.complete)
            #expect(state.error == state.detail)
            #expect(!state.detail.contains("Unlock"))
            #expect(state.menuStatus == "Saved connection needs attention")
        }
    }

    @Test func returnedFakeKeychainErrorsHaveTruthfulDistinctStates() {
        #expect(StartupRecoveryState.keychainFailure(KeychainSecretStoreError.status(errSecUserCanceled)) == .accessCancelled)
        #expect(StartupRecoveryState.keychainFailure(KeychainSecretStoreError.status(errSecAuthFailed)) == .accessDenied)
        #expect(StartupRecoveryState.keychainFailure(KeychainSecretStoreError.status(errSecInteractionNotAllowed)) == .accessUnavailable)
        #expect(StartupRecoveryState.keychainFailure(KeychainSecretStoreError.status(errSecNotAvailable)) == .accessUnavailable)
        #expect(StartupRecoveryState.keychainFailure(KeychainSecretStoreError.status(-12345)) == .keyUnreadable)
    }

    @Test func absentPairingAndSavedRecordsWithoutSelectionAreDifferent() {
        var state = StartupRecoveryState()
        let attempt = UUID()
        let unpaired = state.publish(.unpaired, expectedAttempt: attempt, currentAttempt: attempt, terminating: false)
        #expect(unpaired)
        #expect(state.complete)
        #expect(state.menuStatus == "No phone paired")
        let needsPairing = state.publish(.needsPairing, expectedAttempt: attempt, currentAttempt: attempt, terminating: false)
        #expect(needsPairing)
        #expect(state.complete)
        #expect(state.menuStatus == "Choose your phone again")
        #expect(state.detail == "Pair your phone again to choose it.")
    }

    @Test func staleAndTerminatingPublicationsCannotReplaceCurrentPhase() {
        var state = StartupRecoveryState()
        let attempt = UUID()
        let accepted = state.publish(.keyAccess, expectedAttempt: attempt, currentAttempt: attempt, terminating: false)
        #expect(accepted)
        for phase in [StartupRecoveryState.Phase.ready, .failed(.keyUnreadable), .unpaired, .restoring] {
            let stale = state.publish(phase, expectedAttempt: attempt, currentAttempt: UUID(), terminating: false)
            #expect(!stale)
            #expect(state.phase == .keyAccess)
            let terminating = state.publish(phase, expectedAttempt: attempt, currentAttempt: attempt, terminating: true)
            #expect(!terminating)
            #expect(state.phase == .keyAccess)
        }
    }
    @MainActor @Test func heldRecoveryWarnsWithoutStartingAnotherWorkerAndAcceptsLateSuccess() async throws {
        let worker = HeldStartupStep()
        let timer = HeldStartupStep()
        let owner = StartupRecoveryOperation(sleep: { _ in await timer.hold() })
        let attempt = UUID()
        let probe = StartupRecoveryProbe()
        var starts = 0
        let started: Task<Void, Never>? = owner.start(isCurrent: { true }, onSlow: { probe.state.markDelayed() },
            onFinish: { probe.state.clearDelayed() }, work: {
                await worker.hold()
                _ = await MainActor.run {
                    probe.state.publish(.ready, expectedAttempt: attempt, currentAttempt: attempt, terminating: false)
                }
            })
        let task = try #require(started)
        starts += 1
        await worker.waitUntilEntered()
        await timer.waitUntilEntered()
        let watchdog = owner.watchdogTask
        await timer.release()
        await watchdog?.value
        #expect(probe.state.isDelayed)
        #expect(!probe.state.complete)
        #expect(probe.state.error == nil)
        #expect(!probe.state.showsProgress)
        #expect(probe.state.detail == "Restoring your saved connection is taking longer than expected. Plink is still trying. You can wait, or quit and reopen Plink.")
        for _ in 0..<3 {
            let duplicate = owner.start(isCurrent: { true }, onSlow: {}, onFinish: {}, work: {})
            if duplicate != nil { starts += 1 }
            #expect(duplicate == nil)
        }
        #expect(starts == 1)
        #expect(owner.isRunning)
        await worker.release()
        await task.value
        #expect(probe.state.phase == .ready)
        #expect(!probe.state.isDelayed)
        #expect(!owner.isRunning)
    }

    @MainActor @Test(arguments: [false, true])
    func invalidatedRecoveryKeepsOwnershipUntilReturnAndRejectsLateWork(terminating: Bool) async throws {
        let worker = HeldStartupStep()
        let timer = HeldStartupStep()
        let owner = StartupRecoveryOperation(sleep: { _ in await timer.hold() })
        let attempt = UUID()
        let probe = StartupRecoveryProbe()
        probe.currentAttempt = attempt
        let started: Task<Void, Never>? = owner.start(
            isCurrent: { probe.currentAttempt == attempt && !probe.isTerminating },
            onSlow: { probe.state.markDelayed() }, onFinish: { probe.state.clearDelayed() }, work: {
                await worker.hold() // Also models rollback: gate acquired before any worker stage.
                await MainActor.run {
                    if probe.state.publish(.ready, expectedAttempt: attempt, currentAttempt: probe.currentAttempt,
                                     terminating: probe.isTerminating) { probe.admitted += 1 }
                }
            })
        let task = try #require(started)
        await worker.waitUntilEntered()
        await timer.waitUntilEntered()
        let oldTimer = owner.watchdogTask
        if terminating { probe.isTerminating = true } else { probe.currentAttempt = UUID() }
        owner.cancelWatchdog()
        let duplicate = owner.start(isCurrent: { true }, onSlow: {}, onFinish: {}, work: {})
        #expect(duplicate == nil)
        #expect(owner.isRunning)
        await worker.release()
        await task.value
        #expect(probe.admitted == 0)
        #expect(!probe.state.complete)
        #expect(!owner.isRunning)
        // Start another owned operation only after the old worker has actually exited.
        let nextWorker = HeldStartupStep()
        let nextStarted: Task<Void, Never>? = owner.start(isCurrent: { true }, onSlow: {}, onFinish: {}, work: {
            await nextWorker.hold()
        })
        let next = try #require(nextStarted)
        await nextWorker.waitUntilEntered()
        await timer.release()
        await oldTimer?.value
        #expect(owner.isRunning) // Stale timer cannot clear the replacement's ownership.
        #expect(!probe.state.isDelayed)
        await nextWorker.release()
        await next.value
    }

    @MainActor @Test func terminalPublicationAndWorkerReturnInvalidateLateTimer() async throws {
        let worker = HeldStartupStep()
        let timer = HeldStartupStep()
        let owner = StartupRecoveryOperation(sleep: { _ in await timer.hold() })
        let attempt = UUID()
        let probe = StartupRecoveryProbe()
        let started: Task<Void, Never>? = owner.start(isCurrent: { true }, onSlow: { probe.state.markDelayed() },
            onFinish: { probe.state.clearDelayed() }, work: { await worker.hold() })
        let task = try #require(started)
        await worker.waitUntilEntered()
        await timer.waitUntilEntered()
        let oldTimer = owner.watchdogTask
        probe.state.markDelayed()
        let accepted = probe.state.publish(.failed(.accessDenied), expectedAttempt: attempt,
                                     currentAttempt: attempt, terminating: false)
        #expect(accepted)
        #expect(!probe.state.isDelayed)
        owner.cancelWatchdog()
        #expect(owner.isRunning)
        await worker.release()
        await task.value
        await timer.release()
        await oldTimer?.value
        #expect(probe.state.phase == .failed(.accessDenied))
        #expect(!probe.state.isDelayed)
        #expect(!owner.isRunning)
    }

}


private actor HeldStartupStep {
    private var entered = false
    private var released = false
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var held: [CheckedContinuation<Void, Never>] = []

    func hold() async {
        entered = true
        observers.forEach { $0.resume() }
        observers.removeAll()
        if !released { await withCheckedContinuation { held.append($0) } }
    }

    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { observers.append($0) } }
    }

    func release() {
        released = true
        held.forEach { $0.resume() }
        held.removeAll()
    }
}

@MainActor
private final class StartupRecoveryProbe {
    var state = StartupRecoveryState()
    var currentAttempt = UUID()
    var isTerminating = false
    var admitted = 0
}
