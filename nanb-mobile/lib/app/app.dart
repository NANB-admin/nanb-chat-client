import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/network/app_lifecycle_observer.dart';
import '../core/network/connectivity_reconnector.dart';
import '../core/platform/incoming_share_channel.dart';
import '../core/platform/secure_screen.dart';
import '../core/push/call_launch_payload.dart';
import '../core/push/ios_shared_store.dart';
import '../core/push/notification_tap_router.dart';
import '../features/app_lock/app_lock_gate.dart';
import '../features/calls/call_overlay.dart';
import '../features/settings/models/app_theme_mode.dart';
import 'providers.dart';
import 'router.dart';
import 'theme.dart';

class NanbApp extends ConsumerStatefulWidget {
  const NanbApp({super.key, this.initialLocation = Routes.welcome});

  /// First route the router opens on. `main()` passes [Routes.resuming] when
  /// the cached session-exists flag is set, so a returning user sees a neutral
  /// splash instead of the signed-out welcome screen while MLS init runs.
  final String initialLocation;

  @override
  ConsumerState<NanbApp> createState() => _NanbAppState();
}

class _NanbAppState extends ConsumerState<NanbApp> {
  GoRouter? _router;
  AppLifecycleObserver? _lifecycle;
  ConnectivityReconnector? _connectivity;
  NotificationTapRouter? _tapRouter;
  StreamSubscription<void>? _screenshotSub;
  // App-level messenger so a screenshot warning can surface over any route
  // (the event can fire from the thread, a media viewer, or the chat list).
  final GlobalKey<ScaffoldMessengerState> _messengerKey =
      GlobalKey<ScaffoldMessengerState>();
  static const MethodChannel _callActionChannel =
      MethodChannel('nanb.app/call_action');

