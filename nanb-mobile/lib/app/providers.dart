import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart' as ph;

import '../core/auth/app_lock_controller.dart';
import '../core/auth/app_lock_service.dart';
import '../core/auth/passcode_service.dart';
import '../core/crypto/crypto_bridge.dart';
import '../core/crypto/crypto_bridge_composite.dart';
import '../core/crypto/crypto_bridge_dart.dart';
import '../core/crypto/mls_bridge_factory.dart';
import '../core/crypto/sealed_envelope.dart';
import '../core/crypto/sealed_inner.dart';
import '../core/db/app_database.dart';
import '../core/db/app_database_factory.dart';
import '../core/models/incoming_share.dart';
import '../core/network/api_client.dart';
import '../core/network/api_client_dio.dart';
import '../core/network/socks_proxy.dart';
import '../core/network/tor/tor_controller.dart';
import '../core/network/tor/tor_engine_channel.dart';
import '../core/network/ws_client.dart';
import '../core/platform/secure_screen.dart';
import '../core/network/ws_client_impl.dart';
import '../core/push/call_native.dart';
import '../core/push/fcm_activator.dart';
import '../core/push/firebase_messaging_facade.dart';
import '../core/push/local_notifications.dart';
import '../core/push/notification_permission_gate.dart';
import '../core/push/overlay_permission_gate.dart';
import '../core/push/overlay_permission_seam_not_applicable.dart';
import '../core/push/push_token_provider.dart';
import '../core/push/push_token_provider_fcm.dart';
import '../core/push/push_token_registrar.dart';
import '../core/push/voip_push_channel.dart';
import '../core/push/voip_push_token_provider.dart';
import '../core/secure_storage/secure_storage.dart';
import '../core/secure_storage/secure_storage_factory.dart';
import '../core/network/ws_reconnect_supervisor.dart';
import '../features/calls/call_controller.dart';
import '../features/calls/call_id.dart';
import '../features/calls/caller_name_resolver.dart';
import '../features/calls/callkit_bridge.dart';
import '../features/calls/models/call_session.dart';
import '../features/calls/models/call_signal.dart';
import '../features/calls/notifier_call_transport.dart';
import '../features/calls/turn_credentials_cache.dart';
import '../features/calls/turn_credentials_invalidation.dart';
import '../features/calls/turn_credentials_loader.dart';
import '../features/calls/webrtc_call_media_engine.dart';
import '../features/chat/conversations_notifier.dart';
import '../features/chat/avatar_loader.dart';
import '../features/chat/media_pipeline.dart';
import '../features/chat/pending_upload_staging.dart';
import '../features/chat/services/temp_media_store.dart';
import '../features/chat/video/video_thumbnail_generator.dart';
import '../features/chat/video/video_thumbnail_loader.dart';
import '../features/onboarding/device_link_notifier.dart';
import '../features/onboarding/login_notifier.dart';
import '../features/onboarding/recovery_phrase_storage.dart';
import '../features/onboarding/restore_notifier.dart';
import '../features/onboarding/session_repository.dart';
import '../features/settings/app_preferences_notifier.dart';
import '../features/settings/app_preferences_repository.dart';
import '../features/settings/push_enable_service.dart';
import '../features/settings/models/app_preferences.dart';
import '../core/link/dio_link_page_loader.dart';
import '../features/chat/services/link_preview_fetcher.dart';
import '../features/chat/services/link_preview_route.dart';
import '../features/chat/services/link_thumbnail.dart';

/// Feature flag — in-app Tor routing (the SOCKS proxy + onion-endpoint options
/// in Network settings) is DISABLED until it's properly implemented. It doesn't
/// work with Orbot's modern VPN mode (Orbot's SOCKS port rejects every CONNECT
/// there with a server error), so shipping the toggle is a footgun: a user who
/// enables it while Orbot is VPN-routing gets stuck reconnecting. When false,
/// the Network screen hides those sections and the providers below ignore any
/// persisted socks/onion prefs — so nobody can land on the broken path. Tor
/// still works the supported way: Orbot in VPN mode transparently routing the
/// app's clearnet traffic (verified — the server sees Tor exit IPs). Re-enable
/// by flipping this to true once the in-app SOCKS/embedded-Tor story is solid.
/// (Intentionally `final`, not `const`, so the gated UI isn't flagged as dead
/// code while the feature is off.)
final bool kInAppTorRoutingEnabled = false;

/// Feature flag — **built-in (embedded) Tor** (the in-app C-tor engine + the
/// "Route over Tor (built-in)" toggle). ON: the full path is on-device-verified
/// end-to-end — the engine bootstraps to 100%, all traffic (REST + the live WS)
/// routes through its SOCKS port to the server `.onion`, fail-closed holds while
/// bootstrapping, and toggling switches transport cleanly. The chat list reaches
/// `CONNECTED · E2EE` over the onion. (Getting here needed: the server onion made
/// durable across restarts — moved tor onto the compose bridge — and the WS
/// port-0 bug fixed in `WsClientImpl` so the onion WS dials `:80`, not `:0`.)
/// Gates the Network-screen toggle AND the routing branches below.
/// (Intentionally `final`, not `const`, to match the codebase pattern.)
// OFF on web: a browser cannot run Tor (no SOCKS, no embedded engine), so web
// never routes over Tor and hides every Tor setting.
final bool kBuiltInTorEnabled = !kIsWeb;

