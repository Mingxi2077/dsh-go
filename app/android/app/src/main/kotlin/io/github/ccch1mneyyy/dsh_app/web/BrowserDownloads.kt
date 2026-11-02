package io.github.ccch1mneyyy.dsh_app.web

import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.MediaStore
import androidx.core.content.FileProvider
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.URI
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** Process-owned queue. Only confirmed offers reach here; URLs/headers never persist. */
internal class BrowserDownloads private constructor(private val context: Context) {
    data class Request(val url: String, val name: String, val mime: String, val size: Long, val cookie: String?, val agent: String)
    private data class Record(
        val id: String, var name: String, val mime: String, val host: String, val folder: String,
        val folderLabel: String, var status: String = "queued", var received: Long = 0, var total: Long = -1,
        var error: String? = null, var uri: String? = null, var path: String? = null,
        val cancelled: AtomicBoolean = AtomicBoolean(false),
    ) {
        val active get() = status == "queued" || status == "downloading"
        fun json() = JSONObject().put("id", id).put("filename", name).put("mime", mime).put("sourceHost", host)
            .put("folder", folder).put("folderLabel", folderLabel).put("status", status).put("received", received)
            .put("total", total).put("error", error).put("uri", uri).put("path", path)
        fun map() = mapOf("id" to id, "filename" to name, "mime" to mime, "sourceHost" to host,
            "location" to "$folderLabel/$name", "status" to status, "received" to received, "total" to total, "error" to error)
    }
    private val prefs = context.getSharedPreferences("browser_downloads_v1", Context.MODE_PRIVATE)
    private val records = linkedMapOf<String, Record>()
    private val workers = Executors.newFixedThreadPool(2)
    private val main = Handler(Looper.getMainLooper())
    private val connections = mutableMapOf<String, HttpURLConnection>()
    var onChanged: (() -> Unit)? = null
    var onServiceChanged: (() -> Unit)? = null
    private var folder = prefs.getString("folder", "") ?: ""
    private var folderLabel = prefs.getString("folderLabel", DEFAULT_FOLDER) ?: DEFAULT_FOLDER

    init {
        runCatching {
            val saved = JSONArray(prefs.getString("records", "[]"))
            for (i in 0 until minOf(saved.length(), 500)) {
                val j = saved.getJSONObject(i)
                val record = Record(j.getString("id"), j.getString("filename"), j.getString("mime"),
                    j.getString("sourceHost"), j.optString("folder"), j.optString("folderLabel", DEFAULT_FOLDER),
                    j.getString("status"), j.optLong("received"), j.optLong("total", -1),
                    j.optString("error").ifEmpty { null }, j.optString("uri").ifEmpty { null }, j.optString("path").ifEmpty { null })
                records[record.id] = record
                if (record.active) {
                    record.status = "failed"; record.error = "interrupted"
                }
                if (record.status != "completed") cleanup(record)
                else refreshFilename(record)
            }
        }
        persist()
    }

    @Synchronized fun snapshot(): Map<String, Any?> = mapOf("folderId" to folder, "folderLabel" to folderLabel,
        "firstDownload" to !prefs.getBoolean("confirmed", false), "items" to records.values.map { it.map() })
    @Synchronized fun activeCount() = records.values.count { it.active }
    @Synchronized fun setFolder(uri: String, label: String) {
        folder = uri; folderLabel = label
        prefs.edit().putString("folder", uri).putString("folderLabel", label).apply()
        changed()
    }
    @Synchronized fun start(request: Request, expectedFolder: String) {
        if (folder != expectedFolder) throw BrowserDownloadError("folder_changed")
        if (!BrowserDownloadPolicy.allowed(request.url)) throw BrowserDownloadError("unsupported")
        if (activeCount() >= 6 || records.size >= 500) throw BrowserDownloadError("busy")
        if (folder.isNotEmpty() && context.contentResolver.persistedUriPermissions.none { it.uri.toString() == folder && it.isWritePermission }) throw BrowserDownloadError("directory")
        val record = Record(UUID.randomUUID().toString(), BrowserDownloadPolicy.filename(request.name), request.mime,
            URI(request.url).host, folder, folderLabel, total = request.size)
        records[record.id] = record
        persist()
        try {
            context.startForegroundService(Intent(context, BrowserDownloadService::class.java))
        } catch (_: Exception) {
            records.remove(record.id); persist(); throw BrowserDownloadError("failed")
        }
        prefs.edit().putBoolean("confirmed", true).apply()
        changed()
        workers.execute { transfer(record, request) }
    }

