package us.nanb.crypto

import android.content.Context
import com.wire.crypto.Ciphersuite
import com.wire.crypto.ClientId
import com.wire.crypto.CoreCryptoClient
import com.wire.crypto.DatabaseKey
import com.wire.crypto.coreCryptoDeferredInit
import com.wire.crypto.lift
import kotlinx.coroutines.runBlocking
import java.io.File

/**
 * Process-wide singleton holding the CoreCrypto client + its store
 * location. Channel methods route through this — exactly one CoreCrypto
 * instance per running app process per spec §7.3.
 *
 * Thread-safety: every public method holds the singleton's monitor lock.
 * CoreCrypto's own internal locking handles its store concurrency.
 *
 * NOTE: CoreCrypto v9 requires `provideTransport()` to be called BEFORE
 * `mlsInit()`. Plan B ships CapturingMlsTransport which records CommitBundles
 * from addClientsToConversation so addMember can return Welcome bytes to Dart.
 * Plan C will extend it to also post Commit bundles to POST /messages.
 */
object MlsClientHolder {
    /** Default ciphersuite per survey §4.3 — RFC 9420 MLS_128 baseline. */
    val DEFAULT_CIPHERSUITE =
        Ciphersuite.MLS_128_DHKEMX25519_AES128GCM_SHA256_ED25519

    @Volatile
    private var client: CoreCryptoClient? = null

    @Volatile
    private var dbPath: String? = null

    @Volatile
    private var mlsClientInited = false

    /**
     * Set when the store is purged and rebuilt: every KeyPackage this device
     * has published holds a private key that lived in the destroyed store, so
     * the published pool is dead. Read + cleared by [consumeStoreWasReset].
     */
    private var storeWasReset = false

    fun initIfNeeded(context: Context, seed: ByteArray) {
        synchronized(this) {
            if (client != null) return
            val path = context.filesDir.absolutePath + "/corecrypto.db"
            val key = deriveStoreKey(seed)
            val rawCc = runBlocking { openStore(path, key) }
            val c = rawCc.lift()

            // CoreCrypto v9 requires provideTransport BEFORE mlsInit can run.
            // CapturingMlsTransport records CommitBundles from addClientsToConversation
            // so addMember can return the Welcome bytes synchronously to Dart.
            // Plan C will extend it to also post commits via POST /messages.
            runBlocking {
                c.provideTransport(CapturingMlsTransport)
            }

            client = c
            dbPath = path
        }
    }

    /**
     * Opens CoreCrypto for read-only use from the background isolate.
     *
     * Design notes (per spec §11.1 + Plan D Task 9):
     * - CoreCrypto v9's `coreCryptoDeferredInit` does NOT expose a read-only
     *   flag at the Kotlin API level (confirmed via `javap` on the Maven AAR).
     * - Fallback: the background isolate opens its own [CoreCryptoClient]
     *   instance pointing at the SAME `filesDir/corecrypto.db` file. SQLite
     *   WAL mode (CoreCrypto's default) supports concurrent readers with
     *   at most one writer.
     * - We deliberately do NOT call `provideTransport` here because the
     *   background isolate must never send commits — only decrypt locally.
     *   The foreground writer is the only path that fans out commits.
     *
     * Idempotent: re-calling on an already-init'd instance is a no-op.
     */
    fun initReadOnly(context: Context, seed: ByteArray) {
        synchronized(this) {
            if (client != null) return
            val path = context.filesDir.absolutePath + "/corecrypto.db"
            val key = deriveStoreKey(seed)
            val rawCc = runBlocking { openStore(path, key) }
            val c = rawCc.lift()
            // CoreCrypto v9 requires provideTransport before the mlsInit
            // transaction — and a cold-started background isolate must run
            // ensureMlsClient (load the existing client) before it can
            // decrypt. CapturingMlsTransport only records bundles locally;
            // decryption never produces commits, so nothing is sent.
            runBlocking {
                c.provideTransport(CapturingMlsTransport)
            }
            client = c
            dbPath = path
        }
    }

