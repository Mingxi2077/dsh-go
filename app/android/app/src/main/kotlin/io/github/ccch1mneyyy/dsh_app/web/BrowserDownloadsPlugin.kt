package io.github.ccch1mneyyy.dsh_app.web

import android.Manifest
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.DocumentsContract
import android.webkit.CookieManager
import android.webkit.URLUtil
import android.webkit.WebView
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import io.flutter.plugins.webviewflutter.WebViewFlutterAndroidExternalApi
import java.lang.ref.WeakReference
import java.util.UUID

/** DownloadListener only offers an opaque capability. A second, explicit confirmation starts it. */
class BrowserDownloadsPlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler,
    PluginRegistry.ActivityResultListener, PluginRegistry.RequestPermissionsResultListener {
    private data class Offer(val viewId: Long, val view: WeakReference<WebView>, val page: String?,
        val request: BrowserDownloads.Request, val created: Long)
    private var engine: FlutterPlugin.FlutterPluginBinding? = null
    private var activity: ActivityPluginBinding? = null
    private var channel: MethodChannel? = null
    private lateinit var downloads: BrowserDownloads
    private val offers = linkedMapOf<String, Offer>()
    private val views = mutableMapOf<Long, WeakReference<WebView>>()
    private var picker: MethodChannel.Result? = null
    private var picking = false
    private var permission: (() -> Unit)? = null
    private var permissionResult: MethodChannel.Result? = null
    private val main = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        engine = binding
        downloads = BrowserDownloads.get(binding.applicationContext)
        channel = MethodChannel(binding.binaryMessenger, "dsh/browser-downloads").also { it.setMethodCallHandler(this) }
        downloads.onChanged = { channel?.invokeMethod("changed", downloads.snapshot()) }
    }
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        views.values.forEach { it.get()?.setDownloadListener(null) }; views.clear(); offers.clear()
        downloads.onChanged = null
        channel?.setMethodCallHandler(null); channel = null; engine = null
    }
    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding; binding.addActivityResultListener(this); binding.addRequestPermissionsResultListener(this)
    }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)
    override fun onDetachedFromActivityForConfigChanges() {
        activity?.removeActivityResultListener(this); activity?.removeRequestPermissionsResultListener(this)
        activity = null
        picker?.success(false); picker = null
        permissionResult?.error("expired", null, null); permissionResult = null; permission = null
    }
    override fun onDetachedFromActivity() { onDetachedFromActivityForConfigChanges(); picking = false }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "snapshot" -> result.success(downloads.snapshot())
                "attach" -> attach(call, result)
                "detach" -> {
                    val id = call.argument<Number>("viewId")?.toLong()
                    views.remove(id)?.get()?.setDownloadListener(null)
                    offers.entries.removeAll { it.value.viewId == id }
                    result.success(null)
                }
                "reject" -> { offers.remove(call.argument<String>("id")); result.success(null) }
                "confirm" -> confirm(call, result)
                "cancel" -> { downloads.cancel(call.argument<String>("id") ?: ""); result.success(null) }
                "chooseFolder" -> chooseFolder(result)
                "resetFolder" -> { downloads.setFolder("", BrowserDownloads.DEFAULT_FOLDER); result.success(null) }
                "open" -> {
                    val (uri, mime) = downloads.completedUri(call.argument<String>("id") ?: "")
                    val intent = Intent(Intent.ACTION_VIEW).setDataAndType(uri, mime).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    intent.clipData = ClipData.newRawUri("download", uri)
                    (activity?.activity ?: throw BrowserDownloadError("expired")).startActivity(Intent.createChooser(intent, null))
                    result.success(null)
                }
                "readAttachment" -> {
                    val id = call.argument<String>("id") ?: ""
                    val cap = call.argument<Int>("maxBytes") ?: 0
                    Thread {
                        val outcome = runCatching { downloads.readAttachment(id, cap) }
                        main.post { outcome.fold({ result.success(it) }, { failure(result, it) }) }
                    }.start()
                }
                else -> result.notImplemented()
            }
        } catch (error: Exception) { failure(result, error) }
    }
    private fun failure(result: MethodChannel.Result, error: Throwable) {
        result.error(when (error) {
            is BrowserDownloadError -> error.code
            is ActivityNotFoundException -> "no_app"
            is java.io.FileNotFoundException -> "missing"
            is SecurityException -> "permission"
            else -> "failed"
        }, null, null)
    }
    private fun attach(call: MethodCall, result: MethodChannel.Result) {
        val binding = engine ?: throw BrowserDownloadError("expired")
        val id = call.argument<Number>("viewId")?.toLong() ?: throw BrowserDownloadError("expired")
        val view = WebViewFlutterAndroidExternalApi.getWebView(binding, id) ?: throw BrowserDownloadError("expired")
        views[id] = WeakReference(view)
        view.setDownloadListener { url, agent, disposition, mime, length ->
            if (!view.isAttachedToWindow || activity == null) return@setDownloadListener
            offers.entries.removeAll { it.value.viewId == id || SystemClock.elapsedRealtime() - it.value.created > 300_000 }
            if (offers.size >= 16) return@setDownloadListener
            val token = UUID.randomUUID().toString()
            val supported = BrowserDownloadPolicy.allowed(url)
            val name = BrowserDownloadPolicy.filename(URLUtil.guessFileName(url, disposition, mime))
            val safeMime = mime?.takeIf { Regex("^[a-zA-Z0-9.+-]+/[a-zA-Z0-9.+-]+$").matches(it) } ?: "application/octet-stream"
            val request = BrowserDownloads.Request(url, name, safeMime, length,
                if (supported) CookieManager.getInstance().getCookie(url) else null,
                agent?.takeIf { !it.contains('\r') && !it.contains('\n') } ?: view.settings.userAgentString)
            offers[token] = Offer(id, WeakReference(view), view.url, request, SystemClock.elapsedRealtime())
            channel?.invokeMethod("offer", mapOf("viewId" to id, "id" to token, "url" to url,
                "filename" to name, "mime" to safeMime, "bytes" to length, "supported" to supported))
        }
        result.success(null)
    }
    private fun validOffer(id: String): Offer {
        val offer = offers[id] ?: throw BrowserDownloadError("expired")
        val view = offer.view.get()
        if (view == null || !view.isAttachedToWindow || view.url != offer.page ||
            SystemClock.elapsedRealtime() - offer.created > 300_000) {
            offers.remove(id); throw BrowserDownloadError("expired")
        }
        return offer
    }
    private fun confirm(call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<String>("id") ?: throw BrowserDownloadError("expired")
        validOffer(id)
        val folder = call.argument<String>("folderId") ?: throw BrowserDownloadError("folder_changed")
        val start = {
            try {
                val offer = validOffer(id)
                offers.remove(id) // one shot, including failed starts; never replay an old confirmation
                downloads.start(offer.request, folder)
                result.success(null)
            } catch (error: Exception) { failure(result, error) }
        }
        val screen = activity?.activity ?: throw BrowserDownloadError("expired")
        if (folder.isEmpty() && Build.VERSION.SDK_INT < 29 && screen.checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED) {
            if (permissionResult != null) throw BrowserDownloadError("busy")
            permissionResult = result; permission = start
            screen.requestPermissions(arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE), PERMISSION)
        } else start()
    }
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray): Boolean {
        if (requestCode != PERMISSION) return false
        val reply = permissionResult; val action = permission
        permission = null; permissionResult = null
        if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) action?.invoke()
        else reply?.error("permission", null, null)
        return true
    }
    private fun chooseFolder(result: MethodChannel.Result) {
        if (picking) throw BrowserDownloadError("busy")
        val screen = activity?.activity ?: throw BrowserDownloadError("expired")
        picker = result; picking = true
        try {
            screen.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or Intent.FLAG_GRANT_PREFIX_URI_PERMISSION), PICKER)
        } catch (error: Exception) { picker = null; picking = false; throw error }
    }
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != PICKER) return false
        picking = false
        val result = picker; picker = null
        if (result == null) return true
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) { result.success(false); return true }
        try {
            val ctx = engine?.applicationContext ?: throw BrowserDownloadError("expired")
            if (uri.scheme != "content" || !DocumentsContract.isTreeUri(uri) || uri.authority == "${ctx.packageName}.files") throw BrowserDownloadError("directory")
            val flags = data.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            if (flags and Intent.FLAG_GRANT_WRITE_URI_PERMISSION == 0) throw BrowserDownloadError("permission")
            ctx.contentResolver.takePersistableUriPermission(uri, flags)
            val doc = DocumentsContract.buildDocumentUriUsingTree(uri, DocumentsContract.getTreeDocumentId(uri))
            val label = ctx.contentResolver.query(doc, arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)?.use {
                if (it.moveToFirst()) it.getString(0) else null
            } ?: DocumentsContract.getTreeDocumentId(uri)
            val treeId = DocumentsContract.getTreeDocumentId(uri)
            val provider = ctx.packageManager.resolveContentProvider(uri.authority ?: "", 0)?.loadLabel(ctx.packageManager)?.toString()
            val shownPath = if (uri.authority == "com.android.externalstorage.documents" && ':' in treeId) {
                val chinese = ctx.resources.configuration.locales[0].language == "zh"
                val volume = treeId.substringBefore(':').let { if (it == "primary") { if (chinese) "内部存储" else "Internal storage" } else it }
                "$volume/${treeId.substringAfter(':')}".trimEnd('/')
            } else listOfNotNull(provider, label).distinct().joinToString(" / ")
            downloads.setFolder(uri.toString(), shownPath)
            result.success(true)
        } catch (error: Exception) { failure(result, error) }
        return true
    }
    companion object { private const val PICKER = 0x6D61; private const val PERMISSION = 0x6D62 }
}
