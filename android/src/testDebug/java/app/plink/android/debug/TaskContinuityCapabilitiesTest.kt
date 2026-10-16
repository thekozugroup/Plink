package app.plink.android.debug

import org.junit.Assert.assertEquals
import org.junit.Test

class TaskContinuityCapabilitiesTest {
    class PublicStaticFlag {
        companion object {
            @JvmField
            val FLAG_TASK_CONTINUITY = 2
        }
    }

    class PublicInstanceFlag {
        @JvmField
        val FLAG_TASK_CONTINUITY = 2
    }

    @Test
    fun flagLookupDistinguishesPresentAbsentAndInvalidFields() {
        assertEquals(TaskContinuityCapabilities.FlagLookup("present", 2), TaskContinuityCapabilities.taskContinuityFlag(PublicStaticFlag::class.java))
        assertEquals(TaskContinuityCapabilities.FlagLookup("absent"), TaskContinuityCapabilities.taskContinuityFlag(Any::class.java))
        assertEquals(TaskContinuityCapabilities.FlagLookup("lookup_failed"), TaskContinuityCapabilities.taskContinuityFlag(PublicInstanceFlag::class.java))
    }

    @Test
    fun permissionStatusDistinguishesPackageAndGrantOutcomes() {
        assertEquals("granted", TaskContinuityCapabilities.permissionStatus(TaskContinuityCapabilities.PackageLookup.AVAILABLE, true))
        assertEquals("denied", TaskContinuityCapabilities.permissionStatus(TaskContinuityCapabilities.PackageLookup.AVAILABLE, false))
        assertEquals("unavailable_package", TaskContinuityCapabilities.permissionStatus(TaskContinuityCapabilities.PackageLookup.UNAVAILABLE, false))
        assertEquals("error", TaskContinuityCapabilities.permissionStatus(TaskContinuityCapabilities.PackageLookup.ERROR, false))
    }
}
