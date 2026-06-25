import Foundation
import PlinkCore
import Testing

@Test
func inMemorySecretStoreRoundTripsSessionKey() throws {
    let store = InMemoryPairingSecretStore()
    let key = Data("secret".utf8)

    store.save(sessionKey: key, sessionId: "session")

    #expect(store.load(sessionId: "session") == key)
    store.remove(sessionId: "session")
    #expect(store.load(sessionId: "session") == nil)
}
