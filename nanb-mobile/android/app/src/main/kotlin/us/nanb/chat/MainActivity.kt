package us.nanb.chat

import android.content.Intent
import android.content.SharedPreferences
import android.os.Bundle
import android.os.SystemClock
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.view.WindowManager
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// FlutterFragmentActivity (not FlutterActivity) is required by the local_auth
// plugin: BiometricPrompt needs a FragmentActivity host.
//
// The over-lock incoming-call ring is handled by the native IncomingCallActivity,
// NOT here — so MainActivity is an ordinary activity (no showWhenLocked). When the
// user taps Accept/Decline on that native ring it relaunches MainActivity with a
// `call_action` extra, which is routed to the Dart CallController via the
// nanb.app/call_action channel.
class MainActivity : FlutterFragmentActivity() {

    private var callActionChannel: MethodChannel? = null
    private var pendingAction: Map<String, String>? = null

    /** Last value the Dart "block screenshots" pref pushed via `setSecure`. */
    private var blockScreenshotsRequested = false

    /** Cached handle to flutter_secure_storage's EncryptedSharedPreferences so
     *  the app-lock state can be re-read cheaply on each resume/pause. */
    private var securePrefs: SharedPreferences? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        captureCallAction(intent)
        // "Share via Chat" from another app's share sheet, cold start. Only the
        // intent is read here; the streams are copied when Dart collects them.
        IncomingShareStore.capture(intent)
    }

    override fun onResume() {
        super.onResume()
        // Re-assert FLAG_SECURE from the current app-lock state on every resume,
        // so the recents/app-switcher snapshot is protected whenever the passcode
        // lock is on — the Dart side only drives the block-screenshots pref, so
        // without this an app-lock-only user's last chat leaks into the switcher.
        applySecureFlag()
    }

    override fun onPause() {
        // Re-read the lock state right before the OS captures the recents
        // snapshot, so enabling app-lock mid-session is honored on the very next
        // background (onResume already ran with the pre-toggle value this session).
        applySecureFlag()
        super.onPause()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        captureCallAction(intent)
        // Warm share: the activity was already alive. No push to Dart is
        // needed — onNewIntent is followed by onResume, and the Dart side pulls
        // any pending share on every foreground (see NanbApp).
        IncomingShareStore.capture(intent)
        // The engine is already running (warm) — push the action straight through.
        pendingAction?.let { a ->
            callActionChannel?.invokeMethod("onCallAction", a)
            pendingAction = null
        }
    }

    /** Stash an Accept/Decline handed back by IncomingCallActivity for app.dart. */
    private fun captureCallAction(intent: Intent?) {
        val action = intent?.getStringExtra("call_action") ?: return
        val conv = intent.getStringExtra("conversation_id") ?: ""
        pendingAction = mapOf("action" to action, "conversationId" to conv)
        // Consume so a config-change recreate doesn't replay it.
        intent.removeExtra("call_action")
        // PRIVACY: never log the conversation id (who-talks-to-whom metadata).
        // The accept/decline action alone is not identifying.
        android.util.Log.i("NANBCALL", "MainActivity captured call action=$action")
    }

    /** Keep the screen on for the live span of an IN-APP call (driven by Dart). */
    private fun engageCallWindow() {
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    private fun releaseCallWindow() {
        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        // FLAG_SECURE toggle (block screenshots / recents thumbnail). Dart side:
        // lib/core/platform/secure_screen.dart. This only carries the user's
        // "block screenshots" preference; the app-lock case is OR'd in natively
        // by applySecureFlag() (see appLockEnabled()).
        MethodChannel(messenger, "nanb.app/secure_screen")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setSecure" -> {
                        blockScreenshotsRequested = call.argument<Boolean>("secure") ?: false
                        applySecureFlag()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        // Keep the screen on for an in-app call. Dart side: call_window.dart.
        MethodChannel(messenger, "nanb.app/call_window")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "engage" -> { runOnUiThread { engageCallWindow() }; result.success(null) }
                    "release" -> { runOnUiThread { releaseCallWindow() }; result.success(null) }
                    else -> result.notImplemented()
                }
            }

        // Keep the process alive in the background for a live call so an audio
        // call survives a screen lock / app-switch (FLAG_KEEP_SCREEN_ON only
        // covers the foreground auto-timeout). Starts a microphone foreground
        // service + partial wake lock. Dart side: call_foreground_service.dart.
        MethodChannel(messenger, "nanb.app/call_foreground")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> result.success(CallForegroundService.start(this))
                    "stop" -> { CallForegroundService.stop(this); result.success(null) }
                    else -> result.notImplemented()
                }
            }

        // Boot-relative monotonic clock for the passcode brute-force lockout.
        // SystemClock.elapsedRealtime() is unaffected by changing the device
        // date/time, so "roll the clock forward to skip the lockout" can't work.
        // Dart side: lib/core/platform/monotonic_clock.dart.
        MethodChannel(messenger, "nanb.app/monotonic_clock")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "elapsedRealtimeMs" -> result.success(SystemClock.elapsedRealtime())
                    else -> result.notImplemented()
                }
            }

        // OS share sheet ("Share via Chat"). Dart pulls the pending share on
        // cold start and on every foreground; the reply carries the shared text
        // plus cache-file copies of any shared streams. The copying happens on a
        // worker thread inside take() — a `content://` stream can't be read from
        // Dart, and copying a shared video on the UI thread would ANR.
        // Dart side: lib/core/platform/incoming_share_channel.dart.
        MethodChannel(messenger, "nanb.app/incoming_share")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "takePending" ->
                        IncomingShareStore.take(this) { payload -> result.success(payload) }
                    else -> result.notImplemented()
                }
            }

        // Native IncomingCallActivity hands Accept/Decline back here. Dart pulls
        // any pending action on startup (cold) and we push on onNewIntent (warm).
        callActionChannel = MethodChannel(messenger, "nanb.app/call_action").also {
            it.setMethodCallHandler { call, result ->
                when (call.method) {
                    "getPending" -> {
                        val a = pendingAction
                        pendingAction = null
                        result.success(a)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    /**
     * Apply/clear FLAG_SECURE. The window is secure if EITHER the user's
     * block-screenshots preference (pushed from Dart via `setSecure`) OR the
     * in-app passcode lock is enabled. FLAG_SECURE also blanks the recents /
     * app-switcher thumbnail, so a locked app's last chat never leaks into the
     * multitasking preview.
     */
    private fun applySecureFlag() {
        val secure = blockScreenshotsRequested || appLockEnabled()
        runOnUiThread {
            if (secure) {
                window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
            } else {
                window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
            }
        }
    }

    /**
     * True when the in-app passcode lock is enabled. Read from the same store the
     * Flutter side persists AppPreferences to — flutter_secure_storage with
     * `AndroidOptions(encryptedSharedPreferences: true)`. That store is an
     * androidx EncryptedSharedPreferences file; we open it with the SAME config
     * the plugin uses (file name, master key, key/value schemes) and read the
     * `pref.passcode_enabled` key under the plugin's fixed key prefix.
     *
     * Any failure (store not yet created, keystore hiccup, plugin format change)
     * falls back to false, i.e. FLAG_SECURE is then driven by the Dart pref only
     * (the pre-existing behavior) — never a crash.
     */
    private fun appLockEnabled(): Boolean {
        return try {
            val prefs = securePrefs ?: openSecurePrefs()?.also { securePrefs = it }
            prefs?.getString(SECURE_STORAGE_KEY_PREFIX + "_" + PASSCODE_ENABLED_PREF, null) == "true"
        } catch (e: Exception) {
            false
        }
    }

    /**
     * Opens flutter_secure_storage 9.x's EncryptedSharedPreferences, mirroring
     * `FlutterSecureStorage#initializeEncryptedSharedPreferencesManager` exactly
     * so we read the same file the plugin writes. Read-only use here; opening a
     * second instance over the same file + master key is safe.
     */
    private fun openSecurePrefs(): SharedPreferences? {
        val masterKey = MasterKey.Builder(this)
            .setKeyGenParameterSpec(
                KeyGenParameterSpec.Builder(
                    MasterKey.DEFAULT_MASTER_KEY_ALIAS,
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                )
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setKeySize(256)
                    .build()
            )
            .build()
        return EncryptedSharedPreferences.create(
            this,
            SECURE_STORAGE_FILE,
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )
    }

    companion object {
        // flutter_secure_storage 9.x Android storage layout. Every key is stored
        // under FIXED_PREFIX + "_" + <key>; the app persists AppPreferences here
        // via AndroidOptions(encryptedSharedPreferences: true).
        private const val SECURE_STORAGE_FILE = "FlutterSecureStorage"
        private const val SECURE_STORAGE_KEY_PREFIX =
            "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIHNlY3VyZSBzdG9yYWdlCg"
        // AppPreferencesRepository._kPasscodeEnabled (the in-app passcode lock).
        private const val PASSCODE_ENABLED_PREF = "pref.passcode_enabled"
    }
}
