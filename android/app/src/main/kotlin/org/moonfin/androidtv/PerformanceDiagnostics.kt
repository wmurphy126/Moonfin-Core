package org.moonfin.androidtv

import android.app.Activity
import android.app.ActivityManager
import android.content.ComponentCallbacks2
import android.content.Context
import android.content.res.Configuration
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.BatteryManager
import android.os.Build
import android.os.Debug
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.Process
import android.os.SystemClock
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.lang.ref.WeakReference
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import org.moonfin.nativevideo.MediaTransferMetrics

/** Samples only on explicit Dart requests. PSS/proc reads stay off the UI thread. */
class PerformanceDiagnostics(activity: Activity, messenger: BinaryMessenger) : ComponentCallbacks2 {
    private val context = activity.applicationContext
    private val activityRef = WeakReference(activity)
    private val worker = Executors.newSingleThreadExecutor()
    private val sampling = AtomicBoolean(false)
    private val main = Handler(Looper.getMainLooper())
    private val channel = MethodChannel(messenger, "moonfin/performance")
    @Volatile private var closed = false
    @Volatile private var configured = false
    @Volatile private var mainDelayMaxMs = 0L
    @Volatile private var mainDelayCount = 0
    @Volatile private var trimLevel = -1
    @Volatile private var trimCount = 0
    private var heartbeatAt = 0L
    private val previousCounters = mutableMapOf<String, Long>()
    private var previousMemoryAt = 0L
    private val heartbeat = object : Runnable {
        override fun run() {
            if (!configured || closed) return
            val now = SystemClock.elapsedRealtime()
            val delay = (now - heartbeatAt - 250).coerceAtLeast(0)
            if (delay > mainDelayMaxMs) mainDelayMaxMs = delay
            if (delay > 100) mainDelayCount++
            heartbeatAt = now
            main.postDelayed(this, 250)
        }
    }

    private fun configure(enabled: Boolean) {
        if (enabled == configured) return
        configured = enabled
        MediaTransferMetrics.recordingEnabled = enabled
        main.removeCallbacks(heartbeat)
        if (enabled) {
            mainDelayMaxMs = 0
            mainDelayCount = 0
            trimCount = 0
            trimLevel = -1
            heartbeatAt = SystemClock.elapsedRealtime()
            context.registerComponentCallbacks(this)
            main.postDelayed(heartbeat, 250)
        } else {
            context.unregisterComponentCallbacks(this)
        }
    }

