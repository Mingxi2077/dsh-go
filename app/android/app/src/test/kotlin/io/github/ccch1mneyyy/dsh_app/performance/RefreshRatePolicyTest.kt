package io.github.ccch1mneyyy.dsh_app.performance

import org.junit.Assert.*
import org.junit.Test

class RefreshRatePolicyTest {
    @Test fun resumeRequestsBeforeAnyFrameAndExpiresWithoutFrames() {
        val policy = RefreshRatePolicy()
        assertFalse(policy.wantsHighRate(0))
        policy.resume(100)
        assertTrue(policy.wantsHighRate(100))
        assertEquals(700L, policy.releaseDelay(100))
        assertFalse(policy.wantsHighRate(800))
        assertNull(policy.releaseDelay(800))
    }

    @Test fun touchAndNativeFlingOutliveFlutterIdleAndReleaseAfterLastScroll() {
        val policy = RefreshRatePolicy()
        policy.resume(0)
        policy.touch(true, 800)
        policy.updateFlutterActive(true)
        policy.updateFlutterActive(false)
        // A stationary long press must not lose the request after 700 ms.
        assertTrue(policy.wantsHighRate(3000))
        assertNull(policy.releaseDelay(3000))
        policy.touch(false, 3100)
        // Native scroll notifications continue after the finger leaves the screen.
        for (time in 3200L..6000L step 100) {
            policy.activity(time)
            policy.updateFlutterActive(false)
            assertTrue(policy.wantsHighRate(time))
        }
        assertEquals(1L, policy.releaseDelay(6699))
        assertFalse(policy.wantsHighRate(6700))
    }

    @Test fun flutterAnimationCanOutliveNativeIdleLease() {
        val policy = RefreshRatePolicy()
        policy.resume(0)
        policy.updateFlutterActive(true)
        assertTrue(policy.wantsHighRate(8000))
        assertNull(policy.releaseDelay(8000))
        policy.updateFlutterActive(false)
        assertFalse(policy.wantsHighRate(8000))
    }

    @Test fun maxReleasesInBackgroundAndIgnoresLateCallbacks() {
        val policy = RefreshRatePolicy("max")
        policy.resume(0)
        assertTrue(policy.wantsHighRate(8000))
        policy.pause()
        policy.activity(8100)
        policy.touch(true, 8100)
        policy.updateFlutterActive(true)
        assertFalse(policy.wantsHighRate(8100))
        assertFalse(policy.touching)
        assertFalse(policy.flutterActive)
        policy.resume(9000)
        assertTrue(policy.wantsHighRate(20000))
    }

    @Test fun systemNeverRequestsDespiteEveryActivitySource() {
        val policy = RefreshRatePolicy("system")
        policy.resume(0)
        policy.touch(true, 100)
        policy.activity(200)
        policy.updateFlutterActive(true)
        assertFalse(policy.wantsHighRate(200))
        assertNull(policy.releaseDelay(200))
        policy.pause()
        policy.resume(1000)
        assertFalse(policy.wantsHighRate(1000))
    }

    @Test fun modeChangesDoNotLeakOldFlutterActivity() {
        val policy = RefreshRatePolicy()
        policy.resume(0)
        policy.updateFlutterActive(true)
        policy.setMode("system", 100)
        assertFalse(policy.wantsHighRate(100))
        policy.setMode("max", 200)
        assertTrue(policy.wantsHighRate(200))
        policy.setMode("auto", 300)
        assertTrue(policy.wantsHighRate(300))
        assertFalse(policy.wantsHighRate(1000))
        policy.setMode("auto", 1000) // Same setting must not renew an idle lease.
        policy.setMode("invalid", 1000)
        assertFalse(policy.wantsHighRate(1000))
        assertEquals("auto", policy.mode)
    }

    @Test fun backgroundModeChangeCannotStartARequestAndResumeClearsOldTouch() {
        val policy = RefreshRatePolicy()
        policy.resume(0)
        policy.touch(true, 100)
        policy.pause()
        policy.setMode("max", 200)
        assertFalse(policy.wantsHighRate(200))
        policy.setMode("auto", 300)
        policy.resume(1000)
        assertFalse(policy.wantsHighRate(1700))
    }

    @Test fun fastestModeKeepsResolutionAndRejectsInvalidRates() {
        val current = RefreshDisplayMode(4, 1316, 2832, 60f)
        val fastest = current.copy(id = 1, hz = 120f)
        val modes = listOf(current, fastest, current.copy(id = 2, hz = 90f),
            current.copy(id = 9, width = 1080, height = 1920, hz = 144f),
            current.copy(id = 10, hz = Float.NaN), current.copy(id = 11, hz = Float.POSITIVE_INFINITY))
        assertEquals(fastest, fastestRefreshMode(current, modes))
        assertEquals(current, fastestRefreshMode(current, listOf(current)))
        assertNull(fastestRefreshMode(current, emptyList()))
        assertNull(fastestRefreshMode(current, listOf(current.copy(hz = 0f))))
    }
}