/// Feature flag — **sealed sender** SEND side (docs/sealed-sender-design.md,
/// Phase 1). ON: outgoing envelopes are wrapped in a per-recipient sealed layer,
/// so the server stores the zero-UUID sentinel for conversation/sender (verified
/// end-to-end on-device, Pixel<->Nokia over Tor, + confirmed in the DB). The
/// server can no longer see who messages whom at rest.
/// Caveats: a recipient on a build WITHOUT the receive path can't open a sealed
/// message (the receive path shipped earlier, so the fleet has it). Multi-device
/// coverage is now FULL: group members, all 1:1 peer devices, and this account's
/// own self-sync devices all seal — the per-recipient X25519 is resolved from
/// the group roster or the peer/own device caches (warmed via the account lookup
/// that already returns each device's key). Receiving works regardless of this flag.
/// (`final`, not `const`, so the gated send path isn't dead-code-flagged.)
final bool kSealedSenderEnabled = true;

/// Sealed-sender Phase 2 (unidentified access): when on, a sealed envelope to a
/// recipient whose UAK we hold is deposited on the UNAUTHENTICATED `/messages/
/// sealed` path, so even an actively-logging server never sees the sender (it
/// falls back to the authenticated send on any failure). The client also
/// publishes its UAK commitment on connect and shares its UAK with contacts over
/// E2EE. ON as of 2026-06-17 (verified on-device, like Phase 1). Robust by
/// design: any unauth-send failure falls back to the authenticated send, so
/// delivery never depends on this. Honest residual: the always-on authenticated
/// RECEIVE socket leaves timing correlation intact — this removes the
/// JWT-at-submit signal, not all metadata.
/// (`final`, not `const`, so the gated path isn't dead-code-flagged.)
// OFF on web: a linked web device derives a different UAK, and reporting its
// commitment would overwrite the account's single commitment and break the
// phone's contacts' unauthenticated sends. Receiving works regardless.
final bool kUnidentifiedAccessEnabled = !kIsWeb;

/// Embedded-Tor engine controller (docs/embedded-tor-design.md, M1/M2). Owns
/// the in-app Tor lifecycle + status; `socksProxyProvider` reads its SOCKS port
/// once connected so all traffic routes through it. A `ChangeNotifier`, so
/// watchers (the SOCKS provider, the Network screen) rebuild on status changes.
/// Lazy — only built when first watched/read.
final torControllerProvider = ChangeNotifierProvider<TorController>((ref) {
  // ChangeNotifierProvider already disposes the notifier it manages on
  // teardown — a second explicit ref.onDispose(controller.dispose) double-
  // disposes it ("used after being disposed").
  return TorController(TorEngineChannel());
});

/// Fail-closed sentinel (design §8): a loopback port nothing listens on. While
/// built-in Tor is selected but not yet connected, routing through this makes
/// connections *fail* (held) instead of silently leaking to clearnet. Replaced
/// by the real embedded SOCKS port the moment Tor connects.
const _torBootstrapSentinel = SocksProxyConfig(host: '127.0.0.1', port: 1);

/// The production server's Tor v3 onion endpoint. Plain `http` — an onion
/// service carries its own end-to-end encryption (the .onion address *is* the
/// key) and reaches the server with **no exit node**: the connection stays
/// inside Tor end-to-end, so no exit relay ever sees that you're talking to
/// nanb. It also bypasses CloudFront, forwarding straight to the server's Tor
/// listener. Mirrors `serverUrl` defaulting to `https://nanb.link`. Resource
/// ID: `nanb-server/deploy/aws-architecture.md`.
const _defaultServerOnionUrl =
    'http://dxztqbcjz7kokooueboxk7ue4222as5qnmgkwmgei632hgfmbq2qrlid.onion';

/// Server base URL. Reads from `appPreferencesProvider`:
///   - **built-in Tor on** → the server `.onion` (configured, else the default).
///     The onion is the stronger path: no exit node, end-to-end inside Tor, so
///     no exit relay sees the destination. (Clearnet-over-a-Tor-exit to
///     nanb.link also works — verified 2026-06-16, CloudFront does NOT block
///     Tor exits, contrary to an earlier assumption — but it reveals the
///     destination to the exit relay, so we always prefer the onion.)
///   - legacy Tor + "prefer onion" + an onion URL set → that onion.
///   - else → the clearnet `serverUrl`.
/// Override in tests by overriding this provider.
final apiBaseUrlProvider = Provider<String>((ref) {
  final prefs = ref.watch(appPreferencesProvider).value;
  if (kBuiltInTorEnabled && prefs.builtInTorEnabled) {
    return prefs.torOnionUrl.isNotEmpty
        ? prefs.torOnionUrl
        : _defaultServerOnionUrl;
  }
  if (kInAppTorRoutingEnabled && prefs.useTor && prefs.torOnionUrl.isNotEmpty) {
    return prefs.torOnionUrl;
  }
  return prefs.serverUrl;
});