    /**
     * Runs CoreCrypto's own `mlsInit` transaction — survey §4.2 "Step 3",
     * which `coreCryptoDeferredInit` defers and which every MLS operation
     * (clientKeypackages, createConversation, …) requires. Without it the
     * store opens fine but every call fails with "MLS hasn't been
     * initialized on this instance".
     *
     * [clientId] is the server-assigned device id (UTF-8 bytes) — group
     * member leaves are addressed by device id (see removeMember), so the
     * MLS credential must match. The device id only exists once a session
     * does, which is why this is a separate stage from [initIfNeeded]:
     * Dart calls it right after account creation / restore / boot resume.
     *
     * Idempotent per process; across restarts CoreCrypto loads the existing
     * client from the store (same call, same client id — the Wire apps run
     * mlsInit on every start the same way).
     */
    fun ensureMlsClient(clientId: ByteArray) {
        synchronized(this) {
            if (mlsClientInited) return
            val c = get()
            runBlocking {
                c.transaction { ctx ->
                    ctx.mlsInit(
                        clientId = ClientId(clientId),
                        ciphersuites = listOf(DEFAULT_CIPHERSUITE),
                        nbKeyPackage = 100u,
                    )
                }
            }
            mlsClientInited = true
        }
    }

    fun get(): CoreCryptoClient {
        return client
            ?: throw IllegalStateException("MlsClientHolder.initIfNeeded must be called first")
    }

    fun wipe(context: Context) {
        synchronized(this) {
            val path = dbPath ?: (context.filesDir.absolutePath + "/corecrypto.db")
            // Best-effort close; null-safe since wipe may be called without prior init.
            client?.let { c ->
                try {
                    c.close()
                } catch (_: Throwable) {
                    // Already closed or never opened cleanly — proceed to delete.
                }
            }
            client = null
            dbPath = null
            mlsClientInited = false
            File(path).delete()
        }
    }

    /**
     * Opens (or creates) the CoreCrypto store at [path] with [key].
     *
     * Recovery for a stale keystore: the store key is DETERMINISTIC from the
     * identity seed (see [deriveStoreKey]), so if the correct key cannot open
     * an existing file, that file belongs to a different identity (or is
     * corrupt) and is unusable for this one. This happens when a previous
     * account-creation/restore was interrupted after the keystore was written
     * but before onboarding finished: the next attempt derives a new seed →
     * new key → SQLCipher rejects the old file with SQLITE_NOTADB ("file
     * opened that is not a database file", error code 26), which would
     * otherwise brick all future account creation until app data is cleared.
     *
     * On such an "unreadable keystore" error we delete the file (plus its
     * WAL/SHM sidecars) and retry once. A returning user with the correct
     * seed opens on the first try, so a valid store is never deleted.
     */
    private suspend fun openStore(path: String, key: ByteArray) = try {
        coreCryptoDeferredInit(path = path, key = DatabaseKey(key), entropySeed = null)
    } catch (e: Throwable) {
        if (!isUnreadableKeystore(e) || !File(path).exists()) throw e
        File(path).delete()
        File("$path-wal").delete()
        File("$path-shm").delete()
        // The destroyed store held the private half of every KeyPackage this
        // device has published, so the whole published pool is now dead. Flag
        // it so Dart republishes with reset=true and the server DROPS the
        // stale rows — otherwise peers keep drawing dead packages and every
        // Welcome built from one is undecryptable. See consumeStoreWasReset.
        storeWasReset = true
        coreCryptoDeferredInit(path = path, key = DatabaseKey(key), entropySeed = null)
    }

    /**
     * Reports whether the store was purged+rebuilt since the last call, and
     * clears the flag. Mirrors the iOS `MlsClientHolder.consumeStoreWasReset`.
     */
    fun consumeStoreWasReset(): Boolean = synchronized(this) {
        val was = storeWasReset
        storeWasReset = false
        was
    }

    /**
     * True when [e] indicates the keystore file could not be opened/decrypted
     * (wrong key or corruption) rather than some transient/operational fault.
     * Matched on the underlying SQLite/SQLCipher signal so we only ever delete
     * a file that is genuinely unusable with the supplied key.
     */
    private fun isUnreadableKeystore(e: Throwable): Boolean {
        var cur: Throwable? = e
        while (cur != null) {
            val m = cur.message?.lowercase() ?: ""
            if (m.contains("not a database") || m.contains("code 26") || m.contains("notadb")) {
                return true
            }
            cur = cur.cause
        }
        return false
    }

    /**
     * Derives a 32-byte CoreCrypto store key from the user's identity seed
     * via HKDF with info "nanb-corecrypto-store-v1". Same seed always
     * produces the same key, so a re-mount of the store after process
     * restart works without re-key.
     */
    private fun deriveStoreKey(seed: ByteArray): ByteArray {
        val info = "nanb-corecrypto-store-v1".toByteArray(Charsets.UTF_8)
        return Hkdf.derive(ikm = seed, salt = ByteArray(0), info = info, length = 32)
    }
}