package io.github.ccch1mneyyy.dsh_app.web

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.OutputStream
import org.junit.Assert.*
import org.junit.Test

class BrowserDownloadStreamTest {
    @Test fun unknownLengthAndProgress() {
        val bytes = ByteArray(140_000) { (it % 251).toByte() }
        val out = ByteArrayOutputStream()
        val progress = mutableListOf<Long>()
        assertEquals(bytes.size.toLong(), BrowserDownloadStream.copy(ByteArrayInputStream(bytes), out, -1, { false }) { progress.add(it) })
        assertArrayEquals(bytes, out.toByteArray())
        assertEquals(bytes.size.toLong(), progress.last())
        assertTrue(progress.size > 1)
    }
    private fun fails(code: String, block: () -> Unit) {
        try { block(); fail("expected $code") } catch (e: BrowserDownloadError) { assertEquals(code, e.code) }
    }
    @Test fun truncatedAndOverlongBodiesNeverComplete() {
        for (length in listOf(4L, 2L)) {
            fails("incomplete") { BrowserDownloadStream.copy(ByteArrayInputStream(byteArrayOf(1, 2, 3)), ByteArrayOutputStream(), length, { false }) {} }
        }
    }
    @Test fun cancellationStopsFurtherWrites() {
        var cancel = false
        val out = ByteArrayOutputStream()
        fails("cancelled") {
            BrowserDownloadStream.copy(ByteArrayInputStream(ByteArray(200_000)), out, -1, { cancel }) { cancel = true }
        }
        assertEquals(64 * 1024, out.size())
    }
    @Test fun fullDiskIsAStorageFailure() {
        val out = object : OutputStream() { override fun write(value: Int) { throw IOException("full") } }
        fails("storage") { BrowserDownloadStream.copy(ByteArrayInputStream(byteArrayOf(1)), out, 1, { false }) {} }
    }
}
