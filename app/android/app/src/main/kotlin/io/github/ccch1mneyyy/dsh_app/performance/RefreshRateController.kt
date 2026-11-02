package io.github.ccch1mneyyy.dsh_app.performance

import android.app.Activity
import android.hardware.display.DisplayManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.Display
import android.view.MotionEvent
import android.view.Surface
import android.view.SurfaceHolder
import android.view.View
import android.view.ViewGroup
import android.view.ViewTreeObserver
import io.flutter.embedding.android.FlutterSurfaceView

/** Window-scoped hints only; never writes global settings or creates a frame loop. */
class RefreshRateController(private val activity: Activity, initialMode: String) {
    private val policy = RefreshRatePolicy(initialMode)
    private val handler = Handler(Looper.getMainLooper())
    private val displays = activity.getSystemService(DisplayManager::class.java)
    private val root get() = activity.window.decorView
    private var observer: ViewTreeObserver? = null
    private val surfaces = mutableMapOf<SurfaceHolder, Float?>()
    private var requestedHz = 0f
    private var releasePending = false
    private var disposed = false
    private val release = Runnable {
        releasePending = false
        apply()
    }
    // ViewTreeObserver sees descendant WebView scroll changes, including inertia
    // after ACTION_UP, even when the Flutter engine produces no frames.
    private val scrollListener = ViewTreeObserver.OnScrollChangedListener { nativeActivity() }
    private val layoutListener = ViewTreeObserver.OnGlobalLayoutListener { syncSurfaces() }
    private val surfaceCallback = object : SurfaceHolder.Callback {
        override fun surfaceCreated(holder: SurfaceHolder) { voteSurface(holder, requestedHz) }
        override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
            surfaces[holder] = null
            voteSurface(holder, requestedHz)
        }
        override fun surfaceDestroyed(holder: SurfaceHolder) { surfaces[holder] = null }
    }
    private val displayListener = object : DisplayManager.DisplayListener {
        override fun onDisplayAdded(displayId: Int) = Unit
        override fun onDisplayRemoved(displayId: Int) = Unit
        override fun onDisplayChanged(displayId: Int) {
            if (displayId == display()?.displayId) apply()
        }
    }

    fun resume() {
        if (disposed) return
        policy.resume(SystemClock.uptimeMillis())
        if (observer == null) {
            observer = root.viewTreeObserver.also {
                it.addOnScrollChangedListener(scrollListener)
                it.addOnGlobalLayoutListener(layoutListener)
            }
            displays.registerDisplayListener(displayListener, handler)
        }
        apply()
        syncSurfaces()
    }

    fun pause() {
        policy.pause()
        apply() // Includes max, the window hint, the View hint and every owned surface.
        observer?.takeIf { it.isAlive }?.let {
            it.removeOnScrollChangedListener(scrollListener)
            it.removeOnGlobalLayoutListener(layoutListener)
        }
        observer = null
        displays.unregisterDisplayListener(displayListener)
        for (holder in surfaces.keys) holder.removeCallback(surfaceCallback)
        surfaces.clear()
    }

    fun dispose() {
        pause()
        disposed = true
    }

    fun setMode(mode: String) {
        policy.setMode(mode, SystemClock.uptimeMillis())
        apply()
    }

    fun setFlutterActive(active: Boolean) {
        policy.updateFlutterActive(active)
        apply()
    }

    /** Runs before super.dispatchTouchEvent, ahead of Flutter gesture/animation dispatch. */
    fun touch(event: MotionEvent) {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN, MotionEvent.ACTION_MOVE, MotionEvent.ACTION_POINTER_DOWN ->
                policy.touch(true, SystemClock.uptimeMillis())
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> policy.touch(false, SystemClock.uptimeMillis())
            else -> return
        }
        apply()
    }

    fun nativeActivity() {
        policy.activity(SystemClock.uptimeMillis())
        apply()
    }

    @Suppress("DEPRECATION")
    private fun display(): Display? = root.display ?: activity.windowManager.defaultDisplay

    private fun Display.Mode.description() = RefreshDisplayMode(modeId, physicalWidth, physicalHeight, refreshRate)

    fun apply() {
        if (disposed) return
        val now = SystemClock.uptimeMillis()
        val display = display()
        val target = if (policy.wantsHighRate(now) && display != null) {
            fastestRefreshMode(display.mode.description(), display.supportedModes.map { it.description() })
        } else null
        requestedHz = target?.hz ?: 0f
        val attrs = activity.window.attributes
        if (attrs.preferredDisplayModeId != (target?.id ?: 0) || attrs.preferredRefreshRate != requestedHz) {
            attrs.preferredDisplayModeId = target?.id ?: 0
            attrs.preferredRefreshRate = requestedHz
            activity.window.attributes = attrs
        }
        // Android 15+ View voting complements the window request for HWUI/WebView.
        // Restore the default category on release so normal system heuristics apply.
        if (Build.VERSION.SDK_INT >= 35) {
            val rate = if (requestedHz > 0f) requestedHz else View.REQUESTED_FRAME_RATE_CATEGORY_DEFAULT
            if (root.requestedFrameRate != rate) root.requestedFrameRate = rate
        }
        for (holder in surfaces.keys) voteSurface(holder, requestedHz)
        val delay = policy.releaseDelay(now)
        if (delay == null) {
            handler.removeCallbacks(release)
            releasePending = false
        } else if (!releasePending) {
            releasePending = true
            handler.postDelayed(release, delay)
        }
    }

    private fun syncSurfaces() {
        if (!policy.foreground || disposed) return
        val found = mutableSetOf<SurfaceHolder>()
        fun visit(view: View) {
            // Do not override native video players' own content-rate votes.
            if (view is FlutterSurfaceView) found.add(view.holder)
            if (view is ViewGroup) for (i in 0 until view.childCount) visit(view.getChildAt(i))
        }
        visit(root)
        for (holder in surfaces.keys.toList()) {
            if (holder !in found) {
                voteSurface(holder, 0f)
                holder.removeCallback(surfaceCallback)
                surfaces.remove(holder)
            }
        }
        for (holder in found) {
            if (!surfaces.containsKey(holder)) {
                surfaces[holder] = null
                holder.addCallback(surfaceCallback)
            }
            voteSurface(holder, requestedHz)
        }
    }

    private fun voteSurface(holder: SurfaceHolder, hz: Float) {
        if (Build.VERSION.SDK_INT < 30 || !holder.surface.isValid || surfaces[holder] == hz) return
        try {
            if (Build.VERSION.SDK_INT >= 31) {
                holder.surface.setFrameRate(hz, Surface.FRAME_RATE_COMPATIBILITY_DEFAULT, Surface.CHANGE_FRAME_RATE_ONLY_IF_SEAMLESS)
            } else {
                holder.surface.setFrameRate(hz, Surface.FRAME_RATE_COMPATIBILITY_DEFAULT)
            }
            surfaces[holder] = hz
        } catch (_: IllegalStateException) {
            // Surface replacement can race the lifecycle callback; retry on creation/layout.
            surfaces[holder] = null
        } catch (_: IllegalArgumentException) {
            surfaces[holder] = null
        }
    }

    /** Numeric metadata only. These are reported modes/requests, never measured app FPS. */
    fun diagnostics(): Map<String, Any?> {
        val display = display()
        return mapOf(
            "sdkInt" to Build.VERSION.SDK_INT,
            "mode" to policy.mode,
            "foreground" to policy.foreground,
            "flutterActive" to policy.flutterActive,
            "touching" to policy.touching,
            "requestingHighRate" to policy.wantsHighRate(SystemClock.uptimeMillis()),
            "preferredDisplayModeId" to activity.window.attributes.preferredDisplayModeId,
            "requestedRefreshRateHz" to requestedHz,
            "surfaceVoteCount" to surfaces.values.count { it != null && it > 0f },
            "displayId" to display?.displayId,
            "activeModeId" to display?.mode?.modeId,
            "activeModeRefreshRateHz" to display?.mode?.refreshRate,
            "reportedRefreshRateHz" to display?.refreshRate,
            "supportedModes" to display?.supportedModes?.map {
                mapOf("id" to it.modeId, "width" to it.physicalWidth, "height" to it.physicalHeight, "refreshRateHz" to it.refreshRate)
            },
            "measuredAppFps" to null,
        )
    }
}
