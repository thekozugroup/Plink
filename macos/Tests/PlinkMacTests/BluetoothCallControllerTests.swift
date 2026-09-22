import Foundation
import Testing
@testable import PlinkMac

@MainActor
struct BluetoothCallControllerTests {
    private let address = "AA:BB:CC:DD:EE:01"

    @Test func initialSetupWaitsForSettlementAndConsumesBeforeReentrantPresentation() {
        let setup = BluetoothCallSetup()
        let id = UUID()
        var current = true
        var opened = 0
        setup.queueInitialSetup(id: id, isCurrent: { current }) {
            opened += 1
            setup.drainInitialSetup(ready: true)
        }
        setup.drainInitialSetup(ready: false) // Old disconnect/return is still owned.
        #expect(opened == 0)
        setup.drainInitialSetup(ready: true)
        setup.drainInitialSetup(ready: true)
        setup.queueInitialSetup(id: id, isCurrent: { true }) { opened += 1 }
        setup.drainInitialSetup(ready: true)
        #expect(opened == 1)
        setup.queueInitialSetup(id: UUID(), isCurrent: { current }) { opened += 1 }
        current = false
        setup.drainInitialSetup(ready: true)
        #expect(opened == 1)
    }

    @Test func cancellationAndBackgroundSettlementNeverOpenInitialChooser() {
        let setup = BluetoothCallSetup()
        var opened = 0
        setup.drainInitialSetup(ready: true)
        setup.queueInitialSetup(id: UUID(), isCurrent: { true }) { opened += 1 }
        setup.cancel()
        setup.drainInitialSetup(ready: true)
        #expect(opened == 0)
    }

    @Test func staleInitialRequestCannotReplaceNewPendingIntent() {
        let setup = BluetoothCallSetup()
        var opened = 0
        setup.queueInitialSetup(id: UUID(), isCurrent: { true }) { opened += 1 }
        setup.queueInitialSetup(id: UUID(), isCurrent: { false }) { opened += 100 }
        setup.drainInitialSetup(ready: true)
        #expect(opened == 1)
    }

    @Test func scopedAssociationRemovalPreservesOtherPhoneAndNewerMapping() throws {
        let suite = "PlinkAssociationTest-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["pixel": "pixel-address", "oneplus": "old-address"], forKey: "plink.bluetoothPeers")
        #expect(!BluetoothCallController.removeAssociation(peerID: "oneplus", expectedAddress: "stale-address", defaults: defaults))
        #expect(BluetoothCallController.removeAssociation(peerID: "oneplus", expectedAddress: "old-address", defaults: defaults))
        #expect(defaults.dictionary(forKey: "plink.bluetoothPeers") as? [String: String] == ["pixel": "pixel-address"])
    }

    @Test func catalogDeduplicatesCanonicalAddressesButNeverNames() {
        let phones = BluetoothCallSetup.candidates([
            BluetoothPhone(id: "aa-bb-cc-dd-ee-01", name: "Phone"),
            BluetoothPhone(id: address, name: "Phone"),
            BluetoothPhone(id: "AA:BB:CC:DD:EE:02", name: "Phone"),
            BluetoothPhone(id: "invalid", name: "Phone"),
            BluetoothPhone(id: "00:00:00:00:00:00", name: "Phone"),
            BluetoothPhone(id: "AA:BB:CC:DD:EE:03", name: "Phone", isPaired: false),
            BluetoothPhone(id: "AA:BB:CC:DD:EE:04", name: "Phone", supportsCalls: false)
        ])
        #expect(phones.map(\.id) == [address, "AA:BB:CC:DD:EE:02"])
        #expect(BluetoothCallSetup.matchingSavedPhone("aa-bb-cc-dd-ee-01", in: phones)?.id == address)
        #expect(BluetoothCallSetup.matchingSavedPhone("not-an-address", in: phones) == nil)
    }

