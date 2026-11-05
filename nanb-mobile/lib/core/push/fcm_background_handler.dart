import 'local_notifications.dart';
import 'wakeup_payload.dart';

/// Confirms physical receipt of a pushed envelope so the original sender's UI
/// can show a transport-level "delivered" before this device opens the app.
/// Fire-and-forget and DECRYPT-FREE: it never touches the inner ciphertext or
/// the forward-secret ratchet.
///
/// For a SEALED message (the [WakeupPayload] carries the inlined outer blob)
/// the implementation opens only the OUTER seal (a static X25519 unwrap, no
/// ratchet advance) to learn the sender, then sends a sealed, signed receipt
/// straight back — the server can't relay one itself because sealed sender
/// hides who the sender is. For a legacy non-sealed message it falls back to
/// the simple server-relayed beacon. See `core/push/sealed_delivered_receipt.dart`.
abstract class DeliveryReceiptBeacon {
  Future<void> confirmReceived(WakeupPayload payload);
}

// The production `onBackgroundMessage` entry point is the top-level
// `_firebaseMessagingBackgroundHandler` in main.dart (it needs app-level deps).
// A former empty `firebaseMessagingBackgroundHandler` stub lived here; it was
// removed because registering it by mistake would have silently dropped every
// push.

/// Testable seam. Surfaces a wake notification for a pushed message and
/// nothing more.
///
/// The background isolate DELIBERATELY does NOT decrypt the message. MLS
/// (and the legacy ratchet) are forward-secret: decrypting a message
/// ADVANCES and persists the shared per-sender ratchet generation, and the
/// plaintext key is then discarded. A background decrypt — done only to
/// preview the notification — would consume that generation in the shared
/// CoreCrypto store, so the FOREGROUND could never decrypt the same
/// envelope again: it would fail with MlsDecryptException, drop the
/// message, and the message would be permanently LOST from the thread.
///
/// So the foreground is the SOLE decryptor. This handler only wakes the
/// user; the message is fetched + decrypted + persisted on the next
/// foreground catchup (which runs on app resume / notification tap).
/// Trade-off: notification bodies are generic ("New message"), not a
/// content preview — the correct safety posture, and arguably the more
/// private default for an E2EE app.
Future<void> runFcmBackgroundHandler({
  required WakeupPayload payload,
  required LocalNotifications notifications,
  Set<String> mutedConversationIds = const {},
  Set<String> blockedConversationIds = const {},
  /// Envelope ids the FOREGROUND already consumed (see [HandledEnvelopeLog]).
  /// A wakeup is pushed for every envelope even when the live socket already
  /// delivered it, so the push for a message read on screen is still queued at
  /// FCM and arrives here as soon as the app is closed.
  Set<String> handledEnvelopeIds = const {},
  Map<String, String> callerNames = const {},
  DeliveryReceiptBeacon? beacon,
  String? effectiveConversationId,
  // Best-effort transport pre-warm, fired the instant an INCOMING CALL push
  // lands (before the ring is even shown). Production starts the embedded Tor
  // engine so its ~16s bootstrap overlaps the ring/answer time instead of being
  // paid serially after accept; because native Arti start is idempotent +
  // process-wide, the main isolate adopts the already-running engine on open.
  // Null (or a throw) simply means "no warm-up" — the call still works, just at
  // the old cold-start latency.
  Future<void> Function()? warmTransport,
}) async {
  // A SEALED wakeup carries the zero-UUID sentinel as its transport
  // conversation_id (the server is blind to the real one). The caller opens the
  // inlined outer blob and passes the REAL conversation id here. Use it for
  // mute/block suppression, the notification id, AND the tap deep-link —
  // without it a blocked/muted sealed chat still buzzed a closed device, and
  // tapping opened a non-existent (sentinel) thread ("shows nothing").
  final conversationId =
      (effectiveConversationId != null && effectiveConversationId.isNotEmpty)
          ? effectiveConversationId
          : payload.conversationId;
  // Respect per-conversation mute + block. The background isolate can't open
  // the encrypted DB, so the foreground mirrors both sets into SecureStorage
  // (ConversationsNotifier.mutedConvosKey / blockedConvosKey) and main.dart
  // passes them here.
  //
  // A blocked conversation stays silent in BOTH directions — no notification
  // AND no delivered beacon (mirrors the foreground rule that a blocked peer's
  // message never sends a receipt). So the block check gates everything.
  if (blockedConversationIds.contains(conversationId)) return;

  // Incoming CALL from a KNOWN peer: pre-warm the transport IMMEDIATELY — before
  // the ring, the beacon, or anything else — so the embedded-Tor bootstrap runs
  // during the ring/answer window rather than serially after accept (the
  // dominant chunk of cold-start connect latency). Gated on the conversation
  // being one we already know (mirrored into callerNames) so an UNKNOWN caller
  // can't make a closed device spin up Tor — the ring itself still shows for
  // strangers, but the warm-up (a resource cost) is reserved for real contacts.
  // Best-effort and non-blocking to the ring: any failure (Tor off, channel
  // absent on this isolate) is swallowed. (Residual: native Arti start is
  // idempotent + process-wide, so a repeat push is a no-op, not a re-bootstrap;
  // if the call is never answered the OS reaps the idle engine with the
  // process — a stop-on-missed path would need native timeout work.)
  if (payload.isCall &&
      warmTransport != null &&
      callerNames.containsKey(conversationId)) {
    try {
      await warmTransport();
    } catch (_) {/* best-effort; never block the ring on the warm-up */}
  }

  // A control/protocol-only wakeup (read/delivery receipt, reaction, pin, MLS
  // Welcome, sealed access-key share, non-invite call signal) carries no
  // user-visible content, so it must never raise a banner — opening a chat
  // fires a read receipt, which previously buzzed the peer with a phantom "new
  // message". The server suppresses these wakeups once deployed; this guard
  // also covers in-flight pushes and a new client talking to an older server.
  // No delivered-beacon either: control envelopes carry no delivery ticks.
  if (payload.isSilent) return;

  // SURFACE THE NOTIFICATION FIRST — before the delivered beacon below.
  //
  // The beacon is a NETWORK POST, and on a built-in-Tor device it rides a
  // circuit that this very push may have just cold-started, so it can block for
  // tens of seconds (or the full connect timeout). Running it first meant the
  // ring / banner was gated behind it: an incoming call woke the phone but the
  // ring screen appeared long after the caller had given up — the "the call
  // never shows when my screen is off" report. Nothing the beacon does affects
  // what we display, so it belongs strictly after.
  //
  // Muted: still beacon below (muting silences the alert, not delivery), just
  // don't show anything.
  // Already read in the foreground: the message is on screen and in the local
  // DB, so a banner for it is a phantom. CALLS are exempt on purpose — a
  // duplicate ring is a far cheaper mistake than a suppressed one, and a call
  // wakeup is latency-critical.
  final alreadyHandled =
      !payload.isCall && handledEnvelopeIds.contains(payload.envelopeId);
  if (!alreadyHandled && !mutedConversationIds.contains(conversationId)) {
    await _surfaceWakeNotification(
      payload: payload,
      notifications: notifications,
      conversationId: conversationId,
      caller: callerNames[conversationId] ?? '',
    );
  }

  // Transport-level "delivered": confirm physical receipt to the server
  // REGARDLESS of mute. Muting silences the alert, not delivery — the sender
  // still earns their double-check. Best-effort and decrypt-free: a failure
  // just means the sender learns "delivered" later from the peer's own
  // foreground receipt, exactly as before this beacon existed. Awaited (not
  // detached) so the isolate stays alive long enough for the POST to land.
  if (beacon != null) {
    try {
      await beacon.confirmReceived(payload);
    } catch (_) {/* best-effort; the notification is already up */}
  }
}

