# Tor / metadata privacy — state & roadmap

NANb already encrypts message *content* end-to-end. Tor is about the second
layer: hiding the *metadata* — that you're using NANb, with whom, and when —
from anyone watching your network. This doc records what's built, how to verify
it, and what's deliberately deferred.

## What's built (done)

**SOCKS5 client support** — the app can route its HTTP traffic *and* its live
WebSocket through a SOCKS5 proxy (a local Tor instance). See
`lib/core/network/socks_proxy.dart`, wired via `socksProxyProvider`. Configure
it in **Settings → Network** (toggle + host/port, default `127.0.0.1:9050`).

This means NANb works with **Orbot** (the standalone Tor app) running in plain
proxy mode — no rooting, no whole-device VPN takeover. The app itself decides to
route through Tor; only NANb's traffic is affected.

Verified locally through Stage 2 of `docs/socks-live-test.md` (HTTP + WebSocket
both proven to tunnel through a SOCKS proxy, with negative controls).

## What's NOT done yet (and why)

### Stages 3–4: verify against *real* Tor — needs deployed infrastructure

`docs/socks-live-test.md` Stages 3–4 (real Orbot exit, and `.onion`
end-to-end) are **not runnable against the local dev server**, for a hard
reason: **Tor cannot route to private/loopback addresses.** The local dev
server lives at `10.0.2.2:8080` / `127.0.0.1:8080` — private addresses a Tor
exit node will refuse to reach. So real-Tor verification requires:

- **Orbot installed** on the test device (Play Store or sideloaded APK), in
  proxy mode exposing `127.0.0.1:9050`.
- **A reachable server endpoint that isn't private**, i.e. one of:
  - Stage 3 (clearnet exit): the server exposed on a **public** address
    (a deployed/staging host, or a tunnel like ngrok), then watch the server
    access log show a Tor *exit-node* IP instead of the device's real IP; or
  - Stage 4 (`.onion`): the server's **Tor hidden service actually running**.
    The config template is at `nanb-server/deploy/tor/torrc` — it must be
    deployed on a host running a Tor daemon, which then writes the public
    `.onion` to `/var/lib/tor/nanb/hostname`. Put that address in Settings →
    Network (onion field) with the SOCKS proxy on.

In short: Stages 3–4 are *deployment* verification, gated on standing up the
server's Tor service (or a public endpoint) + Orbot — not something the local
Windows dev box can fake.

### Future next step: embed the Tor daemon (deferred — complexity)

Today Tor support depends on the user installing **Orbot** separately. The
seamless version is to **embed a Tor engine inside NANb** so it starts its own
local SOCKS port on launch and no second app is needed.

This is deliberately **not** being done now. It's a heavier, *native* piece
(below the Flutter/Dart layer) and is blocked on platform build toolchains we
don't have here:

- It's a compiled binary, not Dart — built per-platform (Android arm64/x86,
  iOS arm64) as a native library Flutter loads.
- **Android:** needs the NDK cross-compiling C/Rust + Tor's deps (OpenSSL,
  libevent). This repo already hit the OpenSSL-from-source-on-Windows wall once
  (see `nanb-mobile/native/README.md`) and pivoted to a prebuilt.
- **iOS:** needs a **Mac + Xcode** — same wall as the iOS MLS work
  (`docs/ios-mls-build.md`).

**Realistic path when picked up:** don't compile Tor from scratch — bundle a
**prebuilt**: Guardian Project's `tor-android` (AAR) for Android, `Tor.framework`
for iOS, or the Rust `arti` library. That sidesteps the from-source build pain,
but integration + verifying the embedded Tor actually bootstraps and routes
still requires each target platform's build/test environment (a Mac for iOS, an
Android build env for Android).

The SOCKS5 client work above is the prerequisite that's already in place — an
embedded Tor would just provide the local SOCKS port the app already knows how
to use.