    override fun onTrimMemory(level: Int) { trimLevel = level; trimCount++ }
    override fun onLowMemory() { trimLevel = 100; trimCount++ }
    override fun onConfigurationChanged(config: Configuration) {}

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method == "configure") {
                configure(call.argument<Boolean>("enabled") == true && !closed)
                result.success(null)
            } else if (call.method != "sample") {
                result.notImplemented()
            } else if (closed) {
                result.error("closed", "Diagnostic sampler closed", null)
            } else if (!sampling.compareAndSet(false, true)) {
                // Dart can time out while Android is still collecting a sample.
                // Never let subsequent requests accumulate behind a stuck read.
                result.error("busy", "Resource sample already running", null)
            } else {
                val memory = call.argument<Boolean>("memory") == true
                @Suppress("DEPRECATION")
                val refresh = activityRef.get()?.windowManager?.defaultDisplay?.refreshRate
                worker.execute {
                    try {
                        // Only the worker owns delta baselines. A new recording
                        // explicitly asks for a fresh baseline on its first sample.
                        if (call.argument<Boolean>("reset") == true) {
                            previousCounters.clear()
                            previousMemoryAt = 0
                        }
                        val values = sample(memory).toMutableMap()
                        values["refreshHz"] = refresh
                        main.post { if (!closed) result.success(values) }
                    } catch (_: Exception) {
                        main.post { if (!closed) result.error("sample_failed", "Resource sample unavailable", null) }
                    } finally {
                        sampling.set(false)
                    }
                }
            }
        }
    }

    private fun sample(memory: Boolean): Map<String, Any?> {
        val start = SystemClock.elapsedRealtimeNanos()
        val power = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        val battery = context.getSystemService(Context.BATTERY_SERVICE) as BatteryManager
        val connectivity = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val caps = connectivity.getNetworkCapabilities(connectivity.activeNetwork)
        val network = when {
            caps == null -> "offline"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN) -> "vpn"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
            else -> "other"
        }
        val values = mutableMapOf<String, Any?>(
            "elapsedRealtimeMs" to SystemClock.elapsedRealtime(),
            "nativeUs" to start / 1000,
            "cpuTimeMs" to Process.getElapsedCpuTime(),
            "powerSave" to power.isPowerSaveMode,
            "charging" to battery.isCharging,
            "thermalStatus" to if (Build.VERSION.SDK_INT >= 29) power.currentThermalStatus else null,
            "network" to network,
            "networkValidated" to caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED),
            "metered" to connectivity.isActiveNetworkMetered,
            "mainHeartbeatMaxDelayMs" to mainDelayMaxMs,
            "mainHeartbeatDelayedCount" to mainDelayCount,
            "trimCount" to trimCount,
            "lastTrimLevel" to trimLevel,
        )
        if (memory) {
            // ART counters cover Java/Kotlin allocation and GC, not the Dart heap.
            for ((nativeKey, reportKey) in mapOf(
                "art.gc.gc-count" to "artGcCount",
                "art.gc.gc-time" to "artGcTimeMs",
                "art.gc.blocking-gc-count" to "artBlockingGcCount",
                "art.gc.blocking-gc-time" to "artBlockingGcTimeMs",
                "art.gc.bytes-allocated" to "artBytesAllocated",
                "art.gc.bytes-freed" to "artBytesFreed",
            )) {
                val value = Debug.getRuntimeStat(nativeKey)?.toLongOrNull()
                values[reportKey] = value
                if (value != null) {
                    val previous = previousCounters.put(reportKey, value)
                    if (previous != null && value >= previous) values[reportKey + "Delta"] = value - previous
                }
            }
            val memoryAt = SystemClock.elapsedRealtime()
            if (previousMemoryAt != 0L) values["memoryIntervalMs"] = memoryAt - previousMemoryAt
            previousMemoryAt = memoryAt
            val info = Debug.MemoryInfo()
            Debug.getMemoryInfo(info)
            val runtime = Runtime.getRuntime()
            values.putAll(mapOf(
                "pssKiB" to info.totalPss,
                "privateDirtyKiB" to info.totalPrivateDirty,
                "dalvikPssKiB" to info.dalvikPss,
                "nativePssKiB" to info.nativePss,
                "otherPssKiB" to info.otherPss,
                "javaUsedBytes" to runtime.totalMemory() - runtime.freeMemory(),
                "nativeAllocatedBytes" to Debug.getNativeHeapAllocatedSize(),
                "nativeHeapBytes" to Debug.getNativeHeapSize(),
                "nativeFreeBytes" to Debug.getNativeHeapFreeSize(),
                "javaCommittedBytes" to runtime.totalMemory(),
                "javaLimitBytes" to runtime.maxMemory(),
                "graphicsKiB" to info.getMemoryStat("summary.graphics")?.toLongOrNull(),
                "privateOtherKiB" to info.getMemoryStat("summary.private-other")?.toLongOrNull(),
                "codeKiB" to info.getMemoryStat("summary.code")?.toLongOrNull(),
                "model" to Build.MODEL,
                "os" to Build.VERSION.RELEASE,
                "sdk" to Build.VERSION.SDK_INT,
                "processors" to runtime.availableProcessors(),
                "fdCount" to File("/proc/self/fd").list()?.size,
            ))
            val deviceMemory = ActivityManager.MemoryInfo()
            (context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).getMemoryInfo(deviceMemory)
            values["deviceAvailableBytes"] = deviceMemory.availMem
            values["deviceLowMemory"] = deviceMemory.lowMemory
            try {
                File("/proc/self/status").useLines { lines ->
                    lines.forEach { line ->
                        val key = when {
                            line.startsWith("VmRSS:") -> "rssKiB"
                            line.startsWith("Threads:") -> "threads"
                            line.startsWith("VmHWM:") -> "rssPeakKiB"
                            line.startsWith("RssAnon:") -> "rssAnonymousKiB"
                            line.startsWith("RssFile:") -> "rssFileKiB"
                            line.startsWith("RssShmem:") -> "rssSharedKiB"
                            line.startsWith("voluntary_ctxt_switches:") -> "voluntarySwitches"
                            line.startsWith("nonvoluntary_ctxt_switches:") -> "involuntarySwitches"
                            else -> null
                        }
                        if (key != null) values[key] = line.substringAfter(':').trim().substringBefore(' ').toLongOrNull()
                    }
                }
            } catch (_: Exception) { /* optional on restricted Android builds */ }
            try {
                File("/proc/self/io").useLines { lines -> lines.forEach { line ->
                    val key = when (line.substringBefore(':')) {
                        "read_bytes" -> "storageReadBytes"
                        "write_bytes" -> "storageWriteBytes"
                        "rchar" -> "processReadBytes"
                        "wchar" -> "processWriteBytes"
                        else -> null
                    }
                    if (key != null) values[key] = line.substringAfter(':').trim().toLongOrNull()
                } }
            } catch (_: Exception) { /* some devices restrict proc I/O counters */ }
        }
        values["sampleCostUs"] = (SystemClock.elapsedRealtimeNanos() - start) / 1000
        return values
    }

    fun close() {
        configure(false)
        closed = true
        channel.setMethodCallHandler(null)
        activityRef.clear()
        worker.shutdown()
    }
}