  @override
  void initState() {
    super.initState();
    // Warn the user when the OS reports a screenshot in a protected chat. iOS
    // blanks the capture but can't prevent the gesture, so this is the "detect"
    // half of the secure-screen feature (Android blocks outright; never fires).
    SecureScreen.init();
    _screenshotSub = SecureScreen.screenshots.listen((_) {
      _messengerKey.currentState
        ?..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('Screenshots are restricted in this chat.'),
          ),
        );
    });
    final conversations = ref.read(conversationsProvider);
    // Resolve the supervisor / notifier / app-lock at CALL time, not captured
    // once here: a Tor SOCKS-port change rebuilds those providers, so a captured
    // instance would go stale — resume would hit a closed HTTP client (the
    // "Dio can't establish a new connection after it was closed" replenish
    // error) or drive a dead supervisor (resume-verify / reconnect no-op).
    _lifecycle = AppLifecycleObserver(
      () => ref.read(wsReconnectSupervisorProvider),
      onResumed: (stale) {
        // End any expected-excursion suppression (camera / picker / share
        // sheet): a quick hop returns unlocked; an over-long absence re-locks.
        // Runs before the gate's resume handling so its lock state is settled.
        ref.read(appLockControllerProvider).resumeFromBackground();
        final c = ref.read(conversationsProvider);
        c.appInForeground = true;
        // Foregrounding the app clears the notification tray: anything still
        // there is already visible in the chat list.
        unawaited(ref.read(localNotificationsProvider).cancelAll());
        // Wake the embedded Tor from the dormant state onPaused put it in, so
        // circuit upkeep resumes promptly on foreground. Cheap + in-place (the
        // client + SOCKS port survived the suspend); the deeper recovery of a
        // genuinely wedged Tor is still handled by the supervisor's resume-verify
        // → onResumeTransportUnconfirmed → forceRestart escalation.
        if (kBuiltInTorEnabled &&
            ref.read(appPreferencesProvider).value.builtInTorEnabled) {
          unawaited(ref.read(torControllerProvider).wakeFromBackground());
        }
        c.replenishKeyPackagesIfNeeded();
        // Collect anything another app handed us through the OS share sheet
        // while we were away. Both platforms STASH the payload natively and
        // hand it over on this pull (see IncomingShareChannel), so a warm
        // "Share via Chat" lands here — Android's onNewIntent and iOS's
        // share-extension hand-off both resume us before this runs.
        unawaited(_collectPendingShare());
        // If the initial catchup never settled (its one attempt failed and the
        // socket then stayed up), a deep-linked brand-new conversation is stuck
        // on the loader. Re-run it on foreground so the gate converges; no-op
        // once settled or while offline (it kicks a reconnect instead).
        c.catchUpIfNeeded();
        // Catch up disappearing deletions immediately on foreground, rather
        // than waiting for the next periodic tick.
        c.runDisappearingSweepNow();
        // A long background can leave the embedded Tor wedged — iOS suspends the
        // process (freezing Arti's runtime), and Android Doze kills its circuits
        // while its SOCKS listener stays bound — so the engine still reports
        // `connected` but every CONNECT through it is refused ("Reconnecting via
        // Tor…" forever). Recovery is now driven by the WS supervisor's resume
        // verification (AppLifecycleObserver → verifyConnectionOrReconnect): it
        // probes the socket and, ONLY when liveness can't be confirmed, restarts
        // Tor via the onResumeTransportUnconfirmed hook (wired in providers.dart).
        // That means a resume where the connection actually survived no longer
        // pays a needless Arti re-bootstrap — the slow part of a foregrounded
        // reopen. A foreground wedge is still caught by the supervisor's
        // repeated-failure recovery (onRepeatedFailure → forceRestart).
      },
      // Lock when backgrounded; the gate re-prompts on the next foreground.
      // No-op visually unless an app-lock preference (biometric or passcode)
      // is on. Also flip the foreground flag so inbound messages arriving over
      // the still-live socket now raise their own notification.
      onPaused: () {
        ref.read(conversationsProvider).appInForeground = false;
        ref.read(appLockControllerProvider).lock();
        // Refresh the App Group mirror so the iOS Notification Service Extension
        // has the latest identity/peer-seal keys to send a closed-app sealed
        // "delivered" receipt for a push that arrives while backgrounded.
        unawaited(IosSharedStore.sync(ref.read(secureStorageProvider)));
        // While built-in Tor is the (connected) transport, idle its network
        // before iOS suspends us — freezing an idle Tor gives the resume path a
        // chance to recover it in place instead of finding its event loop wedged
        // by the suspend clock jump.
        if (kBuiltInTorEnabled &&
            ref.read(appPreferencesProvider).value.builtInTorEnabled) {
          unawaited(ref.read(torControllerProvider).prepareForBackground());
        }
      },
    );
    WidgetsBinding.instance.addObserver(_lifecycle!);
    // Reconnect the socket on a network change (regained connectivity, or a
    // WiFi<->cellular handoff that strands the old socket). forceReconnect is a
    // no-op until the supervisor is started, so this is safe before sign-in.
    _connectivity = ConnectivityReconnector(
      networkChanges: networkSignatureStream(Connectivity()),
      onNetworkRegained: () =>
          ref.read(wsReconnectSupervisorProvider)
              .forceReconnect(source: 'network-change'),
    )..start();
    _router = buildRouter(
      conversations: conversations,
      initialLocation: widget.initialLocation,
    );
    _tapRouter = NotificationTapRouter(
      notifications: ref.read(localNotificationsProvider),
      onTap: _onNotificationLaunch,
    );
    // Cold start: once the plugin is initialised (start() does that), clear
    // anything delivered while the app was closed.
    unawaited(_tapRouter!.start().then(
        (_) => ref.read(localNotificationsProvider).cancelAll()));
    unawaited(_maybeRequestFullScreenIntent());
    _setupCallActions();
    _maybeInitMls();
    // Drive the embedded Tor engine from the built-in-Tor preference: start it
    // at launch if it was left on, start/stop on each toggle. socksProxyProvider
    // reactively reroutes the HTTP + WS clients once Tor connects (and holds
    // fail-closed via a sentinel while bootstrapping). fireImmediately handles
    // the persisted-on case after prefs hydrate.
    ref.listenManual(
      appPreferencesProvider,
      (_, next) => _syncBuiltInTor(next.value.builtInTorEnabled),
      fireImmediately: true,
    );
  }

  /// True once [_maybeInitMls] has finished choosing the boot route. Until
  /// then no OS share may be collected — see [_collectPendingShare].
  bool _bootRouted = false;

  bool _builtInTorWasOn = false;
  void _syncBuiltInTor(bool isOn) {
    // Feature-gated: while built-in Tor is off (server-side Tor not ready), never
    // start the engine even if a stale pref persisted true. See kBuiltInTorEnabled.
    if (!kBuiltInTorEnabled) return;
    if (isOn == _builtInTorWasOn) return;
    _builtInTorWasOn = isOn;
    final tor = ref.read(torControllerProvider);
    if (isOn) {
      unawaited(tor.start());
    } else {
      unawaited(tor.stop());
    }
  }

  /// Bridges the native [IncomingCallActivity] (the over-lock ring) Accept/Decline
  /// buttons to the [CallController]. On a cold start we PULL any action captured
  /// before the engine was ready (`getPending`); while warm, MainActivity PUSHES
  /// it (`onCallAction`). Either way: ring the placeholder for the conversation,
  /// then accept or decline (which the awaiting-invite flow reconciles once the
  /// real E2EE invite catches up over the websocket).
  void _setupCallActions() {
    _callActionChannel.setMethodCallHandler((call) async {
      if (call.method == 'onCallAction') _processCallAction(call.arguments);
      return null;
    });
    unawaited(_callActionChannel
        .invokeMethod<dynamic>('getPending')
        .then((pending) {
      if (pending != null) _processCallAction(pending);
    }).catchError((_) {/* not Android / no pending */}));
  }

  void _processCallAction(dynamic args) {
    if (args is! Map) return;
    final action = args['action'] as String?;
    final conv = args['conversationId'] as String?;
    if (conv == null || conv.isEmpty) return;
    // ignore: avoid_print
    print('NANBCALL call_action=$action conv=$conv');
    final controller = ref.read(callControllerProvider);
    controller.ringFromPush(conversationId: conv, callerName: 'Unknown');
    if (action == 'accept') {
      unawaited(controller.accept());
    } else if (action == 'decline') {
      unawaited(controller.decline());
    }
  }

  /// Handles a notification launch/tap. A call notification's payload decodes
  /// to a [CallLaunchPayload] → ring IMMEDIATELY from it (the woken app then
  /// reconnects + catches up the real E2EE invite in the background, which
  /// reconciles the ring and lets the user answer). Any other payload is a bare
  /// conversation id → deep-link to that thread.
  void _onNotificationLaunch(String payload) {
    final call = CallLaunchPayload.decode(payload);
    // ignore: avoid_print
    print('NANBCALL launch isCall=${call != null} '
        'conv=${call?.conversationId ?? payload}');
    if (call != null) {
      ref.read(callControllerProvider).ringFromPush(
            conversationId: call.conversationId,
            callerName: call.caller,
          );
      return;
    }
    _router?.go('/chat/$payload');
  }

  /// Pulls a pending OS share ("Share via Chat" from YouTube / Photos / a
  /// browser) and opens the share-target picker on it.
  ///
  /// Called on cold start (after the session is resolved) and on every
  /// foreground. Consuming is atomic native-side, so a share opens the picker
  /// exactly once even though this runs on every resume.
  ///
  /// Signed-out is a DROP, not a defer: the payload is already consumed, and
  /// parking another app's photo in memory (or on disk natively) waiting for a
  /// sign-in that may never come is worse than making the user share again.
  Future<void> _collectPendingShare() async {
    // Boot routing hasn't settled yet. Return WITHOUT collecting, so the share
    // stays stashed natively for the post-init call at the end of
    // [_maybeInitMls]: on a cold start the first foreground fires this before
    // MLS init finishes, and that init ends in `go(chatList)`, which REPLACES
    // the stack — the share screen would be pushed and then silently wiped.
    if (!_bootRouted) return;
    final share = await const IncomingShareChannel().takePending();
    if (share == null || !mounted) return;
    final conversations = ref.read(conversationsProvider);
    if (conversations.manuallySignedOut) return;
    // `go`, not `push`: the router is refreshed by every notifier
    // notification, and a cold start FROM a share fires a burst of them
    // (connect, catch-up) that discards an imperatively pushed route — the
    // share screen never appeared and the payload was lost. A location change
    // is last-writer-wins and survives those refreshes; the picker's own close
    // action returns to the chat list.
    ref.read(pendingShareProvider.notifier).state = share;
    _router?.go(Routes.shareTarget);
  }

  /// Android 14+ downgrades the full-screen incoming-call ring to a heads-up
  /// banner unless the user grants "full screen notifications". Ask once per
  /// device (the OS remembers the answer; re-enabling is via system settings).
  Future<void> _maybeRequestFullScreenIntent() async {
    const flagKey = 'push.fsi_requested';
    try {
      final storage = ref.read(secureStorageProvider);
      if (await storage.getString(flagKey) == 'true') return;
      final notifications = ref.read(localNotificationsProvider);
      await notifications.init();
      await notifications.requestFullScreenIntentPermission();
      await storage.putString(flagKey, 'true');
    } catch (_) {/* best-effort; the ring still works once granted in Settings */}
  }

  /// If a session was persisted from a previous run, open the CoreCrypto
  /// store now so the first chat-screen entry doesn't trip over an
  /// un-initted MLS store, then resume the user straight to the chat list.
  Future<void> _maybeInitMls() async {
    final sessions = ref.read(sessionRepositoryProvider);
    final session = await sessions.current();
    if (session == null) {
      // No session — either a fresh install (already on /welcome) or a stale
      // session-exists flag from an interrupted wipe that started us on the
      // /resuming splash. Either way, land on welcome rather than a chat list
      // we can't populate.
      _bootRouted = true;
      if (mounted) _router?.go(Routes.welcome);
      return;
    }
    // A session exists. If the user manually signed out (non-destructive —
    // their data is still on disk), raise the in-memory gate and land on
    // /welcome, where they resume in one tap. Don't auto-reconnect or open the
    // chat list: "signed out" must survive a cold restart until they sign in.
    final conversations = ref.read(conversationsProvider);
    await conversations.loadSignedOutGate();
    if (conversations.manuallySignedOut) {
      _bootRouted = true;
      if (mounted) _router?.go(Routes.welcome);
      return;
    }
    // Back-fill the fast-resume flag for sessions persisted before it existed,
    // so the next cold start opens on the splash instead of welcome.
    unawaited(sessions.markExists());
    final crypto = ref.read(cryptoBridgeProvider);
    // Open the CoreCrypto store BEFORE navigating to the chat list, so the
    // first chat-screen entry doesn't trip over an un-initted MLS store.
    // Best-effort: broken MLS must not strand a signed-in user — ratchet
    // messaging works without it.
    try {
      await crypto.mlsInit();
      await crypto.mlsEnsureClient(session.deviceId);
    } catch (e) {
      // ignore: avoid_print
      print('boot MLS init failed: $e — continuing without MLS');
    }
    // A persisted session means the user is still signed in on this device.
    // Resume them to the chat list; ChatListScreen.connect() brings the
    // WebSocket back online. (Without this jump a returning user would sit on
    // the welcome screen / resuming splash forever.)
    _bootRouted = true;
    if (mounted) _router?.go(Routes.chatList);
    // Cold start FROM a share (the user tapped "Chat" in another app's share
    // sheet with our process dead). Deferred by a frame, NOT just sequenced
    // after the `go` above: `go` REPLACES the route stack, and a `push` issued
    // before that replacement is applied is silently discarded — measured on a
    // Pixel 10, where the share was consumed natively but the picker never
    // appeared, losing the share. One frame later the chat list is mounted and
    // the push survives.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => unawaited(_collectPendingShare()),
    );
  }

  @override
  void dispose() {
    if (_lifecycle != null) {
      WidgetsBinding.instance.removeObserver(_lifecycle!);
    }
    unawaited(_connectivity?.dispose() ?? Future.value());
    unawaited(_tapRouter?.dispose() ?? Future.value());
    unawaited(_screenshotSub?.cancel() ?? Future.value());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(appPreferencesProvider);
    return MaterialApp.router(
      title: 'Chat',
      scaffoldMessengerKey: _messengerKey,
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      themeMode: _resolveMode(prefs.value.themeMode),
      routerConfig: _router!,
      debugShowCheckedModeBanner: false,
      // Wrap every route in the biometric lock gate. The gate is inert unless
      // the user enabled app lock; when active it overlays a lock screen above
      // all content until the device authenticates.
      //
      // The text-size preference is applied here via a MediaQuery.textScaler
      // override so every font size (including hardcoded fontSize: values and
      // the mono styles) scales uniformly. A fixed in-app scaler (independent
      // of the OS font setting) keeps Small/Medium/Large predictable.
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(prefs.value.textSize.scale),
        ),
        // App-wide call UI sits below the lock gate (a locked device stays
        // locked) but above all routed content, so an incoming/active call
        // appears over whatever the user is doing.
        child: AppLockGate(
          child: CallOverlay(child: child ?? const SizedBox.shrink()),
        ),
      ),
    );
  }

  ThemeMode _resolveMode(AppThemeMode mode) {
    switch (mode) {
      case AppThemeMode.system:
        return ThemeMode.system;
      case AppThemeMode.light:
        return ThemeMode.light;
      case AppThemeMode.dark:
        return ThemeMode.dark;
    }
  }
}
