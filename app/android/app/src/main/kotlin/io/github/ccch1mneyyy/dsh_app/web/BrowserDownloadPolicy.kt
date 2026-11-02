package io.github.ccch1mneyyy.dsh_app.web

import java.net.URI
import java.net.InetAddress

/** Pure download decisions. Never turn a page-controlled name into a path. */
internal object BrowserDownloadPolicy {
    fun filename(raw: String): String = raw
        .replace(Regex("[\\x00-\\x1f\\x7f/\\\\:*?\"<>|\\u202a-\\u202e\\u2066-\\u2069]"), "_")
        .trim().trim('.').take(160).ifBlank { "download" }

    fun allowed(raw: String): Boolean = runCatching {
        if (raw.length > 8192 || Regex("[\\x00-\\x20\\x7f\\\\]").containsMatchIn(raw)) return false
        val uri = URI(raw)
        val host = (uri.host ?: return false).lowercase().trimEnd('.').removeSurrounding("[", "]")
        if (uri.scheme !in listOf("https", "http") || uri.rawUserInfo != null || uri.port == 0 || uri.port > 65535) return false
        if (host == "localhost" || listOf(".localhost", ".local", ".internal", ".lan", ".home", ".test", ".invalid").any(host::endsWith)) return false
        if (':' in host || Regex("^[0-9.]+$").matches(host)) {
            if (':' !in host && !Regex("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$").matches(host)) return false
            if (':' !in host && host.split('.').any { part -> part.toIntOrNull() !in 0..255 || (part.length > 1 && part.startsWith('0')) }) return false
            return publicAddress(InetAddress.getByName(host))
        }
        val labels = host.split('.')
        labels.size >= 2 && !labels.all { Regex("^(?:[0-9]+|0x[0-9a-f]+)$").matches(it) } &&
            labels.all { it.length <= 63 && Regex("^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$").matches(it) }
    }.getOrDefault(false)

    fun publicAddress(address: InetAddress): Boolean {
        if (address.isAnyLocalAddress || address.isLoopbackAddress || address.isLinkLocalAddress || address.isSiteLocalAddress || address.isMulticastAddress) return false
        val b = address.address.map { it.toInt() and 255 }
        if (b.size == 16) return (b[0] and 0xe0) == 0x20
        return b[0] != 0 && b[0] < 224 && !(b[0] == 100 && b[1] in 64..127) &&
            !(b[0] == 198 && b[1] in 18..19)
    }

    fun sameOrigin(a: String, b: String): Boolean = runCatching {
        val x = URI(a); val y = URI(b)
        fun port(u: URI) = if (u.port != -1) u.port else if (u.scheme == "https") 443 else 80
        x.scheme == y.scheme && x.host.equals(y.host, ignoreCase = true) && port(x) == port(y)
    }.getOrDefault(false)
}

internal class BrowserDownloadError(val code: String) : Exception(code)
