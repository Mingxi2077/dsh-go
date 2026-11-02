package io.github.ccch1mneyyy.dsh_app.islands

import org.junit.Assert.*
import org.junit.Test

class BrowserNavigationTest {
    @Test fun countLimitEvictsOldestSavedTab() {
        val cache = BrowserNavigationCache()
        repeat(81) { assertTrue(cache.put("$it", "https://example.com/$it", byteArrayOf(1))) }
        assertEquals(80, cache.size)
        assertEquals(80, cache.byteCount)
        assertNull(cache.take("0"))
        assertNotNull(cache.take("80"))
    }

    @Test fun bytesAreBoundedAndReplacementOrConsumptionIsAccounted() {
        val cache = BrowserNavigationCache()
        repeat(17) { cache.put("$it", "https://example.com/", ByteArray(BrowserNavigationCache.MAX_ENTRY_BYTES)) }
        assertEquals(16, cache.size)
        assertEquals(BrowserNavigationCache.MAX_TOTAL_BYTES, cache.byteCount)
        assertNull(cache.take("0"))
        assertFalse(cache.put("16", "https://example.com/", ByteArray(BrowserNavigationCache.MAX_ENTRY_BYTES + 1)))
        assertEquals(15, cache.size)
        cache.remove("1")
        assertEquals(14 * BrowserNavigationCache.MAX_ENTRY_BYTES, cache.byteCount)
        cache.clear()
        assertEquals(0, cache.byteCount)
        assertEquals(0, cache.size)
    }

    @Test fun currentUrlRejectsPrivateOrCredentialedOrigins() {
        for (url in listOf("https://example.com/a?token=memory-only#spa", "http://8.8.8.8/",
            "https://[2606:4700:4700::1111]/", "https://example.com:8443/")) {
            assertTrue(url, BrowserNavigationUrl.allows(url))
        }
        for (url in listOf("javascript:alert(1)", "file:///etc/passwd", "http://localhost/", "http://a.local/",
            "https://user:pass@example.com/", "https://@example.com/", "http://127.1/", "http://2130706433/",
            "http://0x7f000001/", "http://0177.0.0.1/", "http://10.0.0.1/", "http://172.16.0.1/",
            "http://192.168.0.1/", "http://169.254.169.254/", "http://100.64.0.1/", "http://[::1]/",
            "http://[::ffff:127.0.0.1]/", "http://[fc00::1]/", "https://example.com:0/",
            "https://example.com:65536/", "https://example.com\\@localhost/", "https://example.com/\n")) {
            assertFalse(url, BrowserNavigationUrl.allows(url))
        }
    }
}
