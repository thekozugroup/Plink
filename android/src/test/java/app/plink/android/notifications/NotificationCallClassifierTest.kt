package app.plink.android.notifications

import org.junit.Assert.*
import org.junit.Test

class NotificationCallClassifierTest {
    @Test fun categoryNeedsNoExtrasAndTemplateIsExact() {
        assertTrue(NotificationCallClassifier.isCall("call") { error("Must not read extras") })
        assertTrue(NotificationCallClassifier.isCall(null) { key ->
            if (key == "android.template") "android.app.Notification\$CallStyle" else error("Must short circuit")
        })
        for (template in listOf(null, "CallStyle", "android.app.Notification\$CallStyleExtra", 1, true,
            StringBuilder("android.app.Notification\$CallStyle"))) {
            assertFalse(NotificationCallClassifier.isCall(null) { key -> if (key == "android.template") template else null })
        }
    }

    @Test fun onlyRecognizedIntegerTypesAddCallClassification() {
        for (type in listOf(1, 2, 3)) {
            assertTrue(NotificationCallClassifier.isCall("msg") { key -> if (key == "android.callType") type else null })
        }
        for (type in listOf(null, -1, 0, 4, 99, "1", 1L, 1.0, true, intArrayOf(1))) {
            assertFalse(NotificationCallClassifier.isCall("voicemail") { key -> if (key == "android.callType") type else null })
        }
    }

    @Test fun malformedReadsDoNotThrowOrHideIndependentPositiveMarker() {
        assertFalse(NotificationCallClassifier.isCall(null) { throw IllegalStateException("Synthetic unreadable Bundle") })
        assertTrue(NotificationCallClassifier.isCall(null) { key ->
            if (key == "android.template") throw ClassCastException("Synthetic wrong type") else 1
        })
        assertNull(NotificationCallClassifier.callType { throw IllegalStateException("Synthetic unreadable Bundle") })
    }

    @Test fun typedReadPreservesExistingUnknownIntegerLifecycleHandling() {
        assertEquals(99, NotificationCallClassifier.callType { 99 })
        assertNull(NotificationCallClassifier.callType { "1" })
        assertNull(NotificationCallClassifier.callType { 1L })
    }

    @Test fun ordinaryVoicemailAndMessageMetadataIsNotCallAuthority() {
        for (category in listOf(null, "voicemail", "msg", "email", "status")) {
            assertFalse(NotificationCallClassifier.isCall(category) { null })
        }
    }
}
