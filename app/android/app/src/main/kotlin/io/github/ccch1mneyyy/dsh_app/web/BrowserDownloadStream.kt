package io.github.ccch1mneyyy.dsh_app.web

import java.io.InputStream
import java.io.OutputStream

internal object BrowserDownloadStream {
    fun copy(input: InputStream, output: OutputStream, length: Long, cancelled: () -> Boolean, progress: (Long) -> Unit): Long {
        val buffer = ByteArray(64 * 1024)
        var received = 0L
        while (true) {
            if (cancelled()) throw BrowserDownloadError("cancelled")
            val count = input.read(buffer)
            if (count < 0) break
            if (cancelled()) throw BrowserDownloadError("cancelled")
            if (length >= 0 && received + count > length) throw BrowserDownloadError("incomplete")
            try { output.write(buffer, 0, count) }
            catch (_: java.io.IOException) { throw BrowserDownloadError("storage") }
            received += count
            progress(received)
        }
        if (cancelled()) throw BrowserDownloadError("cancelled")
        if (length >= 0 && received != length) throw BrowserDownloadError("incomplete")
        return received
    }
}
