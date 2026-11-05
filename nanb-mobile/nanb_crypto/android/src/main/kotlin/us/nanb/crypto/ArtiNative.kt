package us.nanb.crypto

/**
 * JNI bindings to the embedded Arti (pure-Rust Tor) library `libnanb_arti.so`
 * (built by `.github/workflows/android-arti.yml` from the `nanb-arti-ffi` crate,
 * bundled into the app's jniLibs). The Tor logic lives in the shared Rust core —
 * the same engine the iOS app links via its C ABI — so Android and iOS run one
 * Tor implementation. The native method names match the Rust
 * `Java_us_nanb_crypto_ArtiNative_*` exports.
 *
 * The native side runs Arti on its own Rust-owned Tokio runtime + an in-process
 * SOCKS5 proxy; we only POLL its status here (no callbacks back into Kotlin).
 */
internal object ArtiNative {
    init {
        System.loadLibrary("nanb_arti")
    }

    /** Start the engine. Returns 0 on accepted-start (bootstrap continues async —
     *  poll [nativeIsReady]), negative on failure (see [nativeLastError]). No-op if
     *  already running. [dir] = the app's data dir; Arti state/cache live under
     *  `<dir>/arti-state` and `<dir>/arti-cache`. */
    external fun nativeStart(dir: String): Int

    /** Cleanly stop the engine (cancel tasks, drop the client, release locks). */
    external fun nativeStop()

    /** The live SOCKS5 port on 127.0.0.1, or 0 until the listener is bound. */
    external fun nativeSocksPort(): Int

    /** Bootstrap progress, 0..100. */
    external fun nativeBootstrapPct(): Int

    /** True once bootstrapped AND the SOCKS listener is bound (routable). */
    external fun nativeIsReady(): Boolean

    /** Suspend ([dormant] = true) / resume ([dormant] = false) the client's
     *  background activity WITHOUT tearing it down — the client, its guards, and
     *  the SOCKS port all survive. Used on app pause/resume so a resume is a
     *  cheap wake instead of a full re-bootstrap. No-op until bootstrapped. */
    external fun nativeSetDormant(dormant: Boolean)

    /** Last error message, or null if none. */
    external fun nativeLastError(): String?
}
