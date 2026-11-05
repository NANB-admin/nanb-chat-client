package us.nanb.crypto

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Embedded Tor for Android — now backed by ARTI (pure-Rust Tor) via the
 * `nanb-arti-ffi` JNI bridge ([ArtiNative]), REPLACING Guardian Project C-tor
 * (`tor-android` + jtorctl). One Rust Tor engine across iOS + Android.
 *
 * Arti runs in-process (a Rust-owned Tokio runtime + an in-process SOCKS5 proxy),
 * so there's no `TorService`, no control-port polling, and no broadcast plumbing —
 * we just POLL the FFI (isReady / socksPort / bootstrapPct) and emit the status.
 *
 * Wiring (matches the Dart `TorEngineChannel`) — UNCHANGED, so the plugin
 * registration + the Dart side need no edits:
 *  - MethodChannel `nanb.app/tor`        : start / stop / reconnect / prepareForBackground / wake
 *  - EventChannel  `nanb.app/tor_status` : Map{phase, percent?, socksPort?, message?}
 *      phase ∈ off | starting | bootstrapping | connected | error
 */
class TorChannel(private val context: Context) : EventChannel.StreamHandler {

    companion object {
        const val METHOD_CHANNEL = "nanb.app/tor"
        const val EVENT_CHANNEL = "nanb.app/tor_status"
        private const val TAG = "NANBARTI"
        private const val POLL_INTERVAL_MS = 1000L
        private const val CONNECT_DEADLINE_MS = 180_000L
    }

    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null

    @Volatile private var pollGeneration = 0
    @Volatile private var started = false

    // ── MethodChannel ─────────────────────────────────────────────────────────

    fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "start" -> { start(); result.success(null) }
                "stop" -> { stop(); result.success(null) }
                "reconnect" -> { reconnect(); result.success(null) }
                // Pause → dormant: suspend Arti's background upkeep before the app
                // is backgrounded, keeping the client + SOCKS port warm so a resume
                // is a cheap wake, not a re-bootstrap.
                "prepareForBackground" -> { setDormant(true); result.success(null) }
                // Resume → wake: resume background upkeep. (Arti also auto-wakes on
                // first use, so this just gets preemptive circuits building again.)
                "wake" -> { setDormant(false); result.success(null) }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            android.util.Log.i(TAG, "TorChannel error: $e")
            emit("error", message = e.message)
            result.error("tor_error", e.message, null)
        }
    }

    // ── EventChannel.StreamHandler ────────────────────────────────────────────

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    // ── Lifecycle ─────────────────────────────────────────────────────────────

    /** Arti's state + cache directory: `<app filesDir>/arti` (the Rust side
     *  creates `arti-state` / `arti-cache` subdirs under it). */
    private fun dataDir(): String = context.filesDir.resolve("arti").absolutePath

    private fun start() {
        if (started) return
        started = true
        emit("starting")
        emit("bootstrapping", percent = 0)
        val dir = dataDir()
        Thread {
            val rc = ArtiNative.nativeStart(dir)
            if (rc != 0) {
                emit("error", message = ArtiNative.nativeLastError()
                    ?: "Tor (Arti) failed to start ($rc).")
                return@Thread
            }
            startPolling()
        }.start()
    }

    private fun stop() {
        pollGeneration++
        started = false
        Thread { ArtiNative.nativeStop() }.start()
        emit("off")
        android.util.Log.i(TAG, "stop requested")
    }

    /** Resume / recovery path. The old assumption — "Android keeps the process
     *  alive, so there's no wedge to recover from, just re-poll" — is WRONG:
     *  during Doze/deep sleep the OS kills Arti's TCP connections and its
     *  circuits die, yet its in-process SOCKS listener stays bound, so
     *  nativeIsReady()/nativeSocksPort() keep reporting "connected" while every
     *  SOCKS CONNECT to the server .onion is refused. A re-poll can NEVER heal
     *  that. So actually reset the engine: tear it down and bootstrap a fresh
     *  one (new circuits + SOCKS port). nativeStart is a no-op while the engine
     *  is alive, so the stop MUST complete first — do both off the main thread.
     *  The Dart side optimistically holds `bootstrapping` until we re-emit. */
    private fun reconnect() {
        pollGeneration++ // cancel any in-flight poll loop from the old engine
        emit("bootstrapping", percent = 0)
        val dir = dataDir()
        Thread {
            ArtiNative.nativeStop() // cancels tasks, drops the client, frees the data-dir locks
            val rc = ArtiNative.nativeStart(dir)
            if (rc != 0) {
                started = false
                emit("error", message = ArtiNative.nativeLastError()
                    ?: "Tor (Arti) failed to restart ($rc).")
                return@Thread
            }
            started = true
            startPolling()
        }.start()
    }

    /** Suspend/resume Arti's background activity around an app pause/resume
     *  without tearing it down (keeps the client + SOCKS port warm). Runs off the
     *  main thread — a JNI hop shouldn't block the platform-channel callback. The
     *  native side no-ops until the engine has bootstrapped. */
    private fun setDormant(dormant: Boolean) {
        Thread { ArtiNative.nativeSetDormant(dormant) }.start()
    }

    // ── Bootstrap polling ─────────────────────────────────────────────────────

    private fun startPolling() {
        val gen = ++pollGeneration
        val deadline = System.currentTimeMillis() + CONNECT_DEADLINE_MS
        Thread {
            while (gen == pollGeneration && System.currentTimeMillis() < deadline) {
                val pct = ArtiNative.nativeBootstrapPct()
                if (ArtiNative.nativeIsReady()) {
                    val port = ArtiNative.nativeSocksPort()
                    if (port > 0) {
                        android.util.Log.i(TAG, "connected: socks=$port")
                        emit("connected", percent = 100, socksPort = port)
                        return@Thread
                    }
                }
                emit("bootstrapping", percent = pct)
                try {
                    Thread.sleep(POLL_INTERVAL_MS)
                } catch (_: InterruptedException) {
                    return@Thread
                }
            }
            if (gen == pollGeneration) {
                emit("error", message = ArtiNative.nativeLastError()
                    ?: "Tor (Arti) is taking longer than usual to connect.")
            }
        }.start()
    }

    private fun emit(
        phase: String,
        percent: Int? = null,
        socksPort: Int? = null,
        message: String? = null,
    ) {
        val map = HashMap<String, Any?>()
        map["phase"] = phase
        if (percent != null) map["percent"] = percent
        if (socksPort != null) map["socksPort"] = socksPort
        if (message != null) map["message"] = message
        main.post { sink?.success(map) }
    }
}
