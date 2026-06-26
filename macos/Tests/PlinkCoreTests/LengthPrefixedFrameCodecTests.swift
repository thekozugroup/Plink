import Foundation
import PlinkCore
import Testing

@Test
func lengthPrefixedFrameRoundTrips() throws {
    let payload = Data("encrypted-frame".utf8)
    let encoded = try LengthPrefixedFrameCodec.encode(payload)

    #expect(try LengthPrefixedFrameCodec.decode(encoded) == payload)
}

@Test
func emptyLengthPrefixedFrameFailsClosed() throws {
    #expect(throws: NetworkPlinkServerError.self) {
        _ = try LengthPrefixedFrameCodec.encode(Data())
    }
}

@Test
func expectedLengthWaitsForCompletePayload() throws {
    let payload = Data("encrypted-frame".utf8)
    let encoded = try LengthPrefixedFrameCodec.encode(payload)
    let partial = encoded.prefix(6)

    #expect(try LengthPrefixedFrameCodec.expectedTotalLength(Data(encoded.prefix(2))) == nil)
    #expect(try LengthPrefixedFrameCodec.expectedTotalLength(Data(partial)) == encoded.count)
    #expect(throws: NetworkPlinkServerError.self) {
        _ = try LengthPrefixedFrameCodec.decode(Data(partial))
    }
}
