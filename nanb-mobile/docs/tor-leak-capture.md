# Tor leak-capture procedure

How to *prove at runtime* that, with built-in Tor enabled, the app sends
**nothing to clearnet** outside the Tor SOCKS tunnel (the inherent FCM/Play
Services connection aside — see [metadata-threat-model.md](../../docs/metadata-threat-model.md)).

The static guard `test/architecture/no_clearnet_bypass_test.dart` proves no code
path *constructs* a client outside the `buildHttpClient` chokepoint. This
procedure is the empirical complement: observe the actual packets.

## What "pass" looks like
With Tor on and the chat list at `CONNECTED · E2EE · ONION`:
- The app's only outbound TCP is to the **Tor guard relay(s)** (and loopback to
  the embedded SOCKS port `127.0.0.1:9050`).
- **No** direct TCP/TLS to `nanb.link`, `*.cloudfront.net`,
  `*.giphy.com`, or any S3 host from the app's UID.
- Allowed exception: Google Play Services (FCM) traffic — that's a separate
  system process/UID, inherent to FCM, and documented as accepted.

## Method A — SOCKS reachability spot-check (fast, what we use day-to-day)
Confirms the app's Tor reaches a destination and that it exits via Tor, without
a full capture. Forward the phone's embedded SOCKS port to the workstation and
probe through it (workstation `curl` supports `--socks5-hostname`):

```bash
adb -s <serial> forward tcp:19050 tcp:9050        # PC:19050 -> phone Tor SOCKS

# Onion reachable over the phone's Tor (no exit node):
curl --socks5-hostname 127.0.0.1:19050 http://<onion-host>.onion/health   # -> ok

# Confirm traffic genuinely exits via Tor (for clearnet-over-exit paths):
curl --socks5-hostname 127.0.0.1:19050 https://check.torproject.org/api/ip
#   -> {"IsTor":true,"IP":"<some exit ip>"}

adb -s <serial> forward --remove tcp:19050
```
This validates the SOCKS path is live; it does **not** prove the app uses *only*
that path — use Method B for that.

## Method B — full on-device capture (the real proof)
Capture every connection the **app UID** makes and assert none are clearnet.

**Option B1 — PCAPdroid (no root).** Install PCAPdroid, set its target app to
`us.nanb.chat`, start capture, enable Tor in NANb, use the app (open chats, send
a photo, open the GIF picker, scroll). Stop capture and inspect the connections
list:
- Expect: connections to Tor relay IPs/ports only (often `:443`/`:9001`).
- Fail: any connection whose host is `nanb.link`, `*.cloudfront.net`, an S3
  bucket host, or `*.giphy.com`. (PCAPdroid shows resolved hostnames/SNI.)
- Note PCAPdroid itself uses a local VPN; ignore its own loopback entries.

**Option B2 — rooted tcpdump / `pcap` on the device**, or route the phone's
Wi-Fi through a workstation running Wireshark with a known SNI filter. Same
pass/fail criteria. Filter out the Play Services UID before judging.

## Things to exercise during a capture (highest-risk surfaces)
- GIF picker open + scroll (thumbnails — must go through the proxy, not the CDN).
- Receiving/opening a photo and loading a contact avatar (media download).
- Cold start + reconnect (REST + WS handshakes).
- A voice call invite (call signaling + any TURN traffic — note: media-relay
  TURN may be a separate, intentionally non-Tor path; confirm against design).

## Cadence
Run Method B before any release that changes networking, media, GIPHY, calls, or
the Tor layer, and any time the static guard's allow-list changes. Record the
date + build in the PR. Day-to-day, Method A plus a green guard test is enough.
