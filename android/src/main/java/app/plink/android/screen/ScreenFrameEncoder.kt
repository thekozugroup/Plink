package app.plink.android.screen

import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.media.Image
import app.plink.android.protocol.ScreenPreviewPayloadPolicy
import java.io.ByteArrayOutputStream
import java.io.OutputStream
import kotlin.math.floor
import kotlin.math.min
import kotlin.math.sqrt

data class ScreenFrameSize(val width: Int, val height: Int)

sealed interface ScreenFrameEncoding {
    data class Encoded(val width: Int, val height: Int, val jpeg: ByteArray) : ScreenFrameEncoding
    data object TooLarge : ScreenFrameEncoding
}

object ScreenFrameEncoder {
    fun boundedSize(width: Int, height: Int): ScreenFrameSize {
        require(width > 0 && height > 0)
        val longEdge = maxOf(width, height).toDouble()
        val shortEdge = minOf(width, height).toDouble()
        val pixelScale = sqrt(ScreenPreviewPayloadPolicy.maxPixels.toDouble() / (width.toDouble() * height))
        val scale = min(
            1.0,
            min(
                ScreenPreviewPayloadPolicy.maxLongEdge / longEdge,
                min(ScreenPreviewPayloadPolicy.maxShortEdge / shortEdge, pixelScale)
            )
        )
        return ScreenFrameSize(
            width = floor(width * scale).toInt().coerceAtLeast(1),
            height = floor(height * scale).toInt().coerceAtLeast(1)
        )
    }

    /** Copies only the visible crop; acquired Image ownership remains with the caller. */
    fun copyCroppedRgba(image: Image): Bitmap {
        require(image.format == PixelFormat.RGBA_8888)
        val crop = image.cropRect
        require(crop.width() > 0 && crop.height() > 0)
        val plane = image.planes.single()
        val pixelStride = plane.pixelStride
        val rowStride = plane.rowStride
        require(pixelStride >= 4 && rowStride >= image.width * pixelStride)
        val buffer = plane.buffer.duplicate()
        val lastPixel = (crop.bottom - 1) * rowStride + (crop.right - 1) * pixelStride + 3
        require(crop.left >= 0 && crop.top >= 0 && crop.right <= image.width && crop.bottom <= image.height &&
            lastPixel < buffer.limit())

        val bitmap = Bitmap.createBitmap(crop.width(), crop.height(), Bitmap.Config.ARGB_8888)
        val row = IntArray(crop.width())
        try {
            for (y in 0 until crop.height()) {
                var offset = (crop.top + y) * rowStride + crop.left * pixelStride
                for (x in row.indices) {
                    val red = buffer.get(offset).toInt() and 0xff
                    val green = buffer.get(offset + 1).toInt() and 0xff
                    val blue = buffer.get(offset + 2).toInt() and 0xff
                    val alpha = buffer.get(offset + 3).toInt() and 0xff
                    row[x] = (alpha shl 24) or (red shl 16) or (green shl 8) or blue
                    offset += pixelStride
                }
                bitmap.setPixels(row, 0, crop.width(), 0, y, crop.width(), 1)
            }
            return bitmap
        } catch (failure: Throwable) {
            bitmap.recycle()
            throw failure
        }
    }

    /** Caller retains and recycles bitmap. No bytes beyond the policy cap are retained. */
    fun encode(bitmap: Bitmap): ScreenFrameEncoding {
        require(!bitmap.isRecycled && bitmap.width > 0 && bitmap.height > 0)
        compress(bitmap, quality = 60)?.let {
            return ScreenFrameEncoding.Encoded(bitmap.width, bitmap.height, it)
        }
        val fallbackWidth = (bitmap.width / 2).coerceAtLeast(1)
        val fallbackHeight = (bitmap.height / 2).coerceAtLeast(1)
        val fallback = Bitmap.createScaledBitmap(bitmap, fallbackWidth, fallbackHeight, true)
        return try {
            compress(fallback, quality = 40)?.let {
                ScreenFrameEncoding.Encoded(fallback.width, fallback.height, it)
            } ?: ScreenFrameEncoding.TooLarge
        } finally {
            if (fallback !== bitmap) fallback.recycle()
        }
    }

    private fun compress(bitmap: Bitmap, quality: Int): ByteArray? {
        val output = BoundedOutputStream(ScreenPreviewPayloadPolicy.maxJpegBytes)
        return try {
            if (!bitmap.compress(Bitmap.CompressFormat.JPEG, quality, output)) null else output.toByteArray()
        } catch (_: LimitExceededException) {
            null
        }
    }

    private class BoundedOutputStream(private val limit: Int) : OutputStream() {
        private val output = ByteArrayOutputStream(limit)

        override fun write(value: Int) {
            requireCapacity(1)
            output.write(value)
        }

        override fun write(bytes: ByteArray, offset: Int, length: Int) {
            require(offset >= 0 && length >= 0 && offset + length <= bytes.size)
            requireCapacity(length)
            output.write(bytes, offset, length)
        }

        fun toByteArray(): ByteArray = output.toByteArray()

        private fun requireCapacity(additional: Int) {
            if (output.size() + additional > limit) throw LimitExceededException()
        }
    }

    private class LimitExceededException : RuntimeException()
}
