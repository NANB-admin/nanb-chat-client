# Store & TestFlight copy

Canonical wording for App Store Connect / TestFlight so each release isn't rewritten
from scratch. Keep claims here TRUE — App Review reads the beta description, and
anything unprovable ("military-grade", "unhackable") invites a rejection.

Deliberately avoided: competitor names, absolute security claims, and any feature not
actually shipped in the build being submitted.

## Beta App Description (TestFlight, app-level — max 4,000 chars)

> NANb Chat is a private messenger built so that nobody — including us — can read your
> messages. Everything you send is encrypted on your device before it leaves it, and our
> servers only ever handle ciphertext they cannot open.
>
> In this beta you can:
>
> • Message one-to-one or in groups, end-to-end encrypted with MLS, the IETF's messaging
> security standard
> • Send photos, videos, files, voice notes and GIFs — all encrypted before upload
> • Make voice and video calls, relayed so you and the other person never see each
> other's IP address
> • Set disappearing messages per chat, with the sender's timer honoured on both sides
> • React, reply, pin, edit and unsend messages, and search your own history
> • Use one account across several devices, each with its own keys
> • Optionally route your traffic through the Tor network from inside the app
> (Settings → Network) — no separate Tor app needed
> • Lock the app with Face ID or a passcode, and block screenshots
>
> Two things worth knowing before you start. Your recovery phrase is the only way back
> into your account — we have no way to reset it, so save it somewhere safe. And push
> notifications are off until you turn them on: until then the app never contacts
> Google's push service at all.
>
> To begin, pick a username, save your recovery phrase, then add someone by scanning
> their QR code or entering their username.
>
> Expected in this build: notification banners say "New message" without the sender or a
> preview — message content never travels through Apple's or Google's push servers, so
> that's by design, not a bug. Muted chats can still show a banner on iOS.
>
> Feedback on anything that feels slow, drops a message, or fails to connect is
> especially useful — reach us at admin@nanb.us.

## What to Test (per-build field)

> Focus for this build: reliability of the basics. Send text, photos, videos and voice
> notes in both one-to-one and group chats, and check they arrive and show the right
> delivered/read state. Place a voice call and a video call. Background the app for a few
> minutes and confirm you still get a notification. If you use Tor (Settings → Network),
> try messaging and calling with it on, and after leaving the app backgrounded for a
> while.
>
> Please report: anything that never arrives, a chat stuck on "Connecting", a call that
> won't connect, or the app becoming unresponsive.

## Notes for whoever updates this

- **The OS share sheet ("Share via Chat") is NOT mentioned.** It's on master and works on
  Android + on sideloaded iOS, but the TestFlight/App Store build (`ios-release.yml`) still
  SKIPS the iOS share extension until repo secret `IOS_PROFILE_SHARE_BASE64` is set — so the
  submitted build has no iOS share sheet. Add a bullet only once a TestFlight build actually
  ships with it. (Also: on iOS it's a two-step — see `docs/ios-known-issues.md` — so if it's
  ever described, don't imply one-tap send.)
- The two "expected in this build" lines exist to pre-empt bug reports (and reviewer
  confusion) about generic push banners — that's a deliberate privacy property, not a
  defect. See `docs/fcm-metadata.md`.
- External TestFlight testing goes through Beta App Review; internal testing does not.
- Export-compliance answers that accompany a submission are recorded in
  `../../EXPORT_COMPLIANCE.md` (outer folder, outside the repo).
