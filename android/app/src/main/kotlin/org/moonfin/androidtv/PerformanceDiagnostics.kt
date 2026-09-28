package org.moonfin.androidtv

import android.app.Activity
import android.content.Context
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

/** Samples only on explicit Dart requests. PSS/proc reads stay off the UI thread. */
class PerformanceDiagnostics(activity: Activity, messenger: BinaryMessenger) {
    private val context = activity.applicationContext
    private val activityRef = WeakReference(activity)
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val channel = MethodChannel(messenger, "moonfin/performance")
    @Volatile private var closed = false

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method != "sample") {
                result.notImplemented()
            } else if (closed) {
                result.error("closed", "Diagnostic sampler closed", null)
            } else {
                val memory = call.argument<Boolean>("memory") == true
                @Suppress("DEPRECATION")
                val refresh = activityRef.get()?.windowManager?.defaultDisplay?.refreshRate
                worker.execute {
                    try {
                        val values = sample(memory).toMutableMap()
                        values["refreshHz"] = refresh
                        main.post { result.success(values) }
                    } catch (_: Exception) {
                        main.post { result.error("sample_failed", "Resource sample unavailable", null) }
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
                values[reportKey] = Debug.getRuntimeStat(nativeKey)?.toLongOrNull()
            }
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
                "model" to Build.MODEL,
                "os" to Build.VERSION.RELEASE,
                "sdk" to Build.VERSION.SDK_INT,
                "processors" to runtime.availableProcessors(),
                "fdCount" to File("/proc/self/fd").list()?.size,
            ))
            try {
                File("/proc/self/status").useLines { lines ->
                    lines.forEach { line ->
                        val key = when {
                            line.startsWith("VmRSS:") -> "rssKiB"
                            line.startsWith("Threads:") -> "threads"
                            else -> null
                        }
                        if (key != null) values[key] = line.substringAfter(':').trim().substringBefore(' ').toLongOrNull()
                    }
                }
            } catch (_: Exception) { /* optional on restricted Android builds */ }
        }
        values["sampleCostUs"] = (SystemClock.elapsedRealtimeNanos() - start) / 1000
        return values
    }

    fun close() {
        closed = true
        channel.setMethodCallHandler(null)
        activityRef.clear()
        worker.shutdown()
    }
}