    @Test func exactNameStillRequiresExplicitChoiceAndKeepsSingleFlight() throws {
        let setup = BluetoothCallSetup()
        var complete: (@MainActor ([BluetoothPhone]) -> Void)?
        var reads = 0
        var selections = 0
        var commits: [BluetoothPhone] = []
        func begin() {
            setup.begin(phoneName: "Phone", readCatalog: { reads += 1; complete = $0 },
                choose: { _ in selections += 1; return BluetoothPhone(id: address, name: "Chosen phone") }, isCurrent: { true }, validate: { _ in true },
                commit: { commits.append($0) })
        }
        begin()
        begin()
        #expect(setup.inProgress)
        #expect(reads == 1)
        #expect(commits.isEmpty)
        let completion = try #require(complete)
        completion([BluetoothPhone(id: address, name: "Phone"),
                    BluetoothPhone(id: "aa-bb-cc-dd-ee-01", name: "Phone")])
        completion([BluetoothPhone(id: address, name: "Phone")])
        #expect(!setup.inProgress)
        #expect(selections == 1)
        #expect(commits.map(\.id) == [address])
    }

    @Test(arguments: ["exact", "alias", "case", "blank", "ambiguous", "unpaired", "non-hfp", "none"])
    func everyInitialAssociationRequiresChooser(reason: String) {
        let setup = BluetoothCallSetup()
        let phoneName = reason == "alias" ? "CPH2749" : reason == "blank" ? "" : "Phone"
        var candidates = [BluetoothPhone(id: address,
            name: reason == "alias" ? "OnePlus 15" : reason == "case" ? "phone" : reason == "blank" ? "" : "Phone",
            isPaired: reason != "unpaired", supportsCalls: reason != "non-hfp")]
        if reason == "ambiguous" { candidates.append(BluetoothPhone(id: "AA:BB:CC:DD:EE:02", name: "Phone")) }
        if reason == "none" { candidates = [] }
        var choices = 0
        var commits = 0
        setup.begin(phoneName: phoneName, readCatalog: { $0(candidates) },
            choose: { _ in choices += 1; return nil }, isCurrent: { true }, validate: { _ in true },
            commit: { _ in commits += 1 })
        #expect(choices == 1)
        #expect(commits == 0)
        #expect(!setup.inProgress)
    }

    @Test func chooserUsesValidatedCommitPath() {
        let setup = BluetoothCallSetup()
        var validations = 0
        var commits: [BluetoothPhone] = []
        setup.begin(phoneName: "CPH2749", readCatalog: { $0([BluetoothPhone(id: address, name: "OnePlus 15")]) },
            choose: { _ in BluetoothPhone(id: "aa-bb-cc-dd-ee-01", name: "OnePlus 15") }, isCurrent: { true },
            validate: { _ in validations += 1; return true }, commit: { commits.append($0) })
        #expect(validations == 1)
        #expect(commits.map(\.id) == [address])
    }

    @Test func bondedPopupRequiresChoiceAndBindsExactSnapshotRecord() {
        let snapshot = BluetoothCallSetup.candidates([
            BluetoothPhone(id: address, name: "Phone"),
            BluetoothPhone(id: "aa-bb-cc-dd-ee-01", name: "Phone"),
            BluetoothPhone(id: "AA:BB:CC:DD:EE:02", name: "Phone")
        ])
        #expect(snapshot.count == 2)
        for index in [-1, 0, 3, Int.max] {
            #expect(BluetoothCallSetup.bondedChoice(in: snapshot, popupIndex: index) == nil)
        }
        #expect(BluetoothCallSetup.bondedChoice(in: [], popupIndex: 1) == nil)
        let setup = BluetoothCallSetup()
        var commits: [String] = []
        setup.begin(phoneName: "Phone", readCatalog: { $0(snapshot) },
            choose: { _ in BluetoothCallSetup.bondedChoice(in: snapshot, popupIndex: 2) },
            isCurrent: { true }, validate: { _ in true }, commit: { commits.append($0.id) })
        #expect(commits == ["AA:BB:CC:DD:EE:02"])
    }

