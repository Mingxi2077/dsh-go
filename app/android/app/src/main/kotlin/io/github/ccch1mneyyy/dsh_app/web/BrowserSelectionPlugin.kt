package io.github.ccch1mneyyy.dsh_app.web

import android.view.ActionMode
import android.view.MenuItem
import android.webkit.WebView
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.webviewflutter.WebViewFlutterAndroidExternalApi
import java.lang.ref.WeakReference

/** Selection action registered only by the visible ordinary browser route. */
class BrowserSelectionPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var binding: FlutterPlugin.FlutterPluginBinding? = null
    private var channel: MethodChannel? = null
    private data class Registration(val view: WeakReference<WebView>, val token: String, val label: String, val url: String)
    private var registration: Registration? = null
    private var actionMode: WeakReference<ActionMode>? = null
    private var actionToken: String? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        this.binding = binding
        channel = MethodChannel(binding.binaryMessenger, "dsh/browser-selection").also { it.setMethodCallHandler(this) }
        current = WeakReference(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        clear()
        channel?.setMethodCallHandler(null)
        channel = null
        this.binding = null
        if (current?.get() === this) current = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val token = call.argument<String>("token")
        when (call.method) {
            "show" -> {
                val engine = binding ?: return result.success(false)
                val id = (call.argument<Any>("id") as? Number)?.toLong() ?: return result.success(false)
                val label = call.argument<String>("label") ?: return result.success(false)
                val url = call.argument<String>("url") ?: return result.success(false)
                if (token.isNullOrEmpty() || token.length > 64 || label.isBlank() || label.length > 60 || url.length > 8192) return result.success(false)
                val view = runCatching { WebViewFlutterAndroidExternalApi.getWebView(engine, id) }.getOrNull()
                    ?: return result.success(false)
                clear()
                registration = Registration(WeakReference(view), token, label, url)
                result.success(true)
            }
            "hide" -> {
                if (token == registration?.token) clear()
                result.success(null)
            }
            "finish" -> {
                if (token == registration?.token && token == actionToken) {
                    actionMode?.get()?.finish()
                    actionMode = null
                    actionToken = null
                }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun clear() {
        // Remove our action only; never dismiss another field's selection.
        actionMode?.get()?.menu?.removeItem(QUOTE_ID)
        actionMode = null
        actionToken = null
        registration = null
    }

    private fun isCurrent(entry: Registration): Boolean {
        val view = entry.view.get() ?: return false
        return registration === entry && view.isAttachedToWindow && view.isShown && view.hasWindowFocus() &&
            view.hasFocus() && view.url == entry.url
    }

    private fun addAction(mode: ActionMode) {
        val entry = registration ?: return
        if (!isCurrent(entry)) return
        actionMode = WeakReference(mode)
        actionToken = entry.token
        if (mode.menu.findItem(QUOTE_ID) != null) return
        mode.menu.add(0, QUOTE_ID, 1, entry.label).apply {
            setShowAsAction(MenuItem.SHOW_AS_ACTION_IF_ROOM)
            setOnMenuItemClickListener {
                if (isCurrent(entry) && actionToken == entry.token) {
                    isEnabled = false
                    channel?.invokeMethod("quote", mapOf("token" to entry.token, "url" to entry.url), object : MethodChannel.Result {
                        override fun success(result: Any?) { if (actionToken == entry.token) mode.finish() }
                        override fun error(code: String, message: String?, details: Any?) { if (actionToken == entry.token) mode.finish() }
                        override fun notImplemented() { if (actionToken == entry.token) mode.finish() }
                    })
                }
                true
            }
        }
        mode.invalidate()
    }

    companion object {
        private const val QUOTE_ID = 0x44534851
        private var current: WeakReference<BrowserSelectionPlugin>? = null
        fun onActionModeStarted(mode: ActionMode) {
            current?.get()?.addAction(mode)
        }
    }
}
