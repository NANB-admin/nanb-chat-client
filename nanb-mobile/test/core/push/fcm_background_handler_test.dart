import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/push/fcm_background_handler.dart';
import 'package:nanb_chat/core/push/local_notifications.dart';
import 'package:nanb_chat/core/push/wakeup_payload.dart';

class _FakeNotifications implements LocalNotifications {
  /// Shared with [_FakeBeacon] so a test can assert what ran FIRST.
  _FakeNotifications({List<String>? trace}) : trace = trace ?? <String>[];
  final List<String> trace;

  String? lastTitle;
  String? lastBody;
  String? lastConvoId;
  int? lastId;
  bool initCalled = false;
  int showCalls = 0;
  int callShows = 0;
  String? lastCallConvoId;
  String? lastCaller;

  /// Platform failures to simulate (plugin init, posting, native call ring).
  Object? initError;
  Object? showError;
  Object? showCallError;

  @override
  Future<void> cancelAll() async {}

  @override
  Future<void> init() async {
    initCalled = true;
    if (initError != null) throw initError!;
  }

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
    required String conversationId,
  }) async {
    trace.add('show');
    if (showError != null) throw showError!;
    showCalls++;
    lastId = id;
    lastTitle = title;
    lastBody = body;
    lastConvoId = conversationId;
  }

  @override
  Future<void> showCall({
    required int id,
    required String caller,
    required String conversationId,
  }) async {
    trace.add('showCall');
    if (showCallError != null) throw showCallError!;
    callShows++;
    lastCallConvoId = conversationId;
    lastCaller = caller;
  }

  @override
  Future<void> cancel(int id) async {}

  @override
  Future<bool> requestFullScreenIntentPermission() async => true;

  @override
  Stream<String> get conversationTaps => const Stream<String>.empty();
}

class _FakeBeacon implements DeliveryReceiptBeacon {
  _FakeBeacon({List<String>? trace}) : trace = trace ?? <String>[];
  final List<String> trace;

  final List<String> confirmed = [];
  bool throwOnCall = false;

  @override
  Future<void> confirmReceived(WakeupPayload payload) async {
    trace.add('beacon');
    confirmed.add(payload.envelopeId);
    if (throwOnCall) throw Exception('beacon boom');
  }
}

