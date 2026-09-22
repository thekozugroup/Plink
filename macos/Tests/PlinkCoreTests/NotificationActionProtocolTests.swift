import Foundation
import Testing
@testable import PlinkCore

struct NotificationActionProtocolTests {
    @Test func androidProducedOffersUseProductionValidators() throws {
        struct Capture: Decodable { let schemaVersion: Int; let offers: [String] }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let file = root.appendingPathComponent("shared/protocol/v1/notification-actions/android-produced-offers.json")
        let capture = try JSONDecoder().decode(Capture.self, from: Data(contentsOf: file))
        #expect(capture.schemaVersion == 1)
        #expect(!capture.offers.isEmpty)
        for (index, rawEnvelope) in capture.offers.enumerated() {
            // Preserve Android's exact wire bytes and issuance timestamps, including tombstones.
            // Relative issuance TTL is validated here; injected-clock tests cover live expiry.
            let envelope = try PlinkEnvelope.decode(Data(rawEnvelope.utf8))
            try PayloadPolicy.validate(envelope)
            let offer = NotificationActionOffer(envelope)
            #expect(offer != nil, Comment(rawValue: "Android-produced offer at index \(index)"))
        }
    }

    @Test func sharedRawWireCasesUseProductionValidators() throws {
        struct Fixture: Decodable { let cases: [Case] }
        struct Case: Decodable { let name: String; let kind: String; let valid: Bool; let rawEnvelope: String }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let file = root.appendingPathComponent("shared/protocol/v1/notification-actions/v1-cases.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: file))
        #expect(fixture.cases.count >= 77)
        for item in fixture.cases {
            if item.kind == "offer" || item.kind == "legacy" {
                let envelope = try PlinkEnvelope.decode(Data(item.rawEnvelope.utf8))
                try PayloadPolicy.validate(envelope)
                #expect((NotificationActionOffer(envelope) != nil) == (item.kind == "offer" && item.valid), Comment(rawValue: item.name))
            } else {
                var accepted = false
                do {
                    let envelope = try PlinkEnvelope.decode(Data(item.rawEnvelope.utf8))
                    try PayloadPolicy.validate(envelope)
                    accepted = true
                } catch {}
                #expect(accepted == item.valid, Comment(rawValue: item.name))
            }
        }
    }
}
