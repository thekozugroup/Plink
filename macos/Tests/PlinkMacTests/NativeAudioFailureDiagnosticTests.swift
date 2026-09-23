import Foundation
import IOKit
import Testing
@testable import PlinkMac

struct NativeAudioFailureDiagnosticTests {
    @Test func onlyFirstOwnedUnsupportedFailureConsumesCapture() {
        var diagnostic = NativeAudioFailureDiagnostic()
        let results = [diagnostic.shouldCapture(owned: false, status: kIOReturnUnsupported),
                       diagnostic.shouldCapture(owned: true, status: nil),
                       diagnostic.shouldCapture(owned: true, status: 0),
                       diagnostic.shouldCapture(owned: true, status: -1),
                       diagnostic.shouldCapture(owned: true, status: kIOReturnUnsupported),
                       diagnostic.shouldCapture(owned: true, status: kIOReturnUnsupported)]
        #expect(results == [false, false, false, false, true, false])
    }

    @Test func outputContainsOnlyBoundedRelativeLocationsForMatchingImage() {
        let base: UInt = 0x100000000
        let uuid = UUID()
        let frames = [NativeAudioFailureDiagnostic.Frame(address: base + 0x99, imageBase: base + 1),
                      .init(address: base - 1, imageBase: base)] +
            (1...20).map { .init(address: base + UInt($0), imageBase: base) }
        let record = NativeAudioFailureDiagnostic.normalized(imageUUID: uuid, imageBase: base,
            frames: frames, transferInProgress: true)
        #expect(record.offsets == Array(1...8).map(UInt.init))
        #expect(record.logLine == "calls.audio.native_failure state=ready image_uuid=\(uuid.uuidString) relative_pcs=1,2,3,4,5,6,7,8 transfer_in_progress=true")
        #expect(!record.logLine.contains(String(base, radix: 16)))
        let lateMatch = Array(repeating: NativeAudioFailureDiagnostic.Frame(address: 200, imageBase: 100), count: 64)
            + [.init(address: base + 7, imageBase: base)]
        #expect(NativeAudioFailureDiagnostic.normalized(imageUUID: uuid, imageBase: base,
            frames: lateMatch, transferInProgress: false).offsets.isEmpty)
    }

    @Test func unavailableMetadataNeverFallsBackToRawLocations() {
        let frames = [NativeAudioFailureDiagnostic.Frame(address: 0x100001234, imageBase: 0x100000000)]
        for base: UInt? in [nil, 0, 0x100000000] {
            let record = NativeAudioFailureDiagnostic.normalized(imageUUID: nil, imageBase: base,
                frames: frames, transferInProgress: false)
            #expect(record.imageUUID == nil)
            #expect(record.offsets.isEmpty)
            #expect(record.logLine == "calls.audio.native_failure state=image_unavailable image_uuid=unavailable relative_pcs= transfer_in_progress=false")
        }
        let record = NativeAudioFailureDiagnostic.capture(transferInProgress: false)
        #expect(record.imageUUID != nil)
        #expect(record.offsets.count <= 8)
        #expect(!record.logLine.contains("/"))
        #expect(!record.logLine.contains("0x"))
    }
}
