//! FFI bridge between the mobile apps and an embedded Arti (pure-Rust Tor) client.
//!
//! iOS calls the **C ABI** (`nanb_arti_*`, linked as a staticlib via the bridging
//! header); Android calls the **JNI** layer (`Java_us_nanb_crypto_ArtiNative_*`,
//! loaded as `libnanb_arti.so`). Both are thin wrappers over the shared
//! `start_engine` / `stop_engine` / poll core, so the Tor logic lives in ONE place.
//!
//! Why Arti: C-tor can't be cleanly stopped (its only shutdown calls `exit()`,
//! killing the host app), and after a long mobile suspend its libevent loop wedges
//! unrecoverably. Arti has a clean library lifecycle (drop the client / shut the
//! runtime), so the resume path is just stop() + start().
//!
//! Design: one multi-thread Tokio runtime owns a bootstrapped `TorClient` and an
//! in-process SOCKS5 listener on an ephemeral 127.0.0.1 port. The app routes all
//! traffic through that SOCKS proxy (remote DNS, so `.onion` resolves inside Tor).
//! The native side POLLS bootstrap_pct / is_ready / socks_port — no callbacks.
//!
//! Every FFI entry point is wrapped in `catch_unwind`: a Rust panic must never
//! unwind across the FFI boundary.

use std::ffi::{c_char, CStr, CString};
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicU16, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::Context;
use arti_client::{DormantMode, TorClient, TorClientConfig};
use futures::StreamExt;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

/// The bootstrapped client, shared between the SOCKS accept loop and the global
/// [`ArtiState`] so `set_dormant` can reach it. `None` until bootstrap completes.
type SharedClient = Arc<Mutex<Option<Arc<TorClient<tor_rtcompat::PreferredRuntime>>>>>;

/// Live engine state. Held in a global behind a `Mutex` because the FFI calls
/// (start/stop/poll) arrive on arbitrary native threads. Dropping `runtime` (via
/// `shutdown_timeout` in stop) cancels every task — the bootstrap, the SOCKS
/// accept loop, and the `TorClient` — releasing the data-dir locks so a fresh
/// `start` (the resume restart) gets a clean slate.
struct ArtiState {
    runtime: tokio::runtime::Runtime,
    socks_port: Arc<AtomicU16>,
    bootstrap_pct: Arc<AtomicI32>,
    ready: Arc<AtomicBool>,
    /// Set once bootstrap completes; lets [`set_dormant`] reach the live client
    /// without touching the SOCKS accept loop. Dropped with the state on stop.
    client: SharedClient,
}

static STATE: Mutex<Option<ArtiState>> = Mutex::new(None);
static LAST_ERROR: Mutex<Option<CString>> = Mutex::new(None);

fn set_last_error(msg: String) {
    if let Ok(cs) = CString::new(msg) {
        if let Ok(mut g) = LAST_ERROR.lock() {
            *g = Some(cs);
        }
    }
}

// ===========================================================================
// Shared core — called by both the iOS C ABI and the Android JNI layer.
// ===========================================================================

/// Start the embedded Tor: spin up the Tokio runtime, bootstrap a `TorClient`,
/// and bind the in-process SOCKS5 proxy. Returns 0 on accepted-start (bootstrap
/// continues async — poll `is_ready`), negative on failure. No-op if already
/// running. `dir` is the app's data dir; Arti state + cache live in
/// `<dir>/arti-state` and `<dir>/arti-cache`.
fn start_engine(dir: String) -> i32 {
    let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| -> anyhow::Result<()> {
        // Ensure the data dir exists (Arti's from_directories creates the
        // state/cache subdirs, but the parent must exist).
        let _ = std::fs::create_dir_all(&dir);

        // tokio swallows task panics, so surface a panic in the async engine as
        // the last error rather than failing silently.
        std::panic::set_hook(Box::new(|info| {
            set_last_error(format!("panic: {info}"));
        }));
        // rustls 0.23 requires a process-default CryptoProvider before its first
        // use, else it panics. Arti's rustls relies on the process default.
        let _ = rustls::crypto::ring::default_provider().install_default();

        let mut guard = STATE.lock().map_err(|_| anyhow::anyhow!("state lock poisoned"))?;
        if guard.is_some() {
            return Ok(()); // already running
        }

        let runtime = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            // 4 workers (was 2): bootstrap fetches many microdescriptors in
            // parallel and each SOCKS connection may build a circuit — 2 threads
            // throttled that concurrency, making cold bootstrap + first-connect
            // slower than a C-tor daemon (Orbot). 4 matches typical mobile core
            // counts; threads idle when there's no work, so battery cost is nil.
            .worker_threads(4)
            .thread_name("nanb-arti")
            .build()
            .context("build tokio runtime")?;

        let socks_port = Arc::new(AtomicU16::new(0));
        let bootstrap_pct = Arc::new(AtomicI32::new(0));
        let ready = Arc::new(AtomicBool::new(false));
        let client: SharedClient = Arc::new(Mutex::new(None));

        let (sp, bp, rd, cl) =
            (socks_port.clone(), bootstrap_pct.clone(), ready.clone(), client.clone());
        runtime.spawn(async move {
            if let Err(e) = run_arti(dir, sp, bp, rd, cl).await {
                set_last_error(format!("arti: {e:#}"));
            }
        });

        *guard = Some(ArtiState { runtime, socks_port, bootstrap_pct, ready, client });
        Ok(())
    }));

    match outcome {
        Ok(Ok(())) => 0,
        Ok(Err(e)) => {
            set_last_error(format!("{e:#}"));
            -1
        }
        Err(_) => {
            set_last_error("panic in start_engine".to_owned());
            -2
        }
    }
}