/// SOCKS5 proxy the HTTP + WS clients tunnel through, or null for a direct
/// connection. Resolution order:
///   1. **Built-in Tor** (preferred): when on, ALWAYS return a SOCKS config —
///      the real embedded port once `torControllerProvider` is connected, else
///      the fail-closed [_torBootstrapSentinel] (never clearnet while
///      bootstrapping). Watching the controller rebuilds the clients the moment
///      Tor connects, so the live socket reconnects through Tor automatically.
///   2. **Legacy manual SOCKS** (Orbot proxy mode), gated behind the feature
///      flag — superseded by built-in Tor.
/// Override in tests.
final socksProxyProvider = Provider<SocksProxyConfig?>((ref) {
  final notifier = ref.watch(appPreferencesProvider);
  final prefs = notifier.value;
  if (kBuiltInTorEnabled) {
    // Until prefs hydrate we don't yet know whether Tor is the selected
    // transport. HOLD (fail-closed sentinel) instead of connecting clearnet, so
    // a Tor user makes ONE connection — over Tor — rather than connecting
    // clearnet first and visibly reconnecting once prefs load (the "double
    // connect"). load() always completes (even on error → defaults), so this
    // hold is brief and can't strand the connection.
    if (!notifier.hydrated) return _torBootstrapSentinel;
    if (prefs.builtInTorEnabled) {
      final tor = ref.watch(torControllerProvider);
      final port = tor.socksPort;
      if (tor.isConnected && port != null) {
        return SocksProxyConfig(host: '127.0.0.1', port: port);
      }
      return _torBootstrapSentinel;
    }
  }
  if (!kInAppTorRoutingEnabled) return null;
  if (!prefs.socksProxyEnabled) return null;
  return SocksProxyConfig(
    host: prefs.socksProxyHost,
    port: prefs.socksProxyPort,
  );
});

/// Production-wired ApiClient. Tests override this with a fake.
final apiClientProvider = Provider<ApiClient>((ref) {
  final client = ApiClientDio(
    baseUrl: ref.watch(apiBaseUrlProvider),
    socksProxy: ref.watch(socksProxyProvider),
  );
  // Invalidating this provider (e.g. on a Network-settings Save) builds a new
  // client; close the old Dio + its HttpClient pool so it isn't leaked.
  ref.onDispose(client.close);
  return client;
});

final wsClientProvider = Provider<WsClient>((ref) {
  return WsClientImpl(
    baseUrl: ref.watch(apiBaseUrlProvider).replaceFirst('http', 'ws'),
    socksProxy: ref.watch(socksProxyProvider),
  );
});

final secureStorageProvider = Provider<SecureStorage>(
  (_) => createSecureStorage(),
);

/// Content handed to us by the OS share sheet, held here between being
/// collected from the platform and being sent into the chat the user picks.
///
/// Deliberately NOT passed as a go_router `extra`: the router is refreshed by
/// every `ConversationsNotifier` notification, and a cold start FROM a share
/// fires a burst of them (Tor connect, catch-up), which drops an imperatively
/// pushed route and can lose `extra` with it. Measured on a Pixel 10: the share
/// was consumed natively and then silently vanished. Holding it in a provider
/// makes the share-target route rebuildable from state, so a refresh is
/// harmless.
final pendingShareProvider = StateProvider<IncomingShare?>((_) => null);

/// Device biometric/credential authentication seam. Tests override this.
final appLockServiceProvider = Provider<AppLockService>(
  (_) => AppLockServiceLocalAuth(),
);

/// In-app numeric passcode (set/verify/clear), hashed in SecureStorage.
final passcodeServiceProvider = Provider<PasscodeService>(
  (ref) => PasscodeService(ref.watch(secureStorageProvider)),
);

/// SecureStorage key for the user's own display name (locally cached so the
/// settings identity card doesn't hit the network on every render).
const myDisplayNameKey = 'profile.display_name';

/// The user's own display name, or null when unset. The edit-profile screen
/// writes the key then invalidates this. Watched by the settings identity card.
final myDisplayNameProvider = FutureProvider.autoDispose<String?>((ref) async {
  final v = await ref.watch(secureStorageProvider).getString(myDisplayNameKey);
  return (v != null && v.trim().isNotEmpty) ? v : null;
});

/// SecureStorage key for the user's own avatar descriptor JSON (encrypted
/// media). Cached locally so the settings card renders without a lookup.
const myAvatarKey = 'profile.avatar_descriptor';

/// The user's own avatar descriptor, or null when unset.
final myAvatarProvider = FutureProvider.autoDispose<MediaDescriptor?>((ref) async {
  final v = await ref.watch(secureStorageProvider).getString(myAvatarKey);
  if (v == null || !MediaDescriptor.looksLikeDescriptor(v)) return null;
  try {
    return MediaDescriptor.fromJson(v);
  } catch (_) {
    return null;
  }
});

/// Downloads + decrypts + caches profile avatars (reuses the media pipeline).
final avatarLoaderProvider = Provider<AvatarLoader>((ref) {
  return AvatarLoader(ref.watch(mediaPipelineProvider));
});

/// Holds the current lock state. The [AppLockGate] shows the lock screen when
/// this is locked AND the `biometricUnlock` preference is on.
final appLockControllerProvider = ChangeNotifierProvider<AppLockController>(
  (_) => AppLockController(),
);

final appDatabaseProvider = Provider<AppDatabase>((_) => createAppDatabase());

