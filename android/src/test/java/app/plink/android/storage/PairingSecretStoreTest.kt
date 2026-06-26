package app.plink.android.storage

import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PairingSecretStoreTest {
    @Test
    fun inMemorySecretStoreCopiesAndRemovesSessionKeys() = runTest {
        val store = InMemoryPairingSecretStore()
        val key = byteArrayOf(1, 2, 3)

        store.save(key, "session")
        key[0] = 9

        assertArrayEquals(byteArrayOf(1, 2, 3), store.load("session"))
        store.remove("session")
        assertNull(store.load("session"))
    }
}
