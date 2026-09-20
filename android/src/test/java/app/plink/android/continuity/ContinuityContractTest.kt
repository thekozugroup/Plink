package app.plink.android.continuity

import app.plink.android.protocol.PlinkEventType
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ContinuityContractTest {
    @Test
    fun mediaStateMatchesFrozenWireContract() {
        val event = MediaStateEvent("opaque", "Title", "Artist", true, true, false, true, false)
        val payload = event.payload()

        assertEquals(PlinkEventType.MediaState, event.type)
        assertEquals("opaque", payload["sessionId"].toString().trim('"'))
        assertTrue(payload["playing"].toString().toBoolean())
        assertFalse(payload["canPause"].toString().toBoolean())
    }

    @Test
    fun sharedTextClassifiesOnlyHttpUrlsAsWebHandoffs() {
        assertTrue(SharedTextClassifier.classify("https://example.com") is SharedText.Web)
        assertTrue(SharedTextClassifier.classify("plain text") is SharedText.Clipboard)
        assertTrue(SharedTextClassifier.classify("javascript:alert(1)") is SharedText.Clipboard)
    }
}
