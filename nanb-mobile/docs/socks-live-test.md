# SOCKS5 routing — live-device test plan

Verifies the SOCKS5 client support (`core/network/socks_proxy.dart`,
commit `568e29a`): that the HTTP client (Dio) **and** the live WebSocket both
route through a SOCKS5 proxy when one is configured, and that nothing silently
bypasses it.

The plan goes from "prove the wiring works" (host proxy, no Tor needed) to
"prove real Tor works" (Orbot) to "prove .onion works" (server onion service).
Stop after whatever stage answers your question — Stage 1 alone fully validates
the code I wrote; Stages 3–4 validate the *deployment* (Orbot + server onion).

---

## How the networking lays out (read this first)

The non-obvious part is **whose `127.0.0.1` is whose**. The app names a *proxy*
and a *destination*; they're resolved from different machines:

- The **proxy address** is resolved by the **device** (where the app runs).
  - Emulator → host services are at `10.0.2.2`.
  - Real device → host services are at the host's **LAN IP** (e.g. `192.168.1.x`).
- The **destination** (the server URL) is resolved by the **proxy**.
  - A proxy running on the host reaches the dev server at `127.0.0.1:8080`.
  - Tor (Orbot, on the device) reaches a public address or a `.onion`.

This split is what makes Stage 1 an airtight proof: the only way the app can
reach a host-side `127.0.0.1:8080` from inside the emulator is *through the host
proxy*. If routing were bypassed, it would fail.

Identify devices by account/AVD name, never by port — emulator ports shuffle
every boot (`adb -s emulator-<port> emu avd name`). Screenshots: `tool/shot.ps1`.

---

## Stage 0 — start the harness

1. Dev server running on the host (`nanb-server` on `:8080`).
2. Logging SOCKS proxy on the host (this repo, no Tor involved):
   ```powershell
   cd nanb-mobile
   dart run tool/socks_test_proxy.dart 1080
   ```
   It prints every `CONNECT -> host:port` it forwards — that log IS the proof.
   (Verified working: `curl --socks5-hostname 127.0.0.1:1080 http://example.com`
   returns 200 and logs the CONNECT.)
3. A debug build installed on the target:
   ```powershell
   flutter build apk --debug
   adb -s <serial> install -r build/app/outputs/flutter-apk/app-debug.apk
   ```

---

## Stage 1 — prove HTTP routes through SOCKS (emulator, no Tor)

In the app: **Settings → Network**.

| Field | Value |
|---|---|
| Server endpoint | `http://127.0.0.1:8080`  ← host's view, reached *by the proxy* |
| Route through SOCKS proxy | **ON** |
| SOCKS host | `10.0.2.2`  ← the host, *from the emulator* |
| SOCKS port | `1080` |

Tap **Save** (this tears down + reconnects). Then sign in / open the chat list.

**PASS:** the app loads conversations (an authed HTTP call succeeded), and the
proxy console prints `CONNECT -> 127.0.0.1:8080`.

### The two negative controls (these are the real proof)

- **Bypass check:** flip *Route through SOCKS proxy* **OFF**, Save. The app can
  no longer reach the server (the emulator's own `127.0.0.1:8080` has nothing on
  it). → confirms Stage-1 success happened *because of* the proxy, not in spite
  of it. Turn it back ON.
- **Proxy-required check:** keep SOCKS **ON** but stop the proxy process. The app
  fails to connect (connection refused at `10.0.2.2:1080`). → confirms the app
  genuinely dials the proxy. Restart the proxy.

## Stage 2 — prove the WebSocket routes through SOCKS

Same config as Stage 1, proxy running. Have a **second** account (other
emulator, direct/clearnet) send you a message while you watch the chat thread.

**PASS:** the message appears in real time (no app restart / manual refresh),
and the proxy console shows a **second, long-lived** `CONNECT -> 127.0.0.1:8080`
that stays open — that's the `/ws` upgrade tunnelled through SOCKS. This is the
half I was least certain about (`IOWebSocketChannel customClient`), so it's the
key line to see.

> Tip: the WS CONNECT is distinguishable from the HTTP ones because it does not
> close after the request — it lingers for the life of the session.

## Stage 3 — prove real Tor works (Orbot, clearnet exit)  ⟵ needs you

This swaps the host harness for an actual Tor proxy. **Requires installing
Orbot** (Google Play, or sideload the APK) on the device — a manual step.

1. Install + start **Orbot**; enable its SOCKS proxy (default `127.0.0.1:9050`).
   Leave it in proxy mode (it does **not** need VPN/transparent mode — that's the
   whole point of this feature).
2. Expose the dev server on a **public** address Tor can exit to (e.g. an ngrok
   https tunnel or a staging host), and set Server endpoint to that.
3. Network settings:
   - Route through SOCKS proxy: **ON**
   - SOCKS host: `127.0.0.1`  (Orbot runs *on the device*)
   - SOCKS port: `9050`
4. Save, use the app.

**PASS:** the app works, and the **server access log shows a Tor exit-node IP**,
not the device's real IP. (Optionally cross-check the source IP against the
public Tor exit list.)

## Stage 4 — prove `.onion` works end-to-end  ⟵ needs server onion

Requires the server's v3 onion service to be **published and reachable**
(`nanb-server/deploy/tor/torrc`). Confirm the `.onion` is up first (e.g. from a
desktop: `curl --socks5-hostname 127.0.0.1:9050 http://<onion>:8080/healthz`).

1. Orbot running (as Stage 3), SOCKS `127.0.0.1:9050` ON.
2. Network settings: set the **onion URL** field to `http://<onion>:8080`, toggle
   **Prefer onion endpoint** ON, Save.
3. Send/receive both directions across two accounts.

**PASS:** messages flow over the `.onion` (the app resolved it via Tor's remote
DNS — no clearnet server contact at all). The "Prefer onion endpoint" toggle is
now functional purely from inside the app.

---

## What each stage actually proves

| Stage | Validates | Needs |
|---|---|---|
| 1 | Dio HTTP tunnels through SOCKS; doesn't bypass | host proxy only |
| 2 | WebSocket tunnels through SOCKS (real-time) | host proxy + 2nd account |
| 3 | Works against a real Tor SOCKS proxy; hides IP | Orbot + public server |
| 4 | `.onion` reachable from inside the app | Orbot + server onion |

Stages 1–2 are the code I wrote and can be run entirely on this machine. Stages
3–4 validate the surrounding deployment and need an external piece (Orbot, a
public/onion server endpoint) that isn't ours to fake.