/// Last-resort notification for a wakeup the background isolate could not
/// process normally (its dependencies failed to load before
/// [runFcmBackgroundHandler] could run). A generic "New message" — or a ring
/// for a call — on the transport conversation id beats the old behaviour of
/// swallowing the error and showing NOTHING, which is a message the user never
/// hears about until they happen to open the app. Still honours the one rule
/// that needs no state: a silent control wakeup never raises a banner.
/// Never throws.
Future<void> showFallbackWakeNotification({
  required WakeupPayload payload,
  required LocalNotifications notifications,
}) async {
  if (payload.isSilent) return;
  await _surfaceWakeNotification(
    payload: payload,
    notifications: notifications,
    conversationId: payload.conversationId,
    caller: '',
  );
}

/// Posts the wake notification for [payload], degrading instead of giving up.
///
/// Every step used to be a bare `await`, so ONE platform failure — the plugin
/// failing to initialise in the background isolate, or the native call-ring
/// channel being absent — threw out of the handler and the push was simply
/// lost: no banner, no ring. Now:
///   * an init() failure still attempts the post (on Android the plugin can
///     post without the tap callback being wired);
///   * a failed full-screen call ring falls back to an ordinary high-priority
///     "Incoming call" banner, so the callee at least learns of the call;
///   * a failed post is swallowed so the delivered beacon still runs.
/// Never throws.
Future<void> _surfaceWakeNotification({
  required WakeupPayload payload,
  required LocalNotifications notifications,
  required String conversationId,
  required String caller,
}) async {
  try {
    await notifications.init();
  } catch (_) {/* still try to post — see above */}
  if (payload.isCall) {
    try {
      // An incoming-call wakeup rings (full-screen) instead of a generic
      // message banner. The push is content-blind, so the caller name comes
      // from the foreground-mirrored conversationId -> peer-name map; '' shows
      // as "Unknown" for a brand-new contact not yet mirrored.
      await notifications.showCall(
        id: conversationId.hashCode,
        caller: caller,
        conversationId: conversationId,
      );
      return;
    } catch (_) {/* fall back to a plain banner below */}
  }
  // Notification id is keyed on the CONVERSATION, not the envelope. A single
  // logical inbound message routinely produces SEVERAL envelopes addressed to
  // the same device — most notably an MLS migration's Welcome + application
  // pair, plus any group / self-sync fan-out. Each envelope triggers its own
  // wakeup, so keying on the envelope posted a SEPARATE notification per
  // envelope. Keying on the conversation makes a later wakeup REPLACE the
  // earlier one, so a conversation shows at most one notification. The tap
  // payload is the conversation id, so deep-linking still works.
  try {
    await notifications.show(
      id: conversationId.hashCode,
      title: payload.isCall ? 'Incoming call' : 'New message',
      body: payload.isCall
          ? (caller.isEmpty ? 'Open Chat to answer' : caller)
          : 'Open Chat to read',
      conversationId: conversationId,
    );
  } catch (_) {/* nothing left to try; the beacon still runs */}
}