/// CryptoBridge — composite of the pure-Dart identity + legacy-ratchet layer
/// (Ed25519/X25519, Plan 6a/13.1) and the native CoreCrypto MLS layer
/// (real on Android since Plan B; iOS shim still stubbed — see
/// `CryptoBridgeNative`).
final cryptoBridgeProvider = Provider<CryptoBridge>((ref) {
  final storage = ref.watch(secureStorageProvider);
  final identity = CryptoBridgeDart(storage: storage);
  final mls = createMlsBridge();
  return CryptoBridgeComposite(identity: identity, mls: mls);
});

/// Production-wired push-token provider. Falls back to Stub when Firebase
/// init failed at app boot (placeholder google-services.json, no Play
/// Services, or no network). Stub returns null tokens so the registrar
/// silently no-ops in that case.
final pushTokenProviderProvider = Provider<PushTokenProvider>((ref) {
  // Respect the FCM privacy pref: when push is off, never touch FCM — return a
  // stub that yields no token so the registrar no-ops. (main() also skips
  // Firebase init entirely in that case, so the device never contacts Google.)
  if (!ref.watch(appPreferencesProvider).value.pushOverFcmEnabled) {
    return PushTokenProviderStub();
  }
  try {
    return PushTokenProviderFcm(facade: FirebaseMessagingFacadeImpl());
  } catch (_) {
    return PushTokenProviderStub();
  }
});

/// Direct handle to FCM auto-init / token controls, for the privacy toggle to
/// enable on / sever Google on, without a restart. Calls are try-caught (no-op
/// when Firebase isn't initialized, i.e. push was off this session).
final firebaseMessagingFacadeProvider =
    Provider<FirebaseMessagingFacade>((_) => FirebaseMessagingFacadeImpl());

/// Turns notifications on from Settings, and reports why they're off.
///
/// The enable sequence used to live only in the one-time install-time prompt,
/// which never reappears — so there was no route back for a user who tapped
/// "Not now" or who granted the OS permission but left the in-app push pref off.
final pushEnableServiceProvider = Provider<PushEnableService>((ref) {
  final prefs = ref.watch(appPreferencesProvider);
  final messaging = ref.watch(firebaseMessagingFacadeProvider);
  return PushEnableService(
    setAppNotificationsEnabled: prefs.setNotificationsEnabled,
    setPushOverFcmEnabled: prefs.setPushOverFcmEnabled,
    activateFcm: fcmRuntimeActivator,
    requestPermission: messaging.requestPermission,
    readPermission: messaging.permissionStatus,
    registerToken: ref.watch(pushTokenRegistrarProvider).bootstrap,
    openSystemSettings: ph.openAppSettings,
  );
});

/// Coordinates push-token registration with the server. Bootstrapped from
/// [conversationsProvider.connect] after login so the JWT is in place.
final pushTokenRegistrarProvider = Provider<PushTokenRegistrar>((ref) {
  return PushTokenRegistrar(
    api: ref.watch(apiClientProvider),
    provider: ref.watch(pushTokenProviderProvider),
  );
});

/// iOS PushKit + CallKit channel. A no-op off iOS (every call swallows
/// MissingPluginException), so it is safe to construct unconditionally.
final voipPushChannelProvider = Provider<VoipPushChannel>((ref) {
  final channel = VoipPushChannel();
  ref.onDispose(() => unawaited(channel.dispose()));
  return channel;
});

/// Registers the PushKit token with the server under its own platform, so a
/// call can ring an iPhone whose screen is locked (or that isn't running).
/// Separate from [pushTokenRegistrarProvider] because a device holds BOTH
/// tokens — an FCM alert token for messages and this one for the ring.
final voipPushTokenRegistrarProvider = Provider<PushTokenRegistrar>((ref) {
  return PushTokenRegistrar(
    api: ref.watch(apiClientProvider),
    provider: VoipPushTokenProvider(channel: ref.watch(voipPushChannelProvider)),
  );
});

/// Local-notifications plugin wrapper for the main isolate. The background
/// isolate (`main.dart`) constructs its own instance directly. This provider
/// is the one the UI subscribes to for tap routing.
final localNotificationsProvider = Provider<LocalNotifications>((_) {
  return LocalNotificationsImpl();
});

/// Surfaces the OS notification-permission prompt on first sign-in. Falls
/// back to a stub seam when Firebase init failed at boot (placeholder
/// google-services.json, no Play Services), so the prompt is a silent
/// no-op in dev/CI environments.
final notificationPermissionGateProvider = Provider<NotificationPermissionGate>(
  (ref) {
    NotificationPermissionSeam seam;
    if (!ref.watch(appPreferencesProvider).value.pushOverFcmEnabled) {
      // Push disabled → don't prompt for / touch FCM permissions at all.
      seam = NotificationPermissionSeamStub();
    } else {
      try {
        seam = NotificationPermissionSeamFcm(FirebaseMessagingFacadeImpl());
      } catch (_) {
        seam = NotificationPermissionSeamStub();
      }
    }
    return NotificationPermissionGate(
      seam: seam,
      storage: ref.watch(secureStorageProvider),
    );
  },
);