/// Cleanly stop the engine: cancel all tasks + drop the client (releasing the
/// data-dir locks), so a subsequent `start` (the resume restart) is clean.
fn stop_engine() {
    let _ = std::panic::catch_unwind(|| {
        let taken = STATE.lock().ok().and_then(|mut g| g.take());
        if let Some(state) = taken {
            // Cancels every task; waits briefly for graceful teardown. Must be
            // called from OUTSIDE the runtime (it is — the native thread).
            state.runtime.shutdown_timeout(Duration::from_secs(3));
        }
    });
}

fn socks_port() -> u16 {
    STATE
        .lock()
        .ok()
        .and_then(|g| g.as_ref().map(|s| s.socks_port.load(Ordering::Relaxed)))
        .unwrap_or(0)
}

fn bootstrap_pct() -> i32 {
    STATE
        .lock()
        .ok()
        .and_then(|g| g.as_ref().map(|s| s.bootstrap_pct.load(Ordering::Relaxed)))
        .unwrap_or(0)
}

fn is_ready() -> bool {
    STATE
        .lock()
        .ok()
        .and_then(|g| g.as_ref().map(|s| s.ready.load(Ordering::Relaxed)))
        .unwrap_or(false)
}

/// Suspend (`dormant = true`) or resume (`dormant = false`) the client's
/// background activity WITHOUT tearing it down. On mobile the app is paused →
/// dormant before an OS suspend to conserve CPU/battery, then woken on resume.
///
/// This is the cheap alternative to stop+start on resume: the `TorClient`, its
/// guards, and the SOCKS listener (its port) all survive, so waking just resumes
/// circuit upkeep instead of paying a full ~cold re-bootstrap. Arti also auto-
/// wakes a `Soft`-dormant client on first use, so a connection during the window
/// still works; the explicit wake just resumes preemptive-circuit building
/// promptly. No-op if the engine isn't running / hasn't finished bootstrapping.
fn set_dormant(dormant: bool) {
    let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let slot = STATE
            .lock()
            .ok()
            .and_then(|g| g.as_ref().map(|s| s.client.clone()));
        if let Some(slot) = slot {
            let client = slot.lock().ok().and_then(|g| g.as_ref().cloned());
            if let Some(client) = client {
                let mode = if dormant {
                    DormantMode::Soft
                } else {
                    DormantMode::Normal
                };
                client.set_dormant(mode);
            }
        }
    }));
}

/// The last error message as an owned String (for the JNI layer; the C ABI
/// returns the raw `CString` pointer instead).
fn last_error_string() -> Option<String> {
    LAST_ERROR
        .lock()
        .ok()
        .and_then(|g| g.as_ref().map(|cs| cs.to_string_lossy().into_owned()))
}