void main() {
  group('FcmBackgroundHandler', () {
    // The background isolate must NOT decrypt: an MLS/ratchet decrypt advances
    // the forward-secret per-sender generation in the shared store, which
    // would consume the message and make it undecryptable (lost) for the
    // foreground. So the handler only shows a generic wake notification; the
    // foreground decrypts on catchup. These tests pin the no-decrypt contract.
    test('shows a generic wake notification carrying the conversation id',
        () async {
      final notif = _FakeNotifications();
      await runFcmBackgroundHandler(
        payload: const WakeupPayload(
          envelopeId: 'env-1',
          conversationId: 'group:g1',
        ),
        notifications: notif,
      );

      expect(notif.initCalled, isTrue);
      expect(notif.showCalls, 1);
      expect(notif.lastConvoId, 'group:g1');
      expect(notif.lastTitle, 'New message');
      // Body is intentionally generic — never a decrypted preview.
      expect(notif.lastBody, isNot(contains('hello')));
      // Notification id is keyed on the CONVERSATION (not the envelope) so that
      // multiple envelopes backing one logical message collapse into a single
      // notification instead of buzzing the device repeatedly.
      expect(notif.lastId, 'group:g1'.hashCode);
    });

    test('does not raise a banner for an envelope already read in foreground',
        () async {
      // A wakeup is pushed for EVERY envelope even when the live socket already
      // delivered it, so the push for a message read on screen stays queued at
      // FCM and lands here the moment the app is closed — the phantom "New
      // message" a second after closing the app.
      final notif = _FakeNotifications();

      await runFcmBackgroundHandler(
        payload: const WakeupPayload(
          envelopeId: 'env-1',
          conversationId: 'group:g1',
        ),
        notifications: notif,
        handledEnvelopeIds: const {'env-1'},
      );

      expect(notif.showCalls, 0);
    });

    test('still raises a banner for an envelope the foreground never saw',
        () async {
      final notif = _FakeNotifications();

      await runFcmBackgroundHandler(
        payload: const WakeupPayload(
          envelopeId: 'env-2',
          conversationId: 'group:g1',
        ),
        notifications: notif,
        handledEnvelopeIds: const {'env-1'},
      );

      expect(notif.showCalls, 1);
    });

    test('still rings a call whose envelope was already handled', () async {
      // Calls are exempt: a duplicate ring is a far cheaper mistake than a
      // suppressed one.
      final notif = _FakeNotifications();

      await runFcmBackgroundHandler(
        payload: WakeupPayload.tryParse(const {
          'envelope_id': 'env-1',
          'conversation_id': '1to1:a:b',
          'push_kind': 'call',
        })!,
        notifications: notif,
        handledEnvelopeIds: const {'env-1'},
      );

      expect(notif.callShows, 1);
    });

    test('a call wakeup rings (showCall) with the mirrored caller name',
        () async {
      final notif = _FakeNotifications();
      await runFcmBackgroundHandler(
        payload: WakeupPayload.tryParse(const {
          'envelope_id': 'env-1',
          'conversation_id': '1to1:a:b',
          'push_kind': 'call',
        })!,
        notifications: notif,
        callerNames: const {'1to1:a:b': 'bronco'},
      );

      expect(notif.callShows, 1);
      expect(notif.lastCallConvoId, '1to1:a:b');
      expect(notif.lastCaller, 'bronco',
          reason: 'caller name comes from the mirrored conversationId->name map');
      expect(notif.showCalls, 0, reason: 'no generic "new message" for a call');
    });

    test('a call wakeup falls back to empty caller when not mirrored', () async {
      final notif = _FakeNotifications();
      await runFcmBackgroundHandler(
        payload: WakeupPayload.tryParse(const {
          'envelope_id': 'env-1',
          'conversation_id': '1to1:unknown',
          'push_kind': 'call',
        })!,
        notifications: notif,
      );

      expect(notif.callShows, 1);
      expect(notif.lastCaller, '');
    });

    test('a muted conversation suppresses the call ring too', () async {
      final notif = _FakeNotifications();
      await runFcmBackgroundHandler(
        payload: const WakeupPayload(
          envelopeId: 'env-1',
          conversationId: '1to1:a:b',
          pushKind: 'call',
        ),
        notifications: notif,
        mutedConversationIds: const {'1to1:a:b'},
      );
      expect(notif.callShows, 0);
      expect(notif.showCalls, 0);
    });

    test(
        'two envelopes in the same conversation reuse one notification id '
        '(so a Welcome+application pair does not buzz the device twice)',
        () async {
      // An MLS migration's first send fans a Welcome envelope AND an
      // application envelope to the SAME peer device, each with its own
      // envelope id and so its own wakeup push. Keying the notification on the
      // conversation makes the second push REPLACE the first (same Android
      // notification id) instead of stacking a second buzz.
      final notif = _FakeNotifications();
      await runFcmBackgroundHandler(
        payload: const WakeupPayload(
          envelopeId: 'welcome-env',
          conversationId: 'conv-xyz',
        ),
        notifications: notif,
      );
      final firstId = notif.lastId;

      await runFcmBackgroundHandler(
        payload: const WakeupPayload(
          envelopeId: 'application-env',
          conversationId: 'conv-xyz',
        ),
        notifications: notif,
      );

      // Both wakeups posted to the same notification id → the OS coalesces
      // them into a single visible notification (one buzz, not two).
      expect(notif.lastId, firstId);
      expect(notif.lastId, 'conv-xyz'.hashCode);
    });

    test('different conversations get distinct notification ids (no collapse)',
        () async {
      final notif = _FakeNotifications();
      await runFcmBackgroundHandler(
        payload: const WakeupPayload(envelopeId: 'e1', conversationId: 'c1'),
        notifications: notif,
      );
      final firstId = notif.lastId;
      await runFcmBackgroundHandler(
        payload: const WakeupPayload(envelopeId: 'e2', conversationId: 'c2'),
        notifications: notif,
      );
      expect(notif.lastId, isNot(firstId));
    });

    test('requires no API client or crypto bridge (signature is decrypt-free)',
        () async {
      // Compile-time guarantee: runFcmBackgroundHandler takes only payload +
      // notifications. If a future change reintroduces a bridge/api param,
      // this call fails to compile — the canary for "we started decrypting in
      // the background again".
      final notif = _FakeNotifications();
      await runFcmBackgroundHandler(
        payload: const WakeupPayload(
          envelopeId: 'e',
          conversationId: 'c',
        ),
        notifications: notif,
      );
      expect(notif.showCalls, 1);
    });

    test('fires the transport-delivered beacon with the envelope id', () async {
      // The beacon is decrypt-free — it confirms physical receipt so the
      // sender's UI can show a double-check before this device opens the app.
      final notif = _FakeNotifications();
      final beacon = _FakeBeacon();
      await runFcmBackgroundHandler(
        payload: const WakeupPayload(envelopeId: 'env-42', conversationId: 'c1'),
        notifications: notif,
        beacon: beacon,
      );
      expect(beacon.confirmed, ['env-42']);
      // A normal (unmuted, unblocked) message still shows its wake notification.
      expect(notif.showCalls, 1);
    });

    // REGRESSION GUARD. The delivered beacon is a NETWORK POST that, on a
    // built-in-Tor device, rides a circuit this push may have just cold-started
    // — it can block for tens of seconds. It used to run BEFORE the
    // notification, so an incoming call woke the phone and then sat silent
    // until the POST finished ("the call never shows when my screen is off").
    // Nothing the beacon does changes what we display, so it must run last.
    test('rings BEFORE firing the delivered beacon (the beacon can block on a '
        'cold Tor circuit)', () async {
      final trace = <String>[];
      final notif = _FakeNotifications(trace: trace);
      final beacon = _FakeBeacon(trace: trace);
      await runFcmBackgroundHandler(
        payload: const WakeupPayload(
          envelopeId: 'env-1',
          conversationId: 'c1',
          pushKind: 'call',
        ),
        notifications: notif,
        beacon: beacon,
        callerNames: const {'c1': 'Ada'},
      );
      expect(trace, ['showCall', 'beacon']);
    });

    test('shows a message banner BEFORE firing the delivered beacon', () async {
      final trace = <String>[];
      final notif = _FakeNotifications(trace: trace);
      final beacon = _FakeBeacon(trace: trace);
      await runFcmBackgroundHandler(
        payload: const WakeupPayload(envelopeId: 'env-1', conversationId: 'c1'),
        notifications: notif,
        beacon: beacon,
      );
      expect(trace, ['show', 'beacon']);
    });

    test('a blocked conversation neither beacons nor notifies', () async {
      // Block stays silent in BOTH directions: no notification AND no delivered
      // receipt (mirrors the foreground "blocked peer gets no receipt" rule).
      final notif = _FakeNotifications();
      final beacon = _FakeBeacon();
      await runFcmBackgroundHandler(
        payload: const WakeupPayload(envelopeId: 'env-1', conversationId: 'c1'),
        notifications: notif,
        beacon: beacon,
        blockedConversationIds: const {'c1'},
      );
      expect(beacon.confirmed, isEmpty);
      expect(notif.showCalls, 0);
    });

    test('a muted conversation still beacons but shows no notification',
        () async {
      // Mute silences the alert, not delivery — the sender still earns their
      // double-check.
      final notif = _FakeNotifications();
      final beacon = _FakeBeacon();
      await runFcmBackgroundHandler(
        payload: const WakeupPayload(envelopeId: 'env-7', conversationId: 'c1'),
        notifications: notif,
        beacon: beacon,
        mutedConversationIds: const {'c1'},
      );
      expect(beacon.confirmed, ['env-7']);
      expect(notif.showCalls, 0);
    });

    test('a silent control wakeup neither beacons nor notifies', () async {
      // Control/protocol envelopes (read/delivery receipt, reaction, pin, MLS
      // Welcome, access-key share) ride a 'silent' push_kind: they may wake the
      // isolate but must NEVER raise a banner — opening a chat fires a read
      // receipt, which previously buzzed the peer with a phantom "new message".
      // No delivered beacon either: control envelopes carry no delivery tick.
      final notif = _FakeNotifications();
      final beacon = _FakeBeacon();
      await runFcmBackgroundHandler(
        payload: WakeupPayload.tryParse(const {
          'envelope_id': 'env-rcpt',
          'conversation_id': '1to1:a:b',
          'push_kind': 'silent',
        })!,
        notifications: notif,
        beacon: beacon,
      );
      expect(notif.showCalls, 0, reason: 'a control envelope must not banner');
      expect(notif.callShows, 0);
      expect(notif.initCalled, isFalse,
          reason: 'silent returns before any notification work');
      expect(beacon.confirmed, isEmpty,
          reason: 'a control envelope carries no delivery tick to confirm');
    });

    test('a beacon failure is swallowed and the notification still shows',
        () async {
      final notif = _FakeNotifications();
      final beacon = _FakeBeacon()..throwOnCall = true;
      await runFcmBackgroundHandler(
        payload: const WakeupPayload(envelopeId: 'env-9', conversationId: 'c1'),
        notifications: notif,
        beacon: beacon,
      );
      // The attempt was made, the throw didn't propagate, and the wake
      // notification was not starved by the failed beacon.
      expect(beacon.confirmed, ['env-9']);
      expect(notif.showCalls, 1);
    });

    // A SEALED wakeup carries the zero-UUID sentinel as its transport
    // conversation_id; the caller opens the inlined outer blob and passes the
    // REAL conversation id as effectiveConversationId. These pin that block /
    // mute / notification-id / deep-link all key off the REAL id.
    const sentinel = '00000000-0000-0000-0000-000000000000';
    const realConv = '1to1:a:b';

    test('blocked matches the RESOLVED real id for a sealed wakeup (the '
        'sentinel transport id would have leaked through)', () async {
      final notif = _FakeNotifications();
      final beacon = _FakeBeacon();
      await runFcmBackgroundHandler(
        payload: const WakeupPayload(envelopeId: 'env-1', conversationId: sentinel),
        notifications: notif,
        beacon: beacon,
        blockedConversationIds: const {realConv},
        effectiveConversationId: realConv,
      );
      // Silent both ways — the fix: a blocked sealed chat no longer wakes a
      // closed device nor sends a delivered receipt.
      expect(beacon.confirmed, isEmpty);
      expect(notif.showCalls, 0);
    });

    test('a non-blocked sealed wakeup notifies + deep-links to the RESOLVED '
        'real conversation (not the sentinel "shows nothing" thread)', () async {
      final notif = _FakeNotifications();
      await runFcmBackgroundHandler(
        payload: const WakeupPayload(envelopeId: 'env-1', conversationId: sentinel),
        notifications: notif,
        effectiveConversationId: realConv,
      );
      expect(notif.showCalls, 1);
      expect(notif.lastConvoId, realConv,
          reason: 'tap payload must target the real thread, not the sentinel');
      expect(notif.lastId, realConv.hashCode);
    });

    test('muted matches the RESOLVED real id for a sealed wakeup', () async {
      final notif = _FakeNotifications();
      final beacon = _FakeBeacon();
      await runFcmBackgroundHandler(
        payload: const WakeupPayload(envelopeId: 'env-1', conversationId: sentinel),
        notifications: notif,
        beacon: beacon,
        mutedConversationIds: const {realConv},
        effectiveConversationId: realConv,
      );
      // Muted → no alert, but delivery still confirmed (beacon fires).
      expect(notif.showCalls, 0);
      expect(beacon.confirmed, ['env-1']);
    });

    test('an incoming call from a KNOWN peer PRE-WARMS the transport (so Tor '
        'bootstrap overlaps the ring instead of being paid after accept)',
        () async {
      final notif = _FakeNotifications();
      var warmed = 0;
      await runFcmBackgroundHandler(
        payload: const WakeupPayload(
          envelopeId: 'env-1',
          conversationId: '1to1:a:b',
          pushKind: 'call',
        ),
        notifications: notif,
        callerNames: const {'1to1:a:b': 'ada'},
        warmTransport: () async => warmed++,
      );
      expect(warmed, 1);
      expect(notif.callShows, 1);
    });

    test('a call from an UNKNOWN peer rings but does NOT pre-warm the transport '
        '(a stranger cannot make a closed device spin up Tor)', () async {
      final notif = _FakeNotifications();
      var warmed = 0;
      await runFcmBackgroundHandler(
        payload: const WakeupPayload(
          envelopeId: 'env-1',
          conversationId: '1to1:stranger',
          pushKind: 'call',
        ),
        notifications: notif,
        warmTransport: () async => warmed++,
      );
      expect(warmed, 0, reason: 'unknown callers do not trigger the warm-up');
      expect(notif.callShows, 1, reason: 'the ring still shows so it can be declined');
    });

    test('a regular message wakeup does NOT pre-warm the transport', () async {
      final notif = _FakeNotifications();
      var warmed = 0;
      await runFcmBackgroundHandler(
        payload: const WakeupPayload(envelopeId: 'e', conversationId: 'c1'),
        notifications: notif,
        warmTransport: () async => warmed++,
      );
      expect(warmed, 0, reason: 'only calls pay the warm-up; messages stay cheap');
      expect(notif.showCalls, 1);
    });

    test('a blocked call neither warms the transport nor rings', () async {
      final notif = _FakeNotifications();
      var warmed = 0;
      await runFcmBackgroundHandler(
        payload: const WakeupPayload(
          envelopeId: 'e',
          conversationId: 'c1',
          pushKind: 'call',
        ),
        notifications: notif,
        blockedConversationIds: const {'c1'},
        warmTransport: () async => warmed++,
      );
      expect(warmed, 0);
      expect(notif.callShows, 0);
    });

    test('a warm-up failure (e.g. Tor channel absent) is swallowed and the call '
        'still rings', () async {
      final notif = _FakeNotifications();
      await runFcmBackgroundHandler(
        payload: const WakeupPayload(
          envelopeId: 'e',
          conversationId: '1to1:a:b',
          pushKind: 'call',
        ),
        notifications: notif,
        callerNames: const {'1to1:a:b': 'ada'},
        warmTransport: () async => throw Exception('no tor channel here'),
      );
      expect(notif.callShows, 1);
    });
  });

  group('FcmBackgroundHandler platform failures', () {
    // A single platform failure used to throw out of the handler and lose the
    // notification entirely. Each now degrades to the next best thing.
    test('still posts the banner when plugin init fails', () async {
      final notif = _FakeNotifications()..initError = Exception('init boom');

      await runFcmBackgroundHandler(
        payload: const WakeupPayload(envelopeId: 'e', conversationId: 'c1'),
        notifications: notif,
      );

      expect(notif.showCalls, 1);
    });

    test('falls back to an "Incoming call" banner when the native ring fails',
        () async {
      final notif = _FakeNotifications()
        ..showCallError = Exception('no call channel');

      await runFcmBackgroundHandler(
        payload: const WakeupPayload(
            envelopeId: 'e', conversationId: 'c1', pushKind: 'call'),
        notifications: notif,
        callerNames: const {'c1': 'ada'},
      );

      expect(notif.lastTitle, 'Incoming call');
    });

    test('the fallback call banner names the caller', () async {
      final notif = _FakeNotifications()
        ..showCallError = Exception('no call channel');

      await runFcmBackgroundHandler(
        payload: const WakeupPayload(
            envelopeId: 'e', conversationId: 'c1', pushKind: 'call'),
        notifications: notif,
        callerNames: const {'c1': 'ada'},
      );

      expect(notif.lastBody, 'ada');
    });

    test('a failed post does not stop the delivered beacon', () async {
      final notif = _FakeNotifications()..showError = Exception('post boom');
      final beacon = _FakeBeacon();

      await runFcmBackgroundHandler(
        payload: const WakeupPayload(envelopeId: 'env-9', conversationId: 'c1'),
        notifications: notif,
        beacon: beacon,
      );

      expect(beacon.confirmed, ['env-9']);
    });
  });

  group('showFallbackWakeNotification', () {
    test('posts a generic banner on the transport conversation id', () async {
      final notif = _FakeNotifications();

      await showFallbackWakeNotification(
        payload: const WakeupPayload(envelopeId: 'e', conversationId: 'c1'),
        notifications: notif,
      );

      expect(notif.lastConvoId, 'c1');
    });

    test('rings for a call', () async {
      final notif = _FakeNotifications();

      await showFallbackWakeNotification(
        payload: const WakeupPayload(
            envelopeId: 'e', conversationId: 'c1', pushKind: 'call'),
        notifications: notif,
      );

      expect(notif.callShows, 1);
    });

    test('stays silent for a control wakeup', () async {
      final notif = _FakeNotifications();

      await showFallbackWakeNotification(
        payload: const WakeupPayload(
            envelopeId: 'e', conversationId: 'c1', pushKind: 'silent'),
        notifications: notif,
      );

      expect(notif.trace, isEmpty);
    });
  });
}