    @Synchronized private fun persist() {
        val all = JSONArray(); records.values.forEach { all.put(it.json()) }
        prefs.edit().putString("records", all.toString()).commit()
    }
    private fun changed() { main.post { onChanged?.invoke(); onServiceChanged?.invoke() } }

    private fun check(record: Record) { if (record.cancelled.get()) throw BrowserDownloadError("cancelled") }
    private fun transfer(record: Record, request: Request) {
        var connection: HttpURLConnection? = null
        try {
            check(record)
            synchronized(this) { record.status = "downloading"; persist() }; changed()
            var url = request.url
            for (redirect in 0..10) {
                check(record)
                if (!BrowserDownloadPolicy.allowed(url)) throw BrowserDownloadError("unsupported")
                val uri = URI(url)
                if (InetAddress.getAllByName(uri.host).any { !BrowserDownloadPolicy.publicAddress(it) }) throw BrowserDownloadError("unsupported")
                val conn = uri.toURL().openConnection() as HttpURLConnection
                connection = conn
                synchronized(this) { connections[record.id] = conn }
                conn.instanceFollowRedirects = false
                conn.connectTimeout = 20_000; conn.readTimeout = 30_000
                conn.setRequestProperty("Accept-Encoding", "identity")
                conn.setRequestProperty("User-Agent", request.agent)
                // Never forward the source Cookie to a different origin, even a CDN redirect.
                if (BrowserDownloadPolicy.sameOrigin(request.url, url) && !request.cookie.isNullOrEmpty()) conn.setRequestProperty("Cookie", request.cookie)
                val status = conn.responseCode
                if (status in listOf(301, 302, 303, 307, 308)) {
                    val target = conn.getHeaderField("Location") ?: throw BrowserDownloadError("http")
                    val next = uri.resolve(target).toString()
                    if (uri.scheme == "https" && URI(next).scheme != "https") throw BrowserDownloadError("unsupported")
                    conn.disconnect()
                    if (redirect == 10) throw BrowserDownloadError("http")
                    url = next; continue
                }
                if (status != 200) throw BrowserDownloadError("http")
                val length = conn.getHeaderFieldLong("Content-Length", -1)
                synchronized(this) { record.total = length }
                check(record)
                createDestination(record)
                check(record)
                val output = record.path?.let { File(it).outputStream() }
                    ?: context.contentResolver.openOutputStream(Uri.parse(record.uri), "w")
                    ?: throw BrowserDownloadError("directory")
                var updated = System.nanoTime()
                output.use { out ->
                    conn.inputStream.use { input ->
                        BrowserDownloadStream.copy(input, out, length, { record.cancelled.get() }) { received ->
                            synchronized(this) { record.received = received }
                            if (System.nanoTime() - updated > 500_000_000) { changed(); updated = System.nanoTime() }
                        }
                    }
                }
                synchronized(this) {
                    check(record)
                    if (record.folder.isEmpty() && Build.VERSION.SDK_INT >= 29) {
                        context.contentResolver.update(Uri.parse(record.uri), ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }, null, null)
                    }
                    // MediaStore can allocate the collision suffix only when
                    // its output stream is opened. Re-read after publication.
                    refreshFilename(record)
                    record.status = "completed"; persist()
                }
                changed(); return
            }
        } catch (error: Exception) {
            synchronized(this) {
                cleanup(record)
                record.status = if (record.cancelled.get()) "cancelled" else "failed"
                record.error = if (record.cancelled.get()) null else when (error) {
                    is BrowserDownloadError -> error.code
                    is SecurityException -> "permission"
                    is java.io.FileNotFoundException -> "directory"
                    else -> "network"
                }
                persist()
            }
            changed()
        } finally {
            connection?.disconnect()
            synchronized(this) { connections.remove(record.id) }
        }
    }

    @Synchronized private fun createDestination(record: Record) {
        check(record)
        try {
            if (record.folder.isNotEmpty()) {
                val tree = Uri.parse(record.folder)
                val parent = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
                // DocumentsProvider creates a fresh document; do not open/overwrite a guessed path.
                record.uri = DocumentsContract.createDocument(context.contentResolver, parent, record.mime, record.name)?.toString()
                    ?: throw BrowserDownloadError("directory")
            } else if (Build.VERSION.SDK_INT >= 29) {
                record.uri = context.contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, ContentValues().apply {
                    put(MediaStore.Downloads.DISPLAY_NAME, record.name)
                    put(MediaStore.Downloads.MIME_TYPE, record.mime)
                    put(MediaStore.Downloads.RELATIVE_PATH, "$DEFAULT_FOLDER/")
                    put(MediaStore.Downloads.IS_PENDING, 1)
                })?.toString() ?: throw BrowserDownloadError("directory")
            } else {
                val dir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), "DSH-Go/Browser")
                if (!dir.isDirectory && !dir.mkdirs()) throw BrowserDownloadError("directory")
                var file = File(dir, record.name)
                var suffix = 1
                while (!file.createNewFile()) {
                    if (suffix > 9999) throw BrowserDownloadError("storage")
                    val name = File(record.name)
                    file = File(dir, "${name.nameWithoutExtension} (${suffix++})${name.extension.let { if (it.isEmpty()) "" else ".$it" }}")
                }
                record.path = file.absolutePath
                record.uri = FileProvider.getUriForFile(context, "${context.packageName}.files", file).toString()
            }
            // Providers may add a suffix to avoid collisions. Show the actual name.
            refreshFilename(record)
            persist() // Retain the partial target for cleanup after process death.
        } catch (error: SecurityException) { throw error }
        catch (error: BrowserDownloadError) { throw error }
        catch (_: Exception) { throw BrowserDownloadError("directory") }
    }

    private fun refreshFilename(record: Record) {
        record.path?.let { record.name = File(it).name; return }
        val raw = record.uri ?: return
        // A removed file or revoked permission must not hide the whole list.
        runCatching {
            context.contentResolver.query(Uri.parse(raw), arrayOf(MediaStore.MediaColumns.DISPLAY_NAME), null, null, null)?.use {
                if (it.moveToFirst()) {
                    val name = it.getString(0)
                    if (!name.isNullOrBlank()) record.name = name
                }
            }
        }
    }

    private fun cleanup(record: Record) {
        if (record.status == "completed") return
        runCatching {
            if (record.path != null) File(record.path!!).delete()
            else record.uri?.let {
                val uri = Uri.parse(it)
                if (record.folder.isNotEmpty()) DocumentsContract.deleteDocument(context.contentResolver, uri)
                else context.contentResolver.delete(uri, null, null)
            }
        }
        record.uri = null; record.path = null
    }
    @Synchronized fun cancel(id: String) {
        val record = records[id] ?: return
        if (!record.active) return
        record.cancelled.set(true)
        record.status = "cancelled"; persist()
        val conn = connections[id]
        // disconnect can block in the platform implementation: never on the UI thread.
        if (conn != null) Thread { conn.disconnect() }.start()
        changed()
    }
    @Synchronized fun completedUri(id: String): Pair<Uri, String> {
        val record = records[id] ?: throw BrowserDownloadError("missing")
        if (record.status != "completed" || record.uri == null) throw BrowserDownloadError("missing")
        return Uri.parse(record.uri) to record.mime
    }
    fun readAttachment(id: String, limit: Int): ByteArray {
        val (uri, _) = completedUri(id)
        val cap = minOf(limit, 30 * 1024 * 1024)
        if (cap <= 0) throw BrowserDownloadError("too_large")
        return (context.contentResolver.openInputStream(uri) ?: throw BrowserDownloadError("missing")).use { readBounded(it, cap) }
    }
    private fun readBounded(input: InputStream, limit: Int): ByteArray {
        val out = java.io.ByteArrayOutputStream()
        val bytes = ByteArray(64 * 1024)
        while (true) {
            val count = input.read(bytes)
            if (count < 0) break
            if (out.size().toLong() + count > limit) throw BrowserDownloadError("too_large")
            out.write(bytes, 0, count)
        }
        return out.toByteArray()
    }
    companion object {
        const val DEFAULT_FOLDER = "Download/DSH-Go/Browser"
        @Volatile private var instance: BrowserDownloads? = null
        fun get(context: Context): BrowserDownloads = instance ?: synchronized(this) {
            instance ?: BrowserDownloads(context.applicationContext).also { instance = it }
        }
    }
}
