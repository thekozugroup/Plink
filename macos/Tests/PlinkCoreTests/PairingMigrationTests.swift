import Foundation
import Testing
@testable import PlinkCore

@Test func legacyTrustDoesNotAcquireDurableTransportVersion() throws {
    let old = Data(#"{"id":"pixel","name":"Pixel","platform":"android","endpoint":"localhost:45731","sessionId":"old","peerPublicKey":"peer","localPublicKey":"local","trusted":true}"#.utf8)
    var device = try JSONDecoder().decode(PairedDevice.self, from: old)
    #expect(device.securityVersion == 0)
    device.securityVersion = 2
    #expect(try JSONDecoder().decode(PairedDevice.self, from: JSONEncoder().encode(device)).securityVersion == 2)
}
