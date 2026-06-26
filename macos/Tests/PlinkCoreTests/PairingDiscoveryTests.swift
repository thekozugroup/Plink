import CryptoKit
import Foundation
import PlinkCore
import Testing

@Test
func bonjourRecordRoundTripsPairingOffer() throws {
    let key = P256.KeyAgreement.PrivateKey()
    let offer = PairingOffer(
        deviceId: "mac-1",
        deviceName: "MacBook Pro",
        platform: "macos",
        endpoint: "192.168.50.41:45731",
        nonce: "nonce-1",
        publicKey: key.publicKey.derRepresentation.base64EncodedString(),
        targetDeviceId: "pixel-pending"
    )

    let decoded = try PairingBonjour.offer(from: PairingBonjour.txtRecord(for: offer))

    #expect(decoded == offer)
}

@Test
func bonjourRecordFallsBackToResolvedEndpoint() throws {
    let key = P256.KeyAgreement.PrivateKey()
    let offer = PairingOffer(
        deviceId: "mac-1",
        deviceName: "MacBook Pro",
        platform: "macos",
        endpoint: "192.168.50.41:45731",
        nonce: "nonce-1",
        publicKey: key.publicKey.derRepresentation.base64EncodedString(),
        targetDeviceId: "pixel-pending"
    )
    var txtRecord = PairingBonjour.txtRecord(for: offer)
    txtRecord.removeValue(forKey: "endpoint")

    let decoded = try PairingBonjour.offer(
        from: txtRecord,
        endpointHost: "192.168.50.41",
        port: 45731
    )

    #expect(decoded.endpoint == "192.168.50.41:45731")
}

@Test
func bonjourRecordRejectsUnsupportedProtocol() {
    let txtRecord = [
        "plink": Data("1".utf8),
        "protocolVersion": Data("2".utf8)
    ]

    #expect(throws: PairingDiscoveryError.unsupportedProtocol) {
        try PairingBonjour.offer(from: txtRecord)
    }
}
