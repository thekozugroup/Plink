package app.plink.android.clipboard

import android.content.ClipData
import android.content.ClipDescription
import android.os.Binder
import android.os.Bundle
import android.os.IBinder
import android.os.Process
import androidx.annotation.Keep
import java.lang.reflect.Method
import kotlin.system.exitProcess

/** Shizuku constructs this Binder in a non-daemon shell process, not an Android Service. */
@Keep
class ShizukuClipboardService : IClipboardReader.Stub() {
    private var clipboard: Any? = null
    private var readMethod: Method? = null

    override fun readClipboard(): Bundle {
        if (Binder.getCallingUid() / 100_000 != 0) return Bundle().apply { putString(STATUS, UNAVAILABLE) }
        // Outgoing system Binder calls must use the helper's shell identity, not the app caller.
        val identity = Binder.clearCallingIdentity()
        return try {
            check(Process.myUid() == 2000) { "Shell identity required." }
            // Deliberately support only the personal profile. The client refuses every other user.
            val userId = 0
            val currentUser = Class.forName("android.app.ActivityManager")
                .getMethod("getCurrentUser").invoke(null) as Int
            check(currentUser == userId) { "Personal profile is not foreground." }
            val service = clipboard ?: run {
                val binder = Class.forName("android.os.ServiceManager")
                    .getMethod("getService", String::class.java).invoke(null, "clipboard") as IBinder
                requireNotNull(Class.forName("android.content.IClipboard\$Stub")
                    .getMethod("asInterface", IBinder::class.java).invoke(null, binder))
                    .also { clipboard = it }
            }
            val method = readMethod ?: findReadMethod(service).also { readMethod = it }
            val args: Array<Any?> = when (method.parameterTypes.toList()) {
                listOf(String::class.java) -> arrayOf(SHELL_PACKAGE)
                listOf(String::class.java, Int::class.javaPrimitiveType) -> arrayOf(SHELL_PACKAGE, userId)
                listOf(String::class.java, String::class.java, Int::class.javaPrimitiveType) ->
                    arrayOf(SHELL_PACKAGE, null, userId)
                else -> arrayOf(SHELL_PACKAGE, null, userId, 0) // Default device clipboard.
            }
            val clip = method.invoke(service, *args) as ClipData?
            snapshot(clip)
        } catch (_: ReflectiveOperationException) {
            Bundle().apply { putString(STATUS, UNAVAILABLE) }
        } catch (_: RuntimeException) {
            Bundle().apply { putString(STATUS, UNAVAILABLE) }
        } finally {
            Binder.restoreCallingIdentity(identity)
        }
    }

    private fun findReadMethod(service: Any): Method {
        // AOSP IClipboard and scrcpy v2.7 document these Android signatures:
        // https://github.com/Genymobile/scrcpy/blob/v2.7/server/src/main/java/com/genymobile/scrcpy/wrappers/ClipboardManager.java
        val intType = Integer.TYPE
        val signatures = listOf(
            arrayOf(String::class.java, String::class.java, intType, intType),
            arrayOf(String::class.java, String::class.java, intType),
            arrayOf(String::class.java, intType),
            arrayOf(String::class.java)
        )
        for (signature in signatures) {
            try { return service.javaClass.getMethod("getPrimaryClip", *signature) }
            catch (_: NoSuchMethodException) { /* Try the next documented signature. */ }
        }
        throw NoSuchMethodException("Unsupported clipboard API")
    }

    private fun snapshot(clip: ClipData?): Bundle = Bundle().apply {
        putString(STATUS, OK)
        if (clip == null || clip.itemCount != 1) return@apply
        val description = clip.description
        putLong(TIMESTAMP, description.timestamp)
        val sensitive = description.extras?.getBoolean(ClipDescription.EXTRA_IS_SENSITIVE, false) == true
        putBoolean(SENSITIVE, sensitive)
        // Password copies marked sensitive never cross this Binder boundary.
        if (sensitive || !description.hasMimeType(ClipDescription.MIMETYPE_TEXT_PLAIN)) return@apply
        val text = clip.getItemAt(0).text?.toString() ?: return@apply
        if (!ClipboardSyncPolicy.acceptable(text)) return@apply
        putString(TEXT, text)
        putString(ORIGIN, description.extras?.getString(ORIGIN))
    }

    override fun destroy() { exitProcess(0) }

    companion object {
        private const val SHELL_PACKAGE = "com.android.shell"
        const val STATUS = "status"
        const val OK = "ok"
        const val UNAVAILABLE = "unavailable"
        const val TEXT = "text"
        const val TIMESTAMP = "timestamp"
        const val SENSITIVE = "sensitive"
        const val ORIGIN = "app.plink.android.clipboard.origin"
    }
}
