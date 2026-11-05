package us.nanb.chat

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * Foreground service that keeps the app process alive while a call is live, so
 * an audio call (or a minimized video call) survives the user locking the screen
 * or switching apps. Without it, backgrounding lets Doze suspend the process —
 * WebRTC media stops and, once the peer's media-drop + ICE-recovery windows
 * expire, the call is ended as `failed`. (FLAG_KEEP_SCREEN_ON only blocks the
 * *automatic* screen timeout while the call UI is foreground; it does nothing
 * once the user manually locks or switches away.)
 *
 * Runs with the `microphone` foreground-service type: audio is present in every
 * call, and RECORD_AUDIO is always granted by the time a call is live. It
 * deliberately does NOT claim the `camera` type — a locked-screen video call has
 * no reason to keep capturing video, so only audio is kept alive.
 *
 * Driven from Dart via MainActivity's `nanb.app/call_foreground` channel on the
 * call's live edge (start on ring/connect/active, stop on end).
 */
class CallForegroundService : Service() {

    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        try {
            startForegroundNotification()
            acquireWakeLock()
        } catch (e: Exception) {
            // A missing RECORD_AUDIO grant (or an OEM foreground-service quirk)
            // must never crash the call — it just runs foreground-only. The
            // companion pre-checks the permission, so this is a last-resort guard.
            android.util.Log.w("NANBCALL", "call foreground service start failed: $e")
            releaseWakeLock()
            stopSelf()
        }
        // START_NOT_STICKY: if the OS kills us under memory pressure, don't
        // resurrect a stale "call" notification after the call is long gone — the
        // Dart side owns the lifecycle and restarts us for a real call.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        // stopService() (the Dart `stop` path) destroys us and auto-removes the
        // foreground notification; just drop the wake lock here.
        releaseWakeLock()
        super.onDestroy()
    }

    private fun startForegroundNotification() {
        ensureChannel()
        val open = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val contentIntent = PendingIntent.getActivity(
            this,
            0,
            open,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification: Notification = Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("Ongoing call")
            .setContentText("Tap to return to the call")
            .setSmallIcon(R.drawable.ic_stat_nanb)
            .setContentIntent(contentIntent)
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_CALL)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            startForeground(NOTIF_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
        } else {
            startForeground(NOTIF_ID, notification)
        }
    }

    /** Low-importance, silent channel for the ongoing-call notification. */
    private fun ensureChannel() {
        val mgr = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (mgr.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Ongoing calls",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Shown while a voice or video call is active."
            setShowBadge(false)
            setSound(null, null)
            enableVibration(false)
        }
        mgr.createNotificationChannel(channel)
    }

    /** Hold the CPU awake so WebRTC + Tor keep running with the screen off. */
    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKELOCK_TAG).apply {
            setReferenceCounted(false)
            // Safety cap: the Dart side releases this on call end far sooner; the
            // timeout only guards against a missed stop leaking the lock forever.
            acquire(MAX_CALL_MS)
        }
    }

    private fun releaseWakeLock() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
    }

    companion object {
        private const val CHANNEL_ID = "nanb-call"
        private const val NOTIF_ID = 0xCA11 // "CALL"
        private const val WAKELOCK_TAG = "nanb:call"
        private const val MAX_CALL_MS = 4L * 60L * 60L * 1000L // 4h cap

        /** Start the service for a live call. Returns false (and does nothing) if
         *  RECORD_AUDIO isn't granted yet — a `microphone` foreground service
         *  requires it on Android 14+, and on the first call the grant lands a beat
         *  after the ring edge. The Dart side treats false as "retry on the next
         *  status edge" (by then the engine has requested + been granted the mic). */
        fun start(context: Context): Boolean {
            if (context.checkSelfPermission(Manifest.permission.RECORD_AUDIO)
                != PackageManager.PERMISSION_GRANTED
            ) {
                return false
            }
            val intent = Intent(context, CallForegroundService::class.java)
            return try {
                context.startForegroundService(intent)
                true
            } catch (e: Exception) {
                // e.g. ForegroundServiceStartNotAllowedException if somehow started
                // from the background — the call still runs foreground-only.
                android.util.Log.w("NANBCALL", "could not start call foreground service: $e")
                false
            }
        }

        /** Stop the service; the OS removes its foreground notification on destroy. */
        fun stop(context: Context) {
            context.stopService(Intent(context, CallForegroundService::class.java))
        }
    }
}
