import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'dart:async';
import 'dart:convert';

import 'app/app.dart';
import 'app/providers.dart';
import 'app/router.dart';
import 'core/crypto/crypto_bridge_dart.dart';
import 'core/crypto/sealed_inner.dart';
import 'core/network/api_client_dio.dart';
import 'core/network/tor/tor_engine_channel.dart';
import 'core/push/fcm_activator.dart';
import 'core/push/fcm_background_handler.dart';
import 'core/push/handled_envelope_log.dart';
import 'core/push/local_notifications.dart';
import 'core/push/sealed_delivered_receipt.dart';
import 'core/push/wakeup_payload.dart';
import 'core/secure_storage/secure_storage_impl.dart';
import 'features/chat/conversations_notifier.dart';
import 'features/onboarding/session_repository.dart';
import 'features/settings/app_preferences_repository.dart';

/// Production [DeliveryReceiptBeacon], built from SecureStorage (no Riverpod —
/// this is the background isolate). Decrypt-free in both branches.
class _ApiDeliveryReceiptBeacon implements DeliveryReceiptBeacon {
  const _ApiDeliveryReceiptBeacon();

  @override
  Future<void> confirmReceived(WakeupPayload payload) async {
    final storage = SecureStorageImpl();
    // Sealed message (the push inlined the outer blob): open ONLY the outer
    // seal to learn the sender, then send a sealed, Ed25519-signed receipt
    // straight back on the UNAUTHENTICATED path — the server stays blind to who
    // talks to whom AND never sees this device's identity tied to an IP. The
    // simple confirmReceived beacon can't help here: the server stores the
    // zero-UUID sentinel sender for sealed envelopes, so it has nobody to relay
    // a "delivered" to.
    if (payload.sealedPayload.isNotEmpty) {
      final api = await ApiClientDio.createForBackgroundIsolate(storage: storage);
      try {
        await sendSealedDeliveredReceipt(
          deliveredEnvelopeId: payload.envelopeId,
          sealedBlob: payload.sealedPayload,
          crypto: CryptoBridgeDart(storage: storage),
          storage: storage,
          api: api,
        );
      } finally {
        api.close();
      }
      return;
    }
    // Legacy non-sealed message: the server still knows the sender, so the
    // simple transport beacon (it relays delivery_status to the sender) works.
    final api = await ApiClientDio.createForBackgroundIsolate(storage: storage);
    try {
      await api.confirmReceived(payload.envelopeId);
    } finally {
      api.close();
    }
  }
}

