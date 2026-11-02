package io.github.ccch1mneyyy.dsh_app.islands

import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.Looper
import android.webkit.WebView
import java.io.ByteArrayOutputStream
import kotlin.math.min
import kotlin.math.roundToInt

/** Visible browser images, kept in memory; no screen capture permission or file writes. */
internal object BrowserImages {
    private const val MAX_BYTES = 2 * 1024 * 1024

    // MethodChannel runs on the UI thread. Keep validation, drawing and
    // encoding in that same turn; Dart additionally retires results by document
    // revision and request sequence, including same-URL reloads and disposal.
    private fun current(view: WebView, expectedUrl: String?): Boolean =
        Looper.myLooper() == Looper.getMainLooper() && expectedUrl != null &&
            view.isAttachedToWindow && view.url == expectedUrl && view.progress == 100

    fun preview(view: WebView, expectedUrl: String?, requestedWidth: Int): ByteArray? =
        runCatching {
            if (!current(view, expectedUrl)) return null
            val sourceWidth = view.width
            val sourceHeight = view.height
            if (sourceWidth <= 0 || sourceHeight <= 0) return null
            val scale = min(min(1f, requestedWidth.coerceIn(160, 600).toFloat() / sourceWidth), 1200f / sourceHeight)
            val width = (sourceWidth * scale).roundToInt().coerceAtLeast(1)
            val height = (sourceHeight * scale).roundToInt().coerceAtLeast(1)
            val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            try {
                val canvas = Canvas(bitmap)
                canvas.drawColor(android.graphics.Color.WHITE)
                canvas.scale(scale, scale)
                view.draw(canvas)
                val bytes = png(bitmap)
                if (current(view, expectedUrl) && view.width == sourceWidth && view.height == sourceHeight) bytes else null
            } finally {
                bitmap.recycle()
            }
        }.getOrNull()

    fun icon(view: WebView, expectedUrl: String?): ByteArray? =
        runCatching {
            if (!current(view, expectedUrl)) return null
            val source = view.favicon ?: return null
            if (source.isRecycled || source.width <= 0 || source.height <= 0) return null
            val scale = min(1f, 96f / maxOf(source.width, source.height))
            val small = Bitmap.createScaledBitmap(source, (source.width * scale).roundToInt().coerceAtLeast(1), (source.height * scale).roundToInt().coerceAtLeast(1), true)
            try {
                val bytes = png(small)
                if (current(view, expectedUrl) && view.favicon === source) bytes else null
            } finally {
                if (small !== source) small.recycle()
            }
        }.getOrNull()

    private fun png(bitmap: Bitmap): ByteArray? = object : ByteArrayOutputStream() {
        override fun write(value: Int) {
            check(count < MAX_BYTES) { "browser_image_too_large" }
            super.write(value)
        }

        override fun write(bytes: ByteArray, offset: Int, length: Int) {
            check(length <= MAX_BYTES - count) { "browser_image_too_large" }
            super.write(bytes, offset, length)
        }
    }.use { stream ->
        if (!bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream) || stream.size() == 0) null else stream.toByteArray()
    }
}
