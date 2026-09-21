import Foundation
import Testing
@testable import PlinkMac

@MainActor
struct BluetoothCallControllerTests {
    private let address = "AA:BB:CC:DD:EE:01"

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

    @Test func explicitExactNameSetupCommitsOnceAfterCatalogAndKeepsSingleFlight() throws {
        let setup = BluetoothCallSetup()
        var complete: (@MainActor ([BluetoothPhone]) -> Void)?
        var reads = 0
        var selections = 0
        var commits: [BluetoothPhone] = []
        func begin() {
            setup.begin(phoneName: "Phone", readCatalog: { reads += 1; complete = $0 },
                choose: { selections += 1; return nil }, isCurrent: { true }, validate: { _ in true },
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
        #expect(selections == 0)
        #expect(commits.map(\.id) == [address])
    }

    @Test(arguments: ["alias", "case", "blank", "ambiguous", "unpaired", "non-hfp", "none"])
    func nonExactOrUnusableCandidatesRetainChooser(reason: String) {
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
            choose: { choices += 1; return nil }, isCurrent: { true }, validate: { _ in true },
            commit: { _ in commits += 1 })
        #expect(choices == 1)
        #expect(commits == 0)
        #expect(!setup.inProgress)
    }

    @Test func chooserAndShortcutUseSameValidatedCommitPath() {
        let setup = BluetoothCallSetup()
        var validations = 0
        var commits: [BluetoothPhone] = []
        setup.begin(phoneName: "CPH2749", readCatalog: { $0([BluetoothPhone(id: address, name: "OnePlus 15")]) },
            choose: { BluetoothPhone(id: "aa-bb-cc-dd-ee-01", name: "OnePlus 15") }, isCurrent: { true },
            validate: { _ in validations += 1; return true }, commit: { commits.append($0) })
        #expect(validations == 1)
        #expect(commits.map(\.id) == [address])
    }

    @Test(arguments: ["peer", "generation", "call", "busy", "quarantine", "cancel"])
    func heldSetupRejectsStaleOrCancelledCompletion(reason: String) throws {
        let setup = BluetoothCallSetup()
        var current = true
        var complete: (@MainActor ([BluetoothPhone]) -> Void)?
        var choices = 0
        var commits = 0
        setup.begin(phoneName: "Phone", readCatalog: { complete = $0 },
            choose: { choices += 1; return nil }, isCurrent: { current }, validate: { _ in true },
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
            setup.begin(phoneName: "Phone", readCatalog: { $0([]) }, choose: {
                if staleDuringSelection { current = false }
                return BluetoothPhone(id: address, name: "Selected")
            }, isCurrent: { current }, validate: { _ in false }, commit: { _ in commits += 1 })
            #expect(commits == 0)
        }
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
