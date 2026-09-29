package org.moonfin.nativevideo

import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

class MediaTransferMetricsTest {
    private var now = 1000L
    private val events = mutableListOf<Map<String, Any?>>()
    private val metrics = MediaTransferMetrics({ now }, { events.add(it) })

    @Before fun start() { MediaTransferMetrics.recordingEnabled = true; metrics.reset(9) }
    @After fun stop() { MediaTransferMetrics.recordingEnabled = false }

    @Test fun liveReadsIncludeCanceledTransfers() {
        val source = Any()
        metrics.initializing(source, 4096, -1)
        now = 2000; metrics.started(source, 206)
        now = 3000; metrics.bytes(source, 100)
        now = 4000; metrics.bytes(source, 200)
        assertEquals(300L, metrics.snapshot()["networkBytes"])
        assertEquals(1, metrics.snapshot()["activeTransfers"])
        assertEquals(1, events.count { it["event"] == "transfer.first_byte" })
        metrics.ended(source) // End is also called after a canceled seek load.
        assertEquals(300L, metrics.snapshot()["networkBytes"])
        assertEquals(0, metrics.snapshot()["activeTransfers"])
        assertEquals("ended", events.last()["outcome"])
        assertEquals(300L, events.last()["bytes"])
        assertEquals(2000L, events.first { it["event"] == "transfer.first_byte" }["durationUs"])
    }

    @Test fun resetRejectsStaleCallbacksAndClearsLiveReads() {
        val source = Any()
        metrics.initializing(source, 0, 50)
        metrics.bytes(source, 20)
        metrics.reset(10)
        metrics.bytes(source, 30)
        metrics.ended(source)
        assertEquals(0L, metrics.snapshot()["networkBytes"])
        assertEquals(0, metrics.snapshot()["activeTransfers"])
        metrics.initializing(source, 30, 20)
        metrics.bytes(source, 20)
        assertEquals(10, events.last()["diagnosticGeneration"])
    }

    @Test fun disabledRecorderAndTransferCapBoundWork() {
        MediaTransferMetrics.recordingEnabled = false
        metrics.initializing(Any(), 0, -1)
        assertTrue(events.isEmpty())
        assertTrue(metrics.snapshot().isEmpty())
        MediaTransferMetrics.recordingEnabled = true
        repeat(100) { metrics.initializing(Any(), 0, -1) }
        assertEquals(32, metrics.snapshot()["activeTransfers"])
        assertEquals(68, metrics.snapshot()["omittedTransfers"])
    }

    @Test fun throwingSinkDoesNotInterruptReads() {
        val broken = MediaTransferMetrics({ now }, { throw IllegalStateException("sink") })
        broken.reset(1)
        val source = Any()
        broken.initializing(source, 0, 10)
        broken.started(source, 200)
        broken.bytes(source, 10)
        broken.ended(source)
        assertEquals(10L, broken.snapshot()["networkBytes"])
    }
}
