# iOS — known issues & platform limits

Things that behave differently on iOS than Android by platform design (not bugs
we can fix in our code), plus the reasoning so they don't get re-investigated.

---

## Share sheet: "Chat" is a two-step on iOS (no one-tap send)

**Symptom.** Share something from another app (YouTube, Photos, Safari) → tap
**Chat**. The extension shows **"Saved to Chat / Open the Chat app to choose who
to send it to"** with a Done button. It does **not** jump into the app with a
recipient picker the way Android (and WhatsApp/Telegram/Snapchat) do. To finish,
the user opens Chat and the shared content is waiting in the "Share to" picker.

**This is expected on iOS. Do not treat it as a bug or retry the auto-open.**

**Why Android is one-tap and iOS isn't.** On Android a share is an `ACTION_SEND`
intent that the OS delivers straight to `MainActivity` — the real app — launching
or resuming it. There is only ever one process and one owner of the ratchet/MLS
crypto state, which is exactly the model this app is built around. On iOS a share
extension is a **separate, sandboxed, memory-capped, short-lived process, and iOS
forbids it from launching its container app.**

**Auto-open is a confirmed dead end on iOS 26.5 — proven, not assumed.**
`NSExtensionContext.open(_:)` is documented Today-widget-only. The responder-chain
`openURL:` hack is closed on current iOS. Commit `75ae040` fixed a genuine
teardown race in the auto-open attempt (it called `completeRequest` in the same
turn as the open, cancelling it) and installing it on the device **changed
nothing** — that is the proof the OS door is shut. `145bf18` then removed the fake
"Opening Chat…" bounce and shipped the honest confirmation above. The
`nanb://share` URL scheme in `ios/Runner/Info.plist` is now unused (left in,
harmless).

**What the mainstream apps actually do** — and why we don't (yet). WhatsApp et al.
don't open their container either; their extension shows its own picker and
**sends from inside the extension** over plain TLS. Matching that here means
teaching a second, sandboxed process to send safely, which runs into three
obstacles specific to our stack:

1. **Shared crypto state (the hard one).** A real message advances the
   double-ratchet send chain (1:1) or the MLS generation counter, both stored in
   the SQLCipher DB / CoreCrypto store that the app assumes it single-writes. A
   second writer risks the "mutual-reset storm" (see `CLAUDE.md`) or MLS
   generation reuse (breaks forward secrecy). A promising way around it: send the
   share as a **one-shot sealed message to the recipient's static identity key**
   (ephemeral-X25519 → static-X25519 + AES-GCM), which does NOT touch the
   ratchet — the same static-unwrap path `openSealed` already uses. Tradeoff:
   weaker forward secrecy for those specific messages + a new receiver message
   type.
2. **Tor — minor.** The notification extension already sends over clearnet and
   `skiptor`s when built-in Tor is on. Since Tor now defaults OFF (`ecbd78f`) the
   common case is fine; a Tor-on user would get "open Chat to send over Tor."
3. **CoreCrypto/MLS in a memory-capped extension** — unproven; the NSE only does
   lightweight CryptoKit today.

**Status:** deferred. The two-step works and is shipped. In-extension send is a
real project, scoped but not started. Precedent that it's feasible: the
Notification Service Extension (`ios/NanbNotificationService/`) already does
crypto + `POST /messages/sealed` from within an extension.

**Cross-refs:** `ios/NanbShareExtension/ShareViewController.swift` (the
confirmation UI), memory `os-share-sheet-integration`, `DEPLOY_LOG.md`
(2026-07-26 entries).
