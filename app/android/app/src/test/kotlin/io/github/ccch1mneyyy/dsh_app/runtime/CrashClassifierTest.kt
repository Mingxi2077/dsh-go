package io.github.ccch1mneyyy.dsh_app.runtime

import org.junit.Assert.*
import org.junit.Test

class CrashClassifierTest {
    private val fatal = listOf("dsh: startup failed: required row missing")

    @Test fun classifiesAllFiveFailureKinds() {
        fun classify(ready: Long?, now: Long, tail: List<String>) =
            CrashClassifier.classify(137, ready, now, 123L, tail, false).kind
        assertEquals(FailureKind.KILLED, classify(1L, 180_000L, listOf("normal output")))
        assertEquals(FailureKind.STARTUP_FAILED, classify(null, 1L, fatal))
        assertEquals(FailureKind.CRASHED_EARLY, classify(1L, 120_001L, fatal))
        assertEquals(FailureKind.CRASHED_LATE, classify(1L, 120_002L, fatal))
        assertEquals(FailureKind.NO_SPACE, classify(null, 1L, fatal + "ENOSPC"))
    }

    @Test fun aHeapAbortCountsOnlyNearStartup() {
        val oom = listOf(
            "<--- Last few GCs --->",
            "FATAL ERROR: Reached heap limit Allocation failed - JavaScript heap out of memory",
        )
        fun classify(ready: Long?, now: Long) = CrashClassifier.classify(134, ready, now, 1L, oom, false)
        assertEquals(FailureKind.STARTUP_FAILED, classify(null, 1L).kind)
        assertEquals(FailureKind.CRASHED_EARLY, classify(1L, 60_000L).kind)
        // Late: a long session may simply outgrow the heap; it stays an uncounted kill (auto restart).
        assertEquals(FailureKind.KILLED, classify(1L, 600_000L).kind)
        assertTrue(classify(null, 1L).summary!!.contains("heap out of memory"))
        assertTrue(classify(null, 1L).kind.counts)
    }

    @Test fun summariesNeverContainLaunchTokens() {
        val failure = CrashClassifier.classify(1, null, 1L, 1L,
            listOf("dsh: startup failed: http://localhost/?token=private-value"), false)
        assertFalse(failure.summary!!.contains("private-value"))
        assertTrue(failure.summary!!.contains("token="))
    }
}