/// Diagnostic builds only: `--dart-define=NANB_DIAG=true` keeps logcat output in a
/// release build. Never set for store builds.
const bool _diagLogging = bool.fromEnvironment('NANB_DIAG');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Privacy: in RELEASE builds, suppress all console/logcat output. Diagnostic
  // logs across the app carry who-talks-to-whom metadata (conversation/device
  // ids, usernames, caller names); none of it should reach `adb logcat` on a
  // shipped device. Debug builds keep full logging. `debugPrint` is silenced
  // here; bare `print()` is silenced via the Zone wrapping runApp below.
  if (kReleaseMode && !_diagLogging) {
    debugPrint = (String? message, {int? wrapWidth}) {};
  }
  // Cold-start latency: kick off the embedded Tor bootstrap (~16s cold) at the
  // very top of process launch so it overlaps Firebase init, prefs load, and the
  // first-frame build — instead of being paid serially later when the chat list
  // drives connect(). For an OUTGOING call from a closed app this is the dominant
  // cost before the peer can ring (the invite falls back to HTTP-over-Tor when
  // the WS isn't up yet, so it waits on Tor being ready, not on the WebSocket).
  // Native Arti start is idempotent + process-wide, so the transport layer later
  // ADOPTS this already-bootstrapping engine (same mechanism as the on-push warm,
  // `_warmTorForCall`). Fire-and-forget; gated inside on a logged-in session and
  // built-in Tor being the active transport.
  unawaited(_warmTorOnColdStart());
  // Privacy gate: only touch Firebase/FCM when the user has push enabled.
  // Disabled means the app must NOT initialize FCM at all — otherwise the OS
  // push service still registers the device with Google/Apple (real IP + token,
  // NOT over Tor) even if our server never pushes. Read the pref BEFORE any
  // Firebase call. Defaults to DISABLED — push is opt-in (privacy by default);
  // a fresh install contacts Google not at all until the user turns it on.
  //
  // Both Android and iOS now run FCM: the iOS app ships GoogleService-Info.plist
  // and the `aps-environment` entitlement (Runner.entitlements), so Firebase
  // mints an FCM token backed by APNs and the server's FCM client forwards a
  // silent content-available wakeup that drives the SAME background isolate
  // handler as Android. Without the plist `[FIRApp configure]` would crash, so
  // the build wires it in (CI injects it from a secret) before this runs.
  var fcmEnabled = false;
  try {
    final prefs = await AppPreferencesRepository(SecureStorageImpl()).load();
    fcmEnabled = prefs.pushOverFcmEnabled;
    // Hand the already-loaded prefs to the provider so it hydrates synchronously
    // on first build — the transport (Tor vs clearnet) is then known before the
    // first connection, so a Tor user connects ONCE over Tor instead of
    // connecting clearnet, loading prefs, then reconnecting.
    bootstrapAppPreferences = prefs;
  } catch (_) {/* default to disabled; provider falls back to async load() */}
  // Let a mid-session opt-in (first-launch prompt / Settings → Privacy) bring
  // Firebase up without an app restart. Assigned even when push is off this
  // launch, so the opt-in flow can activate it on demand.
  fcmRuntimeActivator = initFirebasePush;
  if (fcmEnabled) {
    try {
      await initFirebasePush();
    } catch (_) {
      // Firebase init failed (placeholder google-services.json, no Play Services,
      // or no network at boot). The app boots without push wakeups; the
      // PushTokenProvider returns null and the registrar silently skips.
    }
  }
  // Pick the initial route from a cached flag so a returning user opens
  // straight onto a neutral splash → chat list, instead of flashing the
  // signed-out welcome screen while the session + native MLS store load. One
  // cheap key read; defaults to welcome on any error.
  var initialLocation = Routes.welcome;
  try {
    if (await SessionRepository(SecureStorageImpl()).exists()) {
      initialLocation = Routes.resuming;
    }
  } catch (_) {/* default to welcome */}

  // In release, run under a Zone that drops bare `print()` too, so no
  // diagnostic line (many carry conversation/device ids) reaches logcat on a
  // shipped device. Debug builds print normally.
  if (kReleaseMode && !_diagLogging) {
    runZoned(
      () => runApp(ProviderScope(child: NanbApp(initialLocation: initialLocation))),
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) {/* swallowed in release */},
      ),
    );
  } else {
    runApp(ProviderScope(child: NanbApp(initialLocation: initialLocation)));
  }
}

/// Initializes Firebase Cloud Messaging for the FOREGROUND isolate: brings up
/// Firebase, enables auto-init + data collection (which is what actually mints
/// an FCM token + connects to Google), and registers the background message
/// handler. Called at boot when push is enabled, and by the opt-in flow at
/// runtime (via `fcmRuntimeActivator`) so turning push on works without a
/// restart. The manifest ships auto-init OFF so a push-disabled launch never
/// contacts Google; this is the enabled path that turns it back on.
Future<void> initFirebasePush() async {
  final app = await Firebase.initializeApp();
  app.setAutomaticDataCollectionEnabled(true);
  await FirebaseMessaging.instance.setAutoInitEnabled(true);
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
}