/// Gates the one-time "allow display over other apps" rationale for incoming
/// calls. The permission lets the native incoming-call ring launch full-screen
/// while the device is unlocked + the app is backgrounded (otherwise Android
/// shows only a heads-up banner). See [OverlayPermissionGate].
final overlayPermissionGateProvider = Provider<OverlayPermissionGate>((ref) {
  return OverlayPermissionGate(
    // A browser has no "display over other apps" permission to ask for.
    seam: kIsWeb
        ? OverlayPermissionSeamNotApplicable()
        : OverlayPermissionSeamPermissionHandler(),
    storage: ref.watch(secureStorageProvider),
  );
});

final sessionRepositoryProvider = Provider<SessionRepository>((ref) {
  return SessionRepository(ref.watch(secureStorageProvider));
});

final loginNotifierProvider = Provider<LoginNotifier>((ref) {
  return LoginNotifier(
    apiClient: ref.watch(apiClientProvider),
    crypto: ref.watch(cryptoBridgeProvider),
    sessions: ref.watch(sessionRepositoryProvider),
  );
});

final wsReconnectSupervisorProvider = Provider<WsReconnectSupervisor>((ref) {
  final sessions = ref.watch(sessionRepositoryProvider);
  final login = ref.watch(loginNotifierProvider);
  final supervisor = WsReconnectSupervisor(
    wsClient: ref.watch(wsClientProvider),
    sessionLoader: () => sessions.current(),
    refreshSession: () => login.refreshSession(),
    // Belt-and-suspenders transport recovery: when the socket can't connect
    // for several tries AND built-in Tor still claims `connected`, its SOCKS
    // listener is up but its circuits are dead (a post-doze wedge a re-poll
    // can't heal). Force a full Arti restart; the fresh SOCKS port reroutes the
    // clients (socksProxyProvider → client rebuild) and the socket reconnects —
    // the same path a cold start uses. Skipped while Tor is still bootstrapping
    // (those failures are expected) or when Tor isn't the transport.
    onRepeatedFailure: () async {
      if (!kBuiltInTorEnabled) return;
      if (!ref.read(appPreferencesProvider).value.builtInTorEnabled) return;
      final tor = ref.read(torControllerProvider);
      if (!tor.isConnected) return;
      await tor.forceRestart();
    },
    // App-resume recovery: fired only when the resume liveness probe could NOT
    // confirm the socket (no pong / mid-reconnect). The likeliest cause after a
    // long iOS suspend is a wedged embedded Tor — its SOCKS port survives but
    // its circuits died — so restart it; a fresh bootstrap re-routes the HTTP/WS
    // clients. A resume where the socket is still alive never reaches here, so
    // we no longer re-bootstrap Tor on every foreground (the old behaviour).
    onResumeTransportUnconfirmed: () async {
      if (!kBuiltInTorEnabled) return;
      if (!ref.read(appPreferencesProvider).value.builtInTorEnabled) return;
      await ref.read(torControllerProvider).reconnectAfterResume();
    },
  );
  ref.onDispose(supervisor.dispose);
  return supervisor;
});

final recoveryPhraseStorageProvider = Provider<RecoveryPhraseStorage>((ref) {
  return RecoveryPhraseStorage(ref.watch(secureStorageProvider));
});

final restoreNotifierProvider = Provider<RestoreNotifier>((ref) {
  return RestoreNotifier(
    apiClient: ref.watch(apiClientProvider),
    crypto: ref.watch(cryptoBridgeProvider),
    sessions: ref.watch(sessionRepositoryProvider),
    phraseStorage: ref.watch(recoveryPhraseStorageProvider),
  );
});

final deviceLinkNotifierProvider = Provider<DeviceLinkNotifier>((ref) {
  return DeviceLinkNotifier(
    apiClient: ref.watch(apiClientProvider),
    crypto: ref.watch(cryptoBridgeProvider),
    sessions: ref.watch(sessionRepositoryProvider),
  );
});

/// Prefs snapshot read by `main()` BEFORE `runApp` and handed to the provider so
/// it hydrates synchronously on first build — the transport (Tor vs clearnet) is
/// known before the first connection, so a Tor user connects ONCE over Tor
/// instead of connecting clearnet, loading prefs, then reconnecting. Null when
/// the preload failed → the provider falls back to its async [load].
AppPreferences? bootstrapAppPreferences;

/// FLAG_SECURE should be on when the user asked to block screenshots OR when
/// the in-app passcode lock is armed — so the app-switcher / recents snapshot
/// never exposes chat content on a passcode-protected phone. (The Android
/// native side also re-applies this on resume as a fallback.)
bool _wantSecure(AppPreferences p) => p.blockScreenshots || p.passcodeEnabled;

final appPreferencesProvider = ChangeNotifierProvider<AppPreferencesNotifier>((
  ref,
) {
  final notifier = AppPreferencesNotifier(
    AppPreferencesRepository(ref.watch(secureStorageProvider)),
  );
  final preloaded = bootstrapAppPreferences;
  if (preloaded != null) {
    // Synchronously hydrated from main()'s pre-runApp read → no async race, so
    // the SOCKS/onion routing picks the right transport on the first build.
    notifier.hydrateFrom(preloaded);
    SecureScreen.setGlobal(_wantSecure(preloaded));
  } else {
    // Fallback (preload failed): async load. Apply block-screenshots as soon as
    // it lands so FLAG_SECURE is armed from boot (not just on toggle).
    notifier.load().then(
          (_) => SecureScreen.setGlobal(_wantSecure(notifier.value)),
        );
  }
  return notifier;
});

