package io.github.ccch1mneyyy.dsh_app.web

import org.junit.Assert.*
import org.junit.Test

class BrowserDownloadPolicyTest {
    @Test fun rejectsNonWebCredentialsAndPrivateTargets() {
        listOf("file:///sdcard/secret", "blob:https://example.com/id", "https://a:b@example.com/x", "http://localhost/a",
            "http://127.1/a", "http://127.0.0.1/a", "http://192.168.1.1/a", "http://0x7f000001/a", "http://[::1]/a",
            "http://100.64.0.1/a", "https://device.local/a", "https://example.com/\r\nheader").forEach {
            assertFalse(it, BrowserDownloadPolicy.allowed(it))
        }
        assertTrue(BrowserDownloadPolicy.allowed("https://example.com/export?token=private"))
        assertTrue(BrowserDownloadPolicy.allowed("https://8.8.8.8/file"))
    }
    @Test fun cookiesAreBoundToSchemeHostAndEffectivePort() {
        assertTrue(BrowserDownloadPolicy.sameOrigin("https://EXAMPLE.com/a", "https://example.com:443/b"))
        assertFalse(BrowserDownloadPolicy.sameOrigin("https://example.com/a", "https://cdn.example.com/b"))
        assertFalse(BrowserDownloadPolicy.sameOrigin("https://example.com/a", "http://example.com/b"))
        assertFalse(BrowserDownloadPolicy.sameOrigin("https://example.com/a", "https://example.com:8443/b"))
    }
    @Test fun hostileNamesCannotTraverseOrSpoofExtensions() {
        val name = BrowserDownloadPolicy.filename("../../\u202Egpj.exe\u0000")
        assertFalse(name.contains('/')); assertFalse(name.contains('\u202E')); assertFalse(name.contains('\u0000'))
        assertEquals("download", BrowserDownloadPolicy.filename("..."))
        assertTrue(BrowserDownloadPolicy.filename("x".repeat(1000)).length <= 160)
        assertEquals("报告.pdf", BrowserDownloadPolicy.filename("报告.pdf"))
    }
}
