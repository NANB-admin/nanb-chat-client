package us.nanb.chat

import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import java.io.File
import java.util.concurrent.Executors

/**
 * Holds the content another app sent us through the system share sheet
 * (`ACTION_SEND` / `ACTION_SEND_MULTIPLE`) until Dart collects it.
 *
 * Two-phase on purpose:
 *
 *  1. [capture] runs on the main thread from `onCreate` / `onNewIntent` and
 *     only records the intent's text + stream URIs — no I/O at all.
 *  2. [take] does the actual byte copying on a worker thread, because a
 *     `content://` URI is not readable from Dart: the bytes have to be pulled
 *     through the ContentResolver into our own cache first, and doing that for
 *     a video on the UI thread is an ANR.
 *
 * The share is consumed exactly once — [take] clears the pending state as it
 * reads it, and [capture] strips the extras off the intent so a configuration
 * change (rotation) that re-delivers the same intent can't replay the share.
 */
object IncomingShareStore {

    /** Subdirectory of the app cache holding the copies handed to Dart. */
    private const val CACHE_DIR = "incoming_share"

    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    private var pendingText: String = ""
    private var pendingUris: List<Uri> = emptyList()

    /**
     * Records a share intent's payload. Returns true when the intent actually
     * carried a share (any other intent — the launcher, a call action — is
     * ignored).
     */
    @Suppress("DEPRECATION") // typed getParcelable* overloads are API 33+ only
    fun capture(intent: Intent?): Boolean {
        if (intent == null) return false
        val uris: List<Uri> = when (intent.action) {
            Intent.ACTION_SEND ->
                listOfNotNull(intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))
            Intent.ACTION_SEND_MULTIPLE ->
                intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
                    ?: emptyList()
            else -> return false
        }
        // EXTRA_TEXT only. Senders that also set EXTRA_SUBJECT (YouTube puts the
        // video title there, the URL in EXTRA_TEXT) would otherwise produce a
        // duplicated-looking message; the URL alone is what the user means to send.
        val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()?.trim().orEmpty()
        if (uris.isEmpty() && text.isEmpty()) return false
        pendingText = text
        pendingUris = uris
        intent.removeExtra(Intent.EXTRA_STREAM)
        intent.removeExtra(Intent.EXTRA_TEXT)
        // PRIVACY: never log the shared content or URIs — it's the user's data
        // and, for a share, often identifying.
        return true
    }

    /**
     * Hands the pending share to [onReady] (always on the main thread, as
     * Flutter's MethodChannel result requires), copying every stream into the
     * app cache first. Passes null when nothing is pending.
     */
    fun take(context: Context, onReady: (Map<String, Any>?) -> Unit) {
        val text = pendingText
        val uris = pendingUris
        pendingText = ""
        pendingUris = emptyList()
        if (text.isEmpty() && uris.isEmpty()) {
            onReady(null)
            return
        }
        val appContext = context.applicationContext
        io.execute {
            // A stream we can't read is dropped rather than failing the whole
            // share — the rest (and any text) still reaches the user's chat.
            val attachments = uris.mapNotNull { copyToCache(appContext, it) }
            val payload = mapOf<String, Any>(
                "text" to text,
                "attachments" to attachments,
            )
            main.post { onReady(payload) }
        }
    }

    /**
     * Copies one shared stream into the app cache and describes it for Dart.
     * Returns null when the stream can't be opened.
     *
     * No size ceiling here: the Dart side enforces the server's 100 MB media
     * cap (and reports what it skipped), so the limit lives in ONE place
     * instead of being silently applied twice with different messages.
     */
    private fun copyToCache(context: Context, uri: Uri): Map<String, String>? {
        return try {
            val resolver = context.contentResolver
            val name = displayName(resolver, uri) ?: "shared-file"
            val mime = resolver.getType(uri) ?: guessMime(name)
            val dir = File(context.cacheDir, CACHE_DIR)
            dir.mkdirs()
            // nanoTime prefix: two shares of the same-named file must not
            // collide, and the Dart side deletes each copy once it's sent.
            val target = File(dir, "${System.nanoTime()}_${sanitize(name)}")
            val input = resolver.openInputStream(uri) ?: return null
            input.use { source ->
                target.outputStream().use { sink -> source.copyTo(sink) }
            }
            mapOf(
                "path" to target.absolutePath,
                "name" to name,
                "mime" to mime,
            )
        } catch (e: Exception) {
            null
        }
    }

    /** The sender-visible file name, via `OpenableColumns.DISPLAY_NAME`. */
    private fun displayName(resolver: ContentResolver, uri: Uri): String? {
        try {
            resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                ?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                        if (index >= 0) {
                            val value = cursor.getString(index)
                            if (!value.isNullOrBlank()) return value
                        }
                    }
                }
        } catch (e: Exception) {
            // Provider refused the query — fall through to the path segment.
        }
        return uri.lastPathSegment?.substringAfterLast('/')?.takeIf { it.isNotBlank() }
    }

    /** Keeps a provider-supplied name usable as a file name. */
    private fun sanitize(name: String): String =
        name.replace(Regex("[^A-Za-z0-9._-]"), "_").take(80)

    /**
     * Last-resort MIME guess for a provider that returns no type. Only the
     * broad family matters — it picks the image / video / file send path.
     */
    private fun guessMime(name: String): String {
        val lower = name.lowercase()
        return when {
            lower.endsWith(".png") -> "image/png"
            lower.endsWith(".gif") -> "image/gif"
            lower.endsWith(".webp") -> "image/webp"
            lower.endsWith(".jpg") || lower.endsWith(".jpeg") -> "image/jpeg"
            lower.endsWith(".mp4") -> "video/mp4"
            lower.endsWith(".mov") -> "video/quicktime"
            lower.endsWith(".pdf") -> "application/pdf"
            else -> "application/octet-stream"
        }
    }
}
