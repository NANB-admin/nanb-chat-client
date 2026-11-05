package us.nanb.chat

import android.app.Activity
import android.app.KeyguardManager
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.graphics.drawable.GradientDrawable
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.os.Build
import android.os.Bundle
import android.os.VibrationEffect
import android.os.Vibrator
import android.view.WindowManager
import android.widget.ImageButton
import android.widget.TextView

/**
 * Native (NON-Flutter) full-screen incoming-call screen, shown over the lock.
 *
 * Declared in the manifest with STATIC `android:showWhenLocked` +
 * `android:turnScreenOn` and its own task. Being a purpose-built, statically
 * declared lock-screen activity — and NOT hosting a Flutter engine — it persists
 * over a secure lock (unlike MainActivity, where the keyguard reclaimed the
 * screen after a few seconds, and unlike a Flutter second activity, which black-
 * screened on the shared-engine handoff).
 *
 * It is launched directly by the call notification's full-screen intent (posted
 * natively by [us.nanb.crypto.CallNotificationChannel]); the OS launching it that
 * way is background-activity-launch exempt.
 *
 * Accept / Decline hand off to MainActivity (the Flutter engine) via a
 * `call_action` intent extra, which app.dart routes to the CallController.
 */
class IncomingCallActivity : Activity() {

    private var ringtone: MediaPlayer? = null
    private var vibrator: Vibrator? = null
    private var convId: String = ""
    private var notifId: Int = 0
    private var handled = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        showWhenLockedAndTurnScreenOn()

        convId = intent?.getStringExtra("conversation_id") ?: ""
        notifId = intent?.getIntExtra("notif_id", convId.hashCode()) ?: convId.hashCode()
        val caller = intent?.getStringExtra("caller") ?: ""
        // PRIVACY: never log the conversation id or the caller display name
        // (who-talks-to-whom / human-readable identity metadata).
        android.util.Log.i("NANBCALL", "IncomingCallActivity onCreate")

        setContentView(R.layout.activity_incoming_call)
        bindCaller(caller)

        findViewById<ImageButton>(R.id.btn_accept).setOnClickListener { onAccept() }
        findViewById<ImageButton>(R.id.btn_decline).setOnClickListener { onDecline() }

        startRinging()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // A re-posted call (singleInstance) — refresh the caller label.
        setIntent(intent)
        convId = intent.getStringExtra("conversation_id") ?: convId
        notifId = intent.getIntExtra("notif_id", notifId)
        bindCaller(intent.getStringExtra("caller") ?: "")
    }

    private fun bindCaller(caller: String) {
        val name = if (caller.isEmpty()) "Unknown" else caller
        findViewById<TextView>(R.id.call_name).text = name
        val avatar = findViewById<TextView>(R.id.call_avatar)
        // Match the Flutter NanbAvatar: strip a leading '@' for the initials, and
        // colour the circle with the same deterministic per-name hue so the ring
        // avatar looks like the rest of the app (which uses initials, not photos).
        val cleaned = name.replaceFirst("@", "")
        avatar.text =
            if (cleaned.isEmpty()) "?"
            else cleaned.substring(0, minOf(2, cleaned.length)).uppercase()
        avatar.background = GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(avatarColor(name))
        }
    }

    /** Deterministic avatar hue from the name, matching Flutter's NanbAvatar
     *  (`HSLColor.fromAHSL(1, hash%360, 0.35, 0.5)`). */
    private fun avatarColor(name: String): Int {
        var h = 0
        for (ch in name) h = (h * 31 + ch.code) % 360
        return hslToColor(h.toFloat(), 0.35f, 0.5f)
    }

    private fun hslToColor(h: Float, s: Float, l: Float): Int {
        val c = (1f - kotlin.math.abs(2f * l - 1f)) * s
        val hp = h / 60f
        val x = c * (1f - kotlin.math.abs(hp % 2f - 1f))
        var r = 0f
        var g = 0f
        var b = 0f
        when {
            hp < 1f -> { r = c; g = x }
            hp < 2f -> { r = x; g = c }
            hp < 3f -> { g = c; b = x }
            hp < 4f -> { g = x; b = c }
            hp < 5f -> { r = x; b = c }
            else -> { r = c; b = x }
        }
        val m = l - c / 2f
        return android.graphics.Color.rgb(
            (((r + m) * 255).toInt()).coerceIn(0, 255),
            (((g + m) * 255).toInt()).coerceIn(0, 255),
            (((b + m) * 255).toInt()).coerceIn(0, 255),
        )
    }

    private fun showWhenLockedAndTurnScreenOn() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        }
        @Suppress("DEPRECATION")
        window.addFlags(
            WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
        )
    }

    private fun startRinging() {
        try {
            val uri = RingtoneManager.getActualDefaultRingtoneUri(this, RingtoneManager.TYPE_RINGTONE)
                ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
            ringtone = MediaPlayer().apply {
                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build()
                )
                setDataSource(this@IncomingCallActivity, uri)
                isLooping = true
                prepare()
                start()
            }
        } catch (e: Exception) {
            android.util.Log.i("NANBCALL", "ringtone error: $e")
        }
        try {
            val v = getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
            vibrator = v
            val pattern = longArrayOf(0, 600, 800)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                v?.vibrate(VibrationEffect.createWaveform(pattern, 0))
            } else {
                @Suppress("DEPRECATION")
                v?.vibrate(pattern, 0)
            }
        } catch (e: Exception) {
            android.util.Log.i("NANBCALL", "vibrate error: $e")
        }
    }

    private fun stopRinging() {
        try {
            ringtone?.let { if (it.isPlaying) it.stop(); it.release() }
        } catch (_: Exception) {}
        ringtone = null
        try {
            vibrator?.cancel()
        } catch (_: Exception) {}
        vibrator = null
    }

    private fun onAccept() {
        if (handled) return
        handled = true
        // PRIVACY: no conversation id in logs.
        android.util.Log.i("NANBCALL", "IncomingCallActivity ACCEPT")
        handOffToFlutter("accept")
        finishCall()
    }

    private fun onDecline() {
        if (handled) return
        handled = true
        // PRIVACY: no conversation id in logs.
        android.util.Log.i("NANBCALL", "IncomingCallActivity DECLINE")
        handOffToFlutter("decline")
        finishCall()
    }

    /**
     * Hand the user's decision to the Flutter engine. Launching MainActivity with
     * the call_action extra boots the engine if needed; app.dart pulls the pending
     * action and drives the CallController (accept → ringFromPush + accept;
     * decline → ringFromPush + decline). For accept we also request keyguard
     * dismissal so the in-call UI is reachable.
     */
    private fun handOffToFlutter(action: String) {
        try {
            val intent = Intent(this, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                putExtra("call_action", action)
                putExtra("conversation_id", convId)
            }
            startActivity(intent)
            if (action == "accept") {
                (getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager)
                    ?.requestDismissKeyguard(this, null)
            }
        } catch (e: Exception) {
            android.util.Log.i("NANBCALL", "handOff error: $e")
        }
    }

    private fun finishCall() {
        stopRinging()
        try {
            (getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager)?.cancel(notifId)
        } catch (_: Exception) {}
        finish()
    }

    override fun onDestroy() {
        stopRinging()
        super.onDestroy()
    }
}