/// Bootstrap the client + run the SOCKS5 proxy until the runtime is dropped.
async fn run_arti(
    dir: String,
    socks_port: Arc<AtomicU16>,
    bootstrap_pct: Arc<AtomicI32>,
    ready: Arc<AtomicBool>,
    client_slot: SharedClient,
) -> anyhow::Result<()> {
    let state_dir = format!("{dir}/arti-state");
    let cache_dir = format!("{dir}/arti-cache");
    let config: TorClientConfig =
        arti_client::config::TorClientConfigBuilder::from_directories(&state_dir, &cache_dir)
            .build()
            .context("build TorClientConfig")?;

    // Use the current (our) Tokio runtime for the client.
    let runtime = tor_rtcompat::PreferredRuntime::current().context("current runtime")?;
    let client = TorClient::with_runtime(runtime)
        .config(config)
        .create_unbootstrapped()
        .context("create TorClient")?;

    // Surface bootstrap progress (0..100) to the polled atomic.
    {
        let bp = bootstrap_pct.clone();
        let mut events = client.bootstrap_events();
        tokio::spawn(async move {
            while let Some(status) = events.next().await {
                bp.store((status.as_frac() * 100.0).round() as i32, Ordering::Relaxed);
            }
        });
    }

    client.bootstrap().await.context("bootstrap")?;
    bootstrap_pct.store(100, Ordering::Relaxed);

    // In-process SOCKS5 proxy on an ephemeral loopback port.
    let listener = TcpListener::bind(("127.0.0.1", 0u16))
        .await
        .context("bind SOCKS listener")?;
    let port = listener.local_addr().context("socks local_addr")?.port();
    socks_port.store(port, Ordering::Relaxed);
    ready.store(true, Ordering::Relaxed);

    // Share ONE bootstrapped client across every SOCKS connection so streams
    // reuse Arti's warm preemptive-circuit pool, instead of building a fresh
    // isolated circuit per connection.
    //
    // Why this is safe here (and why it's the biggest latency win): stream
    // isolation only buys privacy when you contact *different* destinations you
    // don't want linked. Every stream this app opens goes to the SAME server
    // (the `.onion`, or `nanb.link` over an exit), and the server already
    // correlates them via our authenticated session — so per-connection
    // isolation added zero real privacy while paying a full multi-hop circuit
    // build (seconds of first-byte latency) on EVERY WebSocket / HTTP / media
    // connection, and defeating the preemptive-circuit pool. Reusing circuits
    // is what makes reconnects and message sends feel fast. The client still
    // gives full 3-hop anonymity (our real IP is never exposed).
    // `client` is already an `Arc<TorClient>` (create_unbootstrapped returns one),
    // so we just clone that same Arc per connection — no per-connection isolation.
    // Publish it so set_dormant can reach the live client (the accept loop keeps
    // its own clones).
    if let Ok(mut g) = client_slot.lock() {
        *g = Some(client.clone());
    }
    loop {
        let (sock, _) = listener.accept().await.context("socks accept")?;
        let client = client.clone();
        tokio::spawn(async move {
            let _ = handle_socks(sock, client).await;
        });
    }
}

/// Minimal SOCKS5 (RFC 1928) CONNECT handler that bridges to Tor via
/// `TorClient::connect`. DOMAINNAME targets (incl. `.onion`) pass through
/// unresolved so Tor does the lookup — no local DNS leak.
async fn handle_socks(
    mut sock: TcpStream,
    client: Arc<TorClient<tor_rtcompat::PreferredRuntime>>,
) -> anyhow::Result<()> {
    // Greeting: VER, NMETHODS, METHODS...
    let mut head = [0u8; 2];
    sock.read_exact(&mut head).await?;
    if head[0] != 0x05 {
        anyhow::bail!("not socks5");
    }
    let mut methods = vec![0u8; head[1] as usize];
    sock.read_exact(&mut methods).await?;
    sock.write_all(&[0x05, 0x00]).await?; // select "no auth"

    // Request: VER, CMD, RSV, ATYP, DST.ADDR, DST.PORT
    let mut req = [0u8; 4];
    sock.read_exact(&mut req).await?;
    if req[0] != 0x05 || req[1] != 0x01 {
        // only CONNECT is supported
        sock.write_all(&[0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0]).await?;
        anyhow::bail!("unsupported SOCKS command {}", req[1]);
    }
    let host = match req[3] {
        0x01 => {
            let mut a = [0u8; 4];
            sock.read_exact(&mut a).await?;
            std::net::Ipv4Addr::from(a).to_string()
        }
        0x04 => {
            let mut a = [0u8; 16];
            sock.read_exact(&mut a).await?;
            std::net::Ipv6Addr::from(a).to_string()
        }
        0x03 => {
            let mut len = [0u8; 1];
            sock.read_exact(&mut len).await?;
            let mut d = vec![0u8; len[0] as usize];
            sock.read_exact(&mut d).await?;
            String::from_utf8(d).context("domain not UTF-8")?
        }
        other => anyhow::bail!("bad ATYP {other}"),
    };
    let mut port_bytes = [0u8; 2];
    sock.read_exact(&mut port_bytes).await?;
    let port = u16::from_be_bytes(port_bytes);
    // The app appends a trailing control byte (NUL) to the onion host that C-tor's
    // SOCKS tolerated but Arti rejects ("invalid hostname"); strip control +
    // whitespace so the .onion parses.
    let host = host.trim_matches(|c: char| c.is_control() || c.is_whitespace());

    // Connect through Tor (resolves .onion + DNS inside the network).
    let mut stream = match client.connect((host, port)).await {
        Ok(s) => s,
        Err(_) => {
            // general SOCKS failure
            sock.write_all(&[0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0]).await?;
            return Ok(());
        }
    };
    // success: bind addr/port reported as 0.0.0.0:0 (clients ignore it)
    sock.write_all(&[0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]).await?;

    tokio::io::copy_bidirectional(&mut sock, &mut stream).await?;
    Ok(())
}