/// Top-level isolate entry. MUST be top-level — Firebase enforces this.
/// Reconstructs deps from secure storage + platform channels (no Riverpod —
/// this isolate is separate from the main app's ProviderScope).
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  final payload = WakeupPayload.tryParse(message.data);
  if (payload == null) return;
  final notifications = LocalNotificationsImpl();

  // INVARIANT: no dependency below may cost the user the notification. Every
  // load used to sit inside ONE try whose catch swallowed the error — so a
  // single failure (Firebase re-init throwing on this isolate, a keystore
  // hiccup) returned before anything was shown and the message went unheard
  // until the app was next opened. Each load now degrades to its default and
  // the handler always runs.
  try {
    // Each isolate initializes Firebase before using its APIs. Nothing below
    // actually needs it (no Firebase API is called here), so a failure must not
    // abort the wakeup.
    await Firebase.initializeApp();
  } catch (_) {/* best-effort */}

  // No API client / crypto bridge here on purpose: the background isolate
  // never decrypts (that would consume the forward-secret ratchet generation
  // and lose the message for the foreground). It only shows a wake
  // notification; the foreground catches up + decrypts on resume.
  final SecureStorageImpl storage;
  try {
    storage = SecureStorageImpl();
  } catch (_) {
    // Can't read any mirrored state (mute/block/handled/real conversation):
    // show the generic wake notification rather than nothing.
    await showFallbackWakeNotification(
        payload: payload, notifications: notifications);
    return;
  }

  // Read the muted-conversation set the foreground mirrored into
  // SecureStorage so muted chats don't buzz.
  var muted = const <String>{};
  try {
    final raw = await storage.getString(ConversationsNotifier.mutedConvosKey);
    if (raw != null && raw.isNotEmpty) {
      muted = (jsonDecode(raw) as List).cast<String>().toSet();
    }
  } catch (_) {/* best-effort; default = not muted */}
  var blocked = const <String>{};
  try {
    final raw = await storage.getString(ConversationsNotifier.blockedConvosKey);
    if (raw != null && raw.isNotEmpty) {
      blocked = (jsonDecode(raw) as List).cast<String>().toSet();
    }
  } catch (_) {/* best-effort; default = not blocked */}
  // Mirrored 1:1 conversationId -> peer name, so a call ring shows the caller.
  var callerNames = const <String, String>{};
  try {
    final raw = await storage.getString(ConversationsNotifier.callPeerNamesKey);
    if (raw != null && raw.isNotEmpty) {
      callerNames = Map<String, String>.from(jsonDecode(raw) as Map);
    }
  } catch (_) {/* best-effort; default = no names ("Unknown") */}

  // A SEALED wakeup carries the zero-UUID sentinel as its conversation_id, so
  // mute/block (keyed on the real conversation) and the tap deep-link can't
  // match. Open the inlined outer blob to recover the REAL conversation id —
  // a static X25519 unwrap that does NOT advance the forward-secret ratchet
  // (same op the delivered-receipt beacon already performs), so the foreground
  // can still decrypt the message later.
  String? effectiveConvId;
  if (payload.sealedPayload.isNotEmpty) {
    try {
      final opened =
          await CryptoBridgeDart(storage: storage).openSealed(payload.sealedPayload);
      final inner = SealedInner.decode(opened);
      if (inner.conversationId.isNotEmpty) {
        effectiveConvId = inner.conversationId;
      }
    } catch (_) {/* not addressed to us / corrupt → keep the sentinel */}
  }

  // Envelope ids the foreground already consumed, so a wakeup whose message
  // is already on screen doesn't post a phantom banner the instant the user
  // closes the app. Never throws (an unreadable mirror reads as empty).
  final handled = await HandledEnvelopeLog.read(storage);

  try {
    // Never throws for a notification failure (it degrades internally); this
    // catch is only a last guard so the isolate can't crash on the way out.
    await runFcmBackgroundHandler(
      payload: payload,
      notifications: notifications,
      mutedConversationIds: muted,
      handledEnvelopeIds: handled,
      blockedConversationIds: blocked,
      callerNames: callerNames,
      beacon: const _ApiDeliveryReceiptBeacon(),
      effectiveConversationId: effectiveConvId,
      warmTransport: () => _warmTorForCall(storage),
    );
  } catch (_) {/* see above */}
}

/// Best-effort transport pre-warm for an incoming-call push (see
/// [runFcmBackgroundHandler]'s `warmTransport`). Starts the embedded Tor engine
/// so its ~16s bootstrap overlaps the ring/answer window instead of being paid
/// serially after accept. Only when built-in Tor is the active transport
/// (opt-in; absent/default = off), read the same key
/// `ApiClientDio.createForBackgroundIsolate` uses. The `nanb.app/tor` channel is
/// registered on this background isolate, so `start()` reaches native Arti; and
/// native start is idempotent + process-wide, so the main isolate ADOPTS the
/// already-bootstrapping engine when the user opens the app. A
/// MissingPluginException (channel absent, e.g. iOS) propagates to the caller,
/// which swallows it — the call still works at the old cold-start latency.
Future<void> _warmTorForCall(SecureStorageImpl storage) async {
  if ((await storage.getString('pref.built_in_tor_enabled')) != 'true') return;
  await TorEngineChannel().start();
}

/// Foreground cold-start counterpart to [_warmTorForCall]: starts the embedded
/// Tor bootstrap immediately at process launch so its ~16s bootstrap overlaps
/// the rest of startup, cutting the time before a from-cold outgoing call can
/// reach the server and ring the peer. Gated on a logged-in session (no point
/// bootstrapping Tor on the signed-out welcome screen) AND built-in Tor being
/// the active transport. Best-effort: any failure (channel absent on the iOS
/// shim, storage hiccup) just leaves the pre-existing lazy-start latency.
Future<void> _warmTorOnColdStart() async {
  try {
    final storage = SecureStorageImpl();
    if (!await SessionRepository(storage).exists()) return;
    if ((await storage.getString('pref.built_in_tor_enabled')) != 'true') return;
    await TorEngineChannel().start();
  } catch (_) {
    // Best-effort; the transport starts Tor later anyway.
  }
}
