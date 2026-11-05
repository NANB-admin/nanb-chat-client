import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'call_native.dart';

/// Testable seam over `flutter_local_notifications`. The background
/// handler posts via this wrapper so unit tests can verify body content
/// without spinning up the plugin.
abstract class LocalNotifications {
  /// Initialize the plugin once per isolate. Must be called before [show].
  ///
  /// In the main isolate, [init] also surfaces any cold-start launch payload
  /// onto [conversationTaps] — callers should subscribe BEFORE awaiting
  /// init() or the launch event will be dropped (broadcast stream).
  Future<void> init();

  /// Show a notification with [title] and [body]. The notification's tap
  /// payload is set to [conversationId] so the deep-link route can open the
  /// right thread.
  Future<void> show({
    required int id,
    required String title,
    required String body,
    required String conversationId,
  });

  /// Show a high-priority **incoming-call** notification with a full-screen
  /// intent so a closed/locked device rings (lights up the screen) rather than
  /// quietly showing a banner. Tapping it deep-links to [conversationId] (the
  /// CallOverlay then shows the in-call UI once the app catches up).
  Future<void> showCall({
    required int id,
    required String caller,
    required String conversationId,
  });

  /// Cancels a previously shown notification (e.g. an incoming-call ring once
  /// the call is answered, declined, or cancelled).
  Future<void> cancel(int id);

  /// Dismisses every notification this app has delivered (message banners and
  /// any other tray entries). Called when the app is opened so a stale "New
  /// message" banner doesn't linger once the user is already in the app.
  Future<void> cancelAll();

  /// Requests the Android 14+ "full screen notifications" special access. Since
  /// API 34, a declared USE_FULL_SCREEN_INTENT is downgraded to a heads-up
  /// banner for non-calling apps unless the user grants this — so without it the
  /// incoming-call ring never lights up a locked screen. No-op pre-14 / non-
  /// Android. Returns true if granted (or already granted).
  Future<bool> requestFullScreenIntentPermission();

  /// Emits the `conversationId` of every notification the user taps —
  /// whether the tap launches the app cold or fires while already running.
  /// Broadcast so multiple subscribers can listen.
  Stream<String> get conversationTaps;
}

class LocalNotificationsImpl implements LocalNotifications {
  LocalNotificationsImpl({FlutterLocalNotificationsPlugin? plugin})
      : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;
  final StreamController<String> _tapCtl =
      StreamController<String>.broadcast();
  bool _initialized = false;

  @override
  Stream<String> get conversationTaps => _tapCtl.stream;

  @override
  Future<void> init() async {
    if (_initialized) return;
    // Status-bar small icon: a monochrome Chat mark — a chat bubble with a
    // keyhole (see res/drawable/ic_stat_nanb.xml). The app launcher icon would
    // render as a flat white blob ("circle") since Android silhouettes small icons.
    const androidInit = AndroidInitializationSettings('@drawable/ic_stat_nanb');
    // iOS: do NOT request permission here. The OS prompt is owned by
    // NotificationPermissionGate (via FirebaseMessaging.requestPermission) +
    // AppDelegate's registerForRemoteNotifications. init() also runs in the
    // background isolate, where prompting is impossible — so request*Permission
    // must stay false to avoid a duplicate/no-op request. Tap routing
    // (onDidReceiveNotificationResponse) works on iOS without any of these.
    const darwinInit = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    const initSettings =
        InitializationSettings(android: androidInit, iOS: darwinInit);
    await _plugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _handleResponse,
    );
    _initialized = true;

    // Cold-start launch path: if the app was opened *by* a notification tap,
    // surface its payload now so the app shell can navigate to the thread.
    final launch = await _plugin.getNotificationAppLaunchDetails();
    if (launch != null && launch.didNotificationLaunchApp) {
      final payload = launch.notificationResponse?.payload;
      if (payload != null && payload.isNotEmpty) {
        _tapCtl.add(payload);
      }
    }
  }

  void _handleResponse(NotificationResponse response) {
    final payload = response.payload;
    if (payload != null && payload.isNotEmpty) {
      _tapCtl.add(payload);
    }
  }

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
    required String conversationId,
  }) async {
    const androidDetails = AndroidNotificationDetails(
      'nanb-messages',
      'Messages',
      channelDescription: 'New chat messages',
      importance: Importance.high,
      priority: Priority.high,
      icon: 'ic_stat_nanb',
    );
    // iOS: present the banner with sound when the message arrives. The payload
    // carries no content (generic "New message"), so there is nothing sensitive
    // to hide from the lock screen.
    const darwinDetails = DarwinNotificationDetails();
    const details =
        NotificationDetails(android: androidDetails, iOS: darwinDetails);
    await _plugin.show(id, title, body, details, payload: conversationId);
  }

  @override
  Future<void> showCall({
    required int id,
    required String caller,
    required String conversationId,
  }) async {
    // Post the call ring NATIVELY (not via flutter_local_notifications): its
    // full-screen intent must target the native IncomingCallActivity, a
    // statically-declared showWhenLocked activity that PERSISTS over a secure
    // lock. FLN can only target the launcher activity, where the keyguard
    // reclaimed the screen after a few seconds. The native channel is registered
    // by the nanb_crypto plugin on every engine, including this background
    // isolate. See CallNative / CallNotificationChannel.
    await CallNative.showIncomingCall(
      id: id,
      conversationId: conversationId,
      caller: caller,
    );
  }

  @override
  Future<void> cancel(int id) => _safeCancel(id);

  /// Cancels a notification, swallowing the release-only failure where
  /// flutter_local_notifications' `cancel()` deserializes its
  /// scheduled-notification cache with a Gson `TypeToken` whose generic
  /// signature R8 strips (`IllegalStateException: TypeToken must be created
  /// with a type argument`). We never schedule notifications, so this is safe;
  /// the ProGuard keep rules (android/app/proguard-rules.pro) are the real fix
  /// that lets cancel actually run (needed for the full-screen ring re-fire).
  Future<void> _safeCancel(int id) async {
    try {
      await _plugin.cancel(id);
    } catch (_) {/* see above */}
  }

  @override
  Future<void> cancelAll() async {
    try {
      await _plugin.cancelAll();
    } catch (_) {/* same release-only plugin failure as _safeCancel */}
  }

  @override
  Future<bool> requestFullScreenIntentPermission() async {
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) return false;
    try {
      return await android.requestFullScreenIntentPermission() ?? false;
    } catch (_) {
      return false; // older OS / plugin without the API
    }
  }
}
