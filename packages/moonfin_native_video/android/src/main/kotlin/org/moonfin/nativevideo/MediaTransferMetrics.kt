package org.moonfin.nativevideo

import java.util.IdentityHashMap

/** Counts reads as they happen, including loads later canceled by a seek.
 * No URLs, headers, payloads, or per-packet events are retained.
 */
class MediaTransferMetrics(
    private val nowUs: () -> Long,
    private val emit: (Map<String, Any?>) -> Unit,
) {
    companion object {
        @Volatile var recordingEnabled = false
    }

    private data class Read(
        val id: Int, val openedUs: Long, val position: Long, val length: Long,
        var headersUs: Long? = null, var firstByteUs: Long? = null,
        var bytes: Long = 0,
    )
    private val reads = IdentityHashMap<Any, Read>()
    private var seekSerial = 0
    private var seekStartBytes = 0L
    private var generation = 0
    private var sequence = 0
    private var total = 0L
    private var ended = 0
    private var omitted = 0
    private var lastByteUs: Long? = null
    private var firstByteUs: Long? = null

    @Synchronized fun reset(value: Int) {
        generation = value
        seekSerial = 0
        seekStartBytes = 0
        reads.clear()
        sequence = 0
        total = 0
        ended = 0
        omitted = 0
        lastByteUs = null
        firstByteUs = null
    }

    @Synchronized fun seek(serial: Int) {
        seekSerial = serial
        seekStartBytes = total
    }

    private fun event(name: String, read: Read, data: Map<String, Any?> = emptyMap()) {
        try {
            emit(mapOf("event" to name, "diagnosticGeneration" to generation,
                "seekSerial" to seekSerial, "networkBytes" to total,
                "seekBytes" to total - seekStartBytes,
                "nativeUs" to nowUs(), "transfer" to read.id, "rangeStart" to read.position,
                "requestedBytes" to read.length) + data)
        } catch (_: Exception) { /* telemetry cannot interrupt a stream read */ }
    }

    @Synchronized fun initializing(key: Any, position: Long, length: Long) {
        if (!recordingEnabled || generation == 0) return
        // A data source is reusable. Release references on every end/reset.
        if (reads.size >= 32 && !reads.containsKey(key)) { omitted++; return }
        val read = Read(++sequence, nowUs(), position, length)
        reads[key] = read
        event("transfer.open", read)
    }

    @Synchronized fun started(key: Any, status: Int?) {
        if (!recordingEnabled) return
        val read = reads[key] ?: return
        read.headersUs = nowUs()
        event("transfer.headers", read, mapOf("durationUs" to nowUs() - read.openedUs,
            "status" to status))
    }

    @Synchronized fun bytes(key: Any, count: Int) {
        if (!recordingEnabled || count <= 0) return
        val read = reads[key] ?: return
        val now = nowUs()
        total += count
        read.bytes += count
        lastByteUs = now
        if (firstByteUs == null) firstByteUs = now
        if (read.firstByteUs == null) {
            read.firstByteUs = now
            event("transfer.first_byte", read, mapOf("durationUs" to now - read.openedUs))
        }
    }

    @Synchronized fun ended(key: Any) {
        val read = reads.remove(key) ?: return
        if (!recordingEnabled) return
        ended++
        // TransferListener end also means cancellation. Analytics load outcomes
        // are separate; this event deliberately makes no success claim.
        event("transfer.end", read, mapOf("durationUs" to nowUs() - read.openedUs,
            "bytes" to read.bytes, "outcome" to "ended"))
    }

    @Synchronized fun snapshot(): Map<String, Any?> {
        if (!recordingEnabled || generation == 0) return emptyMap()
        val now = nowUs()
        return mapOf("networkBytes" to total, "seekBytes" to total - seekStartBytes,
            "seekSerial" to seekSerial, "activeTransfers" to reads.size,
            "endedTransfers" to ended, "omittedTransfers" to omitted,
            "lastByteAgeUs" to lastByteUs?.let { now - it },
            "firstByteNativeUs" to firstByteUs)
    }
}