/// Holds the in-memory conversation list + per-conversation message lists.
/// Subscribes to the WebSocket envelope stream once `connect()` is called
/// (chat list does this in `initState`).
final mediaPipelineProvider = Provider<MediaPipeline>((ref) {
  return MediaPipeline(
    ref.watch(apiClientProvider),
    // S3 ciphertext expires on the user's retention schedule, not just the
    // server's 30-day ceiling — read at upload time so pref changes apply
    // to subsequent uploads without a rebuild.
    ttlProvider: () =>
        ref.read(appPreferencesProvider).value.disappearingDefault.ttl,
  );
});

/// Production-wired video thumbnail loader. Uses the `video_thumbnail`
/// package to extract a 480px first-frame JPEG. Tests override this with
/// a fake generator so they don't need the native plugin.
final videoThumbnailLoaderProvider = Provider<VideoThumbnailLoader>((_) {
  return VideoThumbnailLoader(generator: PackageVideoThumbnailGenerator());
});

/// Disk staging for restart-resilient outbound media uploads. AES-256-GCM
/// encrypts plaintext into `{appDocs}/pending-uploads/` so a process crash
/// mid-upload doesn't force the user to re-pick — the boot recovery sweep
/// decrypts and resumes from there.
final pendingUploadStagingProvider = Provider<PendingUploadStaging>((_) {
  return PendingUploadStagingImpl();
});

/// Owns the decrypted-media temp files the OS/decoders require on disk (viewed
/// videos, opened attachments), so they're reclaimed on message delete/expiry
/// and on sign-out rather than lingering as plaintext in the temp dir.
final tempMediaStoreProvider = Provider<TempMediaStore>((_) {
  return TempMediaStoreImpl();
});

final conversationsProvider = ChangeNotifierProvider<ConversationsNotifier>((
  ref,
) {
  final notifier = ConversationsNotifier(
    apiClient: ref.watch(apiClientProvider),
    wsClient: ref.watch(wsClientProvider),
    supervisor: ref.watch(wsReconnectSupervisorProvider),
    crypto: ref.watch(cryptoBridgeProvider),
    sessions: ref.watch(sessionRepositoryProvider),
    database: ref.watch(appDatabaseProvider),
    secureStorage: ref.watch(secureStorageProvider),
    media: ref.watch(mediaPipelineProvider),
    pushRegistrar: ref.watch(pushTokenRegistrarProvider),
    voipPushRegistrar: ref.watch(voipPushTokenRegistrarProvider),
    notificationPermissionGate: ref.watch(notificationPermissionGateProvider),
    videoThumbnailLoader: ref.watch(videoThumbnailLoaderProvider),
    pendingUploadStaging: ref.watch(pendingUploadStagingProvider),
    tempMediaStore: ref.watch(tempMediaStoreProvider),
    // Content envelopes expire server-side on the user's retention
    // schedule — read at send time so pref changes apply immediately.
    ttlProvider: () =>
        ref.read(appPreferencesProvider).value.disappearingDefault.ttl,
    // Conversation-privacy flags ride each outgoing 1:1 message as a
    // PrivacyHeader — read at send time, same pattern as ttlProvider.
    privacyFlagsProvider: () {
      final prefs = ref.read(appPreferencesProvider).value;
      return (
        screenshots: prefs.blockScreenshots,
        forwarding: prefs.blockForwarding,
      );
    },
    // Read at read-time so toggling the Privacy setting applies immediately.
    readReceiptsEnabledProvider: () =>
        ref.read(appPreferencesProvider).value.sendReadReceipts,
    // Link-preview cards are built on THIS device, over Tor only (unless the
    // user opted into direct fetches) — see LinkPreviewRoute. Read at send time
    // so a settings change or Tor coming up applies immediately.
    linkPreviewSource: () {
      final prefs = ref.read(appPreferencesProvider).value;
      final torSelected = kBuiltInTorEnabled && prefs.builtInTorEnabled;
      final route = LinkPreviewRoute.resolve(
        mode: prefs.linkPreviewMode,
        socks: ref.read(socksProxyProvider),
        // The in-app Tor hands out a fail-closed dummy proxy until it connects.
        socksReady: !torSelected || ref.read(torControllerProvider).isConnected,
      );
      if (!route.allowed) return null;
      return (url) async {
        final loader = DioLinkPageLoader(socksProxy: route.proxy);
        try {
          return await LinkPreviewFetcher(
            loader: loader,
            makeThumbnail: LinkThumbnail.make,
          ).fetch(url);
        } finally {
          loader.close();
        }
      };
    },
    // Lets the main isolate raise a notification for a message that arrived
    // over the live socket while backgrounded (FCM only fires when offline).
    localNotifications: ref.watch(localNotificationsProvider),
  );
  notifier.sealedSenderEnabled = kSealedSenderEnabled;
  notifier.unidentifiedAccessEnabled = kUnidentifiedAccessEnabled;
  ref.onDispose(notifier.dispose);
  return notifier;
});

