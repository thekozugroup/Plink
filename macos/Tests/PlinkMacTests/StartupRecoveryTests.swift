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
}
