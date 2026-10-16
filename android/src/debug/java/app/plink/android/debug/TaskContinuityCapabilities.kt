package app.plink.android.debug

import android.companion.CompanionDeviceManager
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import org.json.JSONObject
import java.lang.reflect.Modifier

internal object TaskContinuityCapabilities {
    const val ACTION = "app.plink.android.DEBUG_TASK_CONTINUITY_CAPABILITIES"

    private const val FEATURE_COMPANION_DEVICE_SETUP = "android.software.companion_device_setup"
    private const val SHELL_PACKAGE = "com.android.shell"
    private const val MAX_REPORT_LENGTH = 4096
    private val permissions = listOf(
        "android.permission.READ_REMOTE_TASKS",
        "android.permission.REQUEST_TASK_HANDOFF",
        "android.permission.READ_HANDOFF_SETTINGS",
        "android.permission.MODIFY_HANDOFF_SETTINGS"
    )

    enum class PackageLookup { AVAILABLE, UNAVAILABLE, ERROR }
    data class FlagLookup(val status: String, val value: Int? = null)

    fun permissionStatus(packageLookup: PackageLookup, granted: Boolean): String = when (packageLookup) {
        PackageLookup.AVAILABLE -> if (granted) "granted" else "denied"
        PackageLookup.UNAVAILABLE -> "unavailable_package"
        PackageLookup.ERROR -> "error"
    }

    fun report(context: Context): JSONObject {
        val packageManager = context.packageManager
        val report = JSONObject()
            .put("sdkInt", Build.VERSION.SDK_INT)
            .put("previewSdkInt", Build.VERSION.PREVIEW_SDK_INT)
            .put("featureCompanionDeviceSetup", featureState(packageManager))
            .put("companionDeviceManager", companionServiceState(context))
            .put("flagTaskContinuity", taskContinuityFlag().toJson())

        val permissionReport = JSONObject()
        permissionReport.put(context.packageName, packagePermissions(packageManager, context.packageName))
        permissionReport.put(SHELL_PACKAGE, packagePermissions(packageManager, SHELL_PACKAGE))
        report.put("permissions", permissionReport)
            .put("interpretation", "Capability metadata only; transport and Mac interoperability are unverified.")

        return if (report.toString().length <= MAX_REPORT_LENGTH) {
            report
        } else {
            JSONObject().put("error", "report_too_large")
        }
    }

    private fun featureState(packageManager: PackageManager): String = try {
        if (packageManager.hasSystemFeature(FEATURE_COMPANION_DEVICE_SETUP)) "present" else "absent"
    } catch (_: Exception) {
        "error"
    }

    private fun companionServiceState(context: Context): String = try {
        if (context.getSystemService(CompanionDeviceManager::class.java) != null) "available" else "unavailable"
    } catch (_: Exception) {
        "error"
    }

    internal fun taskContinuityFlag(type: Class<*> = CompanionDeviceManager::class.java): FlagLookup {
        return try {
            val field = type.getField("FLAG_TASK_CONTINUITY")
            if (!Modifier.isPublic(field.modifiers) ||
                !Modifier.isStatic(field.modifiers) ||
                field.type != Int::class.javaPrimitiveType
            ) {
                FlagLookup("lookup_failed")
            } else {
                FlagLookup("present", field.getInt(null))
            }
        } catch (_: NoSuchFieldException) {
            FlagLookup("absent")
        } catch (_: Exception) {
            FlagLookup("lookup_failed")
        } catch (_: LinkageError) {
            FlagLookup("lookup_failed")
        }
    }

    private fun FlagLookup.toJson(): JSONObject = JSONObject().put("status", status).also {
        value?.let { flagValue -> it.put("value", flagValue) }
    }

    private fun packagePermissions(packageManager: PackageManager, packageName: String): JSONObject {
        val lookup = try {
            packageManager.getPackageInfo(packageName, 0)
            PackageLookup.AVAILABLE
        } catch (_: PackageManager.NameNotFoundException) {
            PackageLookup.UNAVAILABLE
        } catch (_: Exception) {
            PackageLookup.ERROR
        }

        val results = JSONObject().put("package", when (lookup) {
            PackageLookup.AVAILABLE -> "available"
            PackageLookup.UNAVAILABLE -> "unavailable_package"
            PackageLookup.ERROR -> "error"
        })
        permissions.forEach { permission ->
            val granted = if (lookup == PackageLookup.AVAILABLE) {
                try {
                    packageManager.checkPermission(permission, packageName) == PackageManager.PERMISSION_GRANTED
                } catch (_: Exception) {
                    results.put(permission, "error")
                    return@forEach
                }
            } else {
                false
            }
            results.put(permission, permissionStatus(lookup, granted))
        }
        return results
    }
}