/// The 1:1 call state machine, wired to the app: media via `flutter_webrtc`,
/// signaling via the conversation notifier's E2EE control-message path, and the
/// "accepted 1:1 only" permission via [ConversationsNotifier.isCallable].
/// Inbound call signals (decoded post-lock by the notifier) are routed into the
/// state machine.
///
/// The WebRTC engine currently has no TURN servers configured, so calls
/// negotiate but can't traverse NAT yet — that lands with coturn + the
/// TURN-credential endpoint (see `docs/voice-calls-design.md` §8). Everything
/// else — ring, accept/decline, SDP/ICE exchange, in-call controls — is live.
/// Persistent TURN-credential cache — shared by the call engine (which reads it
/// on every call setup) and the account-switch wipe (which must clear it, since
/// the credential is scoped to the issuing account). See [TurnCredentialsCache].
final turnCredentialsCacheProvider = Provider<TurnCredentialsCache>(
  (ref) => TurnCredentialsCache(storage: ref.read(secureStorageProvider)),
);

final ChangeNotifierProvider<CallController> callControllerProvider =
    ChangeNotifierProvider<CallController>((ref) {
  // Resolve the CURRENT conversations notifier on demand — do NOT watch it.
  // The notifier INSTANCE is rebuilt whenever the transport changes: a built-in-
  // Tor restart on resume hands out a new SOCKS port, which cascades through
  // socksProxy → api/ws clients → conversationsProvider. Watching it here (even
  // via `.notifier`) rebuilds THIS provider and DISPOSES the live CallController
  // mid-call — the "answer a call under app-lock → it vanishes to the chat list"
  // bug. (An earlier fix swapped `conversationsProvider` for `.notifier` to dodge
  // notifyListeners rebuilds, but an *instance* swap still tore the call down.)
  // So we read lazily and re-bind the signal handler below, letting the
  // controller — and the in-progress call — survive the swap.
  ConversationsNotifier liveNotifier() =>
      ref.read(conversationsProvider.notifier);
  final sessions = ref.read(sessionRepositoryProvider);
  // `read`, not `watch`: this provider must NOT rebuild mid-call (see above).
  final turnCredentialsCache = ref.read(turnCredentialsCacheProvider);

  // Our device id, from the session. This provider can be built BEFORE sign-in
  // finishes (no session yet), so a one-shot read would leave the id empty until
  // the next app start — a fresh device then declared an empty id on its first
  // calls. Re-read whenever it is still empty and whenever the notifier is
  // re-bound (which happens after sign-in).
  var selfDeviceId = '';
  void refreshSelfDeviceId() {
    unawaited(sessions.current().then((s) {
      if (s != null) selfDeviceId = s.deviceId;
    }));
  }

  refreshSelfDeviceId();

  final controller = CallController(
    // Each call's engine fetches fresh short-lived TURN credentials and runs
    // relay-only (no peer IP leak); falls back to no-server/relay-only if TURN
    // isn't configured yet (calls then only work on cooperative NATs).
    engineFactory: () => WebrtcCallMediaEngine(
      // Retries the (Tor-path) TURN fetch and throws on persistent failure so
      // the call fails fast with a clear error instead of hanging relay-only
      // with no servers. See [loadCallIceConfig].
      //
      // The fetch is served from [TurnCredentialsCache] first: the server mints
      // these with a 12h TTL, so refetching per call spent a Tor round-trip (the
      // slowest, last step of call setup) re-earning a credential we already
      // held. A hit skips the network — and therefore the retry/backoff window —
      // entirely; a miss behaves exactly as before.
      iceConfigLoader: () => loadCallIceConfig(
        () => turnCredentialsCache.get(
          () => ref.read(apiClientProvider).fetchTurnCredentials(),
        ),
      ),
    ),
    transport: NotifierCallTransport(notifier: liveNotifier, sessions: sessions),
    canCall: (id) => liveNotifier().isCallable(id),
    selfDeviceId: () {
      if (selfDeviceId.isEmpty) refreshSelfDeviceId();
      return selfDeviceId;
    },
    generateCallId: newCallId,
    // On every call end, drop a local-only call-log line into the thread.
    onCallEnded: (ended) {
      // Clear any incoming-call (ring) notification for this thread — the call
      // is over, so the persistent `ongoing` ring notification must go. The ring
      // is now posted NATIVELY (CallNative, full-screen-intent → IncomingCallActivity),
      // so cancel it there. (Same id: conversationId.hashCode.)
      unawaited(CallNative.cancelIncomingCall(ended.conversationId.hashCode));
      // iOS counterpart: dismiss the CallKit system call UI. A VoIP push rang
      // the phone natively before Dart had any say, so every end — including
      // one we decided on ourselves — has to be mirrored back or a phantom
      // ring stays on screen. No-op off iOS.
      unawaited(ref.read(callKitBridgeProvider).onAppCallEnded());
      // A call that failed before ever reaching media may have been killed by a
      // stale cached TURN credential; make the re-dial fetch a fresh one.
      if (shouldDropTurnCredentials(ended)) {
        unawaited(turnCredentialsCache.clear());
      }
      final outgoing = ended.direction == CallDirection.outgoing;
      final String outcome;
      int? duration;
      if (ended.connectedAt != null) {
        outcome = 'completed';
        duration =
            DateTime.now().toUtc().difference(ended.connectedAt!).inSeconds;
      } else {
        switch (ended.endReason) {
          case CallEndReason.declined:
          case CallEndReason.busy:
            outcome = 'declined';
          case CallEndReason.failed:
            outcome = 'failed';
          case CallEndReason.missed:
            outcome = 'missed';
          case CallEndReason.hangup:
          case CallEndReason.cancelled:
          case null:
            outcome = outgoing ? 'cancelled' : 'missed';
        }
      }
      unawaited(liveNotifier().appendCallLog(
        conversationId: ended.conversationId,
        outgoing: outgoing,
        outcome: outcome,
        durationSeconds: duration,
        video: ended.mediaKind == CallMediaKind.video,
      ));
    },
  );

  // Route inbound call signals (the notifier decodes them post-lock) into the
  // state machine, labelling them from the conversation's peer. Bound on the
  // current notifier AND re-bound on every rebuild (a transport change swaps the
  // instance) so the invite/accept signals still reach the live controller after
  // the swap — without re-binding, a Tor restart mid-ring would leave the fresh
  // notifier with no handler and the call would silently never reconcile.
  // Tracked so onDispose can clear it WITHOUT a ref.read (illegal once the
  // container is disposed) — and so each re-bind clears the previous notifier.
  ConversationsNotifier? boundNotifier;
  void bindCallSignals(ConversationsNotifier n) {
    // A re-bind follows sign-in / a transport change: pick up the device id now.
    refreshSelfDeviceId();
    boundNotifier?.onCallSignal = null;
    boundNotifier = n;
    n.onCallSignal = (conversationId, signal, senderDeviceId) {
      final convo = n.byId(conversationId);
      unawaited(controller.handleSignal(
        signal,
        fromAccountId: convo?.peerAccountId ?? '',
        fromDeviceId: senderDeviceId,
        conversationId: conversationId,
        peerUsername: convo?.peerUsername,
      ));
    };
  }

  bindCallSignals(liveNotifier());
  ref.listen<ConversationsNotifier>(
    conversationsProvider.notifier,
    (prev, next) => bindCallSignals(next),
  );

  // ChangeNotifierProvider disposes `controller` itself on teardown; only the
  // notifier back-reference needs clearing here (a second controller.dispose()
  // would assert "used after being disposed").
  ref.onDispose(() => boundNotifier?.onCallSignal = null);
  return controller;
});

