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
