package app.plink.android.notifications

import org.junit.Assert.*
import org.junit.Test

class NotificationActionInputPolicyTest {
    @Test fun olderTextFailsClosedWithoutCallingUnavailableAccessor() {
        for (sdk in listOf(26, 30)) {
            assertEquals("unsupported_input", NotificationActionInputPolicy.reason(sdk, true) { error("Unavailable accessor") })
        }
    }
    @Test fun noInputNeverRequiresMutabilityAcrossSupportedVersions() {
        for (sdk in listOf(26, 30, 31, 36)) {
            assertNull(NotificationActionInputPolicy.reason(sdk, false) { error("No-input accessor must not run") })
        }
    }
    @Test fun boundaryTextUsesRealMutabilityResult() {
        for (sdk in listOf(31, 36)) {
            var reads = 0
            assertNull(NotificationActionInputPolicy.reason(sdk, true) { reads++; false })
            assertEquals("immutable_input", NotificationActionInputPolicy.reason(sdk, true) { reads++; true })
            assertEquals(2, reads)
        }
    }
}
