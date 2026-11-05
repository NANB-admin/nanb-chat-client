# FCM / Google metadata exposure (wakeup pushes)

NANb sends **content-blind wakeup pushes**: the push body never carries the
message, ciphertext, or any key material. The actual message is fetched over the
(onion) socket and decrypted **only in the foreground** — the background isolate
never decrypts (decrypting there would consume the forward-secret ratchet
generation and permanently lose the message). The push exists purely to wake the
device so it can sync.

This document records exactly what Google/FCM can and cannot observe, why each
field in the push is currently load-bearing, and the concrete redesign that would
let us strip the last stable identifier (`conversation_id`).

## What the push actually contains

Server side: `nanb-server/internal/push/service.go` (`DispatchWakeup`) builds the
data map; `nanb-server/internal/push/client_fcm.go` (`SendWakeup`) sends it via
FCM. The FCM **data** map (plaintext to Google — data messages are NOT encrypted
to FCM) is:

| key               | value                          | present when            |
| ----------------- | ------------------------------ | ----------------------- |
| `v`               | `"1"` (schema version)         | always                  |
| `type`            | `"wakeup"`                     | always                  |
| `envelope_id`     | opaque per-envelope id         | always                  |
| `conversation_id` | stable per-conversation id     | always                  |
| `push_kind`       | `"call"`                       | only for call invites   |

Plus the FCM **collapse key** (also Google-visible, used for routing/coalescing):
`wakeup:<deviceID>:<conversationID>` (falls back to `wakeup:<deviceID>` when no
conversation is known).

## What Google CAN see today

- The **device push token** → device identity + IP/region via Play Services, and
  rough online/offline timing from delivery.
- **`conversation_id`** — a *stable* identifier per thread. This is the real
  privacy cost: it lets Google traffic-analyse *which* thread is active for a
  device and *how often*, and correlate the two endpoints of a 1:1 (both devices
  see wakeups tagged with the same conversation id). It appears in BOTH the data
  payload and the collapse key.
- **`envelope_id`** — an opaque, single-use id. Not stable across messages, so it
  reveals message *count*/timing for a device but not *which thread*.
- **`push_kind`** — a coarse category (`"call"` vs. absent). Reveals "this wakeup
  is a call invite", not who or what. Not a stable identifier.
- Timing, frequency, and message/call counts per device.

## What Google CANNOT see

- Message contents, ciphertext, or any key material (none is ever in the push).
- Sender identity, message text, attachments, call media — all fetched over the
  onion socket and decrypted locally in the foreground.

## Why each field is load-bearing (and can't just be removed)

The Android background isolate posts the wake notification **directly from the
push**, without connecting or decrypting. So everything it needs to behave
correctly must be in the push:

- **`conversation_id`** is required by the background isolate
  (`nanb-mobile/lib/core/push/fcm_background_handler.dart`) to:
  - de-dup the notification — the Android notification id is
    `conversationId.hashCode`, so the several envelopes one logical message can
    produce (an MLS migration's Welcome + application pair, group / self-sync
    fan-out) collapse into a single banner instead of buzzing repeatedly;
  - honour per-conversation **mute** and **block** (the foreground mirrors those
    sets into SecureStorage; the handler filters on `conversation_id`);
  - resolve the **call ring** caller name (mirrored `conversationId -> name` map)
    and key the ring notification id;
  - set the **deep-link tap target** so tapping opens the right thread.
  Removing it would break notification de-dup, mute/block, and call rings.

- **`envelope_id`** is required by the **transport-"delivered" beacon**: the
  background isolate calls `delivery.ConfirmReceived(envelopeId)` (decrypt-free)
  so the original sender gets a "delivered" double-check before this device opens
  the app. The server's delivery receipt is keyed per envelope, so the id is
  needed to identify *which* message was delivered. Removing it regresses the
  delivered-receipt feature.

- **`push_kind`** is kept (only when non-empty). It's a category, not a stable
  identifier, and a call wakeup must ring (full-screen) instead of showing a
  generic banner.

### Why the collapse key keeps `conversation_id` too

Scoping the collapse key per conversation (`wakeup:<device>:<conversation>`) is
what lets an offline device coalesce many wakeups for one thread into a single
delivery while keeping *different* threads independent. Switching it to
device-level (`wakeup:<device>`) would make distinct threads fold into one FCM
slot — only the last wakeup survives, so notifications for the other threads are
dropped while the device is offline. And it would buy **no** privacy as long as
`conversation_id` is still in the data payload (Google already sees it there).
So the collapse key can only change in lockstep with removing `conversation_id`
from the payload.

## Current decision

Both `envelope_id` and `conversation_id` are **kept**, because removing either
regresses a shipped feature (delivered receipts; notification de-dup / mute /
block / call rings). This is the conservative, correct posture: the push already
leaks no content, and we do not trade working notifications for a partial
metadata win.

A server-side regression guard pins the exact payload shape (and the
no-ciphertext invariant) so the exposed set cannot silently widen:
`nanb-server/internal/push/service_test.go`
(`TestDispatchWakeup_PayloadShapeIsAnExactAllowList`).

## Recommended future step — how to remove `conversation_id` safely

`conversation_id` can only be dropped once the client stops needing it *in the
background, without decrypting*. The path:

1. **Move notification posting out of the push and into post-sync.** On a wakeup,
   the background isolate would only wake the app (or a headless service) to run
   the existing catch-up sync, then post notifications from the **decrypted**
   envelopes — at which point it knows the real conversation, sender, mute/block
   state, and call status without any push identifier. This is a non-trivial
   change on Android (background sync + crypto under Doze/battery limits) and is
   exactly the work the current design avoids by staying decrypt-free.
2. With notifications driven by sync, the push could shrink to an **opaque,
   per-message wake token** (or nothing but `type:"wakeup"`), and the collapse
   key could drop to device-level (`wakeup:<deviceID>`) — accepting that an
   offline device then coalesces *all* pending wakeups into one (it syncs
   everything on resume anyway, so no message is lost; only the "buzz per thread
   while offline" granularity changes).
3. **`envelope_id`** could likewise be replaced by having the post-sync path emit
   delivered beacons for every newly-fetched envelope (the ids come from the
   catch-up response, not the push), removing the last stable-ish hint.

Until that redesign lands, keep both ids and rely on the onion transport +
content-blind push to keep the *contents* private; the residual exposure is
limited to the metadata enumerated above.
