package io.github.ccch1mneyyy.dsh_app.performance

/** Independent activity sources: Flutter going idle must not cancel a native fling. */
internal class RefreshRatePolicy(initialMode: String = "auto") {
    var mode: String = initialMode
        private set
    var foreground = false
        private set
    var flutterActive = false
        private set
    var touching = false
        private set
    private var nativeUntil = 0L

    fun setMode(value: String, now: Long) {
        if (value !in MODES || value == mode) return
        mode = value
        flutterActive = false
        nativeUntil = 0L
        if (value == "auto") activity(now)
    }

    fun resume(now: Long) {
        foreground = true
        activity(now)
    }

    fun pause() {
        foreground = false
        flutterActive = false
        touching = false
        nativeUntil = 0L
    }

    fun updateFlutterActive(active: Boolean) {
        flutterActive = foreground && mode == "auto" && active
    }

    fun touch(down: Boolean, now: Long) {
        touching = foreground && down
        activity(now)
    }

    fun activity(now: Long) {
        if (foreground && mode == "auto") nativeUntil = now + IDLE_MILLIS
    }

    fun wantsHighRate(now: Long): Boolean = foreground && when (mode) {
        "max" -> true
        "auto" -> flutterActive || touching || now < nativeUntil
        else -> false
    }

    /** No polling/frame production: wake once at the end of the native idle lease. */
    fun releaseDelay(now: Long): Long? =
        if (foreground && mode == "auto" && !flutterActive && !touching && now < nativeUntil) nativeUntil - now else null

    companion object {
        const val IDLE_MILLIS = 700L
        val MODES = setOf("auto", "max", "system")
    }
}

internal data class RefreshDisplayMode(val id: Int, val width: Int, val height: Int, val hz: Float)

/** A higher rate must never change the display's physical resolution. */
internal fun fastestRefreshMode(current: RefreshDisplayMode, modes: List<RefreshDisplayMode>): RefreshDisplayMode? =
    modes.filter { it.width == current.width && it.height == current.height && it.hz.isFinite() && it.hz > 0f }
        .maxByOrNull { it.hz }