    @Test(arguments: ["cancel", "no-choice", "stale", "token", "bond", "capability"])
    func bondedConfirmationRejectsCancelledOrInvalidatedChoice(reason: String) {
        let setup = BluetoothCallSetup()
        let snapshot = BluetoothCallSetup.candidates([BluetoothPhone(id: address, name: "Phone")])
        var current = true
        var commits = 0
        setup.begin(phoneName: "Phone", readCatalog: { $0(snapshot) }, choose: { _ in
            if reason == "cancel" { return nil }
            if reason == "stale" { current = false }
            if reason == "token" { setup.cancel() }
            return BluetoothCallSetup.bondedChoice(in: snapshot, popupIndex: reason == "no-choice" ? 0 : 1)
        }, isCurrent: { current }, validate: { _ in reason != "bond" && reason != "capability" },
        commit: { _ in commits += 1 })
        #expect(commits == 0)
    }

    @Test(arguments: ["peer", "generation", "call", "busy", "quarantine", "cancel"])
    func heldSetupRejectsStaleOrCancelledCompletion(reason: String) throws {
        let setup = BluetoothCallSetup()
        var current = true
        var complete: (@MainActor ([BluetoothPhone]) -> Void)?
        var choices = 0
        var commits = 0
        setup.begin(phoneName: "Phone", readCatalog: { complete = $0 },
            choose: { _ in choices += 1; return nil }, isCurrent: { current }, validate: { _ in true },
            commit: { _ in commits += 1 })
        let completion = try #require(complete)
        if reason == "cancel" { setup.cancel() } else { current = false }
        completion([BluetoothPhone(id: address, name: "Phone")])
        #expect(choices == 0)
        #expect(commits == 0)
        #expect(!setup.inProgress)
    }

    @Test func modalSelectionAndBondRecheckCannotCommitStaleResults() {
        for staleDuringSelection in [false, true] {
            let setup = BluetoothCallSetup()
            var current = true
            var commits = 0
            setup.begin(phoneName: "Phone", readCatalog: { $0([]) }, choose: { _ in
                if staleDuringSelection { current = false }
                return BluetoothPhone(id: address, name: "Selected")
            }, isCurrent: { current }, validate: { _ in false }, commit: { _ in commits += 1 })
            #expect(commits == 0)
        }
    }

    @Test(arguments: ["current", "cancelled", "superseded"])
    func pairingRouteRechecksOwnerAfterBondedModal(outcome: String) {
        let setup = BluetoothCallSetup()
        var current = true
        var canOpenPairing = false
        setup.begin(phoneName: "Phone", readCatalog: { $0([]) }, choose: { isCurrent in
            #expect(isCurrent())
            if outcome == "cancelled" { setup.cancel() }
            if outcome == "superseded" { current = false }
            canOpenPairing = isCurrent()
            return nil
        }, isCurrent: { current }, validate: { _ in true }, commit: { _ in
            Issue.record("Choosing the pairing route must not commit a bonded phone.")
        })
        #expect(canOpenPairing == (outcome == "current"))
    }

    @Test func backgroundCatalogAndSavedLookupDoNotInvokeSetup() {
        let setup = BluetoothCallSetup()
        let phones = BluetoothCallSetup.candidates([BluetoothPhone(id: address, name: "Renamed")])
        #expect(BluetoothCallSetup.matchingSavedPhone("aa-bb-cc-dd-ee-01", in: phones)?.name == "Renamed")
        #expect(!setup.inProgress)
    }

    @Test(arguments: ["committed", "failed", "cancelled", "restored", "superseded"])
    func freshPairingContinuationRequiresCurrentCommittedOwner(outcome: String) async {
        var current = outcome == "committed" || outcome == "superseded" || outcome == "cancelled"
        var calls = 0
        let task = BluetoothCallSetup.afterPairingCommit(isCurrent: { current }, setup: { calls += 1 })
        if outcome == "superseded" { current = false }
        if outcome == "cancelled" { task.cancel() }
        await task.value
        #expect(calls == (outcome == "committed" ? 1 : 0))
    }
}
