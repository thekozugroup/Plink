package app.plink.android.security

import java.time.Instant
import java.time.temporal.ChronoUnit

object PlinkTime {
    fun canonicalTimestamp(instant: Instant): String = instant.truncatedTo(ChronoUnit.SECONDS).toString()
}
