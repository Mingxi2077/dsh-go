package io.github.ccch1mneyyy.dsh_app.islands

import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.Parcel
import android.webkit.WebView
import java.net.InetAddress
import java.net.URI
import java.util.WeakHashMap

/** Opaque, process-local WebView history. No files, preferences or URL replay. */
internal class BrowserNavigation {
    private data class Lease(val key: String, val generation: Long)
    private val views = WeakHashMap<WebView, Lease>()
    private val snapshots = BrowserNavigationCache()
    private val main = Handler(Looper.getMainLooper())

    private fun onMain() = Looper.myLooper() == Looper.getMainLooper()
    private fun validKey(key: String?) = key != null && key.matches(Regex("[0-9a-f]{48}"))

    /** Also enrolls this fresh, ordinary browser WebView for later saving.
     * Auth WebViews never call this method and cannot be saved by save(). */
    fun restore(view: WebView, key: String?, generation: Long?, expectedUrl: String?): Boolean {
        if (!onMain() || !validKey(key) || generation == null || generation <= 0 ||
            !BrowserNavigationUrl.allows(expectedUrl)) return false
        return runCatching {
            // restoreState must precede every load into this WebView. Never
            // overwrite a live document or a WebView used for authorization.
            if (views.containsKey(view) || view.copyBackForwardList().size != 0 ||
                (view.url != null && view.url != "about:blank")) return false
            val prior = views.values.filter { it.key == key }
            if (prior.any { it.generation >= generation }) return false
            views.entries.removeAll { it.value.key == key }
            views[view] = Lease(key!!, generation)
            val snapshot = snapshots.take(key) ?: return false
            if (snapshot.url != expectedUrl) return false
            val parcel = Parcel.obtain()
            val state = try {
                parcel.unmarshall(snapshot.bytes, 0, snapshot.bytes.size)
                parcel.setDataPosition(0)
                parcel.readBundle(javaClass.classLoader) ?: return false
            } finally {
                parcel.recycle()
            }
            // The Bundle is produced only by saveState on an enrolled view.
            // restoreState retains Chromium's serialized POST/SPA entries.
            val history = view.restoreState(state) ?: return false
            val actual = history.currentItem?.url
            val restored = actual == expectedUrl && view.url == expectedUrl && BrowserNavigationUrl.allows(actual)
            if (!restored) {
                view.stopLoading()
                view.clearHistory()
            }
            restored
        }.getOrDefault(false)
    }

    /** Flutter's removal frame can finish before the Android platform view
     * detaches. Keep the channel result pending briefly so destruction and the
     * next restore both wait for the actual detach, without retaining the UI. */
    fun saveWhenDetached(view: WebView, key: String?, generation: Long?, expectedUrl: String?, done: (Boolean) -> Unit) {
        var retries = 0
        fun attempt() {
            val lease = views[view]
            if (lease == null || lease.key != key || lease.generation != generation) {
                done(false)
            } else if (view.isAttachedToWindow && retries++ < 8) {
                main.postDelayed({ attempt() }, 16L)
            } else {
                done(save(view, key, generation, expectedUrl))
            }
        }
        attempt()
    }

    private fun save(view: WebView, key: String?, generation: Long?, expectedUrl: String?): Boolean {
        if (!onMain() || !validKey(key) || !BrowserNavigationUrl.allows(expectedUrl)) return false
        return runCatching {
            val lease = views[view] ?: return false
            if (lease.key != key || lease.generation != generation) return false
            // The Flutter owner removes the platform view before dispose.
            // Never take a snapshot from a visible/loading/stale document.
            if (view.isAttachedToWindow || view.progress != 100 || view.url != expectedUrl) return false
            val state = Bundle()
            val history = view.saveState(state) ?: return false
            if (history.currentItem?.url != expectedUrl || view.url != expectedUrl) return false
            val parcel = Parcel.obtain()
            val bytes = try {
                parcel.writeBundle(state)
                if (parcel.dataSize() > BrowserNavigationCache.MAX_ENTRY_BYTES || parcel.hasFileDescriptors()) return false
                parcel.marshall()
            } finally {
                parcel.recycle()
            }
            snapshots.put(key!!, expectedUrl!!, bytes)
        }.getOrDefault(false).also {
            // A disposed view cannot save twice, whether capture succeeded or
            // failed. Weak keys additionally avoid retaining a native view.
            if (views[view]?.let { it.key == key && it.generation == generation } == true) views.remove(view)
        }
    }

