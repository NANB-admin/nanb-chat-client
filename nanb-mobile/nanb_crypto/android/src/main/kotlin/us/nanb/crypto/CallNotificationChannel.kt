package us.nanb.crypto

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Posts the INCOMING-CALL notification natively so its full-screen intent can
 * target the app's native `IncomingCallActivity` — a statically-declared
 * `showWhenLocked` activity that persists over a secure lock. The OS launching
 * that activity via the full-screen intent is background-activity-launch exempt,
 * which a MainActivity→activity trampoline is NOT (it's blocked on Android 12+).
 * flutter_local_notifications cannot retarget its full-screen intent away from
 * the launcher activity, so the call path is posted here instead of via FLN.
 *
 * Registered on EVERY FlutterEngine by [NanbCryptoPlugin] — including the
 * firebase_messaging background isolate's engine, where the call push is handled.
 * It only reads the opaque conversation id + caller from the push; it never
 * touches ciphertext, so the "background never decrypts" invariant holds.
 *
 * Lives in the plugin module (not the app module) only because that is what gets
 * auto-registered onto the bg isolate engine; it targets the app's activity by
 * class NAME to avoid a circular module dependency.
 */
class CallNotificationChannel(private val context: Context) {
    companion object {
        const val CHANNEL_NAME = "nanb.app/call_native"
        private const val NOTIF_CHANNEL_ID = "nanb-incoming-call"
        private const val APP_PKG = "us.nanb.chat"
        private const val ACTIVITY = "us.nanb.chat.IncomingCallActivity"
    }

    fun onCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "showIncomingCall" -> {
                    val convId = call.argument<String>("conversationId") ?: ""
                    val caller = call.argument<String>("caller") ?: ""
                    val id = call.argument<Int>("id") ?: convId.hashCode()
                    showIncomingCall(id, convId, caller)
                    result.success(null)
                }
                "cancelIncomingCall" -> {
                    val id = call.argument<Int>("id") ?: 0
                    notifManager().cancel(id)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            android.util.Log.i("NANBCALL", "CallNotificationChannel error: $e")
            result.error("call_notif_error", e.message, null)
        }
    }

    private fun showIncomingCall(id: Int, convId: String, caller: String) {
        ensureChannel()
        val fsIntent = Intent().apply {
            setClassName(APP_PKG, ACTIVITY)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            putExtra("conversation_id", convId)
            putExtra("caller", caller)
            putExtra("notif_id", id)
        }
        var piFlags = PendingIntent.FLAG_UPDATE_CURRENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            piFlags = piFlags or PendingIntent.FLAG_IMMUTABLE
        }
        val pi = PendingIntent.getActivity(context, id, fsIntent, piFlags)

        val name = if (caller.isEmpty()) "Unknown" else caller
        val iconRes = context.resources.getIdentifier(
            "ic_stat_nanb", "drawable", context.packageName
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, NOTIF_CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }
        builder
            .setSmallIcon(if (iconRes != 0) iconRes else android.R.drawable.sym_call_incoming)
            .setContentTitle("Incoming call")
            .setContentText(name)
            .setCategory(Notification.CATEGORY_CALL)
            .setOngoing(true)
            .setAutoCancel(false)
            .setFullScreenIntent(pi, true)
            .setContentIntent(pi)
        @Suppress("DEPRECATION")
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            builder.setPriority(Notification.PRIORITY_MAX)
        }

        val nm = notifManager()
        // Cancel any prior call notif with this id first so the full-screen intent
        // re-fires on a fresh post (Android treats a same-id re-post as a silent
        // update and would NOT re-launch the activity).
        nm.cancel(id)
        nm.notify(id, builder.build())

        // ALSO launch the ring activity directly. The notification's full-screen
        // intent only auto-launches when the screen is LOCKED/off; while the
        // device is UNLOCKED and in use (home screen or another app) Android
        // demotes the FSI to a heads-up banner — so the full-screen ring never
        // appears, and since the ringtone plays inside the activity it's also
        // silent. A direct start brings the ring up in that case. It needs
        // background-activity-launch privilege: a high-priority FCM message grants
        // a short temporary window (covers older devices), and SYSTEM_ALERT_WINDOW
        // ("display over other apps") makes it reliable on Android 12+. Best
        // effort — if BAL-blocked it silently no-ops and the FSI notification
        // above is the fallback. The activity is singleInstance, so when it's
        // already showing (e.g. the locked path also fired) this routes to
        // onNewIntent rather than stacking a second screen.
        try {
            context.startActivity(fsIntent)
            // PRIVACY: never log the notification/conversation id — it's a stable
            // fingerprint of who is being called, and this runs in release (the
            // Dart Zone print-silencing does not cover native Kotlin). Log the
            // action only, matching MainActivity.captureCallAction.
            android.util.Log.i("NANBCALL", "showIncomingCall direct-launch attempted")
        } catch (e: Exception) {
            android.util.Log.i("NANBCALL", "showIncomingCall direct-launch blocked: $e")
        }
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val mgr = notifManager()
            if (mgr.getNotificationChannel(NOTIF_CHANNEL_ID) == null) {
                val ch = NotificationChannel(
                    NOTIF_CHANNEL_ID, "Incoming calls", NotificationManager.IMPORTANCE_HIGH
                ).apply {
                    description = "Incoming voice calls"
                    // Silent: IncomingCallActivity plays the looped ringtone itself,
                    // so the notification must not also make a one-shot sound.
                    setSound(null, null)
                    enableVibration(false)
                }
                mgr.createNotificationChannel(ch)
            }
        }
    }

    private fun notifManager(): NotificationManager =
        context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
}