// ===========================================================================
// iOS C ABI (linked as a staticlib; called from ios/Runner/TorChannel.swift).
// ===========================================================================

/// Start with a UTF-8 C-string data dir. See [`start_engine`].
#[no_mangle]
pub extern "C" fn nanb_arti_start(data_dir: *const c_char) -> i32 {
    if data_dir.is_null() {
        set_last_error("data_dir is null".to_owned());
        return -1;
    }
    let dir = match unsafe { CStr::from_ptr(data_dir) }.to_str() {
        Ok(s) => s.to_owned(),
        Err(_) => {
            set_last_error("data_dir is not valid UTF-8".to_owned());
            return -1;
        }
    };
    start_engine(dir)
}

#[no_mangle]
pub extern "C" fn nanb_arti_stop() {
    stop_engine();
}

#[no_mangle]
pub extern "C" fn nanb_arti_socks_port() -> u16 {
    socks_port()
}

#[no_mangle]
pub extern "C" fn nanb_arti_bootstrap_pct() -> i32 {
    bootstrap_pct()
}

#[no_mangle]
pub extern "C" fn nanb_arti_is_ready() -> bool {
    is_ready()
}

/// Suspend (`dormant = true`) / resume (`dormant = false`) background activity
/// without tearing down the engine. See [`set_dormant`].
#[no_mangle]
pub extern "C" fn nanb_arti_set_dormant(dormant: bool) {
    set_dormant(dormant);
}

/// Last error message (NUL-terminated), or null if none. Valid until the next FFI
/// call that records an error; the Swift side copies it immediately.
#[no_mangle]
pub extern "C" fn nanb_arti_last_error() -> *const c_char {
    match LAST_ERROR.lock() {
        Ok(g) => match g.as_ref() {
            Some(cs) => cs.as_ptr(),
            None => std::ptr::null(),
        },
        Err(_) => std::ptr::null(),
    }
}

// ===========================================================================
// Android JNI (loaded as libnanb_arti.so; called from the Kotlin ArtiNative).
// The method names match `us.nanb.crypto.ArtiNative`'s `external fun`s.
// ===========================================================================

#[cfg(target_os = "android")]
mod android {
    use jni::objects::{JClass, JString};
    use jni::sys::{jboolean, jint, jstring};
    use jni::JNIEnv;

    #[no_mangle]
    pub extern "system" fn Java_us_nanb_crypto_ArtiNative_nativeStart(
        mut env: JNIEnv,
        _class: JClass,
        dir: JString,
    ) -> jint {
        let dir: String = match env.get_string(&dir) {
            Ok(s) => s.into(),
            Err(_) => {
                crate::set_last_error("jni: invalid data_dir string".to_owned());
                return -1;
            }
        };
        crate::start_engine(dir)
    }

    #[no_mangle]
    pub extern "system" fn Java_us_nanb_crypto_ArtiNative_nativeStop(_env: JNIEnv, _class: JClass) {
        crate::stop_engine();
    }

    #[no_mangle]
    pub extern "system" fn Java_us_nanb_crypto_ArtiNative_nativeSocksPort(
        _env: JNIEnv,
        _class: JClass,
    ) -> jint {
        crate::socks_port() as jint
    }

    #[no_mangle]
    pub extern "system" fn Java_us_nanb_crypto_ArtiNative_nativeBootstrapPct(
        _env: JNIEnv,
        _class: JClass,
    ) -> jint {
        crate::bootstrap_pct()
    }

    #[no_mangle]
    pub extern "system" fn Java_us_nanb_crypto_ArtiNative_nativeIsReady(
        _env: JNIEnv,
        _class: JClass,
    ) -> jboolean {
        u8::from(crate::is_ready())
    }

    #[no_mangle]
    pub extern "system" fn Java_us_nanb_crypto_ArtiNative_nativeSetDormant(
        _env: JNIEnv,
        _class: JClass,
        dormant: jboolean,
    ) {
        crate::set_dormant(dormant != 0);
    }

    /// Returns the last error as a Java String, or null if none.
    #[no_mangle]
    pub extern "system" fn Java_us_nanb_crypto_ArtiNative_nativeLastError(
        mut env: JNIEnv,
        _class: JClass,
    ) -> jstring {
        match crate::last_error_string() {
            Some(s) => env
                .new_string(s)
                .map(|j| j.into_raw())
                .unwrap_or(std::ptr::null_mut()),
            None => std::ptr::null_mut(),
        }
    }
}