    fun drop(key: String?) {
        if (!onMain() || !validKey(key)) return
        snapshots.remove(key!!)
        views.entries.removeAll { it.value.key == key }
    }

    fun clear() {
        snapshots.clear()
        views.clear()
    }
}

/** Pure byte-accounted cache, independently testable without a renderer. */
internal class BrowserNavigationCache {
    data class Snapshot(val url: String, val bytes: ByteArray)
    private val entries = LinkedHashMap<String, Snapshot>()
    var byteCount = 0
        private set
    val size get() = entries.size

    fun put(key: String, url: String, bytes: ByteArray): Boolean {
        remove(key)
        if (bytes.isEmpty() || bytes.size > MAX_ENTRY_BYTES) return false
        while (entries.size >= MAX_TABS || byteCount + bytes.size > MAX_TOTAL_BYTES) {
            remove(entries.keys.first())
        }
        entries[key] = Snapshot(url, bytes)
        byteCount += bytes.size
        return true
    }

    fun take(key: String): Snapshot? = entries.remove(key)?.also { byteCount -= it.bytes.size }
    fun remove(key: String) { take(key) }
    fun clear() { entries.clear(); byteCount = 0 }

    companion object {
        const val MAX_TABS = 80
        const val MAX_ENTRY_BYTES = 1024 * 1024
        const val MAX_TOTAL_BYTES = 16 * 1024 * 1024
    }
}

/** Defense in depth for the current URL, matching the ordinary browser policy.
 * Never resolve DNS: InetAddress is used only for literal IPv6 addresses. */
internal object BrowserNavigationUrl {
    fun allows(raw: String?): Boolean = runCatching {
        if (raw == null || raw.length > 8192 || raw.any { it <= ' ' || it == '\u007f' || it == '\\' }) return false
        val uri = URI(raw)
        if (uri.scheme !in listOf("http", "https") || uri.rawAuthority == null ||
            uri.rawAuthority.contains('@') || uri.rawUserInfo != null || uri.port == 0 || uri.port > 65535) return false
        var host = uri.host?.lowercase()?.removeSuffix(".") ?: return false
        if (host.isEmpty() || host.contains('%') || host == "localhost" ||
            listOf(".localhost", ".local", ".internal", ".lan", ".home", ".test", ".invalid").any { host.endsWith(it) }) return false
        if (host.startsWith('[') && host.endsWith(']')) host = host.substring(1, host.length - 1)
        if (host.contains(':')) {
            if (!host.matches(Regex("[0-9a-f:.]+"))) return false
            val bytes = InetAddress.getByName(host).address.map { it.toInt() and 255 }
            return if (bytes.size == 4) publicV4(bytes) else (bytes[0] and 0xe0) == 0x20
        }
        val labels = host.split('.')
        if (labels.size == 4 && labels.all { it.matches(Regex("[0-9]+")) }) {
            if (labels.any { it.length > 1 && it.startsWith('0') }) return false
            val bytes = labels.map { it.toIntOrNull() ?: return false }
            return bytes.all { it in 0..255 } && publicV4(bytes)
        }
        if (labels.size < 2 || labels.all { it.matches(Regex("(?:[0-9]+|0x[0-9a-f]+)")) }) return false
        labels.all { it.length <= 63 && it.matches(Regex("[a-z0-9](?:[a-z0-9-]*[a-z0-9])?")) }
    }.getOrDefault(false)

    private fun publicV4(b: List<Int>) = b[0] != 0 && b[0] != 10 && b[0] != 127 && b[0] < 224 &&
        !(b[0] == 169 && b[1] == 254) && !(b[0] == 172 && b[1] in 16..31) &&
        !(b[0] == 192 && b[1] == 168) && !(b[0] == 100 && b[1] in 64..127) &&
        !(b[0] == 198 && b[1] in 18..19)
}
