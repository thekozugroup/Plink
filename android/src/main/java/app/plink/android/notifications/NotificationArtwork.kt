package app.plink.android.notifications

import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Rect
import android.graphics.drawable.Drawable
import app.plink.android.protocol.PlinkEnvelope
import app.plink.android.protocol.PlinkEventType
import app.plink.android.security.PayloadPolicy
import java.io.ByteArrayOutputStream
import java.util.Base64
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull

/** Optional source-package decoration. Never reads notification imagery or changes action identity. */
internal object NotificationArtwork {
    const val iconPixels = 96
    const val maxPngBytes = 16_384
    const val maxBase64Characters = 21_848
    const val nameField = "sourceAppName"
    const val iconField = "sourceAppIconPng"

    data class Metadata(val name: String? = null, val iconPng: String? = null) {
        override fun toString() = "Metadata(namePresent=${name != null}, iconPresent=${iconPng != null})"
    }

    fun read(packageManager: PackageManager, packageName: String): Metadata = read(
        loadName = {
            @Suppress("DEPRECATION")
            val application = packageManager.getApplicationInfo(packageName, 0)
            packageManager.getApplicationLabel(application)
        },
        renderIcon = { render(packageManager.getApplicationIcon(packageName)) }
    )

    /** Separate providers keep lookup/render failure independent and make the bounds testable. */
    internal fun read(loadName: () -> CharSequence?, renderIcon: () -> ByteArray?): Metadata {
        val name = runCatching { cleanName(loadName()?.toString()) }.getOrNull()
        val png = runCatching { renderIcon() }.getOrNull()
        val icon = png?.takeIf { it.isNotEmpty() && it.size <= maxPngBytes }
            ?.let { Base64.getEncoder().encodeToString(it) }
            ?.takeIf { it.length <= maxBase64Characters }
        return Metadata(name, icon)
    }

    internal fun cleanName(raw: String?): String? {
        if (raw == null) return null
        val result = StringBuilder()
        var offset = 0
        var scalars = 0
        while (offset < raw.length && scalars < 80) {
            val point = raw.codePointAt(offset)
            offset += Character.charCount(point)
            val type = Character.getType(point)
            if (Character.isISOControl(point) || type == Character.FORMAT.toInt() ||
                type == Character.LINE_SEPARATOR.toInt() || type == Character.PARAGRAPH_SEPARATOR.toInt() ||
                type == Character.SURROGATE.toInt()
            ) continue
            result.appendCodePoint(point)
            scalars++
        }
        return result.toString().trim().takeIf { it.isNotEmpty() }
    }

    fun decorate(envelope: PlinkEnvelope, load: () -> Metadata): PlinkEnvelope {
        if (envelope.type !in setOf(PlinkEventType.MessageReceived, PlinkEventType.CallRinging) ||
            (envelope.payload["removed"] as? JsonPrimitive)?.booleanOrNull == true
        ) return envelope
        val metadata = runCatching(load).getOrNull() ?: return envelope
        val optional = mutableMapOf<String, JsonPrimitive>()
        metadata.name?.let { optional[nameField] = JsonPrimitive(it) }
        metadata.iconPng?.let { optional[iconField] = JsonPrimitive(it) }
        fun candidate() = envelope.copy(payload = JsonObject(envelope.payload + optional))
        fun fits(value: PlinkEnvelope) = value.encode().toByteArray(Charsets.UTF_8).size <= PayloadPolicy.maxEnvelopeBytes
        var decorated = candidate()
        if (fits(decorated)) return decorated
        optional.remove(iconField)
        decorated = candidate()
        return if (fits(decorated)) decorated else envelope
    }

    internal fun render(drawable: Drawable): ByteArray? {
        val bitmap = Bitmap.createBitmap(iconPixels, iconPixels, Bitmap.Config.ARGB_8888)
        val oldBounds = Rect(drawable.bounds)
        try {
            drawable.setBounds(0, 0, iconPixels, iconPixels)
            drawable.draw(Canvas(bitmap))
            // The raster is fixed at 96x96; compression never processes source-sized pixels.
            val output = ByteArrayOutputStream()
            if (!bitmap.compress(Bitmap.CompressFormat.PNG, 100, output) || output.size() > maxPngBytes) return null
            return output.toByteArray()
        } finally {
            drawable.bounds = oldBounds
            bitmap.recycle()
        }
    }
}