/// What the server stores (and pushes) as `conversation_id` for a SEALED
/// envelope — it is blind to the real one by design. Mirrors
/// `proto.SealedSentinelUUID`. Seeing it means "resolve the conversation from
/// the sealed blob, or not at all".
const String _sealedSentinelConversationId =
    '00000000-0000-0000-0000-000000000000';

/// Joins the iOS system call UI (CallKit, fed by PushKit) to [CallController].
/// Started by [CallOverlay] — which is mounted app-wide — so it is listening
/// (and replaying anything buffered before the engine existed) whenever the app
/// is alive. A no-op off iOS.
///
/// `read`, not `watch`, for the controller: this must not rebuild mid-call, and
/// the bridge resolves the CURRENT controller on demand for the same reason the
/// transport does (a Tor restart swaps provider instances).
final Provider<CallKitBridge> callKitBridgeProvider =
    Provider<CallKitBridge>((ref) {
  final bridge = CallKitBridge(
    channel: ref.watch(voipPushChannelProvider),
    controller: () => ref.read(callControllerProvider),
    // The push is conversation-blind under sealed sender (it carries the
    // all-zero sentinel), so the REAL conversation has to be recovered by
    // opening the inlined outer blob — a static X25519 unwrap that does NOT
    // advance the forward-secret ratchet, so the foreground can still decrypt
    // the invite itself afterwards. Exactly what the Android background
    // isolate does with the same payload.
    resolveConversationId: (payload) async {
      final b64 = payload['sealed_payload'];
      if (b64 != null && b64.isNotEmpty) {
        try {
          final opened = await (ref.read(cryptoBridgeProvider) as SealOpener)
              .openSealed(base64.decode(b64));
          final inner = SealedInner.decode(opened);
          if (inner.conversationId.isNotEmpty) return inner.conversationId;
        } catch (_) {/* not addressed to us / corrupt → fall through */}
      }
      final plain = payload['conversation_id'];
      if (plain == null || plain.isEmpty || plain == _sealedSentinelConversationId) {
        return null;
      }
      return plain;
    },
    resolveCallerName: CallerNameResolver(
      liveName: (id) =>
          ref.read(conversationsProvider.notifier).byId(id)?.peerUsername,
      storage: ref.read(secureStorageProvider),
    ).resolve,
    // Suppress the ring only when we POSITIVELY know it shouldn't happen.
    //
    // On a cold launch — the very case CallKit exists for, where answering from
    // the lock screen starts the process — the conversation store isn't
    // hydrated yet, so `isCallable` would say "no" for every legitimate call
    // and we would hang up on the caller. An unknown conversation therefore
    // rings: the permission rule (accepted, non-blocked 1:1) is enforced again
    // when the real invite lands, by which time the notifier IS hydrated, and a
    // ring that shouldn't have happened simply times out as missed.
    shouldRing: (conversationId) {
      final notifier = ref.read(conversationsProvider.notifier);
      if (notifier.byId(conversationId) == null) return true;
      return notifier.isCallable(conversationId);
    },
  );
  ref.onDispose(() => unawaited(bridge.dispose()));
  return bridge;
});
