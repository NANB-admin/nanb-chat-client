import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../core/crypto/conversation_crypto_state.dart';
import '../../core/crypto/crypto_bridge.dart';
import '../../core/crypto/delivered_receipt.dart';
import '../../core/crypto/mls_exceptions.dart';
import '../../core/crypto/sealed_envelope.dart';
import '../../core/crypto/sealed_inner.dart';
import '../../core/db/app_database.dart';
import '../../core/models/account.dart';
import '../../core/models/api_error.dart';
import '../../core/models/device.dart';
import '../../core/models/envelope.dart' as wire;
import '../../core/models/report_reason.dart';
import '../../core/network/api_client.dart';
import '../../core/network/connection_state.dart';
import '../../core/network/transient_retry.dart';
import '../../core/network/ws_client.dart';
import '../../core/network/ws_connection_event.dart';
import '../../core/network/ws_reconnect_supervisor.dart';
import '../../core/secure_storage/secure_storage.dart';
import '../../core/push/handled_envelope_log.dart';
import '../../core/push/notification_permission_gate.dart';
import '../../core/push/push_token_registrar.dart';
import '../../core/push/local_notifications.dart';
import '../../core/push/push_kind.dart';
import '../../core/push/sealed_delivered_receipt.dart';
import '../onboarding/session_repository.dart';
import 'media_pipeline.dart';
import 'mls_migrator.dart';
import 'pending_upload_staging.dart';
import 'video/video_thumbnail_loader.dart';
import 'models/shared_content.dart';
import 'services/shared_content_loader.dart';
import 'models/catchup_timing.dart';
import 'models/chat_message.dart';
import 'models/client_msg_id_header.dart';
import 'models/conversation.dart';
import 'models/control_migration_outcome.dart';
import 'models/conversation_kind.dart';
import 'models/crypto_mode.dart';
import 'models/forward_marker.dart';
import 'models/group_member.dart';
import 'models/member_seed.dart';
import 'models/history_backfill.dart';
import 'models/message_control.dart';
import 'models/privacy_header.dart';
import 'models/reply_ref.dart';
import 'models/pending_upload.dart';
import 'models/ttl_header.dart';
import 'models/message_kind.dart';
import 'models/system_event.dart';
import 'services/call_signaling_service.dart';
import 'models/chat_background_override.dart';
import 'services/conversation_delete_sync_service.dart';
import 'services/conversation_settings_service.dart';
import 'services/conversation_state_applier.dart';
import 'services/conversation_state_store.dart';
import 'services/conversation_state_sync_service.dart';
import 'services/control_receiver.dart';
import 'services/control_sender.dart';
import 'services/adder_election.dart';
import 'services/device_cache.dart';
import 'services/envelope_retry_log.dart';
import 'services/processed_envelope_log.dart';
import 'services/disappearing_sweep.dart';
import 'services/key_package_replenisher.dart';
import 'services/group_manager.dart';
import 'services/persisted_marker_set.dart';
import 'services/media_cache.dart';
import 'services/message_appender.dart';
import 'services/mls_receiver.dart';
import 'services/notifier_service_host.dart';
import 'services/peer_profile_cache.dart';
import 'services/pin_service.dart';
import 'services/ratchet_receiver.dart';
import 'services/reaction_service.dart';
import 'services/ratchet_core.dart';
import 'services/receipt_service.dart';
import 'services/report_service.dart';
import 'services/request_decision_service.dart';
import 'services/sealed_sender.dart';
import 'services/share_send_target.dart';
import 'services/sticker_marker.dart';
import 'services/temp_media_store.dart';
import 'services/typing_service.dart';
import 'services/upload_worker.dart';
import '../calls/models/call_signal.dart';
import 'services/delete_sync_service.dart';
import 'services/group_avatar_service.dart';
import 'services/group_disband_service.dart';
import 'services/link_preview_service.dart';
import 'services/message_edit_service.dart';

/// Holds the in-memory conversation list + per-conversation message lists
/// **plus** writes through to a SQLCipher-backed `AppDatabase` so a restart
/// rehydrates the chat history. Real content E2EE happens in `CryptoBridge`
/// (Plan 13 X25519 ECDH + Plan 13.1 forward-secret ratchet); the wire body
/// is UTF-8 encoded on the way in and decoded on the way out so messages
/// with emoji / non-Latin characters round-trip correctly.
class ConversationsNotifier extends ChangeNotifier
    implements NotifierServiceHost, ShareSendTarget {
  ConversationsNotifier({
    required ApiClient apiClient,
    required WsClient wsClient,
    required WsReconnectSupervisor supervisor,
    required CryptoBridge crypto,
    required SessionRepository sessions,
    required AppDatabase database,
    required SecureStorage secureStorage,
    required MediaPipeline media,
    required PushTokenRegistrar pushRegistrar,
    /// Registers the iOS PushKit token for the CallKit ring. Optional: a
    /// device with no PushKit token (Android, tests) simply skips.
    PushTokenRegistrar? voipPushRegistrar,
    required NotificationPermissionGate notificationPermissionGate,
    required VideoThumbnailLoader videoThumbnailLoader,
    required PendingUploadStaging pendingUploadStaging,
    TempMediaStore? tempMediaStore,
    Duration? Function()? ttlProvider,
    ({bool screenshots, bool forwarding}) Function()? privacyFlagsProvider,
    bool Function()? readReceiptsEnabledProvider,
    LinkPreviewSource? Function()? linkPreviewSource,
    LocalNotifications? localNotifications,
    Future<void> Function(Duration)? submitRetryDelay,
  })  : _submitRetry = TransientRetry(delay: submitRetryDelay),
        _ttlProvider = ttlProvider,
        _privacyFlagsProvider = privacyFlagsProvider,
        _readReceiptsEnabledProvider = readReceiptsEnabledProvider,
        _linkPreviewSource = linkPreviewSource,
        _localNotifications = localNotifications,
        _api = apiClient,
        _ws = wsClient,
        _supervisor = supervisor,
        _crypto = crypto,
        _sessions = sessions,
        _db = database,
        _secureStorage = secureStorage,
        _media = media,
        _pushRegistrar = pushRegistrar,
        _voipPushRegistrar = voipPushRegistrar,
        _notificationPermissionGate = notificationPermissionGate,
        _videoThumbnailLoader = videoThumbnailLoader,
        _pendingUploadStaging = pendingUploadStaging,
        // Defaults to a no-op in-memory store so unit tests that don't wire one
        // never touch a real temp dir; production injects TempMediaStoreImpl.
        _tempMediaStore = tempMediaStore ?? TempMediaStoreInMemory();

  /// Rides out a transport that isn't ready yet on the SUBMIT leg of a send —
  /// see [_submit], and [TransientRetry] for why the window exists at all. The
  /// same policy the media pipeline has always had; text sends went without it,
  /// which is why a message typed while Tor was connecting died permanently.
  final TransientRetry _submitRetry;

  final ApiClient _api;
  final WsClient _ws;
  final WsReconnectSupervisor _supervisor;
  final CryptoBridge _crypto;
  final SessionRepository _sessions;
  // Non-final: a successfully-injected SQLCipher DB that turns out to be
  // unreadable at open time is swapped for an ephemeral in-memory store in
  // [_ensureHydrated] so start-up never wedges (see [databaseDegradedToMemory]).
  AppDatabase _db;

  /// The real on-disk DB set aside when [_ensureHydrated] degraded to in-memory,
  /// kept so [recoverDegradedDatabase] can wipe + reopen it. Null unless degraded.
  AppDatabase? _diskDb;
  final SecureStorage _secureStorage;
  final MediaPipeline _media;
  final PushTokenRegistrar _pushRegistrar;

  /// Second registrar for the iOS PushKit (VoIP) token — the CallKit ring is
  /// reached over a DIFFERENT transport and topic from the alert token, so the
  /// device registers both. Null off iOS.
  final PushTokenRegistrar? _voipPushRegistrar;
  final NotificationPermissionGate _notificationPermissionGate;
  final VideoThumbnailLoader _videoThumbnailLoader;
  final PendingUploadStaging _pendingUploadStaging;
  final TempMediaStore _tempMediaStore;
  final LocalNotifications? _localNotifications;

  /// Whether the app is currently foregrounded. Set by [AppLifecycleObserver]
  /// (resumed → true, paused/hidden → false). When false, an inbound message
  /// that arrived over the live socket raises its own notification — the FCM
  /// background isolate only runs when the server pushes an OFFLINE device, but
  /// the socket is kept alive across backgrounding, so FCM never fires. Default
  /// true so messages in tests / before the first lifecycle event don't notify.
  bool appInForeground = true;

  /// The conversation whose thread is currently on screen, or null. Set by the
  /// chat thread screen on open/close. With [appInForeground], it suppresses an
  /// inbound-message notification ONLY for the chat the user is actively reading
  /// (they already see it) — every other case still notifies.
  String? _openConversationId;

  /// Records which conversation thread is currently visible (null = none).
  void setOpenConversation(String? conversationId) {
    _openConversationId = conversationId;
    // Opening a thread clears its pending banner (ids are keyed on the
    // conversation — see fcm_background_handler / _notifyPeerReaction).
    if (conversationId != null) {
      unawaited(_localNotifications?.cancel(conversationId.hashCode) ??
          Future<void>.value());
    }
  }

  /// Reads the user's delete-messages-after preference at send time. The
  /// value rides each CONTENT envelope as ttl_seconds so the server expires
  /// it on the user's schedule (cap-down only). Control envelopes
  /// (mls_welcome / mls_handshake) deliberately skip it — expiring protocol
  /// state early would break group joins.
  final Duration? Function()? _ttlProvider;

  int? get _contentTtlSeconds => _ttlProvider?.call()?.inSeconds;

  /// The disappearing TTL (seconds) to attach to messages sent in [c]: the
  /// conversation's per-chat override when set (`disappearingTtl > 0`), else the
  /// global default. Drives both the wire `_ttl` header and our own copy's
  /// expiry, so a per-contact / per-group choice applies to both sides.
  int? _effectiveDisappearingSeconds(Conversation c) {
    final override = c.disappearingTtl;
    return override > 0 ? override : _contentTtlSeconds;
  }

  /// Reads the user's "send read receipts" preference at read time. Null (tests
  /// / not wired) → enabled, preserving the always-on default behaviour.
  final bool Function()? _readReceiptsEnabledProvider;

  /// Supplies the function that builds a link's preview card, or null while
  /// previews are off / have no safe (Tor) route. Read at use time so a settings
  /// change applies immediately. Null in tests → no previews.
  final LinkPreviewSource? Function()? _linkPreviewSource;

  bool get _readReceiptsEnabled => _readReceiptsEnabledProvider?.call() ?? true;

  /// Reads the user's conversation-privacy flags (block screenshots / block
  /// forwarding) at send time. While either flag is set, every outgoing 1:1
  /// message carries a [PrivacyHeader] so peers converge on the current
  /// flags statelessly; [broadcastPrivacyFlags] handles the instant-toggle
  /// (including toggle-OFF) case. Null in tests that don't care.
  final ({bool screenshots, bool forwarding}) Function()? _privacyFlagsProvider;

  /// Sealed-sender (Phase 1, docs/sealed-sender-design.md) SEND gate. When true,
  /// each outgoing envelope is wrapped in a per-recipient sealed layer at the
  /// `_submit` chokepoint — for group members, all 1:1 peer devices, and this
  /// account's own self-sync devices. 1:1 / self-sync sealing is capability-
  /// gated: a device is only sealed to once it has advertised it can open
  /// sealed envelopes (see `_resolveRecipientX25519`), so an old-build recipient
  /// isn't stranded. Default OFF; the provider sets it from
  /// `kSealedSenderEnabled`. A failed seal NEVER blocks a send — it falls back
  /// to unsealed.
  bool sealedSenderEnabled = false;

  /// True once this device has advertised its sealed-receive capability to the
  /// server this session (best-effort, idempotent) — so we report at most once.
  bool _sealCapabilityReported = false;

  /// Bounded mirror of consumed envelope ids, read by the FCM background
  /// isolate so it never raises a banner for a message already shown.
  late final HandledEnvelopeLog _handledEnvelopes =
      HandledEnvelopeLog(storage: _secureStorage);

  /// DURABLE per-envelope failure counts, shared with [MlsReceiver]. Replaces
  /// the in-memory maps whose reset-on-launch made every poison-pill threshold
  /// unreachable, so an envelope that can never be processed re-drained on
  /// every single launch instead of eventually being dropped.
  late final EnvelopeRetryLog _retryLog =
      EnvelopeRetryLog(storage: _secureStorage);
  late final ProcessedEnvelopeLog _processedLog =
      ProcessedEnvelopeLog(storage: _secureStorage);

  /// Envelope ids acked during the CURRENT catchup drain, or null when no drain
  /// is running. Populated by [ack] — the one chokepoint every path funnels
  /// through — so the drain can tell which envelopes it fetched and then failed
  /// to consume, WITHOUT having to enumerate every drop site.
  Set<String>? _drainAckedIds;

  /// How many times an envelope we cannot unseal may redeliver before we give
  /// up and ack it. Bounded so a genuinely corrupt/misaddressed blob can't
  /// redeliver forever, but > 1 so the messages in flight survive long enough
  /// for a republished sealing key to reach the sender.
  static const int _maxUnopenableSealedRedeliveries = 5;

  /// How many times an envelope whose sender we cannot resolve may redeliver
  /// before we ack and drop it. Higher than the decrypt bounds would be
  /// tempting (resolution can fail transiently, e.g. offline), but each attempt
  /// costs a full re-fetch + re-process of the envelope on EVERY launch, and a
  /// stranded envelope is already surfaced to the user as a placeholder.
  static const int _maxUnknownPeerRedeliveries = 5;

  /// How many consecutive drains may fetch an envelope that is never consumed
  /// before it is acked and dropped. This is the catch-all backstop behind the
  /// per-path bounds: an envelope re-fetched this many times is not being
  /// repaired by anything, and each retry costs a full re-fetch + re-process on
  /// every launch.
  static const int _maxUnconsumedRedeliveries = 5;

  /// When we last republished our sealing key after a failed unseal. Throttled:
  /// a catchup batch can fail to open dozens of envelopes at once and they must
  /// not turn into dozens of identical POSTs.
  DateTime? _lastSealingKeyRepublish;
  static const Duration _sealingKeyRepublishCooldown = Duration(minutes: 2);

  /// Sealed-sender Phase 2 (unidentified access). When on, a sealed envelope to
  /// a recipient whose UAK we hold is deposited on the UNAUTHENTICATED path
  /// (`POST /messages/sealed`) so the server never sees the sender; any failure
  /// falls back to the authenticated send. Set from `kUnidentifiedAccessEnabled`.
  bool unidentifiedAccessEnabled = false;

  /// Monotonic counter appended to outbox ids so two sends in the same
  /// microsecond (rapid pick-then-pick) still get distinct ids.
  int _outboxCounter = 0;

  /// Per-conversation FIFO lock chain. Serializes encrypt/decrypt + state
  /// persistence within a conversation so two concurrent calls can't both
  /// advance the chain from the same starting state. Conversations are
  /// independent, so different convos process in parallel.
  final Map<String, Future<void>> _convoLocks = {};

  /// Per-conversation FIFO cap mirrored from the server.
  static const int messageCap = 5000;

  /// Trim the on-disk message history at most once every this many inserts per
  /// conversation, rather than on every single message. The trim is a
  /// DELETE-with-subquery that materialises the newest [messageCap] ids and is
  /// wasted work on the common path (a chat far below the cap). Letting a
  /// conversation sit a few hundred rows over the cap between trims is
  /// harmless; this keeps the delivery + catchup hot path cheap.
  static const int _trimInterval = 200;

  /// Inserts since the last trim, per conversation. See [_maybeTrim].
  final Map<String, int> _insertsSinceTrim = {};

  /// Number of messages hydrated per conversation on cold start. The rest
  /// stay on disk and are loaded by [loadOlderMessages] as the user scrolls
  /// up. Keeping this small is what lets a chat with thousands of
  /// messages render instantly.
  static const int messagesInitialPage = 50;

  /// Number of older messages prepended on each scroll-up batch.
  static const int messagesPageSize = 50;

  /// SecureStorage key for the SQLCipher master key (64 hex chars).
  static const String dbMasterKeyKey = 'crypto.db_master_key.hex';

  /// SecureStorage key holding a JSON array of muted conversation ids. The
  /// FCM background isolate reads it to suppress notifications for muted
  /// conversations — it can't open the encrypted DB, but it can read
  /// SecureStorage. The foreground keeps it in sync via [_persistMutedSet].
  static const String mutedConvosKey = 'push.muted_convos';

  /// SecureStorage key holding a JSON array of blocked conversation ids — read
  /// by the FCM background isolate to suppress wake notifications from blocked
  /// contacts (same mechanism as [mutedConvosKey]). Kept in sync by
  /// [_persistBlockedSet].
  static const String blockedConvosKey = 'push.blocked_convos';

  /// SecureStorage key holding a JSON map of 1:1 conversationId -> peer display
  /// name. The FCM background isolate (no DB access) reads it to put the CALLER's
  /// name on the incoming-call ring — the push itself is content-blind. Kept in
  /// sync by [_persistCallPeerNames].
  static const String callPeerNamesKey = 'push.call_peer_names';

  /// SecureStorage key holding the JSON array of own-device ids last seen by
  /// [_reconcileOwnDevicesIntoGroups]. A device id present in the server's
  /// fleet but NOT here is newly linked, so the designated existing device adds
  /// it to every already-migrated MLS conversation.
  static const String knownOwnDevicesKey = 'mls.known_own_devices';

  /// SecureStorage key holding a JSON array of `"<deviceId>|<convoId>"` markers
  /// for (newly-linked device, conversation) pairs whose history has already
  /// been backfilled, so a re-running reconcile sweep doesn't re-send it. The
  /// receiver dedups by envelope id regardless, so this is an efficiency guard,
  /// not a correctness one.
  static const String backfilledHistoryKey = 'mls.backfilled_history';

  /// SecureStorage key holding a JSON array of `"<deviceId>|<convoId>"` markers
  /// for (newly-linked device, conversation) pairs this device has ALREADY
  /// added to the MLS group, so a retried sweep never re-adds (a duplicate add
  /// would throw / fork).
  static const String ownDeviceAddedKey = 'mls.own_device_added';

  final Map<String, Conversation> _byId = {};

  /// Group conversation ids the user has DELETED, mirrored from the
  /// `deleted_groups` table on hydration. Envelopes that arrive for one of
  /// these are acked+dropped instead of re-creating the conversation: after a
  /// delete we hold no MLS group, so any envelope still queued server-side is
  /// permanently undecryptable AND (because the group placeholder path never
  /// acks) would otherwise resurrect the chat on every single catchup — the
  /// "deleted group comes back forever" defect. An inbound Welcome is the one
  /// exception: a re-invite is a deliberate act by an admin, so it lifts the
  /// tombstone (see [_onEnvelope]).
  final Set<String> _deletedGroupIds = {};

  /// THIS account's id, cached on connect so the UI can resolve "my" reactions
  /// synchronously (reactions are keyed by reactor account id). Empty until
  /// the first connect.
  String? _selfAccountId;

  /// THIS account's id, or empty before the first connect. Used by the message
  /// list to highlight reactions the current user added.
  String get myAccountId => _selfAccountId ?? '';

  StreamSubscription<wire.Envelope>? _wsSub;
  StreamSubscription<WsConnectionEvent>? _supervisorSub;
  bool _connected = false;
  bool _hydrated = false;
  bool _initialCatchupDone = false;
  bool _databaseDegradedToMemory = false;

  /// In-memory mirror of [SessionRepository.isSignedOut]. The router
  /// (`refreshListenable: this`) reads [manuallySignedOut] synchronously to
  /// keep a manually-signed-out user on /welcome even though the session +
  /// chat history remain on disk. Loaded at boot via [loadSignedOutGate], set
  /// by [signOutKeepingData], cleared by [resumeAfterSignOut].
  bool _manuallySignedOut = false;

  /// Single-flight gate so two concurrent `connect()` callers don't both
  /// open a WebSocket. Whoever wins resolves this completer; subsequent
  /// callers `await` it and skip the work.
  Completer<void>? _connecting;

  /// Completes when this connection's initial [reconcileMlsConversations] has
  /// finished. [connect] now starts the WebSocket handshake CONCURRENTLY with
  /// reconcile (so the fast WS send-path comes up sooner instead of after the
  /// slow, Tor-bound reconcile); [_runCatchup] awaits this before draining
  /// backlog, so catchup envelopes that reference freshly-reconciled MLS groups
  /// still decrypt in order. Recreated per [connect]; a null/completed gate
  /// means "reconcile already landed, don't wait".
  Completer<void>? _mlsReconcileGate;

  /// Drives the disappearing-message sweep on a steady cadence while connected,
  /// so expired messages vanish at their TTL rather than only on the next app
  /// launch. Started in [connect], cancelled in [disconnect]/[dispose].
  Timer? _disappearingSweepTimer;

  /// The conversations in NO particular order — a fresh mutable copy of the
  /// live map values. For callers that immediately re-sort or purely filter
  /// (e.g. the chat list, which orders pinned-first itself), so they don't pay
  /// for [conversations]' sort only to throw it away and sort again.
  List<Conversation> get conversationsUnsorted => _byId.values.toList();

  List<Conversation> get conversations {
    final list = conversationsUnsorted;
    list.sort((a, b) {
      final ats = a.lastMessage?.serverTs;
      final bts = b.lastMessage?.serverTs;
      if (ats == null && bts == null) {
        final aName = a.groupName ?? a.peerUsername;
        final bName = b.groupName ?? b.peerUsername;
        return aName.compareTo(bName);
      }
      if (ats == null) return 1;
      if (bts == null) return -1;
      return bts.compareTo(ats); // newest first
    });
    return list;
  }

  Conversation? byId(String id) => _byId[id];

  /// Whether the initial disk hydration has completed. Until this flips true,
  /// `byId` returns null for *every* id simply because nothing has been loaded
  /// yet. A thread deep-linked from a notification tap can build before the
  /// chat list has mounted and driven `connect()` (which hydrates), so the
  /// screen reads this to show a loader during the cold-start load window
  /// instead of a misleading "no such conversation" empty state.
  bool get hydrated => _hydrated;

  /// True when [_ensureHydrated] could not open the on-disk SQLCipher database
  /// with the stored key and fell back to an ephemeral in-memory store so the
  /// session still works. Nothing persists across a restart while this is set,
  /// and the unreadable file is left untouched on disk for a future launch where
  /// the key might line up again. Exposed so the UI can warn that local history
  /// is unavailable on this device.
  bool get databaseDegradedToMemory => _databaseDegradedToMemory;

  /// Whether the first post-connect catchup fetch has succeeded since the
  /// current connection began. A brand-new conversation pushed while the app
  /// was closed has NO local row until this first catchup decrypts + persists
  /// it (the background isolate never decrypts — see [_runCatchup]). So between
  /// the WS reaching `connected` and that catchup delivering the message,
  /// `byId` is still null for a perfectly valid conversation. A thread deep-
  /// linked from the notification tap reads this so it keeps a loader up across
  /// that gap rather than flashing the "no such conversation" empty state.
  /// Re-armed (false) on every (re)connect; set true once catchup succeeds.
  bool get catchupSettled => _initialCatchupDone;

  /// How many envelopes the in-flight catchup has actually fetched, or 0 when
  /// it has not found any (including before its first page comes back).
  ///
  /// [catchupSettled] alone cannot drive a "Catching up…" affordance: it is
  /// re-armed to false at the TOP of [connect], long before anyone knows
  /// whether there is a backlog, so a UI keyed on it covers the list on every
  /// single cold start — including the overwhelmingly common one that drains
  /// nothing and settles in ~270ms. It also overlapped the "Connecting…"
  /// banner, putting two different progress messages on screen at once.
  ///
  /// This is set only once a page comes back non-empty, so the affordance
  /// appears exactly when the list is genuinely about to rearrange under the
  /// user — which is the thing it exists to explain.
  int get catchupBacklog => _catchupBacklog;
  int _catchupBacklog = 0;

  /// Mirrors the WS reconnect supervisor's state. The connection banner
  /// reads this; the router watches for `signedOut` to redirect to /welcome.
  ConnectionState get connectionState => _supervisor.state;

  /// Steps of [connect] that have been running unusually long, surfaced in the
  /// connection banner.
  ///
  /// Start-up used to sit on "Connecting…" forever with NO indication of which
  /// step was wedged — the supervisor's initial state is already `connecting`,
  /// so that label appears before the socket is even attempted, and every phase
  /// of connect() looks identical from the outside. That is undiagnosable on a
  /// TestFlight/App Store device, where there is no console to read.
  ///
  /// A watchdog per phase, NOT a timeout: nothing is cancelled or aborted, so a
  /// slow-but-working device (a large DB migration, a cold Tor circuit) behaves
  /// exactly as before and merely shows what it is waiting on. A Set because
  /// the socket and the MLS reconcile run concurrently.
  final Set<String> _slowConnectPhases = {};

  /// Comma-joined [_slowConnectPhases] for display; empty when nothing is slow.
  String get slowConnectPhases =>
      (_slowConnectPhases.toList()..sort()).join(', ');

  /// Last catchup drain's outcome, surfaced in the connection banner.
  ///
  /// Empty when the last drain processed everything it fetched. Otherwise
  /// `N/M failed: <first error>`. A rejected envelope is left UNACKED and
  /// retried, so the failure is otherwise completely silent — the message
  /// simply never appears and the only trace is a `print` no store build can
  /// show. That is undiagnosable on TestFlight, which is the whole reason this
  /// exists.
  String _catchupDiagnostic = '';
  String get catchupDiagnostic => _catchupDiagnostic;

  /// Where the time went in the last catchup drain. Surfaced in Settings ->
  /// Network, because release builds silence every log and a latency budget
  /// nobody can read is a budget nobody can hold.
  CatchupTiming _catchupTiming = CatchupTiming.empty;
  CatchupTiming get catchupTiming => _catchupTiming;

  /// Runs [op], flagging [name] as slow if it hasn't finished within 12s.
  /// Purely observational — [op] is never cancelled.
  Future<T> _watchedPhase<T>(String name, Future<T> op) async {
    final watchdog = Timer(const Duration(seconds: 12), () {
      _slowConnectPhases.add(name);
      notifyListeners();
    });
    try {
      return await op;
    } finally {
      watchdog.cancel();
      if (_slowConnectPhases.remove(name)) notifyListeners();
    }
  }

  /// Whether the user manually signed out while keeping their data on-device
  /// (see [signOutKeepingData]). The router redirects to /welcome whenever this
  /// is true, regardless of the live WebSocket state.
  bool get manuallySignedOut => _manuallySignedOut;

  /// Loads the persisted manual-sign-out gate into memory at boot so the very
  /// first router redirect evaluation is correct. Call before routing.
  Future<void> loadSignedOutGate() async {
    _manuallySignedOut = await _sessions.isSignedOut();
  }

  /// Drops BOTH signed-out gates the router redirects on, because onboarding
  /// just established a NEW session (account created, restored, or this device
  /// linked).
  ///
  /// MUST be called before navigating to the chat list. Both gates otherwise
  /// survive onboarding in memory and bounce that navigation straight back to
  /// /welcome — the user creates an account, lands nowhere, and only gets in by
  /// force-quitting and relaunching (which rebuilds the notifier from scratch).
  /// `signedOut` in particular is terminal by design: the chat list is what
  /// calls `connect()` to clear it, and the redirect stops the chat list from
  /// ever mounting.
  ///
  /// Notifies synchronously so the router re-evaluates before the caller's
  /// `go()` — the same ordering [resumeAfterSignOut] relies on.
  void clearSignedOutForNewSession() {
    _manuallySignedOut = false;
    _supervisor.clearSignedOut();
    notifyListeners();
  }

  /// Opens the local DB, hydrates from disk, then wires the WebSocket.
  /// Idempotent — second call is a no-op until `disconnect()` is called.
  Future<void> connect() async {
    if (_connected) return;
    if (_connecting != null) {
      // Another caller is mid-connect. Piggy-back on their result.
      return _connecting!.future;
    }
    final completer = Completer<void>();
    _connecting = completer;
    _slowConnectPhases.clear();
    try {
      final session = await _watchedPhase('session', _sessions.current());
      if (session == null) return;
      _selfAccountId = session.accountId;
      // Authorize the shared HTTP client immediately — BEFORE the (possibly
      // slow) hydrate + MLS reconcile below. Otherwise an authed REST call that
      // races early app-open — e.g. setting an avatar from settings right after
      // launch — fires with no bearer and 401s, only to work on a later retry
      // once connect() finishes. Also lets reconcile's own authed calls carry
      // the token.
      _api.setBearerToken(session.jwt);
      // Re-arm the catchup gate for this connection: until the first catchup
      // succeeds, a null conversation reads as "still loading" (a pushed brand-
      // new conversation has no local row until catchup delivers it), so a
      // notification-tap deep-link shows a loader instead of the "no such
      // conversation" empty state.
      _initialCatchupDone = false;
      // Cleared with it: a backlog count left over from the previous connection
      // would show the veil before this connection's catchup has fetched a
      // thing — exactly the assume-first behaviour [catchupBacklog] removes.
      _catchupBacklog = 0;

      // Watched: this opens the SQLCipher DB, whose master key comes from the
      // keychain. A failure here is the documented "wedging start-up forever on
      // Connecting…" path (see _ensureHydrated), and it is indistinguishable
      // from a socket stall in the UI without this label.
      await _watchedPhase('database', _ensureHydrated());
      // The local conversation list is ready — paint it now. Everything below
      // (per-group MLS epoch reconcile, the WebSocket connect, and the first
      // catchup) streams its updates in via notifyListeners, so the user sees
      // their chats immediately instead of waiting on crypto + the network.
      notifyListeners();

      // Start the WebSocket handshake CONCURRENTLY with the (slower) MLS epoch
      // reconcile, rather than after it. The handshake has to traverse a fresh
      // Tor circuit, so serialising it behind reconcile left the socket down for
      // the first seconds after connect — forcing early sends onto the slow
      // HTTP-over-Tor fallback (a 30–60 s onion POST). Running them in parallel
      // gets the fast WS send-path up about as soon as the circuit is built.
      //
      // Ordering that still holds: the initial catchup (which decrypts backlog
      // possibly referencing freshly-reconciled MLS groups) awaits
      // [_mlsReconcileGate] inside [_runCatchup], so reconcile still lands before
      // we drain — only the socket connect is de-serialised. Envelope listeners
      // are attached BEFORE start() so no live push is missed during reconcile.
      final reconcileGate = Completer<void>();
      _mlsReconcileGate = reconcileGate;
      _wsSub = _ws.envelopes.listen(_onEnvelope);
      _supervisorSub = _supervisor.events.listen(_onSupervisorEvent);
      _supervisor.addListener(_onSupervisorStateChanged);
      // Kick both off, THEN await both: the WS handshake and the MLS reconcile
      // now overlap instead of running in series, so time-to-socket-up is
      // max(handshake, reconcile) rather than their sum — the send-path win —
      // while connect() still doesn't return until reconcile has landed (callers
      // rely on that; e.g. needsReestablishment must be set). The gate above
      // holds the initial catchup until reconcile completes, since the socket's
      // Reconnected can fire before reconcile does now that they run in parallel.
      // Watched separately: they run concurrently, so a single label couldn't
      // say WHICH of the two is holding connect() open. The socket phase covers
      // the supervisor's whole retry loop, which by design never gives up — so
      // "socket" showing here means handshakes are failing, while "mls
      // reconcile" means a native CoreCrypto call is hung.
      final supervisorStarted = _watchedPhase('socket', _supervisor.start());
      final reconcileDone = _watchedPhase(
        'mls reconcile',
        reconcileMlsConversations().whenComplete(() {
          if (!reconcileGate.isCompleted) reconcileGate.complete();
        }),
      );
      await Future.wait([supervisorStarted, reconcileDone]);
      _connected = true;
      notifyListeners();
      // Disappearing messages: sweep on a steady cadence so expired messages
      // vanish near their TTL while the app stays open, not only on the next
      // launch/reconnect. The lifecycle resume hook also triggers an immediate
      // sweep so a foregrounded app catches up without waiting for the tick.
      _disappearingSweepTimer?.cancel();
      _disappearingSweepTimer = Timer.periodic(
        const Duration(minutes: 1),
        (_) => unawaited(runDisappearingSweepNow()),
      );
      // Plan D: register FCM token with server after JWT is in place.
      // Best-effort — failures are swallowed by the registrar.
      unawaited(_pushRegistrar.bootstrap());
      // Same idempotent upsert for the PushKit token that rings CallKit. Runs
      // per connect for the same reason: it is what repairs a registration
      // that failed while offline, and without it a locked iPhone never rings.
      final voip = _voipPushRegistrar;
      if (voip != null) unawaited(voip.bootstrap());
      // Sealed-sender capability negotiation: advertise that THIS device can
      // OPEN sealed envelopes so peers' senders are cleared to seal to it.
      // Best-effort + once per session; decoupled from our own send-enable
      // (sealed receive is always present in this build, even when sealed
      // sending is off). A failure (e.g. older server 404s) just allows a
      // retry on the next connect.
      if (!_sealCapabilityReported) {
        _sealCapabilityReported = true;
        unawaited(Future<void>(() async {
          // Carry our CURRENT sealing key, so a device whose local keypair was
          // regenerated (app reinstalled over the top, secure storage rebuilt)
          // republishes it here instead of staying unreachable forever. Peers
          // seal to the server's copy; if it's stale, nothing they send can
          // ever be opened and the receive path destroys it silently.
          final identity = await _crypto.currentIdentity();
          await _api.reportSealedCapability(
              x25519PubKey: identity?.x25519PublicKey ?? const []);
        }).catchError((_) {
          _sealCapabilityReported = false;
        }));
      }
      // Sealed-sender Phase 2: publish our UAK commitment so contacts can send
      // us sealed messages on the unauthenticated path. Best-effort + once per
      // session; gated by the feature flag. A failure allows a retry next connect.
      _sealedSender.reportCommitmentIfNeeded();
      // Pre-warm this account's own-device list so self-synced messages from a
      // sibling device render as `mine` even on a receive-only linked device.
      // Also adds any freshly-linked own device into already-migrated MLS 1:1
      // groups (it resets + repopulates the same cache).
      unawaited(_reconcileOwnDevicesIntoGroups());
      // Surface the OS notification-permission prompt on first sign-in. The
      // gate persists a flag so subsequent cold-starts don't re-spam the user;
      // they can re-enable from system settings if they previously declined.
      unawaited(_notificationPermissionGate.requestIfFirstTime());
    } finally {
      completer.complete();
      _connecting = null;
    }
  }

  void _onSupervisorStateChanged() {
    // Forward the supervisor's notifyListeners pulse so widgets watching
    // `connectionState` rebuild on transitions.
    notifyListeners();
  }

  /// Tears down the WebSocket. Leaves the DB open so a subsequent `connect`
  /// can reuse the hydrated state without paying re-load cost.
  Future<void> disconnect() async {
    await _pushRegistrar.dispose();
    await _voipPushRegistrar?.dispose();
    await _wsSub?.cancel();
    _wsSub = null;
    await _supervisorSub?.cancel();
    _supervisorSub = null;
    _supervisor.removeListener(_onSupervisorStateChanged);
    await _supervisor.stop();
    await _ws.disconnect();
    _api.setBearerToken(null);
    _connected = false;
    _disappearingSweepTimer?.cancel();
    _disappearingSweepTimer = null;
  }

  /// Non-destructive sign-out: tears down the live connection and raises the
  /// manual-sign-out gate, but leaves everything on disk — the SQLCipher
  /// database (chat history), the CoreCrypto/MLS + ratchet state, the device
  /// identity, the recovery phrase, and the session record all survive. The
  /// router redirects to /welcome, where [resumeAfterSignOut] brings the same
  /// device back online in one tap with conversations intact and the SAME
  /// device id (no fresh-device churn, no group re-add). For a true wipe use
  /// the settings "Erase this device" / "Delete account" paths instead.
  Future<void> signOutKeepingData() async {
    _manuallySignedOut = true;
    await _sessions.setSignedOut(true);
    await disconnect();
    notifyListeners();
  }

  /// Reverses [signOutKeepingData]: clears the gate, re-opens the CoreCrypto
  /// store for the persisted device, and reconnects. Conversations rehydrate
  /// from the still-present local DB inside [connect].
  Future<void> resumeAfterSignOut() async {
    _manuallySignedOut = false;
    await _sessions.setSignedOut(false);
    // Notify first so the router stops forcing /welcome before the caller
    // navigates to the chat list.
    notifyListeners();
    final session = await _sessions.current();
    if (session != null) {
      // Re-open the MLS store before the first chat-screen entry, mirroring the
      // cold-start boot path. Best-effort: ratchet messaging works without it.
      try {
        await _crypto.mlsInit();
        await _crypto.mlsEnsureClient(session.deviceId);
      } catch (e) {
        // ignore: avoid_print
        print('resume MLS init failed: $e — continuing without MLS');
      }
    }
    await connect();
  }

  /// Account-switch teardown: [disconnect] + [resetLocalDatabase] + drops
  /// every identity-scoped cache (in memory AND the account-scoped
  /// SecureStorage mirrors), so the next `connect()` builds the NEW
  /// account's session from scratch.
  ///
  /// Sign-out/delete-account MUST call this instead of bare
  /// [resetLocalDatabase]: without the disconnect, `_connected` stayed true
  /// so the next account's `connect()` no-oped — the shared ApiClient kept
  /// the PREVIOUS account's JWT and the WS stayed on its device socket, so
  /// the first sends after an account switch authenticated as (and showed
  /// up from) the old user until a full process restart.
  Future<void> resetForAccountSwitch() async {
    await disconnect();
    // The account is being switched out — drop the manual-sign-out gate so the
    // router stops force-redirecting to /welcome. Without this the in-memory
    // flag stays raised (the wipe only clears the on-disk gate), so the fresh
    // "Create account" / "I have a recovery phrase" buttons navigate and then
    // bounce straight back to /welcome until a process restart. The trailing
    // notifyListeners() in this method re-evaluates the router redirect.
    _manuallySignedOut = false;
    await resetLocalDatabase();
    // Identity-scoped in-memory caches resetLocalDatabase doesn't own.
    _deviceCache.clearMyDevices();
    _selfAccountId = null;
    _peerProfiles.clear();
    _deviceCache.clear();
    _sealCapabilityReported = false;
    _sealedSender.clear();
    _typingService.clear();
    _catchupFailureCounts.clear();
    // Account-scoped SecureStorage mirrors (read by the FCM background
    // isolate / device reconciliation) — stale values would leak the old
    // account's muted set and treat its device fleet as already known.
    try {
      await _secureStorage.delete(mutedConvosKey);
    } catch (_) {/* best-effort */}
    try {
      await _secureStorage.delete(blockedConvosKey);
    } catch (_) {/* best-effort */}
    try {
      await _secureStorage.delete(knownOwnDevicesKey);
    } catch (_) {/* best-effort */}
    try {
      await _secureStorage.delete(backfilledHistoryKey);
    } catch (_) {/* best-effort */}
    try {
      await _secureStorage.delete(ownDeviceAddedKey);
    } catch (_) {/* best-effort */}
    // Peer sealing keys mirrored for the bg delivered-receipt sender — would
    // otherwise leave the previous account's peers' x25519/UAK at rest.
    try {
      await clearPeerSealKeys(_secureStorage);
    } catch (_) {/* best-effort */}
    notifyListeners();
  }

  /// Wipes all persisted chat data. The DB rows are dropped but the file +
  /// master key remain — used by routine clear flows. For a full reset that
  /// also rotates the SQLCipher master key, call [resetLocalDatabase] after
  /// the JWT/identity teardown.
  Future<void> clearLocalData() async {
    await _db.clearAll();
    for (final id in _byId.keys.toList()) {
      _crypto.clearConversationCrypto(id);
    }
    _byId.clear();
    _deletedGroupIds.clear();
    _mediaCache.clear();
    _uploadWorker.clearPending();
    // Note: the UploadWorker culls its workers via `whenComplete` once
    // their stacks drain, so we don't await them here.
    // Sweep every staging file — there's no DB row left to reference them
    // and they would otherwise leak across sign-out.
    try {
      final staged = await _pendingUploadStaging.listStagedOutboxIds();
      for (final id in staged) {
        await _pendingUploadStaging.delete(id);
      }
    } catch (_) {/* best-effort */}
    // Sweep every decrypted-media temp file too — no message rows remain to
    // reference them and they'd otherwise outlive sign-out as plaintext.
    await _tempMediaStore.sweepAll();
    notifyListeners();
  }

  Future<void> _onSupervisorEvent(WsConnectionEvent ev) async {
    switch (ev) {
      case Reconnected():
        await _runCatchup();
        await replenishKeyPackagesIfNeeded();
        _reconfirmDeliveredReceipts();
        _reassertPrivacyFlags();
        _resumeFailedTextSends();
      case SignedOut():
        await clearLocalData();
    }
  }

  /// Re-drives every failed *text* message across all conversations after a
  /// (re)connect. A text send that died while Tor was still bootstrapping (or on
  /// a wedged socket) used to sit with a ✗ until the user manually tapped each
  /// one — media already auto-resumes ([_recoverStalledUploads] + the upload
  /// worker), but text had no equivalent, which is the dominant "I sent it but
  /// it never arrived until I retried" complaint. On every Reconnected we replay
  /// failed text rows through the normal submit path.
  ///
  /// Scope guards keep this from double-sending: only rows already marked
  /// `failed` are touched (an in-flight/slow send is `pending`, never `failed`,
  /// so it's left alone), and [retryTextMessage] re-checks the flag. Each retry
  /// takes the per-conversation lock, so intra-conversation order is preserved;
  /// fire-and-forget across conversations so one slow send can't stall the rest.
  /// If a send fails again it re-marks failed and retries on the next reconnect
  /// (bounded to reconnect cadence, not a tight loop). This mirrors the parity
  /// of the existing manual ✗-tap retry, including its rare lost-ack case.
  void _resumeFailedTextSends() {
    for (final convo in _byId.values.toList()) {
      for (final m in convo.messages) {
        if (!m.failed || m.kind != MessageKind.text) continue;
        final outboxId = m.outboxId;
        if (outboxId == null) continue;
        final conversationId = convo.id;
        unawaited(
          Future(() => retryTextMessage(
                conversationId: conversationId,
                outboxId: outboxId,
              )).catchError((_) => false),
        );
      }
    }
  }

  /// Called on app foreground (via [AppLifecycleObserver]) and after every
  /// WS reconnect. Reads the server's count of unconsumed KeyPackages for the
  /// current user. If below the low-water mark (10), mints + publishes a
  /// refill batch (50) so peers' future add-to-group attempts don't 410 on us.
  ///
  /// Failure modes are non-fatal — the next foreground/reconnect retries.
  /// Spec §6.5: low-water = 10, refill batch = 50.
  Future<void> replenishKeyPackagesIfNeeded() =>
      _keyPackageReplenisher.replenishIfNeeded();

  /// Per-envelope catchup failure counter (poison-pill guard). A non-transient
  /// envelope — e.g. a Welcome for a group CoreCrypto can't process — would
  /// otherwise stay unacked and re-deliver on every catchup forever. After
  /// [_maxCatchupFailures] attempts we ack+drop it. In-memory: resets on
  /// restart, which is fine — it only needs to bound the within-session loop.
  final Map<String, int> _catchupFailureCounts = {};
  static const int _maxCatchupFailures = 5;

  /// How many envelopes to ask for per catchup page. Must not exceed the
  /// server's own cap (`delivery.maxCatchupLimit`, 500) — and matching its
  /// DEFAULT keeps the "a short page is the last page" test exact.
  static const int _catchupPageSize = 200;

  /// Safety bound on pages per catchup run: 25 × 200 = 5000 envelopes. The real
  /// terminator is "a short page" or "nothing new came back"; this only stops a
  /// pathological server response from looping forever.
  static const int _maxCatchupPages = 25;

  /// Envelope ids in the current (re)connect catchup batch. [MessageAppender]
  /// consults this (via the `isCatchupEnvelope` closure) to SKIP raising a
  /// notification for backlog messages — those were already covered by the FCM
  /// wakeup while the app was offline, so re-notifying them on reconnect is the
  /// "tapped the push, app reconnected, got pinged again" duplicate. Only
  /// genuinely live socket pushes (id NOT in this set) notify. Populated for the
  /// duration of [_runCatchup]'s drain and emptied afterwards.
  final Set<String> _catchupEnvelopeIds = {};

  /// Guards against two [_runCatchup] passes overlapping — the supervisor's
  /// `Reconnected`, an app-resume, the manual Retry, and the failure-retry timer
  /// can all drive it.
  bool _catchupRunning = false;

  /// Backoff retry for the INITIAL catchup. Catchup otherwise re-runs only on a
  /// `Reconnected` event, so a one-off failure (Tor blip, server hiccup) while
  /// the socket then stays up would leave [_initialCatchupDone] false forever —
  /// and a deep-linked, not-yet-persisted conversation stuck on the loader. So
  /// while connected-but-unsettled we keep retrying until catchup succeeds.
  Timer? _catchupRetryTimer;
  int _catchupRetryAttempt = 0;

  /// Re-runs the initial catchup when the socket is up but the gate hasn't
  /// settled — e.g. this connection's one catchup attempt failed and there's
  /// been no reconnect since. Drives a reconnect instead when not connected.
  /// Safe to call repeatedly (no-op once settled or while one is running); used
  /// on app resume and by the thread screen's manual Retry.
  Future<void> catchUpIfNeeded() async {
    if (_initialCatchupDone) return;
    if (connectionState != ConnectionState.connected) {
      // Offline / mid-backoff: kick the supervisor so its next Reconnected
      // runs catchup, rather than waiting out the backoff window.
      _supervisor.forceReconnect(source: 'catchup-needed');
      return;
    }
    await _runCatchup();
  }

  void _scheduleCatchupRetry() {
    if (_initialCatchupDone) return;
    if (!_connected) return;
    if (_catchupRetryTimer != null) return; // one in flight already
    final n = _catchupRetryAttempt.clamp(0, 4);
    _catchupRetryAttempt = n + 1;
    final secs = 1 << n; // 1, 2, 4, 8, 16
    _catchupRetryTimer = Timer(Duration(seconds: secs), () {
      _catchupRetryTimer = null;
      if (_initialCatchupDone) return;
      if (connectionState != ConnectionState.connected) return;
      unawaited(_runCatchup());
    });
  }

  Future<void> _runCatchup() async {
    if (_catchupRunning) return;
    _catchupRunning = true;
    try {
      // Timing. The server serves a page in single-digit ms, so a slow catchup
      // is always local — but "local" spans the native CoreCrypto round trip
      // and the SQLCipher writes, which need different fixes. Split the clock
      // so the next optimisation targets whichever actually dominates.
      //
      // [drainClock] starts HERE, above the reconcile gate, so `total` is the
      // true wall clock of a catchup from trigger to settled. It used to start
      // below the gate, which hid gate time entirely — and now that the first
      // fetch overlaps the gate, a clock started after it could report a
      // `fetch` longer than the `total` supposedly containing it.
      final drainClock = Stopwatch()..start();
      var fetchMicros = 0;
      var processMicros = 0;
      var pagesFetched = 0;
      var slowestMicros = 0;
      var slowestType = '';
      final failuresAtStart = _retryLog.failuresRecorded;
      // Kick the FIRST page fetch off BEFORE awaiting the reconcile gate, so
      // the network leg overlaps reconcile instead of queueing behind it. Only
      // PROCESSING needs reconcile to have landed — that is what keeps a
      // freshly-reconciled group's envelopes decryptable — while the fetch
      // itself needs nothing but the socket. Serialising it after the gate
      // spent the whole round trip idle: measured 268–941ms of dead time on
      // every cold start of a Pixel 10, and considerably more over Tor.
      //
      // Deliberately NOT hoisted any earlier (e.g. to where connect() sets the
      // bearer token): [_fetchCatchupPage] prefers the live socket and only
      // falls back to HTTP, and every caller of this method already runs with
      // the socket up. Starting before the handshake would silently take the
      // HTTP path and undo the socket-drain win rather than add to it.
      //
      // A fetch is a pure READ that consumes nothing server-side, so a page we
      // end up discarding costs one round trip and never a message.
      final firstFetchClock = Stopwatch()..start();
      Future<List<wire.Envelope>>? pending = _fetchCatchupPage();
      // Attach a handler the moment it starts: if this fails while we are still
      // inside the gate await below, a future with no listener is reported as an
      // unhandled async error. The real error still surfaces on `await pending`.
      unawaited(pending.then((_) {}, onError: (_) {}));
      // Wait for this connection's initial MLS reconcile to land before draining
      // backlog, so catchup envelopes that reference freshly-reconciled groups
      // decrypt instead of counting toward the poison-pill guard. connect() now
      // runs reconcile concurrently with the WS handshake (see [connect]), so
      // this gate — not send-path ordering — is what preserves decrypt order.
      // Bounded so a stuck reconcile can't wedge catchup: after the timeout we
      // drain anyway and any still-un-reconciled group just retries next pass.
      final gate = _mlsReconcileGate;
      if (gate != null && !gate.isCompleted) {
        try {
          await gate.future.timeout(const Duration(seconds: 20));
        } catch (_) {/* proceed; reconcile is best-effort for catchup */}
      }
      // No `since` cursor: the server already returns only UNACKED, unexpired
      // envelopes (acked_at IS NULL AND expires_at > now), newest-window
      // bounded by its own LIMIT. A client-side time floor here would silently
      // drop any envelope a recipient missed while offline longer than that
      // floor — they'd sit unacked on the server until expiry, never
      // delivered. Successful envelopes are acked inside _onEnvelope, so they
      // drop out of subsequent catchups on their own.
      //
      // PAGED. The server caps one response at [_catchupPageSize]; this used to
      // fetch exactly one page and stop, so a device returning from a long
      // absence drained 200 envelopes and then waited for the next RECONNECT to
      // see the rest — several long "Catching up…" rounds for one backlog, with
      // everything past the first page simply absent in between. Now one run
      // drains until a short page (or nothing new) comes back.
      var failedCount = 0;
      String firstError = '';
      var totalDrained = 0;
      // Envelope ids handled in THIS run. An envelope that fails stays unacked,
      // so the server hands it back on the very next page — without this the
      // loop would re-drain the same failures until the page cap and, worse,
      // re-count their decrypt-failure streaks (which drive MLS
      // re-establishment).
      final drainedIds = <String>{};
      _drainAckedIds = <String>{};
      for (var page = 0; page < _maxCatchupPages; page++) {
        final List<wire.Envelope> envs;
        if (pending != null) {
          // The page that has been in flight since before the gate.
          envs = await pending;
          firstFetchClock.stop();
          fetchMicros += firstFetchClock.elapsedMicroseconds;
          pending = null;
        } else {
          final fetchClock = Stopwatch()..start();
          envs = await _fetchCatchupPage();
          fetchClock.stop();
          fetchMicros += fetchClock.elapsedMicroseconds;
        }
        pagesFetched++;
        if (envs.isEmpty) break;
        // Only NOW is there known backlog. Publishing the count here, rather
        // than letting the UI assume backlog from the moment connect() starts,
        // is what keeps the "Catching up…" veil off the screen in the common
        // case where there is nothing to catch up on. See [catchupBacklog].
        _catchupBacklog += envs.length;
        notifyListeners();
        final fresh =
            envs.where((e) => drainedIds.add(e.envelopeId)).toList();
        if (fresh.isEmpty) break; // only already-handled (failing) envelopes left
        totalDrained += fresh.length;
        // Tag this batch as backlog for the duration of the drain so the
        // appender doesn't raise a (duplicate) notification per catchup message
        // — see [_catchupEnvelopeIds]. Cleared in the finally so live pushes
        // after the drain notify normally.
        _catchupEnvelopeIds.addAll(fresh.map((e) => e.envelopeId));
        try {
          // Coalesce the appender's per-message host pulses into ONE rebuild at
          // the end of the drain. Each envelope otherwise fires notifyHost() →
          // a full chat-list + thread rebuild; a large backlog turned that into
          // an O(K) rebuild storm. Data still lands live (setConversation); the
          // listener pulse is deferred, though a LONG batch still flushes on a
          // slow cadence so the thread fills in as it drains.
          //
          // A handler that HANGS (a native crypto call that never returns —
          // observed live: a poisoned MLS group wedged decrypt forever) would
          // otherwise stall this sequential drain at that envelope for the rest
          // of the session: _catchupRunning stays true, so no catchup ever runs
          // again and NOTHING acks — every conversation goes silent, not just
          // the poisoned one. Bound each envelope and skip the rest of a wedged
          // conversation's envelopes for this drain (they'd only queue behind
          // the stuck handler's convo lock). The skipped envelopes stay unacked
          // and retry next catchup.
          final wedgedConvos = <String>{};
          await _batchNotifications(() async {
            for (final env in fresh) {
              if (wedgedConvos.contains(env.conversationId)) {
                // ignore: avoid_print
                print('catchup: skipping envelope ${env.envelopeId} '
                    '(${env.envelopeType}) — conversation ${env.conversationId} '
                    'wedged earlier in this drain');
                continue;
              }
              // Per-envelope isolation: one poisoned envelope must not abort the
              // rest of the batch — it stays unacked and retries next catchup,
              // while later envelopes still process.
              final envClock = Stopwatch()..start();
              try {
                await _onEnvelope(env).timeout(const Duration(seconds: 90));
                _catchupFailureCounts.remove(env.envelopeId);
              } on TimeoutException {
                wedgedConvos.add(env.conversationId);
                // ignore: avoid_print
                print('catchup: envelope ${env.envelopeId} (${env.envelopeType}) '
                    'on ${env.conversationId} HUNG >90s; abandoning it and '
                    'skipping its conversation for this drain');
              } catch (e) {
                failedCount++;
                // First failure only: later ones are usually the same cause, and
                // the banner has room for one line.
                if (firstError.isEmpty) firstError = '${env.envelopeType}: $e';
                final n = (_catchupFailureCounts[env.envelopeId] ?? 0) + 1;
                if (n >= _maxCatchupFailures) {
                  // Poison pill: ack+drop so it stops re-delivering forever. A
                  // genuinely-needed group re-establishes via a later
                  // send/Welcome.
                  _catchupFailureCounts.remove(env.envelopeId);
                  // ignore: avoid_print
                  print('catchup: envelope ${env.envelopeId} '
                      '(${env.envelopeType}) failed $n×; ack+dropping as a '
                      'poison pill: $e');
                  try {
                    await ack([env.envelopeId]);
                  } catch (_) {/* best-effort */}
                } else {
                  _catchupFailureCounts[env.envelopeId] = n;
                  // ignore: avoid_print
                  print('catchup: envelope ${env.envelopeId} '
                      '(${env.envelopeType}) failed (attempt $n): $e — '
                      'left unacked');
                }
              } finally {
                envClock.stop();
                processMicros += envClock.elapsedMicroseconds;
                // Track the single worst envelope: one pathological item (a
                // wedged group, an outsized media record) can dominate a drain
                // and an average would hide it entirely.
                if (envClock.elapsedMicroseconds > slowestMicros) {
                  slowestMicros = envClock.elapsedMicroseconds;
                  slowestType = env.envelopeType;
                }
              }
            }
          });
        } finally {
          // Backlog drained (or aborted) — stop treating these ids as catchup so
          // a later live push for the same conversation notifies normally.
          _catchupEnvelopeIds.removeAll(fresh.map((e) => e.envelopeId));
        }
        // BACKSTOP: whatever this page fetched but did NOT ack is coming back
        // on the next drain. Several receive paths deliberately leave an
        // envelope unacked so a later redelivery can succeed once state is
        // repaired — correct while repair is still possible, an infinite loop
        // when it never will be. Each of those sites had its own (or no) bound,
        // so this counts the SYMPTOM at the one place it is observable —
        // "fetched again and still not consumed" — and catches every path,
        // including ones added later.
        //
        // Measured on-device 2026-08-22: 24 envelopes survived six launches
        // under three separately-bounded paths, because they were taking a
        // fourth. Whack-a-mole per drop site does not converge; this does.
        final unconsumed = fresh
            .map((e) => e.envelopeId)
            .where((id) => !(_drainAckedIds?.contains(id) ?? false))
            .toList(growable: false);
        for (final id in unconsumed) {
          if (await _retryLog.recordFailure(id) >= _maxUnconsumedRedeliveries) {
            await _retryLog.forget(id);
            // ignore: avoid_print
            print('catchup: envelope $id fetched $_maxUnconsumedRedeliveries× '
                'without ever being consumed; ack+dropping');
            try {
              await ack([id]);
            } catch (_) {/* best-effort */}
          }
        }
        // A short page is the last page.
        if (envs.length < _catchupPageSize) break;
      }
      // Publish the drain's outcome. Set even when clean (to empty), so a
      // drain that recovers clears a stale banner.
      _catchupDiagnostic =
          failedCount == 0 ? '' : '$failedCount/$totalDrained failed: $firstError';
      drainClock.stop();
      _catchupTiming = CatchupTiming(
        envelopes: totalDrained,
        pages: pagesFetched,
        fetch: Duration(microseconds: fetchMicros),
        process: Duration(microseconds: processMicros),
        total: drainClock.elapsed,
        slowest: Duration(microseconds: slowestMicros),
        slowestType: slowestType,
        // Failures the RECEIVERS swallowed. Without this a drain that
        // re-failed every envelope reported a clean run.
        silentFailures: _retryLog.failuresRecorded - failuresAtStart,
      );
      notifyListeners();
      // A successful catchup means any conversation we were going to receive
      // (including a pushed brand-new one) has now been delivered + persisted.
      // Flip the gate so a still-null conversation reads as genuinely absent
      // rather than "loading" — and pulse listeners so a thread parked on the
      // loader settles to its empty state. Only the first flip needs the pulse.
      if (!_initialCatchupDone) {
        _initialCatchupDone = true;
        notifyListeners();
      }
      // Settled — drop any pending failure-retry.
      _catchupRetryTimer?.cancel();
      _catchupRetryTimer = null;
      _catchupRetryAttempt = 0;
    } catch (_) {
      // Catchup is best-effort. The cursor isn't advanced on failure, so the
      // same range is retried. We deliberately leave `_initialCatchupDone`
      // unset: nothing was delivered, so a null conversation must keep loading
      // until a retry succeeds. Schedule that retry here (with backoff) so a
      // one-off failure on an otherwise-stable socket still converges to a
      // settled gate, instead of waiting for a reconnect that may never come.
      _scheduleCatchupRetry();
    } finally {
      _catchupRunning = false;
      _drainAckedIds = null;
      // This drain is over either way — a count that outlived it would keep the
      // veil up over a list nothing is still rearranging. On the failure path
      // [_initialCatchupDone] stays false on purpose, so this is the only thing
      // that takes the affordance back down until the retry finds real backlog.
      if (_catchupBacklog != 0) {
        _catchupBacklog = 0;
        notifyListeners();
      }
    }
  }

  /// Per-conversation cap on how many recent inbound messages we re-confirm as
  /// delivered on each reconnect — bounds control traffic to the loaded window.
  static const int _deliveredReconfirmLimit = 50;

  /// Heals "delivered" receipts lost on a flaky connection. The receipt fired
  /// at receive time ([MessageAppender.append]) is best-effort + unawaited, so
  /// if the socket was unstable — e.g. during the catchup right after the
  /// recipient foregrounds — it can be dropped, leaving the SENDER stuck on a
  /// single ✓ forever (the envelope is already acked, so it never re-delivers
  /// to re-trigger the receipt). Receipts are idempotent + monotonic on the
  /// sender, so after each (re)connect we simply re-send a `delivered` receipt
  /// for the recent inbound (peer) messages of every 1:1: a lost ✓✓ heals, an
  /// already-delivered/read one is a no-op. Fire-and-forget per conversation so
  /// one slow send can't stall the rest. Runs OUTSIDE any conversation lock
  /// (called from the supervisor-event handler after catchup), so sendControl —
  /// which re-acquires the convo lock — is safe.
  void _reconfirmDeliveredReceipts() {
    for (final convo in _byId.values.toList()) {
      if (convo.kind != ConversationKind.oneToOne || convo.blocked) continue;
      final eids = <String>[];
      for (final m in convo.messages.reversed) {
        if (eids.length >= _deliveredReconfirmLimit) break;
        if (m.mine || m.kind == MessageKind.system) continue;
        eids.add(m.envelopeId);
      }
      if (eids.isEmpty) continue;
      unawaited(Future(() async {
        try {
          await _controlSender.sendControl(
            convo.id,
            MessageControl.receipt(ReceiptKind.delivered, eids).encode(),
          );
        } catch (_) {/* best-effort; next reconnect retries */}
      }));
    }
  }

  /// Re-asserts the user's conversation-privacy flags to every 1:1 on each
  /// (re)connect, so a peer that missed the live [broadcastPrivacyFlags] toggle
  /// (offline at the time, with no new message carrying the [PrivacyHeader]
  /// since) converges instead of lagging — the gap that let a peer keep
  /// forwarding/screenshotting after the user enabled blocking. Only fired when
  /// a flag is ON: OFF is the default a peer assumes for an unseen flag, so
  /// re-asserting it every reconnect would send a control to every 1:1 for users
  /// who never touched the feature. (Toggling OFF still propagates immediately
  /// via the live broadcast; an OFF that a peer misses self-heals the next time
  /// the user enables and disables, the cost of which is a peer over-restricting
  /// — never under-restricting, the safe direction.) Fire-and-forget; runs
  /// outside any conversation lock (called from the supervisor-event handler).
  void _reassertPrivacyFlags() {
    final flags = _privacyFlagsProvider?.call();
    if (flags == null || !(flags.screenshots || flags.forwarding)) return;
    unawaited(broadcastPrivacyFlags(
      screenshots: flags.screenshots,
      forwarding: flags.forwarding,
    ));
  }

  /// Full local reset: deletes the SQLCipher file, removes the master key
  /// from `SecureStorage`, and resets the in-memory hydration flag so the
  /// next `connect()` opens a freshly-encrypted DB. Called by settings
  /// delete-account so a phone-sharer can never decrypt the previous user's
  /// data even with raw filesystem access.
  Future<void> resetLocalDatabase() async {
    await _db.deleteFile();
    await _secureStorage.delete(dbMasterKeyKey);
    for (final id in _byId.keys.toList()) {
      _crypto.clearConversationCrypto(id);
    }
    _byId.clear();
    _deletedGroupIds.clear();
    _mediaCache.clear();
    _uploadWorker.clearPending();
    try {
      final staged = await _pendingUploadStaging.listStagedOutboxIds();
      for (final id in staged) {
        await _pendingUploadStaging.delete(id);
      }
    } catch (_) {/* best-effort */}
    // Sweep every decrypted-media temp file too — see [clearLocalData].
    await _tempMediaStore.sweepAll();
    _hydrated = false;
    notifyListeners();
  }

  /// Looks up a username on the server and creates (or surfaces) a 1:1
  /// conversation. Returns the conversation id so the caller can navigate.
  /// Caches a peer's display name + avatar descriptor from a looked-up account.
  void _recordPeerDisplayName(Account account) {
    _peerProfiles.record(account);
    if (account.devices.isNotEmpty) {
      _deviceCache.setPeerDevices(account.accountId, account.devices);
    }
  }

  /// The peer's avatar descriptor for a 1:1 conversation (encrypted media), or
  /// null when they haven't set one. The UI decrypts + renders it via
  /// [AvatarImage]; falls back to initials otherwise.
  MediaDescriptor? peerAvatarDescriptor(Conversation c) =>
      _peerProfiles.avatarDescriptor(c);

  /// The name to render for a conversation: a group's name, else the peer's
  /// cached display name, else their `@username`.
  String displayNameFor(Conversation c) => _peerProfiles.displayNameFor(c);

  /// Refreshes the peer's display name for a 1:1 conversation by re-looking up
  /// their account. Called when a thread opens so the name stays current.
  /// Best-effort: network failures are swallowed.
  Future<void> refreshPeerProfile(String conversationId) async {
    final convo = _byId[conversationId];
    if (convo == null || convo.kind != ConversationKind.oneToOne) return;
    if (convo.peerUsername.isEmpty) return;
    try {
      final account = await _api.lookupAccount(convo.peerUsername);
      final beforeName = _peerProfiles.nameOf(account.accountId);
      final beforeAvatar = _peerProfiles.avatarMediaIdOf(account.accountId);
      _recordPeerDisplayName(account);
      // Backfill the peer's identity key if we never captured it. Some 1:1s are
      // created key-less (inbound placeholder, MLS-receive, group) and nothing
      // else fills it, so the safety number could never compute. Only fill when
      // EMPTY — a key *change* goes through the dedicated identity-change path
      // (which also resets `verified`), never here.
      var keyFilled = false;
      if (convo.peerIdentityPubKey.isEmpty && account.identityPubKey.isNotEmpty) {
        final filled = convo.copyWith(peerIdentityPubKey: account.identityPubKey);
        _byId[conversationId] = filled;
        await _db.upsertConversation(filled);
        keyFilled = true;
      }
      final changed = keyFilled ||
          _peerProfiles.nameOf(account.accountId) != beforeName ||
          _peerProfiles.avatarMediaIdOf(account.accountId) != beforeAvatar;
      if (changed) notifyListeners();
    } catch (_) {/* keep the cached/username fallback */}
  }

  /// True when the 1:1 peer is currently typing in [conversationId].
  /// Delegates to [TypingService].
  bool isPeerTyping(String conversationId) =>
      _typingService.isPeerTyping(conversationId);

  /// Sends a typing signal to the 1:1 peer. Delegates to [TypingService].
  void sendTyping(String conversationId, bool isTyping) =>
      _typingService.sendTyping(conversationId, isTyping);

  Future<String> startConversation({
    required String myDeviceId,
    required String username,
  }) async {
    final account = await _api.lookupAccount(username);
    _recordPeerDisplayName(account);
    // The 1:1 conversation ID must be derived from both *account* IDs so that
    // both participants compute the same ID (device IDs differ per side, so a
    // device-based ID never matches across devices — inbound envelopes would
    // land as "unknown peer" placeholders forever). Use our account ID from
    // the session; fall back to the passed device ID only if no session.
    final myAccountId = (await _sessions.current())?.accountId ?? myDeviceId;
    final convoId = Conversation.oneToOneId(myAccountId, account.accountId);
    // Create when absent, OR upgrade an "unknown peer" placeholder (one created
    // by an inbound envelope that arrived before we knew the peer — it carries
    // no account id or keys). Upgrading drops the undecryptable stub messages;
    // the originating envelope was never acked, so the next /messages/catchup
    // re-delivers it and it now decrypts against the real, seeded conversation.
    final existing = _byId[convoId];
    final isPlaceholder = existing != null && existing.peerAccountId.isEmpty;
    if (existing == null || isPlaceholder) {
      final convo = Conversation(
        id: convoId,
        peerUsername: account.username,
        peerAccountId: account.accountId,
        // Address the peer's real device. The server routes envelopes by
        // recipient_device_id, so using the account id here (the old v1
        // placeholder) meant messages were never delivered. The account
        // lookup now returns the peer's primary device_id; fall back to the
        // account id only for an older server that doesn't send one.
        peerDeviceId: account.deviceId ?? account.accountId,
        peerIdentityPubKey: account.identityPubKey,
        peerX25519PubKey: account.x25519PubKey,
        messages: const [],
        unreadCount: 0,
      );
      _byId[convoId] = convo;
      await _db.upsertConversation(convo);

      // Seed the per-conversation ratchet state. Only possible once we know
      // the peer's X25519 pub key (legacy peers without it can't be used).
      if (account.x25519PubKey.isNotEmpty) {
        final initialState = await _crypto.initConversationCrypto(
          conversationId: convoId,
          peerX25519PubKey: account.x25519PubKey,
        );
        await _db.saveConversationCryptoState(initialState);
      }
      notifyListeners();
    } else if (existing.pending) {
      // The peer already messaged us (pending request) and now the user is
      // deliberately starting a chat with them — that's an implicit accept.
      await acceptMessageRequest(convoId);
    }
    return convoId;
  }

  /// Accepts a message request: the conversation becomes a normal chat and
  /// the composer unlocks. The decision self-syncs to our other devices so a
  /// linked device clears its pending banner too — but the PEER is never told
  /// (acceptance stays private). No-op self-sync on a single-device account.
  Future<void> acceptMessageRequest(String conversationId) =>
      _requestDecisions.acceptMessageRequest(conversationId);

  /// Rejects a message request: local-only deletion (the sender is not
  /// notified), but the decision self-syncs to our other devices FIRST (while
  /// the group state still exists to encrypt with) so a linked device drops the
  /// conversation too. If the same sender messages again, a fresh request
  /// re-appears via auto-resolve.
  Future<void> rejectMessageRequest(String conversationId) =>
      _requestDecisions.rejectMessageRequest(conversationId);

  /// Accepts a group invitation (a `pending` group conversation born from a
  /// Welcome someone else sent): unlocks the conversation by clearing `pending`
  /// and self-syncs the decision to our own other devices so a sibling that got
  /// the same Welcome clears its banner too. The group is NOT told — acceptance
  /// stays private, exactly like a 1:1 message request. No-op on a non-pending
  /// or unknown conversation.
  Future<void> acceptGroupInvite(String conversationId) =>
      _requestDecisions.acceptGroupInvite(conversationId);

  /// Rejects a group invitation by LEAVING the group properly: self-syncs the
  /// decision FIRST (while we're still a member able to encrypt to our own
  /// devices), then removes our account from the MLS group — which fans a
  /// removal Commit to the other members and deletes the conversation locally.
  /// A sibling device that got the same Welcome drops its copy via the
  /// self-synced decision. If the roster hasn't landed yet (rejected the instant
  /// the invite arrived) we can't address a leave Commit, so we fall back to a
  /// local-only delete.
  Future<void> rejectGroupInvite(String conversationId) =>
      _requestDecisions.rejectGroupInvite(conversationId);

  /// Sets the pinned flag (sorts the conversation to the top of the list).
  /// Local-only preference. No-op if the conversation is gone.
  /// Sets (descriptor JSON) or clears (null) a group's photo; admin-only on the
  /// receiving side. See [GroupAvatarService].
  Future<void> setGroupAvatar(String conversationId, String? descriptorJson) =>
      _groupAvatarService.setAvatar(conversationId, descriptorJson);

  Future<void> setPinned(String conversationId, bool pinned) =>
      _stateSync.setPinned(conversationId, pinned);

  /// Mute/unmute. Delegates to [ConversationSettingsService].
  Future<void> setMuted(String conversationId, bool muted) =>
      _stateSync.setMuted(conversationId, muted);

  /// Set the per-conversation disappearing-messages override. Delegates to
  /// [ConversationSettingsService].
  Future<void> setDisappearingTtl(String conversationId, int ttlSeconds) =>
      _stateSync.setDisappearingTtl(conversationId, ttlSeconds);

  int disappearingTtlOf(String conversationId) =>
      _settings.disappearingTtlOf(conversationId);

  /// Archive/unarchive. Delegates to [ConversationSettingsService].
  Future<void> setArchived(String conversationId, bool archived) =>
      _stateSync.setArchived(conversationId, archived);

  /// Block/unblock a contact. Delegates to [ConversationSettingsService].
  @override
  Future<void> setBlocked(String conversationId, bool blocked) =>
      _stateSync.setBlocked(conversationId, blocked);

  bool isBlocked(String conversationId) => _settings.isBlocked(conversationId);

  /// This chat's background override (use-default when none). Synchronous once
  /// hydrated; the thread screen resolves `override ?? global default`.
  ChatBackgroundOverride backgroundOverrideOf(String conversationId) =>
      _stateSync.backgroundOverrideOf(conversationId);

  /// Sets this chat's background override. A preset / 'default' syncs to the
  /// account's other devices; a custom photo stays on this device.
  Future<void> setBackgroundOverride(
          String conversationId, ChatBackgroundOverride value) =>
      _stateSync.setBackgroundOverride(conversationId, value);

  /// User-facing delete from the chat list: a 1:1 is also deleted on the
  /// account's other devices (own devices only, nothing to the peer); a group
  /// takes the normal leave path.
  Future<void> deleteConversationEverywhere(String conversationId) =>
      _conversationDeleteSync.deleteAndSync(conversationId);

  /// Reports [conversationId]'s peer for abuse: forwards the peer's recent
  /// messages to the server moderation queue (with [reason] + optional [note])
  /// via [ReportService], then blocks the contact locally unless [alsoBlock] is
  /// false (blocking reuses [setBlocked]). No-op if the conversation is gone.
  Future<void> reportUser(
    String conversationId, {
    required ReportReason reason,
    String? note,
    bool alsoBlock = true,
  }) async {
    final convo = _byId[conversationId];
    if (convo == null) return;
    await _reportService.reportConversation(
      convo: convo,
      reason: reason,
      note: note,
    );
    if (alsoBlock) await setBlocked(conversationId, true);
  }

  /// Mirrors a map of 1:1 conversationId -> peer display name into SecureStorage
  /// so the FCM background isolate (no DB access) can show the CALLER's name on
  /// the incoming-call ring — the wake push is content-blind. 1:1 only; groups
  /// don't place calls. Best-effort; called after hydration, then kept current
  /// by [notifyListeners].
  Future<void> _persistCallPeerNames() async {
    final names = _callPeerNames();
    _lastPersistedCallPeerNames = names;
    try {
      await _secureStorage.putString(callPeerNamesKey, jsonEncode(names));
    } catch (_) {/* best-effort */}
  }

  Map<String, String> _callPeerNames() {
    final names = <String, String>{};
    for (final c in _byId.values) {
      if (!c.id.startsWith('1to1:')) continue;
      final name = displayNameFor(c);
      if (name.isNotEmpty) names[c.id] = name;
    }
    return names;
  }

  /// What [_persistCallPeerNames] last wrote, so the per-pulse check below only
  /// touches SecureStorage when a name actually changed.
  Map<String, String> _lastPersistedCallPeerNames = const {};

  /// The mirror was written only at hydration, so a contact started, accepted
  /// or renamed in this session rang as "Unknown" while the app was in the
  /// background (seen on-device 2026-10-21) until the next cold start. Every
  /// state change already funnels through here, so re-check it on each pulse.
  @override
  void notifyListeners() {
    super.notifyListeners();
    if (!_hydrated) return;
    final names = _callPeerNames();
    if (mapEquals(names, _lastPersistedCallPeerNames)) return;
    unawaited(_persistCallPeerNames());
  }

  /// True if the conversation is muted — checked before surfacing a local
  /// notification for an inbound message. Delegates to
  /// [ConversationSettingsService].
  bool isMuted(String conversationId) => _settings.isMuted(conversationId);

  /// Deletes a conversation locally: the row, its messages, media caches and
  /// ratchet crypto state.
  ///
  /// For a 1:1 there is no wire traffic — the peer keeps their copy and can
  /// message again (which re-creates the conversation, as a pending request
  /// when we never contacted them).
  ///
  /// For a GROUP, deleting is leaving: we fan a removal Commit for every one of
  /// our own device leaves to the rest of the roster first (see
  /// [_emitSelfLeaveCommits]) so peers and the group's MLS state stop treating
  /// this account as a member. Without it the delete was purely cosmetic —
  /// everyone kept addressing us and the chat kept coming back. The group id is
  /// then tombstoned so envelopes already queued server-side (which we can no
  /// longer decrypt) are dropped rather than resurrecting it.
  ///
  /// [emitLeaveCommits] false is used ONLY when an admin has disbanded the group
  /// ([disbandGroupLocally]): the group no longer exists for anyone, so leave
  /// commits would be pointless spam. Everything else (wipe, tombstone) is the same.
  @override
  Future<void> deleteConversation(String conversationId,
      {bool emitLeaveCommits = true}) async {
    final convo = _byId.remove(conversationId);
    if (convo == null) return;
    _siblingDeferredAt.remove(conversationId);
    if (convo.kind == ConversationKind.group) {
      // BEFORE the wipe below — producing Commits needs the live MLS group.
      if (emitLeaveCommits) await _emitSelfLeaveCommits(convo);
      _deletedGroupIds.add(conversationId);
      try {
        await _db.markGroupDeleted(conversationId);
      } catch (_) {/* best-effort; the in-memory gate still holds this run */}
    }
    for (final m in convo.messages) {
      _mediaCache.evict(m.envelopeId);
      _mediaCache.evictThumbnail(m.envelopeId);
      await _purgeMessageArtifacts(m);
    }
    _crypto.clearConversationCrypto(conversationId);
    // Wipe the MLS group too. Without this, CoreCrypto keeps the now-orphaned
    // group after the conversation is gone — it leaks state and, because a
    // 1:1's id is deterministic from the two account ids, landmines any future
    // chat with the same peer (re-creation collides with the stale group and
    // can't re-establish). Best-effort; a no-op for ratchet-only 1:1s.
    if (convo.cryptoMode == CryptoMode.mls ||
        convo.kind == ConversationKind.group) {
      try {
        await _crypto.wipeGroup(conversationId);
      } catch (_) {/* no local group existed */}
    }
    try {
      await _db.deleteConversationCryptoState(conversationId);
    } catch (_) {/* best-effort */}
    await _db.deleteConversation(conversationId);
    unawaited(_stateSync.forget(conversationId));
    notifyListeners();
  }

  /// Clears a conversation's local message history WITHOUT deleting the
  /// conversation, contact, or (for groups) membership and MLS state — backs
  /// "Clear chat history". Local only: no wire traffic, the peer keeps their
  /// copy, and new messages keep arriving in the same thread. Media/thumbnail
  /// caches for the wiped messages are evicted; crypto state is left intact so
  /// the chat keeps working.
  Future<void> clearMessages(String conversationId) async {
    final convo = _byId[conversationId];
    if (convo == null) return;
    final clearedUpTo = _stateSync.newestMessageMs(convo);
    for (final m in convo.messages) {
      _mediaCache.evict(m.envelopeId);
      _mediaCache.evictThumbnail(m.envelopeId);
      await _purgeMessageArtifacts(m);
    }
    await _db.clearMessagesForConversation(conversationId);
    final cleared = convo.copyWith(
      messages: const [],
      unreadCount: 0,
      hasMoreOlderMessages: false,
    );
    _byId[conversationId] = cleared;
    // Persist the convo row too so the cleared unread count survives a reload.
    await _db.upsertConversation(cleared);
    notifyListeners();
    // Tell our other devices (watermark, best-effort; never re-broadcast on apply).
    if (clearedUpTo != null) {
      unawaited(_stateSync.noteCleared(conversationId, clearedUpTo));
    }
  }

  /// Reclaims a single message's off-DB artifacts when it's removed in bulk
  /// (clear chat / delete conversation): its decrypted temp-media copies (an
  /// opened attachment or viewed video the OS wrote to the temp dir) and any
  /// encrypted upload-staging file. Keyed by both envelope and outbox id so a
  /// not-yet-acked message is covered too. Best-effort; never throws.
  Future<void> _purgeMessageArtifacts(ChatMessage m) async {
    await _tempMediaStore.deleteForEnvelope(m.envelopeId);
    final outbox = m.outboxId;
    if (outbox != null && outbox.isNotEmpty) {
      await _tempMediaStore.deleteForEnvelope(outbox);
      try {
        await _pendingUploadStaging.delete(outbox);
      } catch (_) {/* best-effort */}
    }
  }

  /// Resolve a username to a [MemberSeed] for group creation (no 1:1 started).
  /// Delegates to [GroupManager].
  Future<MemberSeed> resolveGroupMemberByUsername(String username) =>
      _groupManager.resolveGroupMemberByUsername(username);

  /// Bootstrap a new MLS group. Delegates to [GroupManager].
  Future<String> createGroup({
    required String groupName,
    required String selfUsername,
    required List<MemberSeed> initialMembers,
  }) =>
      _groupManager.createGroup(
        groupName: groupName,
        selfUsername: selfUsername,
        initialMembers: initialMembers,
      );

  /// Add a member to an existing group. Delegates to [GroupManager].
  Future<void> addMemberToGroup({
    required String conversationId,
    required MemberSeed newMember,
  }) =>
      _groupManager.addMemberToGroup(
        conversationId: conversationId,
        newMember: newMember,
      );

  /// Records that the peer's long-term identity public key has changed
  /// (e.g., peer reinstalled and restored from a different recovery phrase,
  /// OR a security-number recomputation revealed a mismatch). Updates the
  /// stored peerIdentityPubKey AND injects a local-only system ChatMessage
  /// flagged as `identity_key_changed` so the user sees a banner in the
  /// thread next time they open it.
  ///
  /// Idempotent: if [newPubKey] matches the stored value, no-op. If a
  /// system event for an identity_key_changed has already been written in
  /// this conversation within the last 5 minutes (heuristic), no second
  /// event is injected (avoids dupes when called from multiple detection
  /// sites within a tight window).
  ///
  /// Local-only: does NOT send anything on the wire. The peer never sees
  /// this event.
  Future<void> notePeerIdentityKeyChange({
    required String conversationId,
    required List<int> newPubKey,
  }) {
    return _runLocked(conversationId, () async {
      final convo = _byId[conversationId];
      if (convo == null) return;
      if (listEquals(convo.peerIdentityPubKey, newPubKey)) return;

      // Dedup: don't inject if a recent identity_key_changed system event
      // exists in the last 5 minutes.
      final now = DateTime.now().toUtc();
      final cutoff = now.subtract(const Duration(minutes: 5));
      final dedup = convo.messages
          .where((m) => m.kind == MessageKind.system && m.serverTs.isAfter(cutoff))
          .map((m) => SystemEvent.tryDecode(m.body))
          .any((ev) => ev?.kind == SystemEventKind.identityKeyChanged);

      // Build updated conversation with verified: false (since key changed)
      List<ChatMessage> nextMessages = convo.messages;
      if (!dedup) {
        nextMessages = [
          ...convo.messages,
          ChatMessage(
            envelopeId: 'local-syn-identity-${now.toIso8601String()}',
            conversationId: conversationId,
            senderDeviceId: 'system',
            body: SystemEvent.identityKeyChanged(
              username: convo.peerUsername,
              at: now,
            ).toJsonString(),
            serverTs: now,
            mine: false,
            kind: MessageKind.system,
          ),
        ];
      }

      // Reconstruct Conversation with the new peerIdentityPubKey
      // (copyWith doesn't expose peerIdentityPubKey, so use full constructor)
      final next = Conversation(
        id: convo.id,
        peerUsername: convo.peerUsername,
        peerAccountId: convo.peerAccountId,
        peerDeviceId: convo.peerDeviceId,
        peerIdentityPubKey: List<int>.from(newPubKey),
        peerX25519PubKey: convo.peerX25519PubKey,
        messages: nextMessages,
        unreadCount: convo.unreadCount,
        verified: false,
        hasMoreOlderMessages: convo.hasMoreOlderMessages,
        cryptoMode: convo.cryptoMode,
        needsReestablishment: convo.needsReestablishment,
        kind: convo.kind,
        groupName: convo.groupName,
        groupAvatar: convo.groupAvatar,
        members: convo.members,
        mlsEpoch: convo.mlsEpoch,
      );

      _byId[conversationId] = next;
      await _db.upsertConversation(next);
      if (!dedup) {
        await _db.upsertMessages(conversationId, [nextMessages.last]);
      }

      // An identity-key change means the peer's keys are entirely different;
      // the existing ratchet root (seeded from the old X25519 key) is now
      // dead. Drop it so the next inbound/outbound re-seeds from scratch.
      // Defensive: the 1:1 account model pins identity keys immutably (restore
      // requires the original key), so this path isn't normally reachable —
      // but if a mismatch is ever observed we must not keep enciphering
      // against a stale ratchet. (The genuine wiped-device case keeps the same
      // identity and is handled by [RatchetReceiver] on decrypt failure.)
      _crypto.clearConversationCrypto(conversationId);
      await _db.deleteConversationCryptoState(conversationId);

      notifyListeners();
    });
  }

  /// Sends a plaintext text message in the named conversation.
  @override
  Future<void> sendMessage({
    required String conversationId,
    required String myDeviceId,
    required String text,
    ChatMessage? replyTo,
  }) async {
    // Defence in depth: the thread replaces the composer with an Unblock bar
    // when blocked, so this normally can't be reached — but never emit to a
    // blocked contact.
    if (isBlocked(conversationId)) return;
    ReplyRef? replyRef;
    if (replyTo != null) {
      replyRef = ReplyRef(
        envelopeId: replyTo.envelopeId,
        sender: await _quotedSenderName(conversationId, replyTo),
        preview: _quotedPreview(replyTo),
      );
    }
    return _sendOptimistic(
      conversationId: conversationId,
      myDeviceId: myDeviceId,
      bodyForUI: text,
      kind: MessageKind.text,
      buildWireBody: () => text,
      replyRef: replyRef,
    );
  }

  /// Resolves the display name of the quoted message's sender so the reply
  /// header is self-contained (both sides render the same name).
  Future<String> _quotedSenderName(
    String conversationId,
    ChatMessage quoted,
  ) async {
    if (quoted.mine) {
      final session = await _sessions.current();
      return session?.username ?? 'You';
    }
    final convo = _byId[conversationId];
    if (convo != null && convo.kind == ConversationKind.group) {
      for (final m in convo.members) {
        if (m.deviceId == quoted.senderDeviceId) return m.username;
      }
    }
    return convo?.peerUsername ?? 'Unknown';
  }

  /// One-line preview of the quoted message for the reply header / quoted bar.
  static String _quotedPreview(ChatMessage m) {
    switch (m.kind) {
      case MessageKind.image:
        return StickerMarker.isSticker(m) ? '🏷️ Sticker' : '📷 Photo';
      case MessageKind.video:
        return '🎬 Video';
      case MessageKind.voice:
        return '🎤 Voice message';
      case MessageKind.file:
        return '📎 ${m.mediaFilename ?? 'File'}';
      case MessageKind.system:
      case MessageKind.text:
        final t = m.body.replaceAll('\n', ' ').trim();
        return t.length > 80 ? '${t.substring(0, 80)}…' : t;
    }
  }

  /// Inserts an optimistic image bubble immediately, then enqueues the
  /// upload + send on the conversation's LIFO stack. Returns as soon as the
  /// bubble is on screen — the caller is free to keep typing while the upload
  /// runs in the background. A more recently picked item jumps the queue.
  @override
  Future<void> sendImage({
    required String conversationId,
    required String myDeviceId,
    required List<int> imageBytes,
    required String mimeType,
    String caption = '',
    bool forwarded = false,
    // Only set for stickers: the `sticker.<ext>` marker that tells the receiving
    // client to render this image frameless. See [StickerMarker].
    String? filename,
  }) async {
    final outboxId = await _insertOptimisticMessage(
      conversationId: conversationId,
      myDeviceId: myDeviceId,
      bodyForUI: caption,
      kind: MessageKind.image,
      uploading: true,
      mediaMime: mimeType,
      mediaFilename: filename,
      mediaBytesForCache: imageBytes,
      forwarded: forwarded,
    );
    _uploadWorker.enqueue(PendingUpload(
      outboxId: outboxId,
      conversationId: conversationId,
      myDeviceId: myDeviceId,
      kind: MessageKind.image,
      bytes: imageBytes,
      mimeType: mimeType,
      bodyForUI: caption,
      filename: filename,
      forwarded: forwarded,
    ));
  }

  /// Inserts an optimistic voice bubble immediately, then enqueues the upload.
  /// `waveform` carries the per-recording amplitude bars (0..255 each)
  /// captured at record time. Optional — peers running pre-waveform clients
  /// (or recordings shorter than the first amplitude tick) ship `null` and
  /// the receiver renders a fallback waveform.
  Future<void> sendVoice({
    required String conversationId,
    required String myDeviceId,
    required List<int> voiceBytes,
    List<int>? waveform,
    int? durationMs,
    bool forwarded = false,
  }) async {
    const mime = 'audio/mp4';
    final outboxId = await _insertOptimisticMessage(
      conversationId: conversationId,
      myDeviceId: myDeviceId,
      bodyForUI: '',
      kind: MessageKind.voice,
      uploading: true,
      mediaMime: mime,
      voiceWaveform: waveform,
      mediaDurationMs: durationMs,
      mediaBytesForCache: voiceBytes,
      forwarded: forwarded,
    );
    _uploadWorker.enqueue(PendingUpload(
      outboxId: outboxId,
      conversationId: conversationId,
      myDeviceId: myDeviceId,
      kind: MessageKind.voice,
      bytes: voiceBytes,
      mimeType: mime,
      bodyForUI: '',
      waveform: waveform,
      durationMs: durationMs,
      forwarded: forwarded,
    ));
  }

  /// Inserts an optimistic video bubble immediately, then enqueues the upload.
  /// `caption` goes into `ChatMessage.body` for display below the thumbnail.
  @override
  Future<void> sendVideo({
    required String conversationId,
    required String myDeviceId,
    required List<int> videoBytes,
    required String mimeType,
    String caption = '',
    bool forwarded = false,
  }) async {
    final outboxId = await _insertOptimisticMessage(
      conversationId: conversationId,
      myDeviceId: myDeviceId,
      bodyForUI: caption,
      kind: MessageKind.video,
      uploading: true,
      mediaMime: mimeType,
      mediaBytesForCache: videoBytes,
      forwarded: forwarded,
    );
    _uploadWorker.enqueue(PendingUpload(
      outboxId: outboxId,
      conversationId: conversationId,
      myDeviceId: myDeviceId,
      kind: MessageKind.video,
      bytes: videoBytes,
      mimeType: mimeType,
      bodyForUI: caption,
      forwarded: forwarded,
    ));
  }

  /// Inserts an optimistic file bubble immediately, then enqueues the upload.
  /// `filename` is preserved on the descriptor and surfaces in the file
  /// bubble on the recipient side.
  @override
  Future<void> sendFile({
    required String conversationId,
    required String myDeviceId,
    required List<int> fileBytes,
    required String mimeType,
    required String filename,
    bool forwarded = false,
    String caption = '',
  }) async {
    final outboxId = await _insertOptimisticMessage(
      conversationId: conversationId,
      myDeviceId: myDeviceId,
      bodyForUI: caption,
      kind: MessageKind.file,
      uploading: true,
      mediaMime: mimeType,
      mediaFilename: filename,
      mediaBytesForCache: fileBytes,
      forwarded: forwarded,
    );
    _uploadWorker.enqueue(PendingUpload(
      outboxId: outboxId,
      conversationId: conversationId,
      myDeviceId: myDeviceId,
      kind: MessageKind.file,
      bytes: fileBytes,
      mimeType: mimeType,
      bodyForUI: caption,
      filename: filename,
      forwarded: forwarded,
    ));
  }

  /// Re-runs a previously-failed media send. Looks the message up by
  /// outboxId, pulls the bytes from `_mediaCache` (this-process LRU) or
  /// from the encrypted staging file on disk (survives restarts), clears
  /// `failed`, re-flags `uploading=true`, and pushes onto the LIFO upload
  /// stack. Returns false (with the message untouched) when the bytes are
  /// unrecoverable from either source.
  Future<bool> retryUpload({
    required String conversationId,
    required String outboxId,
  }) async {
    final live = _byId[conversationId];
    if (live == null) return false;
    final msg = live.messages
        .where((m) => m.outboxId == outboxId)
        .cast<ChatMessage?>()
        .firstWhere((_) => true, orElse: () => null);
    if (msg == null || !msg.failed) return false;
    var bytes = _mediaCache.cached(outboxId);
    if (bytes == null) {
      final key = msg.pendingUploadKey;
      if (key != null) {
        bytes = await _pendingUploadStaging.readDecrypted(
          outboxId: outboxId,
          key: key,
        );
        if (bytes != null) _mediaCache.put(outboxId, bytes);
      }
    }
    if (bytes == null) return false;
    // Flip the message back to uploading.
    final replaced = <ChatMessage>[
      for (final m in live.messages)
        m.outboxId == outboxId
            ? m.copyWith(failed: false, uploading: true)
            : m,
    ];
    _byId[conversationId] = live.copyWith(messages: replaced);
    final retried = replaced.firstWhere((m) => m.outboxId == outboxId);
    await _db.upsertMessages(conversationId, [retried]);
    notifyListeners();
    _uploadWorker.enqueue(PendingUpload(
      outboxId: outboxId,
      conversationId: conversationId,
      myDeviceId: msg.senderDeviceId,
      kind: msg.kind,
      bytes: bytes,
      mimeType: msg.mediaMime ?? _defaultMimeForKind(msg.kind),
      bodyForUI: msg.body,
      filename: msg.mediaFilename,
      waveform: msg.voiceWaveform,
      durationMs: msg.mediaDurationMs,
      forwarded: msg.forwarded,
    ));
    return true;
  }

  /// Re-sends a previously-failed *text* message. Unlike [retryUpload] (which
  /// needs cached media bytes), a text message carries everything it needs in
  /// its own body, so retry just clears `failed`, flips it back to pending and
  /// re-runs the submit path. Returns false if the outbox row is gone or isn't
  /// a failed text message.
  Future<bool> retryTextMessage({
    required String conversationId,
    required String outboxId,
  }) async {
    final live = _byId[conversationId];
    if (live == null) return false;
    final msg = live.messages
        .where((m) => m.outboxId == outboxId)
        .cast<ChatMessage?>()
        .firstWhere((_) => true, orElse: () => null);
    if (msg == null || !msg.failed || msg.kind != MessageKind.text) {
      return false;
    }
    // Clear the failed flag so the bubble shows "pending" again while we retry.
    final replaced = <ChatMessage>[
      for (final m in live.messages)
        m.outboxId == outboxId ? m.copyWith(failed: false) : m,
    ];
    _byId[conversationId] = live.copyWith(messages: replaced);
    await _db.upsertMessages(
      conversationId,
      [replaced.firstWhere((m) => m.outboxId == outboxId)],
    );
    notifyListeners();
    final body = msg.body;
    // Re-apply the forward marker the original send carried (the stored
    // body is the displayed text, headers already stripped).
    final wireBody = msg.forwarded ? '${ForwardMarker.prefix}$body' : body;
    try {
      await _submitOutbox(
        conversationId: conversationId,
        outboxId: outboxId,
        buildWireBody: () => wireBody,
        mediaBytesForCache: null,
      );
      return true;
    } catch (_) {
      // _submitOutbox re-marks the row failed on error; surface the failure.
      return false;
    }
  }

  /// Removes a message from this device only (the peer keeps it). Drops the
  /// in-memory row, the DB row, and any cached/staged media for it.
  Future<void> deleteMessageLocal(
    String conversationId,
    ChatMessage m,
  ) async {
    final live = _byId[conversationId];
    if (live == null) return;
    final id = m.envelopeId; // == outboxId for a not-yet-acked message
    // If the deleted message was the conversation's pin, clear the pin too so
    // the banner never points at a gone message. Each device that processes
    // the delete clears its own pin — the deletion already propagated, so no
    // extra pin-control is needed.
    final wasPinned = live.pinnedEnvelopeId == id;
    var updated = live.copyWith(
      messages: [
        for (final x in live.messages)
          if (x.envelopeId != id) x,
      ],
    );
    if (wasPinned) updated = updated.copyWith(pinnedEnvelopeId: null);
    _byId[conversationId] = updated;
    await _db.deleteMessage(id);
    if (wasPinned) await _db.upsertConversation(updated);
    _mediaCache.evict(id);
    _mediaCache.evictThumbnail(id);
    await _tempMediaStore.deleteForEnvelope(id);
    final outbox = m.outboxId;
    if (outbox != null && outbox.isNotEmpty) {
      _mediaCache.evict(outbox);
      _mediaCache.evictThumbnail(outbox);
      await _tempMediaStore.deleteForEnvelope(outbox);
      try {
        await _pendingUploadStaging.delete(outbox);
      } catch (_) {/* best-effort */}
    }
    notifyListeners();
  }

  /// Appends a system-event pill to [conversationId] and persists it, WITHOUT
  /// taking the conversation lock — the caller already holds it (e.g.
  /// [ControlReceiver] from the locked decrypt path, where a peer's screenshot
  /// control is turned into a "took a screenshot" line). Local-only: nothing is
  /// sent on the wire. No-op if the conversation isn't loaded.
  Future<void> _appendSystemEventLocked(
    String conversationId,
    SystemEvent event,
  ) async {
    final live = _byId[conversationId];
    if (live == null) return;
    final now = event.at ?? DateTime.now().toUtc();
    final msg = ChatMessage(
      envelopeId:
          'local-sys-${event.kind.wireName}-${now.microsecondsSinceEpoch}',
      conversationId: conversationId,
      senderDeviceId: 'system',
      body: event.toJsonString(),
      serverTs: now,
      mine: false,
      kind: MessageKind.system,
    );
    final updated = live.copyWith(messages: [...live.messages, msg]);
    _byId[conversationId] = updated;
    await _db.upsertConversation(updated);
    await _db.upsertMessages(conversationId, [msg]);
    notifyListeners();
  }

  /// Edits the text of one of your own recent messages and shares the change
  /// with the conversation. False when the edit isn't allowed or changes nothing.
  Future<bool> editMessage({
    required String conversationId,
    required ChatMessage target,
    required String newText,
  }) async {
    final updated = await _messageEditService.edit(
      conversationId: conversationId,
      target: target,
      newText: newText,
    );
    if (updated == null) return false;
    // The old card described the old text; build one for the new text if it has a link.
    unawaited(Future(() => _linkPreviewService.attachFor(updated)));
    return true;
  }

  /// Deletes one of *your own* messages for everyone: tells the peer to drop
  /// it (an encrypted `unsend` control through the normal send path) and then
  /// removes it locally. A message that never reached the server (still
  /// pending/failed) has nothing for the peer to delete — it's removed locally
  /// only. Best-effort: a failed control send still deletes locally.
  ///
  /// The control reaches EVERY device of the peer (a freshly refreshed device
  /// list) or every member device of a group, and — for a 1:1 — our OWN other
  /// devices too (a group already includes them as members), which apply it
  /// because it is authored by this account.
  Future<void> unsendMessage({
    required String conversationId,
    required ChatMessage target,
  }) async {
    final reachedServer = target.outboxId == null || target.outboxId!.isEmpty;
    if (reachedServer) {
      final body = MessageControl.unsend(target.envelopeId).encode();
      if (_byId[conversationId]?.kind != ConversationKind.group) {
        unawaited(_controlSender
            .sendSelfControl(conversationId, body)
            .catchError((_) {/* best-effort */}));
      }
      try {
        await _controlSender.sendControl(conversationId, body,
            allPeerDevices: true);
      } catch (_) {/* still delete locally below */}
    }
    await deleteMessageLocal(conversationId, target);
  }

  /// The user chose "Delete for me": delete here and self-sync the deletion to
  /// our OWN other devices only. See [DeleteSyncService].
  Future<void> deleteMessageForMe(String conversationId, ChatMessage m) =>
      _deleteSync.deleteForMe(conversationId, m);

  /// Whether this account administers [conversationId] and so may delete the
  /// group for everyone. See [GroupDisbandService].
  bool canDisbandGroup(String conversationId) =>
      _groupDisband.canDisband(conversationId);

  /// Deletes a group for EVERYONE (admin only): tells every member device, then
  /// deletes it here. False (nothing done) if we are not that group's admin.
  Future<bool> disbandGroup(String conversationId) =>
      _groupDisband.disband(conversationId);

  /// Forwards an existing message into another conversation as a fresh send
  /// (re-encrypted for the target; media is re-uploaded under a new key so
  /// the original's key is never shared across conversations). The new
  /// message carries the [ForwardMarker] so both sides render a "Forwarded"
  /// tag. Returns false when the send couldn't start (no session, system
  /// message, or media bytes unrecoverable).
  Future<bool> forwardMessage({
    required ChatMessage source,
    required String targetConversationId,
  }) async {
    final session = await _sessions.current();
    if (session == null) return false;
    final myDeviceId = session.deviceId;
    switch (source.kind) {
      case MessageKind.system:
        return false;
      case MessageKind.text:
        final text = source.body;
        await _sendOptimistic(
          conversationId: targetConversationId,
          myDeviceId: myDeviceId,
          bodyForUI: text,
          kind: MessageKind.text,
          buildWireBody: () => text,
          forwarded: true,
        );
        return true;
      case MessageKind.image:
      case MessageKind.video:
      case MessageKind.voice:
      case MessageKind.file:
        List<int>? bytes;
        try {
          bytes = await mediaBytesFor(source);
        } catch (_) {
          return false; // download failed — surface as "couldn't forward"
        }
        if (bytes == null) return false;
        final mime = source.mediaMime ?? _defaultMimeForKind(source.kind);
        switch (source.kind) {
          case MessageKind.image:
            await sendImage(
              conversationId: targetConversationId,
              myDeviceId: myDeviceId,
              imageBytes: bytes,
              mimeType: mime,
              caption: source.body,
              forwarded: true,
              // Keeps the sticker marker so a forwarded sticker stays a sticker.
              filename: source.mediaFilename,
            );
          case MessageKind.video:
            await sendVideo(
              conversationId: targetConversationId,
              myDeviceId: myDeviceId,
              videoBytes: bytes,
              mimeType: mime,
              caption: source.body,
              forwarded: true,
            );
          case MessageKind.voice:
            await sendVoice(
              conversationId: targetConversationId,
              myDeviceId: myDeviceId,
              voiceBytes: bytes,
              waveform: source.voiceWaveform,
              durationMs: source.mediaDurationMs,
              forwarded: true,
            );
          case MessageKind.file:
            await sendFile(
              conversationId: targetConversationId,
              myDeviceId: myDeviceId,
              fileBytes: bytes,
              mimeType: mime,
              filename: source.mediaFilename ?? 'attachment',
              forwarded: true,
              caption: source.body,
            );
          case MessageKind.text:
          case MessageKind.system:
            return false; // unreachable — handled above
        }
        return true;
    }
  }

  /// Broadcasts the user's conversation-privacy flags to every active 1:1
  /// as a `privacy` control. Called on toggle change so peers apply the new
  /// flags immediately — including toggling OFF, which the per-message
  /// [PrivacyHeader] can't express by absence. Best-effort per conversation;
  /// a peer that misses the broadcast converges via the header on the next
  /// message instead.
  Future<void> broadcastPrivacyFlags({
    required bool screenshots,
    required bool forwarding,
  }) async {
    final body = MessageControl.privacy(
      screenshots: screenshots,
      forwarding: forwarding,
    ).encode();
    for (final convo in _byId.values.toList()) {
      if (convo.kind != ConversationKind.oneToOne) continue;
      if (convo.pending || convo.peerAccountId.isEmpty) continue;
      try {
        await _controlSender.sendControl(convo.id, body);
      } catch (e) {
        debugPrint('privacy broadcast to ${convo.id} failed: $e');
      }
    }
  }

  /// Per-conversation timestamp of the last screenshot notice we sent, to
  /// coalesce an OS that posts the screenshot notification more than once for a
  /// single capture (so the peer never gets duplicate pills for one screenshot).
  final Map<String, DateTime> _lastScreenshotNotify = {};
  static const Duration _screenshotNotifyThrottle = Duration(seconds: 2);

  /// The user took a screenshot while viewing [conversationId]. Tell the peer
  /// via a `screenshot` control so their thread shows a "took a screenshot"
  /// line — the real protection on iOS, where the OS can't block a still
  /// capture (Android blocks it outright, so this rarely fires there).
  ///
  /// Fires when screenshot protection is active for this 1:1 from EITHER side:
  /// the peer asked (`peerBlocksScreenshots`) OR the user's own block-
  /// screenshots preference is on. Native detection only fires while secure (so
  /// one of those is already true), but the peer's flag may not have propagated
  /// to a freshly-restored device — so we must not depend on it alone, or the
  /// peer never learns their chat was captured. No-op for groups/pending chats,
  /// when no protection is active, or within the throttle window. Best-effort:
  /// a failed send is dropped (the next capture retries).
  Future<void> notifyPeerOfScreenshot(String conversationId) async {
    final convo = _byId[conversationId];
    if (convo == null) return;
    if (convo.kind != ConversationKind.oneToOne) return;
    final myScreenshots = _privacyFlagsProvider?.call().screenshots ?? false;
    if (!convo.peerBlocksScreenshots && !myScreenshots) return;
    if (convo.pending || convo.peerAccountId.isEmpty) return;
    final now = DateTime.now();
    final last = _lastScreenshotNotify[conversationId];
    if (last != null && now.difference(last) < _screenshotNotifyThrottle) {
      return;
    }
    _lastScreenshotNotify[conversationId] = now;
    try {
      await _controlSender.sendControl(
        conversationId,
        const MessageControl.screenshot().encode(),
      );
    } catch (e) {
      debugPrint('screenshot notice to $conversationId failed: $e');
    }
    // Mirror it on the screenshotter's OWN thread so both ends see the capture
    // happened (the peer renders its own line from the control above). Local-
    // only; taken under the convo lock since we're outside the decrypt path.
    // Best-effort — a failed wire send above still leaves this local notice.
    await _runLocked(
      conversationId,
      () => _appendSystemEventLocked(
        conversationId,
        SystemEvent.screenshotTaken(byYou: true, at: now.toUtc()),
      ),
    );
  }


  // ── Reactions ───────────────────────────────────────────────────────────────

  /// Toggle the current user's emoji [emoji] reaction on [targetEnvelopeId].
  /// Delegates to [ReactionService]; see it for the toggle + sync semantics.
  Future<void> react({
    required String conversationId,
    required String targetEnvelopeId,
    required String emoji,
  }) =>
      _reactionService.react(
        conversationId: conversationId,
        targetEnvelopeId: targetEnvelopeId,
        emoji: emoji,
      );

  // ── In-chat search ──────────────────────────────────────────────────────────

  /// Search [conversationId]'s text messages for [query] (case-insensitive
  /// substring), oldest → newest. Runs entirely against the local SQLCipher DB
  /// (the plaintext never leaves the device), so it covers the full on-device
  /// history, not just what's currently scrolled into view. Empty query → empty.
  Future<List<ChatMessage>> searchMessages(String conversationId, String query) =>
      _db.searchMessages(conversationId, query);

  // ── Collaborator services + the capability surface they call back through ──
  // Cohesive concerns are pulled out of this (large) notifier into services in
  // `services/`. The notifier implements [NotifierServiceHost] so each service
  // shares the live conversation map, the per-conversation FIFO lock,
  // persistence, listener notification, and the encrypted control fan-out —
  // without depending on the notifier's internals.

  late final PinService _pinService = PinService(this);
  late final GroupAvatarService _groupAvatarService = GroupAvatarService(this);
  late final DeviceCache _deviceCache = DeviceCache(api: _api);
  final PeerProfileCache _peerProfiles = PeerProfileCache();
  late final UploadWorker _uploadWorker = UploadWorker(host: this, media: _media, submitOutbox: _submitOutbox, markOutboxFailed: _markOutboxFailed);
  late final KeyPackageReplenisher _keyPackageReplenisher = KeyPackageReplenisher(api: _api, crypto: _crypto, storage: _secureStorage);
  late final DisappearingSweep _disappearingSweep = DisappearingSweep(host: this, mediaCache: _mediaCache, tempMediaStore: _tempMediaStore, ttlProvider: () => _ttlProvider?.call());
  late final ControlReceiver _controlReceiver = ControlReceiver(host: this, receipts: _receiptService, requestDecisions: _requestDecisions, sealedSender: _sealedSender, reactions: _reactionService, pins: _pinService, groupAvatars: _groupAvatarService, linkPreviews: _linkPreviewService, edits: _messageEditService, deleteSync: _deleteSync, stateApplier: _stateApplier, conversationDeleteSync: _conversationDeleteSync, groupDisband: _groupDisband, deleteMessageLocal: deleteMessageLocal, appendSystemEvent: _appendSystemEventLocked);
  late final MessageAppender _messageAppender = MessageAppender(host: this, controlReceiver: _controlReceiver, controlSender: _controlSender, callSignalHandler: () => onCallSignal, applyGroupInfo: _applyGroupInfo, notifications: _localNotifications, appInForeground: () => appInForeground, activeConversationId: () => _openConversationId, isCatchupEnvelope: (id) => _catchupEnvelopeIds.contains(id));
  late final MlsReceiver _mlsReceiver = MlsReceiver(host: this, crypto: _crypto, api: _api, sessions: _sessions, deviceCache: _deviceCache, appender: _messageAppender, controlSender: _controlSender, appendUnknownPeerEnvelope: _appendUnknownPeerEnvelope, isUnknownPeerPlaceholder: _isUnknownPeerPlaceholder, recordPeerDisplayName: _recordPeerDisplayName, peerAccountFromOneToOneId: _peerAccountFromOneToOneId, retryLog: _retryLog, processedLog: _processedLog);
  late final RatchetReceiver _ratchetReceiver = RatchetReceiver(host: this, crypto: _crypto, ratchetCore: _ratchetCore, deviceCache: _deviceCache, appender: _messageAppender, isUnknownPeerPlaceholder: _isUnknownPeerPlaceholder, appendUnknownPeerEnvelope: _appendUnknownPeerEnvelope, warmDeviceCaches: _warmDeviceCaches, requestReestablish: (c, s, m) => _mlsReceiver.maybeReestablish(c, s, m, force: true));
  late final RatchetCore _ratchetCore = RatchetCore(crypto: _crypto, api: _api, db: _db, contentTtlSeconds: () => _contentTtlSeconds);
  late final ControlSender _controlSender = ControlSender(host: this, crypto: _crypto, api: _api, sessions: _sessions, ratchetCore: _ratchetCore, deviceCache: _deviceCache, contentTtlSeconds: () => _contentTtlSeconds, migrateMultiDevice: _migrateForControl);
  late final ReactionService _reactionService = ReactionService(this, onPeerReaction: _notifyPeerReaction);
  late final MessageEditService _messageEditService = MessageEditService(this);
  late final LinkPreviewService _linkPreviewService = LinkPreviewService(this, source: () => _linkPreviewSource?.call());
  late final MediaCache _mediaCache =
      MediaCache(media: _media, thumbnailLoader: _videoThumbnailLoader);
  late final ConversationSettingsService _settings = ConversationSettingsService(
    host: this,
    secureStorage: _secureStorage,
    mutedKey: mutedConvosKey,
    blockedKey: blockedConvosKey,
  );
  late final GroupManager _groupManager = GroupManager(
    host: this,
    crypto: _crypto,
    api: _api,
    sessions: _sessions,
    myDeviceList: _myDeviceList,
    recordPeerDisplayName: _recordPeerDisplayName,
    contentTtlSeconds: () => _contentTtlSeconds,
  );
  late final CallSignalingService _callSignaling = CallSignalingService(this);
  late final TypingService _typingService = TypingService(this);
  late final ReceiptService _receiptService = ReceiptService(this);
  late final ReportService _reportService =
      ReportService(api: _api, db: _db);
  late final RequestDecisionService _requestDecisions =
      RequestDecisionService(this);
  late final DeleteSyncService _deleteSync =
      DeleteSyncService(this, deleteMessageLocal: deleteMessageLocal);
  late final ConversationStateStore _stateStore =
      ConversationStateStore(_secureStorage);
  late final ConversationStateSyncService _stateSync =
      ConversationStateSyncService(this,
          settings: _settings, store: _stateStore);
  late final ConversationStateApplier _stateApplier = ConversationStateApplier(
      this,
      settings: _settings,
      store: _stateStore,
      deleteMessageLocal: deleteMessageLocal);
  late final ConversationDeleteSyncService _conversationDeleteSync =
      ConversationDeleteSyncService(this,
          sendSelfControlNotifyingSealed: (id, body, onSealed) =>
              _controlSender.sendSelfControl(id, body, onSealed: onSealed),
          deleteConversation: (id) => deleteConversation(id));
  late final GroupDisbandService _groupDisband = GroupDisbandService(this);
  late final SealedSender _sealedSender = SealedSender(
    crypto: _crypto,
    api: _api,
    sessions: _sessions,
    secureStorage: _secureStorage,
    conversation: (id) => _byId[id],
    peerDevices: (accountId) =>
        _deviceCache.peerDevices(accountId),
    myDevices: () => _deviceCache.myDevicesSync(),
    warmDeviceCaches: _warmDeviceCaches,
    x25519ForSender: _x25519ForSender,
    sendControl: (convoId, body) => _controlSender.sendControl(convoId, body),
    sealedEnabled: () => sealedSenderEnabled,
    unauthEnabled: () => unidentifiedAccessEnabled,
  );

  /// Raises the generic "New message" banner for a reaction that arrived over the
  /// live socket (the FCM path only fires when the socket is down). Same rules as
  /// an inbound message: not while the user is reading that thread, not when the
  /// chat is muted or blocked, and not while draining a reconnect backlog (the
  /// wakeup push already covered those).
  void _notifyPeerReaction(String conversationId) {
    final notifications = _localNotifications;
    final convo = _byId[conversationId];
    if (notifications == null || convo == null) return;
    if (convo.muted || convo.blocked) return;
    if (_catchupEnvelopeIds.isNotEmpty) return;
    if (appInForeground && _openConversationId == conversationId) return;
    unawaited(notifications.show(
      id: conversationId.hashCode,
      title: 'New message',
      body: 'Open Chat to read',
      conversationId: conversationId,
    ));
  }

  @override
  Conversation? conversation(String id) => _byId[id];

  @override
  Iterable<Conversation> allConversations() => _byId.values;

  @override
  void setConversation(String id, Conversation conversation) =>
      _byId[id] = conversation;

  @override
  Future<T> runLocked<T>(String id, Future<T> Function() body) =>
      _runLocked(id, body);

  // When true, per-change host pulses are COALESCED: instead of firing a
  // [notifyListeners] each, they set [_pendingBatchedNotify] and a single
  // notification is flushed when the batch closes. Draining a catchup backlog
  // through the appender would otherwise pulse once per message — an O(K)
  // full-UI rebuild storm — see [_batchNotifications].
  bool _batchingNotifications = false;
  bool _pendingBatchedNotify = false;

  /// When the open batch last flushed a pulse. A batch that runs LONG — a big
  /// catchup drain, and note ONE envelope may legitimately take up to 90s
  /// before the drain abandons it — would otherwise leave the UI on pre-drain
  /// state for its entire duration: the "I open Chat and my messages take
  /// forever to appear" report. Flushing on a slow cadence keeps the rebuild
  /// count O(duration / interval) instead of O(envelopes), while letting the
  /// thread fill in as it drains.
  DateTime? _lastBatchFlush;
  static const Duration _batchFlushInterval = Duration(milliseconds: 400);

  /// Runs [body] with host notifications coalesced into a SINGLE
  /// [notifyListeners] at the end (fired only if something actually pulsed).
  /// Data mutations ([setConversation]) still apply live inside the batch; only
  /// the listener pulse is deferred, so the UI rebuilds once with the settled
  /// state instead of once per intermediate change. Nested calls are no-ops
  /// (the outermost batch owns the flush). Always closes the batch + flushes,
  /// even if [body] throws.
  Future<void> _batchNotifications(Future<void> Function() body) async {
    if (_batchingNotifications) return body(); // already batching (nested)
    _batchingNotifications = true;
    _pendingBatchedNotify = false;
    _lastBatchFlush = DateTime.now();
    try {
      await body();
    } finally {
      _batchingNotifications = false;
      if (_pendingBatchedNotify) {
        _pendingBatchedNotify = false;
        notifyListeners();
      }
    }
  }

  @override
  void notifyHost() {
    if (_batchingNotifications) {
      _pendingBatchedNotify = true;
      // Stream a long batch instead of staying dark until it closes — see
      // [_lastBatchFlush].
      final now = DateTime.now();
      final last = _lastBatchFlush;
      if (last == null || now.difference(last) >= _batchFlushInterval) {
        _lastBatchFlush = now;
        _pendingBatchedNotify = false;
        notifyListeners();
      }
      return;
    }
    notifyListeners();
  }

  @override
  AppDatabase get db => _db;

  @override
  Future<void> sendControl(String conversationId, String body,
          {String? pushKind, String? toDeviceId, bool allPeerDevices = false}) =>
      _controlSender.sendControl(conversationId, body,
          pushKind: pushKind,
          toDeviceId: toDeviceId,
          allPeerDevices: allPeerDevices);

  @override
  Future<void> sendSelfControl(String conversationId, String body) =>
      _controlSender.sendSelfControl(conversationId, body);

  @override
  Future<void> sendControlNotifyingSealed(String conversationId, String body,
          {required void Function() onSealed}) =>
      _controlSender.sendControl(conversationId, body, onSealed: onSealed);

  @override
  Future<void> disbandGroupLocally(String conversationId) =>
      deleteConversation(conversationId, emitLeaveCommits: false);

  @override
  Future<SubmitMessageResult> submit(SubmitMessagePayload payload) =>
      _submit(payload);

  @override
  Future<void> maybeTrim(String conversationId) => _maybeTrim(conversationId);

  @override
  Future<String?> currentAccountId() async =>
      _selfAccountId ?? (await _sessions.current())?.accountId;

  @override
  Future<bool> isMyDeviceWarm(String deviceId, String myDeviceId) =>
      _isMyDeviceWarm(deviceId, myDeviceId);

  @override
  void sendEphemeral(Map<String, dynamic> frame) => _ws.sendEphemeral(frame);

  @override
  bool get readReceiptsEnabled => _readReceiptsEnabled;

  @override
  ({bool screenshots, bool forwarding})? privacyFlags() =>
      _privacyFlagsProvider?.call();

  // ── Pinned message (single, shared per chat) ────────────────────────────────

  /// Set the conversation's single pinned message to [envelopeId], or clear the
  /// pin when [envelopeId] is null. Distinct from [setPinned], which pins a
  /// whole conversation in the CHAT LIST (a local-only preference). The pin is
  /// a SHARED chat property (one per chat, last-write-wins) — see [PinService].
  Future<void> setConversationPin(String conversationId, String? envelopeId) =>
      _pinService.setPin(conversationId, envelopeId);

  /// Fetch a stored message by its envelope id (full on-device history, not
  /// just the loaded window). Backs the pinned banner resolving its target when
  /// the pinned message has scrolled out of memory.
  Future<ChatMessage?> getMessage(String envelopeId) =>
      _db.getMessage(envelopeId);

  // ── Calls (1:1 voice/video signaling) ──────────────────────────────────────

  /// Set by the call layer to receive inbound [CallSignal]s decoded from an
  /// encrypted body (ring / SDP / ICE / hangup). Invoked POST-LOCK from
  /// [MessageAppender.append] so the handler may safely send a reply. Null
  /// when calling isn't wired.
  void Function(String conversationId, CallSignal signal, String senderDeviceId)?
      onCallSignal;

  /// True when [conversationId] is a 1:1 you may place/receive a call in.
  /// Delegates to [CallSignalingService].
  bool isCallable(String conversationId) =>
      _callSignaling.isCallable(conversationId);

  /// Encrypts + submits a call [signal] to the peer of [conversationId].
  /// Delegates to [CallSignalingService].
  Future<void> sendCallSignal(String conversationId, CallSignal signal,
          {String? pushKind, String? toDeviceId, bool allPeerDevices = false}) =>
      _callSignaling.sendCallSignal(conversationId, signal,
          pushKind: pushKind,
          toDeviceId: toDeviceId,
          allPeerDevices: allPeerDevices);

  /// Appends a LOCAL-ONLY call-log entry to [conversationId]. Delegates to
  /// [CallSignalingService].
  Future<void> appendCallLog({
    required String conversationId,
    required bool outgoing,
    required String outcome,
    int? durationSeconds,
    bool video = false,
  }) =>
      _callSignaling.appendCallLog(
        conversationId: conversationId,
        outgoing: outgoing,
        outcome: outcome,
        durationSeconds: durationSeconds,
        video: video,
      );




  static String _defaultMimeForKind(MessageKind kind) {
    switch (kind) {
      case MessageKind.image:
        return 'image/jpeg';
      case MessageKind.video:
        return 'video/mp4';
      case MessageKind.voice:
        return 'audio/mp4';
      case MessageKind.file:
        return 'application/octet-stream';
      case MessageKind.text:
      case MessageKind.system:
        return 'application/octet-stream';
    }
  }

  /// Synchronous peek at the in-memory media cache. Lets a freshly-built image
  /// bubble paint already-decrypted bytes on its first frame — notably after
  /// the optimistic→acked envelope-id swap re-keys the row and recreates the
  /// bubble's State — instead of flashing the placeholder through a
  /// one-microtask [Future]. Null on a miss; the caller falls back to the async
  /// [mediaBytesFor].
  /// Synchronous peek at the in-memory media cache — lets a freshly-built image
  /// bubble paint already-decrypted bytes on its first frame. Delegates to
  /// [MediaCache].
  List<int>? cachedMediaBytes(ChatMessage m) =>
      _mediaCache.cached(m.envelopeId);

  /// Decrypted media bytes for [m] (fetching + decrypting on a miss, with
  /// concurrent-call dedupe). Delegates to [MediaCache].
  Future<List<int>?> mediaBytesFor(ChatMessage m) => _mediaCache.bytesFor(m);

  /// Decoded first-frame JPEG bytes for a video message (cached). Delegates to
  /// [MediaCache].
  Future<Uint8List?> videoThumbnailFor(ChatMessage m) =>
      _mediaCache.thumbnailFor(m);

  /// Acknowledges a list of received envelope ids on the server so they're
  /// dropped from the offline queue. Prefers the warm WebSocket (fire-and-
  /// forget — acks are idempotent and a lost one just redelivers on the next
  /// catchup), falling back to an HTTP POST when the socket can't take it.
  @override
  Future<void> ack(List<String> envelopeIds) async {
    if (envelopeIds.isEmpty) return;
    // Mirror what we consumed so the FCM background isolate can tell a genuine
    // wakeup from one whose message we already showed on screen. A push is sent
    // for EVERY envelope regardless of socket delivery, so the wakeup for a
    // message read in the foreground is still queued at FCM — and lands in the
    // isolate the moment the app is closed, posting a phantom "New message".
    // Detached: this is a mirror, never a gate on acking.
    unawaited(_handledEnvelopes.record(envelopeIds));
    _drainAckedIds?.addAll(envelopeIds);
    if (_ws.sendAckFrame(envelopeIds)) return; // went over the socket
    try {
      await _api.ackMessages(envelopeIds);
    } catch (_) {
      // Best-effort; the server retains envelopes for ~30 days so a missed
      // ack just delays dropping them, doesn't lose messages.
    }
  }

  Future<void> _onEnvelope(wire.Envelope env) async {
    // Typing is an ephemeral signal — handle it before the per-conversation
    // lock + session check (no decrypt, no ack, no persistence).
    if (env.envelopeType == wire.EnvelopeType.typing) {
      _typingService.onTyping(env);
      return;
    }
    // Sealed-sender (Phase 1): the outer envelope's ciphertext is an opaque
    // per-recipient blob hiding the real type/conversation/sender. Unwrap with
    // this device's X25519 key, restore the inner envelope (using the OUTER id +
    // recipient + serverTs the server gave us), and re-dispatch it through this
    // same path exactly as if it had arrived in the clear. Unwrap BEFORE the
    // per-conversation lock — the inner conversation isn't known until decoded,
    // and the recursive call takes the right lock for the inner type.
    if (env.envelopeType == wire.EnvelopeType.sealed) {
      if (_crypto is! SealOpener) {
        // No opener available (shouldn't happen in production) — drop + ack so
        // it doesn't redeliver forever.
        await ack([env.envelopeId]);
        return;
      }
      final opener = _crypto as SealOpener;
      wire.Envelope inner;
      try {
        final innerBytes = await opener.openSealed(env.ciphertext);
        final rec = SealedInner.decode(innerBytes);
        inner = wire.Envelope(
          envelopeId: env.envelopeId,
          version: env.version,
          domain: env.domain,
          envelopeType: rec.envelopeType,
          conversationId: rec.conversationId,
          senderDeviceId: rec.senderDeviceId,
          recipientAccountId: env.recipientAccountId,
          recipientDeviceId: env.recipientDeviceId,
          ciphertext: rec.ciphertext,
          serverTs: env.serverTs,
        );
        // Mirror this sender device's sealing keys (x25519 pub + the peer's UAK)
        // so the FCM background isolate can send it a sealed "delivered" receipt
        // for a future message that arrives while the app is closed. 1:1 only,
        // no-op until we hold the peer's UAK. Fire-and-forget — never blocks the
        // receive.
        unawaited(_sealedSender.mirrorPeerSealKeys(
            rec.senderDeviceId, rec.conversationId));
      } catch (e) {
        // Not openable by us. This used to ack immediately, reasoning that our
        // X25519 key is stable so a retry can't help — but that premise fails
        // exactly when it matters most. If our local sealing keypair is ever
        // regenerated while our device id stays the same, EVERY inbound sealed
        // envelope lands here, and acking destroyed each one on arrival: the
        // messages were unrecoverable, nothing surfaced on this device, and the
        // SENDER saw a perfectly normal delivery (measured on-device
        // 2026-08-20 — a phone in this state acked 100% of envelopes in ~0.3s
        // and rendered none of them, one-way dead with no error anywhere).
        //
        // So instead: republish our CURRENT sealing key (peers seal to the
        // server's copy, so that is the only thing that can end the outage) and
        // let this envelope redeliver a bounded number of times, giving the
        // repair a chance to land before we drop it.
        // ignore: avoid_print
        print('sealed open failed for ${env.envelopeId}: $e');
        unawaited(_republishSealingKey());
        await _boundUnopenableSealed(env.envelopeId);
        return;
      }
      return _onEnvelope(inner);
    }
    // Server-asserted transport "delivered": a recipient device confirmed our
    // pushed envelope physically landed (before it opened the app). The
    // delivered envelope id rides in the ciphertext as UTF-8. Funnel it through
    // the SAME monotonic receipt path as a peer-sent receipt — _applyReceipt
    // only advances status, so a later end-to-end `read` is never downgraded,
    // and an unmatched/stale id is a harmless no-op. No decrypt, no ack.
    // Server-originated "a device was linked to this account": run the
    // own-device reconcile now (the designated old device adds the newcomer to
    // existing MLS 1:1 groups). Ephemeral — no envelope id, so nothing to ack,
    // and detached so it never holds up the receive pipeline.
    if (env.envelopeType == wire.EnvelopeType.devicesChanged) {
      unawaited(_reconcileOwnDevicesIntoGroups());
      return;
    }
    if (env.envelopeType == wire.EnvelopeType.deliveryStatus) {
      final deliveredId = utf8.decode(env.ciphertext, allowMalformed: true);
      if (deliveredId.isEmpty) return;
      return _runLocked(
        env.conversationId,
        () => _receiptService.applyReceipt(
            env.conversationId, ReceiptKind.delivered, [deliveredId]),
      );
    }
    // A sealed, signed transport "delivered" the recipient's FCM background
    // isolate sent back for a message it got while closed (the server couldn't
    // relay one — sealed sender hides the sender). We arrive here after the
    // sealed branch above unwrapped it. Verify the Ed25519 signature against
    // this conversation's peer identity (unforgeable), advance the receipt
    // monotonically, then ack the (real, stored) outer envelope.
    if (env.envelopeType == wire.EnvelopeType.deliveredReceipt) {
      await _applySealedDeliveredReceipt(env);
      await ack([env.envelopeId]);
      return;
    }
    // Drop envelopes that are not conversation-level types. key_package_publish
    // and media_envelope are handled elsewhere (or not at all in v1).
    final session = await _sessions.current();
    if (session == null) return;

    final convoId = env.conversationId;

    // Serialize all state-mutation for this conversation behind the lock so
    // a concurrent `sendMessage` can't race with this decrypt.
    return _runLocked(convoId, () async {
      // Residue for a group the user deleted. We hold no MLS group for it any
      // more, so this can never decrypt — and the group placeholder paths
      // never ack, so leaving it alone means it re-creates the conversation on
      // every catchup, forever. Ack it away. A Welcome is the exception: being
      // re-invited is deliberate, so it lifts the tombstone and falls through
      // to the normal join.
      if (_deletedGroupIds.contains(convoId)) {
        if (env.envelopeType == wire.EnvelopeType.mlsWelcome) {
          _deletedGroupIds.remove(convoId);
          try {
            await _db.clearGroupDeleted(convoId);
          } catch (_) {/* best-effort */}
        } else {
          await ack([env.envelopeId]);
          return;
        }
      }
      switch (env.envelopeType) {
        case wire.EnvelopeType.mlsWelcome:
          await _mlsReceiver.onWelcome(env, session.deviceId);
          break;
        case wire.EnvelopeType.mlsApplication:
          await _mlsReceiver.onApplication(env, session.deviceId);
          break;
        case wire.EnvelopeType.mlsHandshake:
          await _mlsReceiver.onHandshake(env);
          break;
        case wire.EnvelopeType.textLegacy:
          await _ratchetReceiver.onTextLegacy(env, session.deviceId);
          break;
        default:
          // ignore: avoid_print
          print('inbound envelope with unknown type ${env.envelopeType}; dropping');
      }
    });
  }


  /// Applies a received [SystemEventKind.groupInfo] roster broadcast:
  /// populates the conversation's group name + members from the metadata
  /// MLS itself can't carry. The current device is marked `isSelf` by
  /// matching [selfDeviceId]; an own-device sender's broadcast is ignored
  /// (we already have authoritative local state).
  Future<void> _applyGroupInfo(
    String convoId,
    String senderDeviceId,
    SystemEvent ev,
  ) async {
    final session = await _sessions.current();
    final selfDeviceId = session?.deviceId;
    if (selfDeviceId != null && senderDeviceId == selfDeviceId) return;
    final convo = _byId[convoId];
    if (convo == null) return;
    final roster = ev.members ?? const [];
    final members = [
      for (final m in roster)
        GroupMember(
          accountId: m.accountId,
          username: m.username,
          deviceId: m.deviceId,
          identityPubKey: m.identityPubKey,
          x25519PubKey: m.x25519PubKey,
          isAdmin: m.isAdmin,
          isSelf: selfDeviceId != null && m.deviceId == selfDeviceId,
        ),
    ];
    // We DECRYPTED this broadcast under the group's current epoch, which is
    // cryptographic proof that this device is still a member. So a roster that
    // omits us is the SENDER's projection being stale (they hadn't learned
    // about this device yet, or they rebuilt from an old snapshot) — it must
    // never blank out our own membership row, which is what the thread reads
    // to decide whether to show "You were removed from this group" and disable
    // the composer. Carry our own row through instead; the next accurate
    // broadcast replaces it.
    if (selfDeviceId != null &&
        members.isNotEmpty &&
        !members.any((m) => m.deviceId == selfDeviceId)) {
      final priorSelf =
          convo.members.where((m) => m.deviceId == selfDeviceId).toList();
      if (priorSelf.isNotEmpty) {
        members.add(priorSelf.first);
      }
    }
    // Normally the conversation is already group-kind (the Welcome placeholder
    // set it) and copyWith carries kind/peer fields through unchanged. But a
    // group message that raced ahead of its Welcome may have left a 1:1-kind
    // "unknown peer" stub under the group id — a successfully decrypted
    // group_info is cryptographic proof this IS a group, so rebuild the row
    // group-kind (copyWith pins `kind`), clearing the stub's junk peer fields.
    var base = convo;
    if (base.kind != ConversationKind.group && convoId.startsWith('group:')) {
      base = Conversation(
        id: base.id,
        peerUsername: '',
        peerAccountId: '',
        peerDeviceId: '',
        peerIdentityPubKey: const [],
        messages: base.messages,
        unreadCount: base.unreadCount,
        verified: base.verified,
        hasMoreOlderMessages: base.hasMoreOlderMessages,
        cryptoMode: CryptoMode.mls,
        kind: ConversationKind.group,
        groupName: base.groupName,
        groupAvatar: base.groupAvatar,
        members: base.members,
        mlsEpoch: base.mlsEpoch,
        pending: base.pending,
        pinned: base.pinned,
        pinnedEnvelopeId: base.pinnedEnvelopeId,
        muted: base.muted,
        archived: base.archived,
        blocked: base.blocked,
        disappearingTtl: base.disappearingTtl,
      );
    }
    final updated = base.copyWith(
      groupName: (ev.groupName ?? '').isNotEmpty ? ev.groupName : base.groupName,
      groupAvatar: (ev.groupAvatar ?? '').isNotEmpty
          ? ev.groupAvatar
          : base.groupAvatar,
      members: members.isNotEmpty ? members : base.members,
      mlsEpoch: ev.epoch ?? base.mlsEpoch,
    );
    _byId[convoId] = updated;
    await _db.upsertConversation(updated);
    if (members.isNotEmpty) {
      await _db.upsertGroupMembers(convoId, members);
    }
    notifyListeners();
  }



  /// True (after ack+drop) when [env] came from one of this account's own
  /// devices and we hold no real conversation for it; also removes an
  /// 'unknown' stub an earlier build made for it. False means: not residue.
  Future<bool> _dropOwnDeviceResidue(wire.Envelope env) async {
    final session = await _sessions.current();
    if (session == null) return false;
    if (!await _isMyDeviceWarm(env.senderDeviceId, session.deviceId)) {
      return false;
    }
    final existing = _byId[env.conversationId];
    if (existing != null && !_isUnknownPeerPlaceholder(existing)) return false;
    if (existing != null) await deleteConversation(env.conversationId);
    try {
      await ack([env.envelopeId]);
    } catch (_) {/* best-effort; the next catchup retries */}
    return true;
  }

  /// Handles an envelope for a peer we don't know about yet (or only know
  /// as a placeholder). First tries to auto-resolve the sender: the server
  /// maps the envelope's sender_device_id to its account, which lets us
  /// seed a real, decryptable conversation and immediately re-fetch the
  /// held envelope. Only when resolution fails (offline, deleted sender,
  /// non-1:1 conversation id) does the old "unknown peer" placeholder
  /// appear.
  ///
  /// **Does not ack** in either case — the envelope stays on the server and
  /// `/messages/catchup` re-delivers it for proper decryption once the
  /// conversation is seeded.
  Future<void> _appendUnknownPeerEnvelope(wire.Envelope env) async {
    // Self-sync residue: an envelope from one of OUR OWN devices for a 1:1 this
    // device doesn't hold is read position / state / delete traffic for a chat
    // that was already deleted here. It is never a stranger (and its sender
    // resolves to our own account, so it could never become a real request) -
    // ack+drop it instead of resurrecting an 'unknown' request that comes back
    // after every delete.
    if (!env.conversationId.startsWith('group:') &&
        await _dropOwnDeviceResidue(env)) {
      return;
    }
    // BOUNDED. "Stays unacked so catchup re-delivers it once the conversation
    // is seeded" is right while seeding can still happen — and an infinite loop
    // when it never will. Unlike the two decrypt paths this had NO bound at
    // all, so an envelope whose sender can never be resolved was re-fetched and
    // re-processed on every launch, forever. Measured on-device 2026-08-22: 24
    // such envelopes from the previous day survived six consecutive launches
    // with the (now durable) decrypt bounds in place — proving they take THIS
    // path — while burning ~900ms of every catchup.
    //
    // Counted durably, so the threshold is reachable across restarts; a
    // resolution that later succeeds clears the count on the decrypt path.
    if (await _retryLog.recordFailure(env.envelopeId) >=
        _maxUnknownPeerRedeliveries) {
      await _retryLog.forget(env.envelopeId);
      // ignore: avoid_print
      print('catchup: envelope ${env.envelopeId} unresolvable after '
          '$_maxUnknownPeerRedeliveries attempts; ack+dropping');
      try {
        await ack([env.envelopeId]);
      } catch (_) {/* best-effort; retried next reconnect */}
      return;
    }
    // A group envelope with no local conversation means its Welcome hasn't
    // (successfully) been processed yet. NEVER seed a 1:1 "unknown peer" stub
    // under a group id — copyWith pins `kind`, so the stub would strand the
    // group as a peerless 1:1 forever ("sender couldn't be identified").
    // Surface a pending group-invite placeholder instead (the same shape the
    // Welcome handler creates); the envelope stays unacked and decrypts once
    // a (re-)Welcome lands the group state.
    if (env.conversationId.startsWith('group:')) {
      final convoId = env.conversationId;
      final placeholder = Conversation(
        id: convoId,
        peerUsername: '',
        peerAccountId: '',
        peerDeviceId: '',
        peerIdentityPubKey: const [],
        messages: const [],
        unreadCount: 0,
        kind: ConversationKind.group,
        groupName: 'New group',
        members: const [],
        cryptoMode: CryptoMode.mls,
        pending: true,
      );
      _byId[convoId] = placeholder;
      await _db.upsertConversation(placeholder);
      notifyListeners();
      return;
    }
    final resolved = await _tryResolveUnknownSender(env);
    if (resolved) {
      // Re-fetch the held envelope(s) — but AFTER the per-conversation
      // lock we're currently inside releases. _onEnvelope re-acquires
      // that lock, so awaiting the refetch inline deadlocks the lock
      // chain (observed live: the refetch hung, the catchup batch
      // stalled behind it, and every later envelope for this
      // conversation queued forever until app restart).
      unawaited(_refetchHeldEnvelopes(env.serverTs));
      return;
    }

    final convoId = env.conversationId;
    final placeholder = Conversation(
      id: convoId,
      peerUsername: 'unknown',
      peerAccountId: '',
      peerDeviceId: env.senderDeviceId,
      peerIdentityPubKey: const [],
      peerX25519PubKey: const [],
      messages: [
        ChatMessage(
          envelopeId: env.envelopeId,
          conversationId: convoId,
          senderDeviceId: env.senderDeviceId,
          body: '[encrypted message from unknown peer]',
          serverTs: env.serverTs,
          mine: false,
        ),
      ],
      unreadCount: 1,
      // Inbound from a stranger we couldn't even resolve — still a message
      // request. When the placeholder later upgrades (resolution retry),
      // _tryResolveUnknownSender keeps it pending; startConversation (the
      // user reaching out themselves) clears it.
      pending: true,
    );
    _byId[convoId] = placeholder;
    await _db.upsertConversation(placeholder);
    notifyListeners();
  }

  /// Re-fetches unacked envelopes from just before [aroundTs] and runs them
  /// through the normal dispatch. Called (unawaited, outside the convo
  /// lock) after an unknown sender was resolved, so the messages that were
  /// held back decrypt immediately instead of waiting for the next
  /// foreground catchup.
  Future<void> _refetchHeldEnvelopes(DateTime aroundTs) async {
    try {
      final envs = await _api.catchupMessages(
        since: aroundTs.subtract(const Duration(seconds: 1)),
      );
      for (final e in envs) {
        try {
          await _onEnvelope(e);
        } catch (_) {/* stays unacked; next catchup retries */}
      }
    } catch (_) {/* next catchup picks it up */}
  }

  /// Resolves the sender of [env] via `GET /devices/{id}/account` and seeds
  /// a real ratchet-mode 1:1 conversation (replacing any unknown-peer
  /// placeholder). Returns false when the sender can't be resolved or the
  /// envelope's conversation id isn't the 1:1 id for (me, sender) — group
  /// envelopes and junk stay on the conservative placeholder path.
  ///
  /// The conversation is created ratchet-mode even if the sender has
  /// migrated to MLS: their unacked `mls_welcome` re-delivers alongside the
  /// application message and `MlsReceiver.onWelcome` flips the mode.
  /// True for the stub conversations [_appendUnknownPeerEnvelope] creates —
  /// 1:1, no account id, no keys. Groups legitimately have an empty
  /// peerAccountId, so the kind check matters.
  bool _isUnknownPeerPlaceholder(Conversation convo) =>
      convo.kind == ConversationKind.oneToOne &&
      convo.peerAccountId.isEmpty &&
      convo.peerIdentityPubKey.isEmpty;

  Future<bool> _tryResolveUnknownSender(wire.Envelope env) async {
    try {
      final account =
          await _api.lookupAccountByDevice(env.senderDeviceId);
      final session = await _sessions.current();
      if (session == null) return false;
      final expectedId =
          Conversation.oneToOneId(session.accountId, account.accountId);
      if (expectedId != env.conversationId) return false;
      // Without the peer's X25519 key the ratchet can't be seeded — the
      // message would stay undecryptable, so keep the placeholder.
      if (account.x25519PubKey.isEmpty) return false;
      _recordPeerDisplayName(account);
      // The sender may be a LINKED device: its ratchet is keyed on its OWN
      // X25519, not the account's primary one. Seeding with the primary key made
      // that first message undecryptable (SecretBoxAuthenticationError).
      final senderX25519 = account.devices
          .where((d) =>
              d.deviceId == env.senderDeviceId && d.x25519PubKey.isNotEmpty)
          .map((d) => d.x25519PubKey)
          .firstOrNull;
      final peerX25519 = senderX25519 ?? account.x25519PubKey;

      final convo = Conversation(
        id: expectedId,
        peerUsername: account.username,
        peerAccountId: account.accountId,
        // Reply to the device that actually messaged us — authoritative
        // over the account lookup's "primary device".
        peerDeviceId: env.senderDeviceId,
        peerIdentityPubKey: account.identityPubKey,
        peerX25519PubKey: peerX25519,
        messages: const [],
        unreadCount: 0,
        // Inbound-created = a message request: the user never contacted
        // this sender, so the composer stays locked until they accept.
        pending: true,
      );
      _byId[expectedId] = convo;
      await _db.upsertConversation(convo);
      final initialState = await _crypto.initConversationCrypto(
        conversationId: expectedId,
        peerX25519PubKey: peerX25519,
      );
      await _db.saveConversationCryptoState(initialState);
      notifyListeners();
      // ignore: avoid_print
      print('auto-resolved unknown sender ${env.senderDeviceId} '
          '-> @${account.username}');
      return true;
    } catch (_) {
      // Offline, older server without the endpoint, deleted sender — the
      // placeholder path handles all of these.
      return false;
    }
  }

  /// Clear unread + send a read receipt (1:1). Delegates to [ReceiptService].
  void markRead(String conversationId) {
    _receiptService.markRead(conversationId);
    unawaited(_stateSync.noteRead(conversationId));
  }

  /// Sweeps using the current global TTL. Delegates to [DisappearingSweep].
  /// Called by the periodic timer + the foreground-resume hook.
  Future<void> runDisappearingSweepNow() => _disappearingSweep.runNow();

  /// Removes expired messages from the DB + in-memory state. Delegates to
  /// [DisappearingSweep].
  Future<void> runDisappearingSweep(Duration? ttl) =>
      _disappearingSweep.run(ttl);

  /// Marks the conversation as verified (or unverified). Persists so the
  /// VERIFIED chip on `ContactProfileScreen` survives app restarts.
  Future<void> setVerified(String conversationId, bool verified) =>
      _stateSync.setVerified(conversationId, verified);

  /// Returns the current device's MLS device id, resolved from the active
  /// JWT session. Throws [StateError] if no session is active.
  @override
  Future<String> selfDeviceId() async {
    final session = await _sessions.current();
    if (session == null) {
      throw StateError('no active session');
    }
    return session.deviceId;
  }

  /// Leaves every group this account is in, best-effort. Used before account
  /// deletion: the server cannot see MLS membership, so unless we commit our
  /// own removal the other members keep our leaf (and name) forever. Each
  /// group is independent — one failing (offline, already removed) must not
  /// stop the rest. Returns the number of groups that could NOT be left.
  Future<int> leaveAllGroups() async {
    final String selfId;
    try {
      selfId = await selfDeviceId();
    } catch (_) {
      return 0;
    }
    final groupIds = _byId.values
        .where((c) => c.kind == ConversationKind.group)
        .map((c) => c.id)
        .toList();
    var failed = 0;
    for (final id in groupIds) {
      try {
        await removeMemberFromGroup(
          conversationId: id,
          targetDeviceId: selfId,
        );
      } catch (_) {
        failed++;
      }
    }
    return failed;
  }

  /// Remove [targetDeviceId] from the group conversation [conversationId].
  /// Covers both admin-initiated remove AND self-leave (when target == own
  /// deviceId).
  ///
  /// Wire effects (spec §10.6):
  /// 1. `_crypto.removeMember(...)` → Commit bytes.
  /// 2. Fan-out Commit to ALL pre-remove devices (including the removed device).
  /// 3a. Self-leave: delete the local conversation entirely.
  /// 3b. Admin-remove: broadcast a `member_removed` system event to remaining
  ///     members, update local state.
  ///
  /// Throws [StateError] if the conversation does not exist, is not a group,
  /// or the target is not a member.
  @override
  Future<void> removeMemberFromGroup({
    required String conversationId,
    required String targetDeviceId,
  }) async {
    return _runLocked(conversationId, () async {
      final convo = _byId[conversationId];
      if (convo == null || convo.kind != ConversationKind.group) {
        throw StateError('not a group conversation: $conversationId');
      }
      final target = convo.members.firstWhere(
        (m) => m.deviceId == targetDeviceId,
        orElse: () => throw StateError('no such member: $targetDeviceId'),
      );
      final session = await _sessions.current();
      if (session == null) {
        throw StateError('removeMemberFromGroup requires active session');
      }
      // A "member" is an ACCOUNT, not a single device — removing one evicts all
      // of that account's device leaves. Removing our own account = leaving.
      final isSelf = target.accountId == session.accountId;

      // Every device leaf of the target account. Put OUR OWN current device
      // last: removing ourselves first would drop us from the group and we
      // couldn't produce the remaining Commits.
      final targetDeviceIds = convo.members
          .where((m) => m.accountId == target.accountId)
          .map((m) => m.deviceId)
          .toList()
        ..sort((a, b) =>
            a == session.deviceId ? 1 : (b == session.deviceId ? -1 : 0));

      // Capture pre-remove device list for the Commit fan-out. The removed
      // devices must receive the Commit too so they can process their removal.
      final preRemoveDeviceTuples = convo.members
          .map((m) => (m.accountId, m.deviceId))
          .toList();

      // One Commit per removed leaf (no native bulk-remove). Apply locally and
      // fan each to every pre-remove device IN ORDER so all members advance in
      // lock-step; an already-removed device simply drops the later Commits.
      for (final devId in targetDeviceIds) {
        final List<int> commit;
        try {
          commit = await _crypto.removeMember(
            groupId: conversationId,
            targetDeviceId: devId,
          );
        } catch (e) {
          // The leaf is already gone from our MLS group (a previous attempt
          // applied the Commit locally, then failed during fan-out) — nothing
          // left to commit; just fall through and repair the projection.
          if (e.toString().contains('keyPackage references')) continue;
          rethrow;
        }
        for (final (accId, dId) in preRemoveDeviceTuples) {
          try {
            await _api.submitMessage(SubmitMessagePayload(
              conversationId: conversationId,
              envelopeType: wire.EnvelopeType.mlsHandshake,
              recipientAccountId: accId,
              recipientDeviceId: dId,
              ciphertext: commit,
            ));
          } on ApiError catch (e) {
            // 404 = recipient account/device no longer exists (deleted
            // account, revoked device). It can't process the Commit anyway —
            // aborting here would leave the remaining members unreached and
            // out of epoch sync.
            if (e.statusCode != 404) rethrow;
          }
        }
      }

      if (isSelf) {
        // Self-leave: delete the conversation entirely. Our devices can no
        // longer participate, so drop the local MLS group and tombstone the id
        // — anything already queued for us server-side is undecryptable now,
        // and the group placeholder paths would otherwise re-create the chat
        // from it on every catchup.
        try {
          await _crypto.wipeGroup(conversationId);
        } catch (_) {/* already gone */}
        _deletedGroupIds.add(conversationId);
        try {
          await _db.markGroupDeleted(conversationId);
        } catch (_) {/* best-effort; the in-memory gate still holds this run */}
        await _db.deleteGroupMembersForConversation(conversationId);
        await _db.deleteConversation(conversationId);
        _byId.remove(conversationId);
        notifyListeners();
        return;
      }

      // 2. Update local membership projection (admin-remove path) — drop every
      //    device of the removed account.
      final remaining = convo.members
          .where((m) => m.accountId != target.accountId)
          .toList();
      final epoch = await _crypto.currentEpoch(conversationId);
      await _db.upsertGroupMembers(conversationId, remaining);
      await _db.updateConversationGroupFields(conversationId, mlsEpoch: epoch);

      // 3. System event to remaining members.
      final selfMember = convo.members.firstWhere(
        (m) => m.deviceId == session.deviceId,
        orElse: () => convo.members.firstWhere((m) => m.isSelf,
            orElse: () => throw StateError('no self member in group')),
      );
      final ev = SystemEvent.memberRemoved(
        accountId: target.accountId,
        username: target.username,
        epoch: epoch,
        by: selfMember.username,
      );
      final plaintext = utf8.encode(ev.toJsonString());
      final ciphertext = await _crypto.encrypt(
        groupId: conversationId,
        plaintext: plaintext,
      );
      for (final m in remaining) {
        await _api.submitMessage(SubmitMessagePayload(
          conversationId: conversationId,
          envelopeType: wire.EnvelopeType.mlsApplication,
          recipientAccountId: m.accountId,
          recipientDeviceId: m.deviceId,
          ciphertext: ciphertext,
          ttlSeconds: _contentTtlSeconds,
        ));
      }

      // 4. Persist updated convo.
      final updated = Conversation(
        id: convo.id,
        peerUsername: convo.peerUsername,
        peerAccountId: convo.peerAccountId,
        peerDeviceId: convo.peerDeviceId,
        peerIdentityPubKey: convo.peerIdentityPubKey,
        peerX25519PubKey: convo.peerX25519PubKey,
        messages: convo.messages,
        unreadCount: convo.unreadCount,
        verified: convo.verified,
        hasMoreOlderMessages: convo.hasMoreOlderMessages,
        cryptoMode: convo.cryptoMode,
        needsReestablishment: convo.needsReestablishment,
        kind: convo.kind,
        groupName: convo.groupName,
        groupAvatar: convo.groupAvatar,
        members: remaining,
        mlsEpoch: epoch,
      );
      _byId[conversationId] = updated;
      await _db.upsertConversation(updated);
      notifyListeners();
    });
  }

  /// Fans a removal Commit for every one of THIS account's device leaves in
  /// [convo] out to the whole pre-leave roster — the wire half of leaving a
  /// group. Used by [deleteConversation], where "delete" means "leave": the
  /// local row disappearing is invisible to everyone else, so without this the
  /// peers' rosters (and the MLS tree) keep this account as a member and keep
  /// addressing it, which is what made a deleted group keep coming back.
  ///
  /// Entirely best-effort and never throws: the user asked to delete the
  /// conversation, and a failed Commit (offline, group state already gone)
  /// must not block that. Our own current device leaf goes LAST — removing it
  /// first would evict us from the group before we could produce the remaining
  /// Commits. Callers must invoke this BEFORE wiping the local MLS group.
  ///
  /// The Commits are MINTED inline (local CoreCrypto, fast, and it has to
  /// happen before the group is wiped) but SENT fire-and-forget: the delete is
  /// a local action behind a UI spinner, and an offline device must not hold it
  /// hostage to one connect-timeout per recipient device.
  Future<void> _emitSelfLeaveCommits(Conversation convo) async {
    if (convo.kind != ConversationKind.group) return;
    if (convo.members.isEmpty) return;
    try {
      final session = await _sessions.current();
      if (session == null) return;
      final myLeaves = convo.members
          .where((m) => m.accountId == session.accountId)
          .map((m) => m.deviceId)
          .toList()
        ..sort((a, b) =>
            a == session.deviceId ? 1 : (b == session.deviceId ? -1 : 0));
      if (myLeaves.isEmpty) return;
      // Everyone who must learn we left, ourselves excluded.
      final recipients = convo.members
          .where((m) => m.deviceId != session.deviceId)
          .map((m) => (m.accountId, m.deviceId))
          .toList();
      if (recipients.isEmpty) return;
      final commits = <List<int>>[];
      for (final devId in myLeaves) {
        try {
          commits.add(await _crypto.removeMember(
            groupId: convo.id,
            targetDeviceId: devId,
          ));
        } catch (e) {
          debugPrint('leave-group: commit for $devId failed on ${convo.id}: $e');
        }
      }
      if (commits.isEmpty) return;
      unawaited(_fanOutLeaveCommits(convo.id, commits, recipients));
    } catch (e) {
      debugPrint('leave-group: aborted on ${convo.id}: $e');
    }
  }

  /// Ships the already-minted leave [commits] for [conversationId] to every
  /// [recipients] device, in order so members advance in lock-step. Detached
  /// from the delete (see [_emitSelfLeaveCommits]); never throws.
  Future<void> _fanOutLeaveCommits(
    String conversationId,
    List<List<int>> commits,
    List<(String, String)> recipients,
  ) async {
    for (final commit in commits) {
      for (final (accId, devId) in recipients) {
        try {
          await _api.submitMessage(SubmitMessagePayload(
            conversationId: conversationId,
            envelopeType: wire.EnvelopeType.mlsHandshake,
            recipientAccountId: accId,
            recipientDeviceId: devId,
            ciphertext: commit,
          ));
        } catch (e) {
          debugPrint('leave-group: commit to $devId failed on '
              '$conversationId: $e');
        }
      }
    }
  }

  /// Best-effort cleanup after one of THIS account's devices is revoked: remove
  /// its MLS leaf from every group/1:1 it belongs to, so no dead leaf lingers
  /// in the tree. Each removal is a Commit fanned to the remaining member
  /// devices (never the revoked device or our own current device). A group the
  /// device isn't in just throws and is skipped.
  Future<void> removeRevokedDeviceFromGroups(String revokedDeviceId) async {
    final session = await _sessions.current();
    if (session == null || revokedDeviceId == session.deviceId) return;
    for (final convo in _byId.values.toList()) {
      if (convo.cryptoMode != CryptoMode.mls) continue;
      await _runLocked(convo.id, () async {
        final live = _byId[convo.id];
        if (live == null || live.cryptoMode != CryptoMode.mls) return;
        final List<int> commit;
        try {
          commit = await _crypto.removeMember(
              groupId: convo.id, targetDeviceId: revokedDeviceId);
        } catch (_) {
          return; // not a member of this group — nothing to evict
        }
        final recipients = live.kind == ConversationKind.group
            ? [for (final m in live.members) (m.accountId, m.deviceId)]
            : (await _mlsFanoutRecipients(live))
                .map((r) => (r.accountId, r.deviceId))
                .toList();
        for (final (accId, devId) in recipients) {
          if (devId == revokedDeviceId || devId == session.deviceId) continue;
          try {
            await _api.submitMessage(SubmitMessagePayload(
              conversationId: convo.id,
              envelopeType: wire.EnvelopeType.mlsHandshake,
              recipientAccountId: accId,
              recipientDeviceId: devId,
              ciphertext: commit,
            ));
          } catch (e) {
            debugPrint('revoke cleanup: commit to $devId failed: $e');
          }
        }
        // Drop the revoked device from a group's member projection.
        if (live.kind == ConversationKind.group &&
            live.members.any((m) => m.deviceId == revokedDeviceId)) {
          final remaining = live.members
              .where((m) => m.deviceId != revokedDeviceId)
              .toList();
          final epoch = await _crypto.currentEpoch(convo.id);
          _byId[convo.id] = live.copyWith(members: remaining, mlsEpoch: epoch);
          await _db.upsertGroupMembers(convo.id, remaining);
          await _db.updateConversationGroupFields(convo.id, mlsEpoch: epoch);
          notifyListeners();
        }
      });
    }
  }

  /// Test/debug hook — inserts a conversation directly. Used by widget tests
  /// and the chat-list screen's empty-state placeholder seed.
  @visibleForTesting
  void seed(Conversation conversation) {
    _byId[conversation.id] = conversation;
    notifyListeners();
  }

  /// Test hook — completes when the background upload worker for
  /// [conversationId] has drained. Used by media-send tests so the original
  /// "send then assert" pattern still works now that the send returns as
  /// soon as the optimistic bubble is inserted.
  @visibleForTesting
  Future<void> waitForUploads(String conversationId) =>
      _uploadWorker.waitFor(conversationId);

  /// Test hook — routes an envelope through the inbound handler. Allows tests
  /// to drive [MlsReceiver.onApplication] / [MlsReceiver.onHandshake] without a live
  /// WebSocket.
  @visibleForTesting
  Future<void> handleEnvelopeForTest(wire.Envelope env) => _onEnvelope(env);


  /// Appends an optimistic outbound message to `_byId[conversationId]` and
  /// persists it. Returns the generated outbox id. Used as the first step by
  /// both [_sendOptimistic] (text — no descriptor needed) and the upload
  /// pipeline (media — descriptor fields blank until upload completes;
  /// `uploading=true` drives the bubble's spinner).
  ///
  /// For media inserts (uploading=true + bytes), [_pendingUploadStaging]
  /// encrypts the plaintext and writes it to disk under `outboxId`; the
  /// random per-upload key persists on the message row so boot recovery
  /// can decrypt + resume the upload across restarts.
  ///
  /// Caller is responsible for the actual submit step (see [_submitOutbox]).
  Future<String> _insertOptimisticMessage({
    required String conversationId,
    required String myDeviceId,
    required String bodyForUI,
    required MessageKind kind,
    required bool uploading,
    String? mediaMime,
    String? mediaFilename,
    List<int>? voiceWaveform,
    int? mediaDurationMs,
    String? replyToEnvelopeId,
    String? replyToSender,
    String? replyToPreview,
    List<int>? mediaBytesForCache,
    bool forwarded = false,
  }) async {
    if (!_byId.containsKey(conversationId)) {
      throw StateError('conversation $conversationId not found');
    }
    final outboxId =
        'outbox-${DateTime.now().toUtc().microsecondsSinceEpoch}-${++_outboxCounter}';
    List<int>? pendingKey;
    if (uploading && mediaBytesForCache != null) {
      // Encrypt + persist BEFORE the DB row goes in. If the app dies between
      // write and upsert, the next boot's orphan sweep deletes the file (no
      // matching row references it), so we never have a uploading=true row
      // whose staging file is missing.
      pendingKey = await _pendingUploadStaging.writeEncrypted(
        outboxId: outboxId,
        plaintext: mediaBytesForCache,
      );
    }
    final pendingMessage = ChatMessage(
      envelopeId: outboxId,
      conversationId: conversationId,
      senderDeviceId: myDeviceId,
      body: bodyForUI,
      serverTs: DateTime.now().toUtc(),
      mine: true,
      outboxId: outboxId,
      kind: kind,
      mediaMime: mediaMime,
      mediaFilename: mediaFilename,
      voiceWaveform: voiceWaveform,
      mediaDurationMs: mediaDurationMs,
      replyToEnvelopeId: replyToEnvelopeId,
      replyToSender: replyToSender,
      replyToPreview: replyToPreview,
      forwarded: forwarded,
      uploading: uploading,
      pendingUploadKey: pendingKey,
    );
    // Re-read the convo AFTER the staging write — multiple concurrent
    // [_insertOptimisticMessage] calls each yield at the writeEncrypted
    // await, so a snapshot captured beforehand would be stale and the last
    // resumer would wipe earlier inserts.
    final convo = _byId[conversationId];
    if (convo == null) {
      throw StateError('conversation $conversationId not found');
    }
    _byId[conversationId] = convo.copyWith(
      messages: [...convo.messages, pendingMessage],
    );
    if (mediaBytesForCache != null) {
      _mediaCache.put(outboxId, mediaBytesForCache);
    }
    await _db.upsertMessages(conversationId, [pendingMessage]);
    notifyListeners();
    return outboxId;
  }

  /// Encrypts + submits an already-inserted outbox message under the
  /// per-conversation lock, swapping it for the server-acked envelope on
  /// success. Marks `failed=true` on error. Routes through [MlsMigrator] so
  /// ratchet ↔ MLS migration is handled the same way for text and media.
  /// This account's own devices (for self-sync fan-out), cached for the
  /// session. Best-effort — returns empty on failure.
  Future<List<Device>> _myDeviceList() => _deviceCache.myDevices();

  /// The fan-out targets for a 1:1 send — every peer device + this account's
  /// OTHER devices (self-sync), each with its X25519. Returns null when it's a
  /// plain single-device conversation (one peer device, no other own devices),
  /// so the caller keeps the existing single-peer path.
  Future<List<RatchetFanoutTarget>?> _multiDeviceTargets(Conversation convo) async {
    final session = await _sessions.current();
    if (session == null) return null;
    final peerDevices = _deviceCache.peerDevices(convo.peerAccountId);
    final myOthers =
        (await _myDeviceList()).where((d) => d.deviceId != session.deviceId);
    if (peerDevices.length <= 1 && myOthers.isEmpty) return null;
    final targets = <RatchetFanoutTarget>[];
    for (final d in peerDevices) {
      if (d.x25519PubKey.isEmpty) continue;
      // The peer's primary device keeps the legacy '' ratchet so single-device
      // peers (and the existing receive path) stay in sync unchanged.
      final isPrimary = d.deviceId == convo.peerDeviceId;
      targets.add(RatchetFanoutTarget(
        accountId: convo.peerAccountId,
        deviceId: d.deviceId,
        ratchetKey: isPrimary ? '' : d.deviceId,
        x25519: d.x25519PubKey,
      ));
    }
    for (final d in myOthers) {
      if (d.x25519PubKey.isEmpty) continue;
      targets.add(RatchetFanoutTarget(
        accountId: session.accountId,
        deviceId: d.deviceId,
        ratchetKey: d.deviceId,
        x25519: d.x25519PubKey,
      ));
    }
    return targets.length > 1 ? targets : null;
  }

  /// The member device addresses for an MLS 1:1 send — every device of the
  /// peer plus this account's own OTHER devices (self-sync). All of these were
  /// added to the MLS group at migration, so the single encrypted ciphertext is
  /// delivered to each. Warms the peer-device cache on a cold miss; falls back
  /// to the single primary peer device when no device list is available (the
  /// single-device case, byte-identical to the pre-multi-device behaviour).
  Future<List<({String accountId, String deviceId})>> _mlsFanoutRecipients(
      Conversation convo) async {
    final session = await _sessions.current();
    var peerDevices =
        _deviceCache.peerDevices(convo.peerAccountId);
    if (peerDevices.isEmpty ||
        _deviceCache.peerDevicesStale(convo.peerAccountId)) {
      // Also refresh a STALE list: a peer who linked a device after we cached
      // their list would otherwise never receive our sends (the new device is
      // an MLS member but not a fan-out target). Bounded so a slow/wedged
      // network can't stall the send — on failure keep the cached list.
      try {
        _recordPeerDisplayName(await _api
            .lookupAccount(convo.peerUsername)
            .timeout(const Duration(seconds: 5)));
        peerDevices = _deviceCache.peerDevices(convo.peerAccountId);
      } catch (_) {/* offline/slow — fall back to the cached list below */}
    }
    final recipients = <({String accountId, String deviceId})>[];
    for (final d in peerDevices) {
      recipients.add((accountId: convo.peerAccountId, deviceId: d.deviceId));
    }
    if (recipients.isEmpty && convo.peerDeviceId.isNotEmpty) {
      recipients
          .add((accountId: convo.peerAccountId, deviceId: convo.peerDeviceId));
    }
    if (session != null) {
      for (final d in await _myDeviceList()) {
        if (d.deviceId != session.deviceId) {
          recipients
              .add((accountId: session.accountId, deviceId: d.deviceId));
        }
      }
    }
    return recipients;
  }

  /// How long a non-elected sibling defers a 1:1's initial MLS migration before
  /// taking it over itself. The elected (smallest-id) sibling may simply not
  /// hold this chat — a self-synced first message creates no row on it — and
  /// would then never start the group, stranding the chat on ratchet.
  Duration siblingInitiatorGrace = const Duration(seconds: 45);

  final Map<String, DateTime> _siblingDeferredAt = {};

  /// True when [myDeviceId] is the lexically-smallest of this account's devices
  /// (or the only one), i.e. the one device allowed to start a 1:1's initial
  /// MLS migration. Every sibling computes the same answer from the same list.
  Future<bool> _isDesignatedInitiatorDevice(String myDeviceId) async {
    final ids = [
      for (final d in await _myDeviceList()) d.deviceId,
    ];
    return ids.every((id) => id.compareTo(myDeviceId) >= 0);
  }

  /// Whether this device may start [convoId]'s initial migration now: always
  /// the elected sibling, and any other sibling once it has deferred for
  /// [siblingInitiatorGrace] without the chat having moved to MLS.
  Future<bool> _mayInitiateMigration(String convoId, String myDeviceId) async {
    if (await _isDesignatedInitiatorDevice(myDeviceId)) {
      _siblingDeferredAt.remove(convoId);
      return true;
    }
    final now = DateTime.now();
    var since = _siblingDeferredAt[convoId];
    // A deferral older than a few graces is a leftover of an EARLIER attempt
    // (the chat has since been deleted, rebuilt or re-contacted): start over,
    // or the next re-contact would skip the wait and race the elected device.
    if (since == null || now.difference(since) > siblingInitiatorGrace * 4) {
      since = now;
      _siblingDeferredAt[convoId] = now;
    }
    return now.difference(since) >= siblingInitiatorGrace;
  }

  /// The all-devices migration for a CONTROL send (receipt, call signal,
  /// re-establish...). Without it a control on a multi-device 1:1 took the
  /// single-peer migrator, which builds a two-member group holding one peer
  /// device and none of our siblings — the other devices could never join.
  Future<ControlMigrationOutcome> _migrateForControl(
    Conversation convo,
    String body, {
    required bool force,
    required String pushKind,
  }) async {
    if (convo.kind != ConversationKind.oneToOne ||
        convo.cryptoMode != CryptoMode.ratchet) {
      return ControlMigrationOutcome.notApplicable;
    }
    final session = await _sessions.current();
    if (session == null || await _multiDeviceTargets(convo) == null) {
      return ControlMigrationOutcome.notApplicable;
    }
    if (!await _mayInitiateMigration(convo.id, session.deviceId)) {
      return ControlMigrationOutcome.deferToSibling;
    }
    final res = await _migrateAllDevicesToMls(convo, body,
        force: force, pushKindOverride: pushKind);
    return res == null
        ? ControlMigrationOutcome.notApplicable
        : ControlMigrationOutcome.migrated;
  }

  /// Full multi-device MLS migration for a 1:1: builds a fresh MLS group whose
  /// members are EVERY device of the peer plus this account's own other devices
  /// (self-sync), encrypts [wireBody] once, and fans the Welcome + application
  /// envelope out to each device. Returns the first successful submit, or null
  /// when the peer has published no MLS key packages yet (the caller then falls
  /// back to per-device ratchet fan-out). On success the conversation is flipped
  /// to MLS and its ratchet state dropped.
  Future<SubmitMessageResult?> _migrateAllDevicesToMls(
    Conversation convo,
    String wireBody, {
    bool force = false,
    String? pushKindOverride,
  }) async {
    final session = await _sessions.current();
    if (session == null) return null;

    // Deterministic migration (see MlsMigrator._initiatesMigration): only the
    // smaller account initiates. The larger account returns null here and stays
    // on multi-device ratchet fan-out, adopting the peer's Welcome instead — so
    // the two accounts can't both build an MLS group at once (the simultaneous-
    // migration collision). [force] is a rebuild of a group we LOST, where
    // waiting for the peer would strand a follower — see _resetLostMlsGroup.
    if (!force &&
        session.accountId.isNotEmpty &&
        convo.peerAccountId.isNotEmpty &&
        session.accountId.compareTo(convo.peerAccountId) >= 0) {
      return null;
    }

    // Sibling devices of this account must not BOTH build the group: each
    // would Welcome the peer into its own group and fork the chat. Only the
    // lexically-smallest own device initiates; the others stay on ratchet and
    // adopt its Welcome (it includes them as members). Applies to forced
    // rebuilds too: two siblings each re-establishing is the same fork.
    if (!await _mayInitiateMigration(convo.id, session.deviceId)) {
      return null;
    }

    final List<DeviceKeyPackageResult> peerPkgs;
    try {
      peerPkgs = await _api.lookupDeviceKeyPackages(convo.peerUsername);
    } catch (_) {
      return null; // peer not MLS-ready / offline → ratchet fan-out
    }
    if (peerPkgs.isEmpty) return null;

    // Own other devices (self-sync). Best-effort — a failure just means our
    // other devices join the group on their own next send instead of now.
    var ownPkgs = const <DeviceKeyPackageResult>[];
    try {
      ownPkgs = (await _api.lookupDeviceKeyPackages(session.username))
          .where((d) => d.deviceId != session.deviceId)
          .toList(growable: false);
    } catch (_) {/* keep empty */}

    final groupId = await _crypto.createGroup(conversationId: convo.id);
    if (groupId != convo.id) {
      throw StateError(
          'spec §7.3 violated: createGroup returned $groupId, expected ${convo.id}');
    }
    final addResult = await _crypto.addMembers(
      groupId: groupId,
      peerKeyPackages: [
        for (final p in peerPkgs) p.keyPackage,
        for (final o in ownPkgs) o.keyPackage,
      ],
    );
    final ct = await _crypto.encrypt(
      groupId: groupId,
      plaintext: utf8.encode(wireBody),
    );

    final recipients = <({String accountId, String deviceId})>[
      for (final p in peerPkgs)
        (accountId: convo.peerAccountId, deviceId: p.deviceId),
      for (final o in ownPkgs)
        (accountId: session.accountId, deviceId: o.deviceId),
    ];

    // 1. Welcome to every new member device FIRST (so each can decrypt #2).
    //    Track which devices actually received their Welcome — the application
    //    envelope below must go ONLY to those. A device that gets the app but
    //    not its Welcome is stranded: it holds ciphertext for a group it was
    //    never welcomed into, can't decrypt it, and (MLS forward secrecy) can't
    //    recover that message even after a later re-add — while the failed
    //    decrypt drives needless split-brain re-establishment churn. This was
    //    the first-message-loss path on a flaky network: a single dropped
    //    Welcome submit silently stranded that device. Skipping the app for it
    //    instead lets it join cleanly on a later reconcile/send.
    final welcomed = <({String accountId, String deviceId})>[];
    for (final r in recipients) {
      try {
        await _api.submitMessage(SubmitMessagePayload(
          conversationId: convo.id,
          envelopeType: wire.EnvelopeType.mlsWelcome,
          recipientAccountId: r.accountId,
          recipientDeviceId: r.deviceId,
          ciphertext: addResult.welcome,
        ));
        welcomed.add(r);
      } catch (e) {
        debugPrint('mls migrate: welcome to ${r.deviceId} failed: $e');
      }
    }
    if (welcomed.isEmpty) {
      // No device received its Welcome (total submit failure). Don't send an
      // application message nobody can decrypt; wipe the half-built local group
      // so the next send re-migrates from a clean slate (a lingering group would
      // make the retry's createGroup collide), then surface the error to retry.
      try {
        await _crypto.wipeGroup(convo.id);
      } catch (_) {/* best-effort */}
      throw StateError('mls migrate: no Welcome reached any device');
    }

    // 2. Flip to MLS and drop the now-orphaned ratchet state(s) as soon as ANY
    //    Welcome is accepted — BEFORE the application submit, not after it.
    //    The group now exists locally and on the peer; if the app submit then
    //    fails (a flapping connection), the conversation must already be MLS so
    //    the retry only re-encrypts into this group. Left on ratchet, every
    //    retry re-ran createGroup and sent the peer a brand-new Welcome — five
    //    in four minutes — and the peer's catch-up replaced its group on each
    //    one, voiding every message sent under the earlier groups.
    final migrated = convo.copyWith(cryptoMode: CryptoMode.mls);
    _byId[convo.id] = migrated;
    _siblingDeferredAt.remove(convo.id);
    await _db.upsertConversation(migrated);
    try {
      await _db.deleteConversationCryptoState(convo.id);
    } catch (_) {/* none existed */}
    notifyListeners();

    // 3. The application envelope — ONLY to devices that got their Welcome.
    SubmitMessageResult? firstOk;
    Object? firstErr;
    for (final r in welcomed) {
      try {
        final res = await _api.submitMessage(SubmitMessagePayload(
          conversationId: convo.id,
          envelopeType: wire.EnvelopeType.mlsApplication,
          recipientAccountId: r.accountId,
          recipientDeviceId: r.deviceId,
          ciphertext: ct,
          ttlSeconds: _contentTtlSeconds,
          pushKind: pushKindOverride ??
              pushKindForRecipient(
                  recipientAccountId: r.accountId,
                  selfAccountId: session.accountId),
        ));
        firstOk ??= res;
      } catch (e) {
        firstErr ??= e;
        debugPrint('mls migrate: app to ${r.deviceId} failed: $e');
      }
    }
    if (firstOk == null) {
      throw firstErr ?? StateError('mls migrate: no recipient reached');
    }

    return firstOk;
  }

  Future<Set<String>?> _loadKnownOwnDevices() async {
    try {
      final raw = await _secureStorage.getString(knownOwnDevicesKey);
      if (raw == null) return null;
      return (jsonDecode(raw) as List).cast<String>().toSet();
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveKnownOwnDevices(Set<String> ids) async {
    try {
      await _secureStorage.putString(
          knownOwnDevicesKey, jsonEncode(ids.toList()));
    } catch (_) {/* best-effort */}
  }

  /// Detects a device freshly linked to THIS account and adds it to every
  /// already-migrated MLS 1:1 group so it receives going forward (a 1:1 that
  /// migrated before the link otherwise strands the new device — it never got a
  /// Welcome). Exactly one EXISTING device does the adding — the lexically
  /// device elected by AdderElection (the device that linked it, else the
  /// smallest old id) — so two devices can't race to add the newcomer and
  /// fork the group. Covers MLS 1:1s and MLS groups. Best-effort: a failure just retries on the next connect.
  Future<void> _reconcileOwnDevicesIntoGroups() async {
    // Triggered from connect() AND the live devices_changed signal, which can
    // land while a sweep is already running. Two overlapping sweeps would both
    // add the newcomer to the same group (forking it), so run one at a time and
    // coalesce triggers that arrive meanwhile into a single follow-up pass.
    if (_ownDeviceReconcileRunning) {
      _ownDeviceReconcileAgain = true;
      return;
    }
    _ownDeviceReconcileRunning = true;
    try {
      do {
        _ownDeviceReconcileAgain = false;
        await _reconcileOwnDevicesIntoGroupsOnce();
      } while (_ownDeviceReconcileAgain);
    } finally {
      _ownDeviceReconcileRunning = false;
    }
  }

  bool _ownDeviceReconcileRunning = false;
  bool _ownDeviceReconcileAgain = false;

  Future<void> _reconcileOwnDevicesIntoGroupsOnce() async {
    final session = await _sessions.current();
    if (session == null) return;
    _deviceCache.clearMyDevices();
    final List<Device> myDevices;
    try {
      myDevices = await _myDeviceList();
    } catch (_) {
      return;
    }
    if (myDevices.isEmpty) return;
    final currentIds = myDevices.map((d) => d.deviceId).toSet();

    final known = await _loadKnownOwnDevices();
    if (known == null) {
      // First observation — baseline only. Devices already present were added
      // at migration time (or will be when a conversation first migrates);
      // retro-adding them here would double-add and fork the group.
      await _saveKnownOwnDevices(currentIds);
      return;
    }
    final newIds = currentIds.difference(known)..remove(session.deviceId);
    if (newIds.isEmpty) {
      if (currentIds.length != known.length) {
        await _saveKnownOwnDevices(currentIds);
      }
      return;
    }
    // Per new device, elect ONE existing device to add it (the device that
    // linked it if still active, else the smallest old id) — see AdderElection.
    // Every device computes the same answer from the same list. Devices we are
    // not the adder for are just recorded as handled (the elected adder keeps
    // its own pending state until its sweep fully succeeds).
    final addIds = <String>{
      for (final d in myDevices)
        if (newIds.contains(d.deviceId) &&
            AdderElection.adderFor(
                    newDevice: d,
                    activeDevices: myDevices,
                    newDeviceIds: newIds) ==
                session.deviceId)
          d.deviceId,
    };
    if (addIds.isEmpty) {
      await _saveKnownOwnDevices(currentIds); // not us — just rebaseline
      return;
    }
    final deviceById = {for (final d in myDevices) d.deviceId: d};

    // Add the new device(s) to each MLS 1:1. Fetch FRESH key packages PER
    // CONVERSATION — an MLS key package is single-use, so reusing one across
    // groups makes every Welcome after the first invalid (CoreCrypto rejects it
    // with MlsArgumentException). A transient failure leaves `retryNeeded` set
    // so we don't rebaseline and instead retry the whole sweep next connect.
    final backfilled = await _loadBackfilledHistory();
    final addedLog =
        PersistedMarkerSet(storage: _secureStorage, key: ownDeviceAddedKey);
    final added = await addedLog.load();
    var retryNeeded = false;
    for (final convo in _byId.values.toList()) {
      if (convo.cryptoMode != CryptoMode.mls ||
          (convo.kind != ConversationKind.oneToOne &&
              convo.kind != ConversationKind.group)) {
        continue;
      }
      // Skip the (single-use) key-package fetch when every device is already in.
      if (addIds.every((id) => added.contains('$id|${convo.id}'))) continue;
      final Map<String, List<int>> kpByDevice;
      try {
        final myKps = await _api.lookupDeviceKeyPackages(session.username);
        kpByDevice = {for (final k in myKps) k.deviceId: k.keyPackage};
      } catch (e) {
        debugPrint('reconcile: key-package fetch for ${convo.id} failed: $e');
        retryNeeded = true;
        continue;
      }
      for (final newId in addIds) {
        if (added.contains('$newId|${convo.id}')) continue;
        final kp = kpByDevice[newId];
        if (kp == null) {
          // It publishes ~100 packages right after linking; stay pending so a
          // later connect / devices_changed retries instead of re-baselining.
          retryNeeded = true;
          continue;
        }
        try {
          if (convo.kind == ConversationKind.group) {
            await _groupManager.addOwnDeviceToGroup(
                conversationId: convo.id,
                newDevice: deviceById[newId]!,
                keyPackage: kp);
          } else {
            await _addDeviceToOneToOneGroup(
                convo.id, session.accountId, newId, kp);
          }
        } catch (e) {
          debugPrint('reconcile: add $newId to ${convo.id} failed: $e');
          retryNeeded = true;
          continue;
        }
        added.add('$newId|${convo.id}');
        await addedLog.save(added);
        // The device is now an MLS member of this 1:1 — replay its recent
        // history so a freshly-linked device isn't blank. Once per
        // (device, convo); best-effort (a failure retries on a later sweep, and
        // the receiver dedups so a re-send is harmless).
        final marker = '$newId|${convo.id}';
        if (!backfilled.contains(marker)) {
          try {
            await _backfillHistoryToDevice(convo.id, session.accountId, newId);
            backfilled.add(marker);
            await _saveBackfilledHistory(backfilled);
          } catch (e) {
            debugPrint('reconcile: backfill $newId for ${convo.id} failed: $e');
          }
        }
        // Also hand the new device this chat's state (mute/pin/archive/timer/
        // block/verified/background/read position). Best-effort; the existing
        // retry/marker behaviour above is unaffected.
        try {
          await _stateSync.sendFullState(convo.id);
        } catch (e) {
          debugPrint('reconcile: state sync for ${convo.id} failed: $e');
        }
      }
    }
    // Only rebaseline once the sweep fully succeeded — otherwise a missed add
    // would become permanent (the device would never be seen as "new" again).
    if (!retryNeeded) {
      await _saveKnownOwnDevices(currentIds);
    }
  }

  /// Adds one of our OWN newly-linked devices to an existing MLS 1:1 group:
  /// Welcome to the new device, Commit to every current member (peer devices +
  /// our other old devices), so the newcomer joins at the post-add epoch.
  Future<void> _addDeviceToOneToOneGroup(
    String conversationId,
    String myAccountId,
    String newDeviceId,
    List<int> keyPackage,
  ) async {
    await _runLocked(conversationId, () async {
      final convo = _byId[conversationId];
      if (convo == null || convo.cryptoMode != CryptoMode.mls) return;
      final r = await _crypto.addMember(
          groupId: conversationId, peerKeyPackage: keyPackage);
      // Welcome to the new device.
      await _api.submitMessage(SubmitMessagePayload(
        conversationId: conversationId,
        envelopeType: wire.EnvelopeType.mlsWelcome,
        recipientAccountId: myAccountId,
        recipientDeviceId: newDeviceId,
        ciphertext: r.welcome,
      ));
      // Commit to every existing member device (NOT the newcomer — it joins via
      // the Welcome above).
      final recipients = (await _mlsFanoutRecipients(convo))
          .where((rc) => rc.deviceId != newDeviceId);
      for (final rc in recipients) {
        try {
          await _api.submitMessage(SubmitMessagePayload(
            conversationId: conversationId,
            envelopeType: wire.EnvelopeType.mlsHandshake,
            recipientAccountId: rc.accountId,
            recipientDeviceId: rc.deviceId,
            ciphertext: r.commit,
          ));
        } catch (e) {
          debugPrint('reconcile commit to ${rc.deviceId} failed: $e');
        }
      }
      final epoch = await _crypto.currentEpoch(conversationId);
      if (convo.mlsEpoch != epoch) {
        final updated = convo.copyWith(mlsEpoch: epoch);
        _byId[conversationId] = updated;
        await _db.updateConversationGroupFields(conversationId, mlsEpoch: epoch);
        notifyListeners();
      }
    });
  }

  /// How many of the newest messages per 1:1 to replay to a newly-linked
  /// device. Bounded so a long-running chat doesn't ship its whole archive.
  static const int _historyBackfillLimit = 200;

  /// Soft cap on a single backfill chunk's encoded JSON. Stays well under the
  /// WS frame limit (512 KiB) and the server message cap (1 MiB), with headroom
  /// for MLS framing + base64 expansion.
  static const int _historyBackfillChunkBytes = 200 * 1024;

  /// Replays the recent history of one 1:1 to a freshly-added own [newDeviceId]
  /// so a linked device isn't blank. Reads the newest stored messages, chunks
  /// them under the per-envelope size budget, and sends each chunk as an MLS
  /// application message addressed ONLY to the new device (history stays private
  /// to our own fleet — never fanned to the peer). Idempotent on the receiver,
  /// so a partial run is safe to resume on a later sweep. Runs encrypted at the
  /// post-add epoch the new device just joined via its Welcome.
  Future<void> _backfillHistoryToDevice(
    String conversationId,
    String myAccountId,
    String newDeviceId,
  ) async {
    final List<ChatMessage> history;
    try {
      history =
          await _db.loadMessages(conversationId, limit: _historyBackfillLimit);
    } catch (_) {
      return;
    }
    // Real, server-acked, renderable messages only — skip system events and any
    // still-local outbox / failed / uploading rows.
    final eligible = history
        .where((m) =>
            m.outboxId == null &&
            !m.failed &&
            !m.uploading &&
            m.kind != MessageKind.system)
        .toList(growable: false);
    if (eligible.isEmpty) return;
    final chunks = _chunkBackfill(eligible);
    for (var i = 0; i < chunks.length; i++) {
      final payload = HistoryBackfill(
        conversationId: conversationId,
        seq: i + 1,
        total: chunks.length,
        messages: chunks[i],
      ).encode();
      await _runLocked(conversationId, () async {
        final convo = _byId[conversationId];
        if (convo == null || convo.cryptoMode != CryptoMode.mls) return;
        final ct = await _crypto.encrypt(
            groupId: conversationId, plaintext: utf8.encode(payload));
        await _api.submitMessage(SubmitMessagePayload(
          conversationId: conversationId,
          envelopeType: wire.EnvelopeType.mlsApplication,
          recipientAccountId: myAccountId,
          recipientDeviceId: newDeviceId,
          ciphertext: ct,
          // History replay to our OWN new device — dozens of old messages must
          // not each raise a "new message" banner there.
          pushKind: PushKind.silent,
        ));
      });
    }
  }

  /// Packs [msgs] (ascending) into chunks each under [_historyBackfillChunkBytes].
  List<List<BackfillMessage>> _chunkBackfill(List<ChatMessage> msgs) {
    final chunks = <List<BackfillMessage>>[];
    var current = <BackfillMessage>[];
    var currentBytes = 0;
    for (final m in msgs) {
      final bm = _toBackfillMessage(m);
      final size = utf8.encode(jsonEncode(bm.toJson())).length;
      if (current.isNotEmpty &&
          currentBytes + size > _historyBackfillChunkBytes) {
        chunks.add(current);
        current = <BackfillMessage>[];
        currentBytes = 0;
      }
      current.add(bm);
      currentBytes += size;
    }
    if (current.isNotEmpty) chunks.add(current);
    return chunks;
  }

  BackfillMessage _toBackfillMessage(ChatMessage m) => BackfillMessage(
        envelopeId: m.envelopeId,
        serverTsMs: m.serverTs.toUtc().millisecondsSinceEpoch,
        senderDeviceId: m.senderDeviceId,
        mine: m.mine,
        kind: m.kind,
        body: m.body,
        expiresAtMs: m.expiresAt?.toUtc().millisecondsSinceEpoch,
        mediaId: m.mediaId,
        mediaKey: m.mediaKey,
        mediaSha256: m.mediaSha256,
        mediaSize: m.mediaSize,
        mediaMime: m.mediaMime,
        mediaFilename: m.mediaFilename,
        voiceWaveform: m.voiceWaveform,
        mediaDurationMs: m.mediaDurationMs,
        replyToEnvelopeId: m.replyToEnvelopeId,
        replyToSender: m.replyToSender,
        replyToPreview: m.replyToPreview,
        forwarded: m.forwarded,
      );

  Future<Set<String>> _loadBackfilledHistory() async {
    try {
      final raw = await _secureStorage.getString(backfilledHistoryKey);
      if (raw == null) return <String>{};
      return (jsonDecode(raw) as List).cast<String>().toSet();
    } catch (_) {
      return <String>{};
    }
  }

  Future<void> _saveBackfilledHistory(Set<String> markers) async {
    try {
      await _secureStorage.putString(
          backfilledHistoryKey, jsonEncode(markers.toList()));
    } catch (_) {/* best-effort */}
  }



  /// The X25519 key for [deviceId]. Delegates to [DeviceCache].
  List<int> _x25519ForSender(Conversation convo, String deviceId) =>
      _deviceCache.x25519ForSender(convo, deviceId);

  /// Refreshes the peer-device + own-device caches (a cold inbound from a newly
  /// linked device needs its X25519 to seed the ratchet).
  Future<void> _warmDeviceCaches(Conversation convo) async {
    try {
      _recordPeerDisplayName(await _api.lookupAccount(convo.peerUsername));
    } catch (_) {/* offline — sender stays undecryptable, dropped */}
    _deviceCache.clearMyDevices();
    await _myDeviceList();
  }

  /// Like [DeviceCache.isMyDevice] but warms the own-device cache once if it's never been
  /// loaded — a RECEIVE-ONLY linked device never populates it on a send path,
  /// so a self-synced copy of our own message (relayed from a sibling device)
  /// would otherwise render as incoming instead of `mine`. Only fetches when
  /// the cache is cold, so a genuine peer device doesn't trigger a lookup on
  /// every inbound message.
  Future<bool> _isMyDeviceWarm(String deviceId, String myDeviceId) =>
      _deviceCache.isMyDeviceWarm(deviceId, myDeviceId);

  /// Fetches one catchup page, preferring the already-open WebSocket.
  ///
  /// `POST /messages/catchup` runs right after connect, concurrently with the
  /// rest of the connect fan-out, so it can't reuse a pooled connection and pays
  /// a full DNS+TCP+TLS setup. Measured on-device 2026-08-22 that single request
  /// cost 644-957ms while the server answered it in under 10ms — more than half
  /// the whole catchup. The socket is already warm, and the SEND path has taken
  /// this route for a while (the `send` frame); this is the receive half.
  ///
  /// Falls back to HTTP on ANY socket failure. A drain is a pure READ that
  /// consumes nothing, so — unlike a send — re-issuing it can never
  /// double-deliver; the worst case is exactly the old behaviour.
  Future<List<wire.Envelope>> _fetchCatchupPage() async {
    if (_ws.isConnected) {
      try {
        return await _ws.catchupOverSocket(
          'catchup-${_clientRefCounter++}',
          limit: _catchupPageSize,
        );
      } catch (_) {
        // Not connected, refused, dropped or timed out — fall through to HTTP
        // rather than leave the backlog undrained.
      }
    }
    return _api.catchupMessages(limit: _catchupPageSize);
  }

  /// Counts one failed sealed-OPEN for [envelopeId] and, once it has failed
  /// [_maxUnopenableSealedRedeliveries] times, acks it so it stops redelivering
  /// forever. Mirrors the MLS receiver's bound for undecryptable application
  /// messages: never destroy a message on its FIRST failure, never let a truly
  /// dead one churn indefinitely.
  Future<void> _boundUnopenableSealed(String envelopeId) async {
    // DURABLE, for the same reason as the MLS bound: an in-memory count resets
    // on every app start, and an envelope we can never unseal fails exactly
    // once per launch — so it would re-drain forever without ever reaching the
    // drop threshold.
    final n = await _retryLog.recordFailure(envelopeId);
    if (n >= _maxUnopenableSealedRedeliveries) {
      await _retryLog.forget(envelopeId);
      try {
        await ack([envelopeId]);
      } catch (_) {/* best-effort; retried next reconnect */}
    }
  }

  /// Republishes this device's CURRENT X25519 sealing key after we failed to
  /// open a sealed envelope.
  ///
  /// Peers encrypt the sealed outer layer to whatever the SERVER holds for us,
  /// so a stale published key makes us unreachable in a way no amount of
  /// retrying, reconnecting or re-keying on the sender's side can fix — the
  /// device itself is the only party that knows the real key. Throttled by
  /// [_sealingKeyRepublishCooldown] because a catchup batch fails to open many
  /// envelopes at once.
  Future<void> _republishSealingKey() async {
    final last = _lastSealingKeyRepublish;
    if (last != null &&
        DateTime.now().difference(last) < _sealingKeyRepublishCooldown) {
      return;
    }
    _lastSealingKeyRepublish = DateTime.now();
    try {
      final identity = await _crypto.currentIdentity();
      final key = identity?.x25519PublicKey ?? const <int>[];
      if (key.isEmpty) return;
      await _api.reportSealedCapability(x25519PubKey: key);
    } catch (_) {
      // Best-effort: allow an immediate retry on the next failed unseal rather
      // than sitting out the cooldown after a transient network error.
      _lastSealingKeyRepublish = null;
    }
  }

  /// The peer account id of a 1:1 conversation, parsed from its
  /// `1to1:<accA>:<accB>` id — the account that isn't [myAccountId]. Returns
  /// '' if the id doesn't parse or neither half is ours.
  String _peerAccountFromOneToOneId(String convoId, String myAccountId) {
    final parts = convoId.split(':');
    if (parts.length != 3) return '';
    if (parts[1] == myAccountId) return parts[2];
    if (parts[2] == myAccountId) return parts[1];
    return '';
  }


  /// Monotonic counter for WS-send correlation ids (`client_ref`). Only needs
  /// to be unique among concurrently in-flight sends on this client.
  int _clientRefCounter = 0;

  /// Applies a sealed, Ed25519-signed transport "delivered" receipt the
  /// recipient's background isolate sent back (see
  /// `core/push/sealed_delivered_receipt.dart`). Verifies the signature against
  /// the conversation peer's identity key BEFORE advancing the receipt, so a
  /// forged or replayed marker is dropped. Funnels through the same monotonic
  /// [_applyReceipt] path as every other receipt (never downgrades `read`).
  Future<void> _applySealedDeliveredReceipt(wire.Envelope env) async {
    final receipt = DeliveredReceipt.tryDecode(env.ciphertext);
    if (receipt == null) return;
    final convo = _byId[receipt.conversationId];
    if (convo == null || convo.peerIdentityPubKey.length != 32) return;
    if (!await receipt.verify(convo.peerIdentityPubKey)) return;
    await _runLocked(
      receipt.conversationId,
      () => _receiptService.applyReceipt(receipt.conversationId, ReceiptKind.delivered,
          [receipt.deliveredEnvelopeId]),
    );
  }

  /// Submits one envelope over the PREFERRED transport: the already-open,
  /// always-warm WebSocket when it's up (a frame on the live socket, no per-send
  /// TCP/TLS setup), falling back to an HTTP POST only when the socket isn't
  /// connected — in which case the frame never left, so there's no
  /// double-delivery risk. A WS send that reaches the socket but then times out
  /// / errors is deliberately NOT retried on HTTP (the frame may have landed):
  /// it propagates as a failed send + manual retry.
  Future<SubmitMessageResult> _submit(SubmitMessagePayload rawPayload) async {
    // Sealed-sender (Phase 1 seal + Phase 2 unauthenticated deposit) is owned by
    // SealedSender; trySubmitUnauthenticated returns non-null only when a sealed
    // envelope was accepted on the unauth path, else we fall through to the
    // authenticated WS/HTTP send below (privacy degrades, delivery does not).
    final payload = await _sealedSender.seal(rawPayload);
    // Retry ONLY this network leg, and only on a TRANSIENT failure (no HTTP
    // status = the request never reached the server). The seal above stays
    // OUTSIDE the retry on purpose: every attempt re-sends the SAME sealed
    // bytes, so nothing re-encrypts, no ratchet advances, and — critically — no
    // MLS key package is consumed. Retrying further out (around encrypt+submit)
    // would re-run the migration path, which fetches SINGLE-USE key packages.
    //
    // What this buys: a message typed while built-in Tor is still connecting
    // used to die permanently — `_submitOutbox` marks the outbox row failed on
    // ANY throw, so the fail-closed SOCKS sentinel (pre-bootstrap) or the
    // bearer-less client (at the moment Tor connects) destroyed it, and only a
    // manual tap re-sent it. Media never had this bug because its pipeline has
    // always retried transients. Now both share one policy ([TransientRetry]).
    return _submitRetry.run(() async {
      // Sealed-sender is re-attempted with the already-sealed payload; it
      // returns non-null only when the unauth deposit was ACCEPTED, so a retry
      // can't double-deposit a previously-rejected envelope.
      final unauthResult = await _sealedSender.trySubmitUnauthenticated(payload);
      if (unauthResult != null) return unauthResult;
      if (_ws.isConnected) {
        final clientRef = 's${_clientRefCounter++}';
        try {
          final ack = await _ws.sendAndAwaitAck(
            {'type': 'send', 'client_ref': clientRef, ...payload.toJson()},
            clientRef,
          );
          return SubmitMessageResult(
            envelopeId: ack.envelopeId,
            serverTs: ack.serverTs,
          );
        } on WsNotConnectedException {
          // Socket dropped between the isConnected check and the write — the
          // frame never went out, so the HTTP fallback below is safe.
        }
      }
      return _api.submitMessage(payload);
    });
  }

  /// Eagerly migrates a still-ratchet 1:1 to MLS in the background (creates the
  /// group + ships the Welcome) when a thread opens, so the FIRST message send
  /// is a fast MLS application message instead of paying the migration
  /// round-trips (key-package lookup + Welcome) inline. Best-effort +
  /// idempotent: no-ops for non-1:1, already-MLS, an unidentified peer, or a
  /// MULTI-DEVICE peer (those migrate via the all-devices path on first send).
  /// Any failure leaves the conversation on ratchet to migrate lazily on the
  /// next send — no regression.
  Future<void> warmUpMlsMigration(String conversationId) async {
    final convo = _byId[conversationId];
    if (convo == null ||
        convo.kind != ConversationKind.oneToOne ||
        convo.cryptoMode != CryptoMode.ratchet ||
        convo.peerAccountId.isEmpty) {
      return;
    }
    // Multi-device peers need the all-devices migration (handled lazily on the
    // first send); only warm up the simple single-device-peer case here.
    // A cold or stale directory can hide the peer's second device, and a
    // warm-up group built without it strands that device. If the directory
    // can't be refreshed, don't warm up — the first send migrates properly.
    if (_deviceCache.peerDevices(convo.peerAccountId).isEmpty ||
        _deviceCache.peerDevicesStale(convo.peerAccountId)) {
      try {
        _recordPeerDisplayName(await _api
            .lookupAccount(convo.peerUsername)
            .timeout(const Duration(seconds: 5)));
      } catch (_) {
        return;
      }
    }
    final peerDevices = _deviceCache.peerDevices(convo.peerAccountId);
    if (peerDevices.length > 1) return;
    // A warm-up group holds only the peer, so with sibling devices it would
    // both miss them and race their own warm-up. Those accounts migrate via the
    // all-devices path on first send (single designated initiator).
    final session = await _sessions.current();
    if (session == null) return;
    if ((await _myDeviceList()).any((d) => d.deviceId != session.deviceId)) {
      return;
    }

    await _runLocked(conversationId, () async {
      final live = _byId[conversationId];
      if (live == null ||
          live.cryptoMode != CryptoMode.ratchet ||
          live.peerX25519PubKey.isEmpty) {
        return; // raced with a send that already migrated, or not addressable
      }
      final migrator = MlsMigrator(
        bridge: _crypto,
        apiClient: _api,
        myAccountId: myAccountId,
        // Unused on the migrate-only path — it never falls to ratchet encrypt.
        legacyEncryptOnRatchet: (_, _) async => const <int>[],
      );
      final w = await migrator.migrateOnly(live);
      if (w == null) return; // can't migrate yet — stays ratchet

      // Ship the Welcome so the peer can join. On failure, leave the local group
      // in place (don't wipe) and stay ratchet: the next real send's lazy
      // migration recovers the orphan via createGroup→wipe→retry, the same path
      // a failed inline migration already takes today.
      try {
        await _submit(SubmitMessagePayload(
          conversationId: conversationId,
          envelopeType: wire.EnvelopeType.mlsWelcome,
          recipientAccountId: live.peerAccountId,
          recipientDeviceId: w.recipientDeviceId,
          ciphertext: w.welcome,
          // Warm-up migration ships a bare Welcome (no content) when a chat is
          // opened — it must not raise a phantom "new message" on the peer.
          pushKind: PushKind.silent,
        ));
      } catch (e) {
        debugPrint('mls warm-up: welcome submit failed for $conversationId: $e');
        return; // stays ratchet (mode not flipped); lazy migration retries
      }

      // Welcome shipped — flip to MLS so the next send is a plain app message.
      final migrated = live.copyWith(cryptoMode: CryptoMode.mls);
      _byId[conversationId] = migrated;
      await _db.upsertConversation(migrated);
      await _db.deleteConversationCryptoState(conversationId);
      notifyListeners();
    });
  }

  /// Submits the same already-encrypted ciphertext to every [recipients] device
  /// CONCURRENTLY — one envelope per device — instead of one sequential
  /// round-trip per device. With N devices this turns N×RTT into ~1×RTT.
  /// Best-effort, matching the per-device partial-failure posture: returns the
  /// first success (in recipient order), and only throws — with the first
  /// error — when EVERY recipient failed. Safe because each call ships an
  /// independent envelope of the same pre-computed ciphertext (no shared crypto
  /// state advances during submit); the ratchet fan-out, which advances state
  /// per device, deliberately stays sequential.
  /// Co-delivery timing-jitter window. A group / multi-device send fans the same
  /// ciphertext out to N devices; firing all submits at the same instant lets
  /// the server (and any observer) cluster "N envelopes at time T = one group
  /// message" → group size / co-membership. Spreading the submits over a short
  /// random window decorrelates that. Partial only — a determined
  /// timing-correlation attacker needs a mixnet to fully defeat (out of scope;
  /// see docs/metadata-threat-model.md) — and kept small to stay sub-perceptible.
  static const Duration _fanoutJitterWindow = Duration(milliseconds: 600);

  /// The random pre-submit delay for one fan-out recipient: zero for a single
  /// recipient (nothing to decorrelate — and no latency cost on a 1:1 single
  /// device), else a uniform draw in `[0, _fanoutJitterWindow]`. Pure (rng
  /// injected) so the range/edge logic is unit-testable without timing flakiness.
  @visibleForTesting
  static Duration fanoutJitterDelay(int recipientCount, Random rng) {
    if (recipientCount <= 1) return Duration.zero;
    return Duration(
        milliseconds: rng.nextInt(_fanoutJitterWindow.inMilliseconds + 1));
  }

  Future<SubmitMessageResult> _fanoutSubmit<T>(
    List<T> recipients,
    SubmitMessagePayload Function(T) payloadFor, {
    required String label,
  }) async {
    final rng = Random();
    final settled = await Future.wait(
      recipients.map((r) async {
        // Spread co-delivered submits over [_fanoutJitterWindow] (see above).
        // Safe to delay: each submit ships an independent, pre-computed
        // ciphertext — no shared crypto state advances here — and the user's
        // optimistic "sent" tick is already shown before fan-out, so this only
        // shifts server-side reconciliation by sub-second, never the UI.
        final d = fanoutJitterDelay(recipients.length, rng);
        if (d > Duration.zero) await Future<void>.delayed(d);
        try {
          return (ok: await _submit(payloadFor(r)), err: null);
        } catch (e) {
          debugPrint('$label fanout failed: $e');
          return (ok: null as SubmitMessageResult?, err: e as Object?);
        }
      }),
    );
    SubmitMessageResult? firstOk;
    Object? firstError;
    for (final s in settled) {
      firstOk ??= s.ok;
      if (s.err != null) firstError ??= s.err;
    }
    if (firstOk == null) {
      throw firstError ?? StateError('$label: no recipient reached');
    }
    return firstOk;
  }

  Future<void> _submitOutbox({
    required String conversationId,
    required String outboxId,
    required String Function() buildWireBody,
    required List<int>? mediaBytesForCache,
  }) async {
    final convo = _byId[conversationId];
    if (convo == null) {
      throw StateError('conversation $conversationId not found');
    }

    // Addressability guard: a 1:1 whose peer was never identified (or —
    // legacy data bug — whose peerAccountId is OUR OWN account id, from
    // the old MLS-welcome fallback) must not submit: the envelope would be
    // dropped or, worse, delivered back to ourselves.
    if (convo.kind == ConversationKind.oneToOne) {
      final myAccountId = (await _sessions.current())?.accountId;
      if (convo.peerAccountId.isEmpty || convo.peerAccountId == myAccountId) {
        throw StateError(
            'conversation $conversationId has no addressable peer');
      }
    }

    // Legacy path guard: if peerX25519PubKey is empty, _ratchetCore.encryptForConvo
    // would fail inside MlsMigrator. Surface a clear StateError early.
    if (convo.peerX25519PubKey.isEmpty && convo.cryptoMode == CryptoMode.ratchet) {
      throw StateError('crypto: no peer key for conversation $conversationId');
    }

    return _runLocked(conversationId, () async {
      var peerSessionRecovered = false;
      var lostGroupRebuilt = false;
      while (true) {
        try {
          await _encryptSubmitAndAck(
            conversationId: conversationId,
            outboxId: outboxId,
            buildWireBody: buildWireBody,
            mediaBytesForCache: mediaBytesForCache,
            forceMigration: lostGroupRebuilt,
          );
          return;
        } catch (e) {
          // An MLS 1:1 whose LOCAL group is gone (CoreCrypto store rebuilt on an
          // app update, restore from phrase, an old build's self-removal wipe):
          // the encrypt throws "Couldn't find conversation" and, before this,
          // the message dead-ended with that raw error on screen and the chat
          // stayed unsendable until the user made a new account. Rebuild in
          // place instead: drop the dead group, fall back to ratchet, and retry
          // THIS message with a forced migration — the same rebuild
          // MlsReceiver.maybeReestablish performs, except the fresh Welcome
          // carries the user's actual message rather than a no-op control.
          // Forced because the stranded side may be the migration FOLLOWER,
          // which the role rule would otherwise keep on ratchet.
          final lost = _byId[conversationId];
          if (!lostGroupRebuilt && lost != null && _isLostLocalMlsGroup(e, lost)) {
            lostGroupRebuilt = true;
            await _resetLostMlsGroup(lost);
            continue;
          }
          // A 1:1 send addressed to a peer device that no longer exists — the
          // peer wiped + restored from their recovery phrase, minting a NEW
          // device and revoking the old — bounces with account_not_found (the
          // server's delivery liveness check). Re-resolve the peer's CURRENT
          // devices, drop the now-stale MLS group, and retry ONCE so the
          // message converges on the new device instead of dead-ending.
          final live = _byId[conversationId];
          if (!peerSessionRecovered &&
              live != null &&
              live.kind == ConversationKind.oneToOne &&
              _isPeerDeviceGone(e)) {
            peerSessionRecovered = true;
            if (await _reestablishPeerSession(live) != null) {
              continue; // retry the send against the refreshed device set
            }
          }
          await _markOutboxFailed(conversationId, outboxId);
          rethrow;
        }
      }
    });
  }

  /// One encrypt → submit → ack-merge attempt for an outbox message, extracted
  /// from [_submitOutbox] so it can be retried after [_reestablishPeerSession]
  /// rebuilds a peer whose device set changed under us. Runs INSIDE the
  /// conversation lock (never re-takes it).
  Future<void> _encryptSubmitAndAck({
    required String conversationId,
    required String outboxId,
    required String Function() buildWireBody,
    required List<int>? mediaBytesForCache,
    bool forceMigration = false,
  }) async {
    // Re-read from _byId — state may have been mutated by a concurrent
    // receive between the optimistic append and the lock acquisition.
    final liveConvoAtSend = _byId[conversationId];
    if (liveConvoAtSend == null) return; // convo removed concurrently
    var wireBody = buildWireBody();

    // While either conversation-privacy flag is on, every outgoing 1:1
    // message carries the flags as the OUTERMOST header so the peer
    // converges statelessly (new conversations, re-installs, missed
    // toggle broadcasts). Both-off sends no header — the explicit OFF
    // travels via MessageControl.privacy from broadcastPrivacyFlags.
    if (liveConvoAtSend.kind == ConversationKind.oneToOne) {
      final flags = _privacyFlagsProvider?.call();
      if (flags != null && (flags.screenshots || flags.forwarding)) {
        wireBody = PrivacyHeader(
              blocksScreenshots: flags.screenshots,
              blocksForwarding: flags.forwarding,
            ).encodePrefix() +
            wireBody;
      }
    }

    // Disappearing TTL rides as the OUTERMOST header on every message so
    // the recipient expires it on OUR timer (serverTs + this), not their
    // own retention setting. Captured here and reused for our own copy's
    // expiry once the server assigns the authoritative serverTs on ack.
    // Per-conversation override wins over the global default.
    final ttlSecs = _effectiveDisappearingSeconds(liveConvoAtSend);
    if (ttlSecs != null && ttlSecs > 0) {
      wireBody = TtlHeader(ttlSecs).encodePrefix() + wireBody;
    }

    // Stable client message id (the outboxId) as the OUTERMOST header. A send
    // whose ack was lost is auto-resent on the next reconnect, re-encrypting but
    // reusing this SAME outboxId — so both copies carry the same `_cid` and the
    // receiver dedups them (renders once). Rides inside the E2EE body, invisible
    // to the server (sealed-sender safe). See [ClientMsgIdHeader].
    if (outboxId.isNotEmpty) {
      wireBody = ClientMsgIdHeader(outboxId).encodePrefix() + wireBody;
    }

    // Multi-device 1:1 (ratchet): fan out a separate ciphertext per device
    // (each its own ratchet), bypassing the single-peer MlsMigrator path.
    // Single-device, groups, and MLS conversations keep the existing path.
    final SubmitMessageResult result;
    final fanoutTargets =
        (liveConvoAtSend.kind == ConversationKind.oneToOne &&
                liveConvoAtSend.cryptoMode == CryptoMode.ratchet)
            ? await _multiDeviceTargets(liveConvoAtSend)
            : null;
    if (fanoutTargets != null) {
      // Multi-device 1:1 on ratchet: migrate the whole conversation to an
      // MLS group that includes EVERY device of both accounts, so the
      // message delivers to all of them (and stays delivered as MLS from
      // here on). Falls back to per-device ratchet fan-out only when the
      // peer hasn't published MLS key packages yet.
      final mlsResult = await _migrateAllDevicesToMls(
          liveConvoAtSend, wireBody,
          force: forceMigration);
      result = mlsResult ??
          await _ratchetCore.fanout(conversationId, wireBody, fanoutTargets,
              selfAccountId: (await _sessions.current())?.accountId);
    } else {
    // The ratchet callback captures the advanced state here but does NOT
    // persist it — persistence happens after a successful submit below,
    // matching the pre-MlsMigrator invariant that the sender's chain only
    // advances past slots the server has actually acknowledged.
    ConversationCryptoState? pendingRatchetState;
    final migrator = MlsMigrator(
      bridge: _crypto,
      apiClient: _api,
      myAccountId: myAccountId,
      legacyEncryptOnRatchet: (c, pt) => _ratchetCore.encryptForConvo(
        c,
        pt,
        onStateAdvanced: (s) => pendingRatchetState = s,
      ),
    );

    final migResult = await migrator.encryptForSend(
      convo: liveConvoAtSend,
      plaintext: utf8.encode(wireBody),
      forceMigration: forceMigration,
    );

    // 1. Submit Welcome envelope FIRST when migrating.
    if (migResult.welcomeBytes != null) {
      await _api.submitMessage(SubmitMessagePayload(
        conversationId: conversationId,
        envelopeType: wire.EnvelopeType.mlsWelcome,
        recipientAccountId: liveConvoAtSend.peerAccountId,
        recipientDeviceId: migResult.welcomeRecipientDeviceId!,
        ciphertext: migResult.welcomeBytes!,
      ));
    }

    // 2. Submit the application envelope — addressed to the single peer
    //    for 1:1s, fanned out to every other member's device for groups.
    //    (peerAccountId/peerDeviceId are EMPTY on group conversations —
    //    submitting to them was a silent black hole.)
    if (liveConvoAtSend.kind == ConversationKind.group) {
      // Every member device EXCEPT this one — our OWN other devices are
      // members too (self-sync), so filter by device id, not isSelf.
      final sendSession = await _sessions.current();
      final myDeviceId = sendSession?.deviceId;
      final selfAccountId = sendSession?.accountId;
      final recipients = liveConvoAtSend.members
          .where((m) => m.deviceId != myDeviceId)
          .toList();
      if (recipients.isEmpty) {
        throw StateError(
            'group $conversationId has no other members to send to');
      }
      // Partial-failure posture matches createGroup's Welcome fanout:
      // deliver to whoever is reachable; the send only counts as failed
      // when NO member got it. Unreached members recover via catchup the
      // next time they submit/ack (their envelope was never inserted, so
      // they simply miss this message — same gap group chat already has
      // for offline members beyond retention). Fanned out concurrently.
      result = await _fanoutSubmit(
        recipients,
        (m) => SubmitMessagePayload(
          conversationId: conversationId,
          envelopeType: migResult.envelopeType,
          recipientAccountId: m.accountId,
          recipientDeviceId: m.deviceId,
          ciphertext: migResult.ciphertext,
          ttlSeconds: ttlSecs,
          pushKind: pushKindForRecipient(
              recipientAccountId: m.accountId, selfAccountId: selfAccountId),
        ),
        label: 'group send',
      );
    } else if (migResult.envelopeType == wire.EnvelopeType.mlsApplication) {
      // MLS 1:1 — fan the single ciphertext out to every device of the peer
      // plus our own other devices (all are group members). For a
      // single-device peer this reduces to one recipient, identical to the
      // old single-peer submit.
      final recipients = await _mlsFanoutRecipients(liveConvoAtSend);
      final selfAccountId = (await _sessions.current())?.accountId;
      result = await _fanoutSubmit(
        recipients,
        (rcpt) => SubmitMessagePayload(
          conversationId: conversationId,
          envelopeType: migResult.envelopeType,
          recipientAccountId: rcpt.accountId,
          recipientDeviceId: rcpt.deviceId,
          ciphertext: migResult.ciphertext,
          ttlSeconds: ttlSecs,
          // Our own other devices get the self-sync copy silently.
          pushKind: pushKindForRecipient(
              recipientAccountId: rcpt.accountId,
              selfAccountId: selfAccountId),
        ),
        label: 'mls 1:1 send',
      );
    } else {
      // Single-device ratchet 1:1 (text_legacy) — submit to the peer.
      result = await _submit(SubmitMessagePayload(
        conversationId: conversationId,
        envelopeType: migResult.envelopeType,
        recipientAccountId: liveConvoAtSend.peerAccountId,
        recipientDeviceId: liveConvoAtSend.peerDeviceId,
        ciphertext: migResult.ciphertext,
        ttlSeconds: ttlSecs,
      ));
    }

    // 3. Persist the ratchet state advancement now that the ciphertext is
    //    acknowledged. On the MLS path pendingRatchetState stays null
    //    (no ratchet involved), so this is a no-op for MLS sends.
    if (pendingRatchetState != null) {
      await _db.saveConversationCryptoState(pendingRatchetState!);
    }

    // 4. On successful migration: persist the crypto_mode flip.
    if (migResult.newMode == CryptoMode.mls &&
        liveConvoAtSend.cryptoMode == CryptoMode.ratchet) {
      final migratedConvo = liveConvoAtSend.copyWith(cryptoMode: CryptoMode.mls);
      _byId[conversationId] = migratedConvo;
      await _db.upsertConversation(migratedConvo);
      await _db.deleteConversationCryptoState(conversationId);
      notifyListeners();
    }
    } // end single-device / group / MLS path

    // Find the current outbox message (which may have been updated with
    // descriptor fields by the upload worker between insert and submit).
    final liveBeforeAck = _byId[conversationId];
    if (liveBeforeAck == null) return;
    final pending = liveBeforeAck.messages.firstWhere(
      (m) => m.outboxId == outboxId,
      orElse: () => throw StateError(
          'outbox $outboxId vanished before ack'),
    );

    // Build the acked message and merge it into the *current* state of
    // `_byId[conversationId]` — between the optimistic append and now,
    // a peer message may have arrived via WS. Preserve those. Clearing
    // `pendingUploadKey` here is part of the post-ack cleanup: the
    // staging file is about to be deleted, so the key would only point
    // at empty disk.
    final ackedMessage = pending.copyWith(
      envelopeId: result.envelopeId,
      serverTs: result.serverTs,
      outboxId: '',
      clearPendingUploadKey: true,
      // Expire our own copy on the same timer the recipient got (the TTL
      // we just sent), anchored to the server's authoritative timestamp.
      expiresAt: ttlSecs != null && ttlSecs > 0
          ? result.serverTs.toUtc().add(Duration(seconds: ttlSecs))
          : null,
    );
    final live = _byId[conversationId];
    if (live != null) {
      final replaced = <ChatMessage>[
        for (final m in live.messages)
          if (m.envelopeId != outboxId) m,
        ackedMessage,
      ];
      _byId[conversationId] = live.copyWith(messages: replaced);
      if (mediaBytesForCache != null) {
        _mediaCache.put(result.envelopeId, mediaBytesForCache);
        _mediaCache.evict(outboxId);
        // Move any thumbnail cached under outboxId to envelopeId so the
        // outgoing video bubble doesn't re-decode immediately after ack.
        final outboxThumb = _mediaCache.cachedThumbnail(outboxId);
        if (outboxThumb != null) {
          _mediaCache.evictThumbnail(outboxId);
          _mediaCache.putThumbnail(result.envelopeId, outboxThumb);
        }
      }
      await _db.deleteMessage(outboxId);
      await _db.upsertMessages(conversationId, [ackedMessage]);
      await _maybeTrim(conversationId);
      // Best-effort: the bytes are now on the server, the bubble can
      // re-download them after _mediaCache eviction, and the encrypted
      // staging file is dead weight.
      await _pendingUploadStaging.delete(outboxId);
      notifyListeners();
      // Build the link's preview card AFTER this send finishes (and off the
      // conversation lock — the service re-takes it to attach the card, so
      // running it inline would self-deadlock). Never delays or fails the send.
      unawaited(Future(() => _linkPreviewService.attachFor(ackedMessage)));
    }
  }

  /// True when [e] is the server's "recipient account deleted or device revoked"
  /// rejection (`account_not_found`) — surfaced as a [WsSendException] (WS send
  /// path), an [ApiError] (HTTP fallback), or an [AccountNotFoundException]. It
  /// means the peer DEVICE we addressed is gone, the tell-tale of a peer that
  /// wiped + restored from their recovery phrase (new device, old one revoked).
  bool _isPeerDeviceGone(Object e) {
    if (e is AccountNotFoundException) return true;
    if (e is WsSendException) return e.code == 'account_not_found';
    if (e is ApiError) return e.code == 'account_not_found';
    return false;
  }

  /// True when [e] says CoreCrypto holds NO group for the MLS 1:1 [convo] — a
  /// state no retry of the same encrypt can fix, but a rebuild can. Groups are
  /// excluded: only an existing member can re-add us there.
  bool _isLostLocalMlsGroup(Object e, Conversation convo) =>
      e is MlsUnknownGroupException &&
      convo.kind == ConversationKind.oneToOne &&
      convo.cryptoMode == CryptoMode.mls &&
      convo.peerAccountId.isNotEmpty;

  /// Drops the (already missing) local MLS group of the 1:1 [convo] and flips
  /// it back to ratchet so the next encrypt re-migrates from scratch. Mirrors
  /// the reset in [MlsReceiver.maybeReestablish]; also tells the receiver a
  /// rebuild just happened, so an already-queued re-establishment doesn't wipe
  /// the fresh group this send is about to create. Lock-free: the caller holds
  /// the conversation lock.
  Future<void> _resetLostMlsGroup(Conversation convo) async {
    debugPrint('mls: local group for ${convo.id} is gone; rebuilding on send');
    try {
      await _crypto.wipeGroup(convo.id);
    } catch (_) {/* nothing to wipe — that's the point */}
    final reset = convo.copyWith(
      cryptoMode: CryptoMode.ratchet,
      needsReestablishment: false,
    );
    _byId[convo.id] = reset;
    await _db.upsertConversation(reset);
    try {
      await _db.deleteConversationCryptoState(convo.id);
    } catch (_) {/* none existed */}
    _mlsReceiver.noteLocalRebuild(convo.id);
    notifyListeners();
  }

  /// Recovers a 1:1 whose peer changed devices under us — the peer wiped +
  /// restored from their recovery phrase, minting a NEW device id and revoking
  /// the old one, so our cached device + stale MLS group now address a dead
  /// device and every send bounces with `account_not_found`. Re-resolves the
  /// peer's CURRENT devices (refreshing the device cache), drops the stale local
  /// MLS group, and flips the conversation back to ratchet so the next send
  /// re-migrates a fresh group against the new device. Lock-free: the caller
  /// must already hold the conversation lock. Returns the refreshed conversation,
  /// or null when the peer can't be re-resolved (whole account gone / offline) —
  /// recovery is impossible right now, so the send should fail normally.
  Future<Conversation?> _reestablishPeerSession(Conversation convo) async {
    if (convo.peerUsername.isEmpty) return null;
    final Account account;
    try {
      account = await _api.lookupAccount(convo.peerUsername);
    } catch (_) {
      return null;
    }
    _recordPeerDisplayName(account); // refreshes the peer-device cache
    // Drop the stale local MLS group (its only leaf is the peer's dead device).
    try {
      await _crypto.wipeGroup(convo.id);
    } catch (_) {/* no local group to wipe */}
    final refreshed = Conversation(
      id: convo.id,
      peerUsername: convo.peerUsername,
      peerAccountId: convo.peerAccountId,
      peerDeviceId: account.deviceId ?? convo.peerDeviceId,
      peerIdentityPubKey: account.identityPubKey.isNotEmpty
          ? account.identityPubKey
          : convo.peerIdentityPubKey,
      peerX25519PubKey: account.x25519PubKey.isNotEmpty
          ? account.x25519PubKey
          : convo.peerX25519PubKey,
      messages: convo.messages,
      unreadCount: convo.unreadCount,
      verified: convo.verified,
      hasMoreOlderMessages: convo.hasMoreOlderMessages,
      // Flip to ratchet so the retry re-migrates a fresh group from scratch.
      cryptoMode: CryptoMode.ratchet,
      needsReestablishment: convo.needsReestablishment,
      kind: convo.kind,
      groupName: convo.groupName,
      groupAvatar: convo.groupAvatar,
      members: convo.members,
      mlsEpoch: null,
      pending: convo.pending,
      pinned: convo.pinned,
      pinnedEnvelopeId: convo.pinnedEnvelopeId,
      muted: convo.muted,
      archived: convo.archived,
      blocked: convo.blocked,
      peerBlocksScreenshots: convo.peerBlocksScreenshots,
      peerBlocksForwarding: convo.peerBlocksForwarding,
      disappearingTtl: convo.disappearingTtl,
    );
    _byId[convo.id] = refreshed;
    await _db.upsertConversation(refreshed);
    try {
      await _db.deleteConversationCryptoState(convo.id);
    } catch (_) {/* none existed */}
    notifyListeners();
    return refreshed;
  }

  /// Flips the outbox entry to `failed=true, uploading=false`. Used by both
  /// the `_submitOutbox` error path and the upload worker's catch block.
  /// No-op if the outbox row has already disappeared.
  Future<void> _markOutboxFailed(String conversationId, String outboxId) async {
    final live = _byId[conversationId];
    if (live == null) return;
    final replaced = <ChatMessage>[
      for (final m in live.messages)
        m.outboxId == outboxId
            ? m.copyWith(failed: true, uploading: false)
            : m,
    ];
    _byId[conversationId] = live.copyWith(messages: replaced);
    final failed = replaced.firstWhere(
      (m) => m.outboxId == outboxId,
      orElse: () => throw StateError('outbox $outboxId not in convo $conversationId'),
    );
    await _db.upsertMessages(conversationId, [failed]);
    notifyListeners();
  }

  /// Text-send path: optimistic append immediately followed by encrypt +
  /// submit. Media sends go through [UploadWorker.enqueue] instead so the foreground
  /// UI doesn't block on the upload.
  Future<void> _sendOptimistic({
    required String conversationId,
    required String myDeviceId,
    required String bodyForUI,
    required MessageKind kind,
    required String Function() buildWireBody,
    ReplyRef? replyRef,
    bool forwarded = false,
  }) async {
    final outboxId = await _insertOptimisticMessage(
      conversationId: conversationId,
      myDeviceId: myDeviceId,
      bodyForUI: bodyForUI,
      kind: kind,
      uploading: false,
      replyToEnvelopeId: replyRef?.envelopeId,
      replyToSender: replyRef?.sender,
      replyToPreview: replyRef?.preview,
      forwarded: forwarded,
    );
    return _submitOutbox(
      conversationId: conversationId,
      outboxId: outboxId,
      // Headers ride at the front of the wire body (reply, then forward
      // marker); the receiver splits them back off in
      // MessageAppender.append in the same order.
      buildWireBody: () {
        var body = buildWireBody();
        if (forwarded) body = '${ForwardMarker.prefix}$body';
        if (replyRef != null) body = '${replyRef.encodePrefix()}$body';
        return body;
      },
      mediaBytesForCache: null,
    );
  }


  /// Per-conversation FIFO lock. The first caller for a given conversation
  /// gets a fresh slot; subsequent callers chain off the prior slot's
  /// completion. Conversations are independent — different convo IDs run
  /// in parallel.
  Future<T> _runLocked<T>(String conversationId, Future<T> Function() body) async {
    final previous = _convoLocks[conversationId];
    final completer = Completer<void>();
    _convoLocks[conversationId] = completer.future;
    if (previous != null) {
      try {
        await previous;
      } catch (_) {
        // Prior holder threw; we don't care — we just need it to finish.
      }
    }
    try {
      return await body();
    } finally {
      completer.complete();
      // Only remove if no one queued behind us.
      if (identical(_convoLocks[conversationId], completer.future)) {
        _convoLocks.remove(conversationId);
      }
    }
  }

  /// Bumps the per-conversation insert counter and trims the on-disk history
  /// only once it crosses [_trimInterval] — so the `trimMessages` delete-scan
  /// doesn't run on every delivered/sent message. Call right after
  /// persisting an inserted message. A conversation can sit up to
  /// [_trimInterval] rows over [messageCap] between trims, which is harmless.
  Future<void> _maybeTrim(String conversationId) async {
    final n = (_insertsSinceTrim[conversationId] ?? 0) + 1;
    if (n < _trimInterval) {
      _insertsSinceTrim[conversationId] = n;
      return;
    }
    _insertsSinceTrim[conversationId] = 0;
    await _db.trimMessages(conversationId, keep: messageCap);
  }

  /// Called after [_ensureHydrated] succeeds. For each conversation in
  /// [CryptoMode.mls] mode, verifies that CoreCrypto knows about the
  /// corresponding group via [CryptoBridge.currentEpoch].
  ///
  /// - **Success:** the epoch is retrieved; no persistent change (no
  ///   `mlsEpoch` column until Plan C's schema bump). Any prior
  ///   [Conversation.needsReestablishment] flag is cleared.
  /// - **[MlsUnknownGroupException]:** CoreCrypto can't open the group;
  ///   the conversation is flagged [Conversation.needsReestablishment] so
  ///   the UI can surface a banner. The flag is in-memory only — not
  ///   persisted. The same reconciliation re-runs on every app boot so the
  ///   condition is re-detected automatically.
  /// - **Any other exception:** left alone — transient errors (I/O, etc.)
  ///   should not incorrectly flag healthy conversations.
  ///
  /// Ratchet-mode conversations are skipped entirely.
  @visibleForTesting
  Future<void> reconcileMlsConversations() async {
    final myDeviceId = (await _sessions.current())?.deviceId;
    for (final convo in _byId.values.toList()) {
      if (convo.cryptoMode != CryptoMode.mls) continue;
      try {
        // Bounded: a poisoned group's native call can hang forever (observed
        // live), and an unbounded probe here would stall reconcile — and with
        // it the reconcile gate every catchup waits on.
        await _crypto
            .currentEpoch(convo.id)
            .timeout(const Duration(seconds: 10));
        // Success — clear any prior needsReestablishment flag.
        if (convo.needsReestablishment) {
          _byId[convo.id] = convo.copyWith(needsReestablishment: false);
          notifyListeners();
        }
      } on TimeoutException {
        // ignore: avoid_print
        print('reconcile: currentEpoch on ${convo.id} HUNG >10s; skipping');
      } on MlsUnknownGroupException {
        // CoreCrypto doesn't know this group — flag for re-establishment.
        _byId[convo.id] = convo.copyWith(needsReestablishment: true);
        notifyListeners();
        // Proactively heal a 1:1 we hold NO group for (typically after a
        // recovery-phrase restore wiped our MLS store). Without this we'd wait
        // for the peer's next message to fail to decrypt 3× before re-keying —
        // and every message in that window is lost (sealed to a group we left).
        // Kicking off the SAME deterministic re-establishment now gets a fresh
        // Welcome to the peer before they send. MlsReceiver.maybeReestablish owns all
        // the safety: the device-id tiebreaker (so two restored sides don't
        // both re-key), the 45s cooldown, and the in-flight guard. We seed the
        // failure count to the threshold so it proceeds; a peer Welcome that
        // lands first clears it and aborts our attempt.
        if (myDeviceId != null &&
            convo.kind == ConversationKind.oneToOne &&
            convo.peerAccountId.isNotEmpty &&
            convo.peerDeviceId.isNotEmpty) {
          unawaited(Future(() => _mlsReceiver.maybeReestablish(
              convo.id, convo.peerDeviceId, myDeviceId, force: true)));
        }
      } catch (_) {
        // Unexpected error — leave the conversation state unchanged.
      }
    }
  }

  Future<void> _ensureHydrated() async {
    if (_hydrated) return;
    if (!_db.isOpen) {
      final master = await _ensureMasterKey();
      try {
        // A freshly minted key means any leftover on-disk DB is encrypted with
        // the old, now-gone key and can never be decrypted — so let open() wipe
        // + recreate it instead of wedging start-up forever on "Connecting…". A
        // key loaded from storage keeps the file: open() throws
        // DatabaseUnreadableException and we degrade to in-memory below rather
        // than destroy possibly-recoverable history.
        await _db.open(
          masterKeyHex: master.key,
          recreateIfUnreadable: master.generated,
        );
      } on DatabaseUnreadableException catch (e) {
        // Last-resort, non-destructive fallback: the encrypted file exists but
        // can't be opened with the stored key (corruption, or a key/file skew
        // we won't auto-wipe). Swap in an ephemeral in-memory store so the
        // session still works this run; the on-disk file is left untouched for
        // a future launch where the key might line up again.
        debugPrint('conversations: DB unreadable, degrading to in-memory ($e)');
        _databaseDegradedToMemory = true;
        _diskDb = _db; // keep the real (unreadable) store for an explicit reset
        _db = AppDatabaseInMemory();
        await _db.open(masterKeyHex: master.key);
      }
    }
    // Only the most recent page per conversation. Older messages stream in
    // on demand via `loadOlderMessages` when the user scrolls up.
    final convos = await _db.loadConversations(
      messagesPerConversation: messagesInitialPage,
    );
    for (final c in convos) {
      _byId[c.id] = c;
    }
    // Mirror the deleted-group tombstones so the receive gate survives a
    // restart — the resurrecting envelopes are redelivered on every catchup,
    // including the very first one after a cold start.
    try {
      _deletedGroupIds
        ..clear()
        ..addAll(await _db.loadDeletedGroupIds());
    } catch (_) {/* best-effort: an older store has no tombstone table */}
    await _recoverStalledUploads();
    // Keep the background-isolate mute + block lists + caller-name map in sync
    // with what we just loaded.
    await _settings.persistMutedSet();
    await _settings.persistBlockedSet();
    await _stateSync.load();
    await _persistCallPeerNames();
    _hydrated = true;
  }

  /// Recovers from [databaseDegradedToMemory]: wipes the unreadable on-disk
  /// database and switches back to a real persistent store, then re-hydrates
  /// (the fresh DB is empty). The account, keys and session are untouched — no
  /// re-onboarding; messages still on the server re-sync on the next catchup.
  /// The throwaway in-memory data (which never persisted) is discarded. No-op
  /// unless currently degraded. (Distinct from [resetLocalDatabase], the
  /// account-switch/delete wipe that also rotates the SQLCipher key.)
  Future<void> recoverDegradedDatabase() async {
    final disk = _diskDb;
    if (!_databaseDegradedToMemory || disk == null) return;
    final master = await _ensureMasterKey();
    // Explicit, user-vouched wipe — the on-disk history is unreadable and
    // unrecoverable, so authorise open() to delete + recreate the file.
    await disk.open(masterKeyHex: master.key, recreateIfUnreadable: true);
    try {
      await _db.close();
    } catch (_) {/* best-effort: drop the throwaway in-memory store */}
    _db = disk;
    _diskDb = null;
    _databaseDegradedToMemory = false;
    _byId.clear();
    _hydrated = false;
    await _ensureHydrated();
    notifyListeners();
  }

  /// Resumes (or fails) every persisted `uploading=true` row on cold start.
  /// For each row:
  ///   - If the staging file + `pendingUploadKey` still decrypt cleanly,
  ///     re-enqueue the upload so the worker picks up where it left off.
  ///   - Otherwise flip the row to `failed=true, uploading=false` so the
  ///     bubble surfaces the retry affordance (which will return false since
  ///     the bytes aren't recoverable).
  /// Also sweeps orphan staging files (on disk but no matching `uploading=true`
  /// row) — they're leftovers from a crash between [writeEncrypted] and the
  /// DB upsert.
  Future<void> _recoverStalledUploads() async {
    final referencedOutboxIds = <String>{};
    for (final entry in _byId.entries.toList()) {
      final convo = entry.value;
      final dbUpdates = <ChatMessage>[];
      final newMessages = <ChatMessage>[];
      for (final m in convo.messages) {
        if (m.outboxId == null) {
          newMessages.add(m);
          continue;
        }
        // Track ALL outbox rows that hold a staging key — uploading rows
        // get resumed below, failed rows keep their staging file around so
        // `retryUpload` can read it. Anything not referenced is an orphan
        // and swept after the loop.
        if (m.pendingUploadKey != null) {
          referencedOutboxIds.add(m.outboxId!);
        }
        if (!m.uploading) {
          newMessages.add(m);
          continue;
        }
        final key = m.pendingUploadKey;
        final bytes = key == null
            ? null
            : await _pendingUploadStaging.readDecrypted(
                outboxId: m.outboxId!,
                key: key,
              );
        if (bytes == null) {
          // Staging gone or decrypt failed — unrecoverable.
          final failed = m.copyWith(
            uploading: false,
            failed: true,
            clearPendingUploadKey: true,
          );
          newMessages.add(failed);
          dbUpdates.add(failed);
          continue;
        }
        // Re-prime the in-memory cache so the bubble + retry both work, and
        // queue the upload so the worker resumes it.
        _mediaCache.put(m.outboxId!, bytes);
        newMessages.add(m);
        _uploadWorker.enqueue(PendingUpload(
          outboxId: m.outboxId!,
          conversationId: entry.key,
          myDeviceId: m.senderDeviceId,
          kind: m.kind,
          bytes: bytes,
          mimeType: m.mediaMime ?? _defaultMimeForKind(m.kind),
          bodyForUI: m.body,
          filename: m.mediaFilename,
          waveform: m.voiceWaveform,
          durationMs: m.mediaDurationMs,
        ));
      }
      if (dbUpdates.isNotEmpty) {
        _byId[entry.key] = convo.copyWith(messages: newMessages);
        await _db.upsertMessages(entry.key, dbUpdates);
      }
    }
    // Orphan sweep: any staging file without a referencing outbox row.
    try {
      final staged = await _pendingUploadStaging.listStagedOutboxIds();
      for (final id in staged) {
        if (!referencedOutboxIds.contains(id)) {
          await _pendingUploadStaging.delete(id);
        }
      }
    } catch (_) {/* best-effort sweep */}
    // Any decrypted-media temp file present at boot is a straggler from a prior
    // session (a crash left it behind, or the OS hasn't evicted the temp dir).
    // Nothing has been viewed yet this run, so wiping them all is safe.
    await _tempMediaStore.sweepAll();
  }

  /// Prepends up to [messagesPageSize] older messages to the in-memory
  /// window for [conversationId]. The cursor is the oldest currently-loaded
  /// message's `serverTs`. When the DB returns fewer than [messagesPageSize]
  /// rows, sets `hasMoreOlderMessages = false` so the UI can hide the
  /// load-more affordance.
  ///
  /// Idempotent: a no-op when the conversation has no more older messages
  /// or already has a load in flight (single-flight via the convo lock).
  Future<void> loadOlderMessages(String conversationId) async {
    final convo = _byId[conversationId];
    if (convo == null) return;
    if (!convo.hasMoreOlderMessages) return;
    if (convo.messages.isEmpty) {
      // No anchor for the cursor — fall back to loading the first page.
      // This branch is reachable only if a caller manually cleared the
      // in-memory window without resetting hasMoreOlderMessages.
      return;
    }
    return _runLocked(conversationId, () async {
      // Re-read after the lock; another caller may have advanced the window
      // already, in which case hasMore could have flipped false.
      final live = _byId[conversationId];
      if (live == null || !live.hasMoreOlderMessages || live.messages.isEmpty) {
        return;
      }
      final cursorMs = live.messages.first.serverTs.millisecondsSinceEpoch;
      final older = await _db.loadMessages(
        conversationId,
        limit: messagesPageSize,
        beforeServerTsMs: cursorMs,
      );
      final hasMore = older.length == messagesPageSize;
      final updated = live.copyWith(
        messages: [...older, ...live.messages],
        hasMoreOlderMessages: hasMore,
      );
      _byId[conversationId] = updated;
      notifyListeners();
    });
  }

  /// Everything still stored for [conversationId] that was shared in it —
  /// photos/videos, links and files — read straight from the database so it
  /// covers the whole history, not just the pages currently in memory.
  Future<SharedContent> sharedContentFor(String conversationId) {
    return SharedContentLoader().load(({required limit, beforeServerTsMs}) =>
        _db.loadMessages(conversationId,
            limit: limit, beforeServerTsMs: beforeServerTsMs));
  }

  /// Returns the SQLCipher master key and whether it was freshly generated this
  /// call (`generated: true`) versus loaded from secure storage. A freshly
  /// generated key means any pre-existing on-disk database is encrypted with a
  /// key that no longer exists and can never be decrypted, so the open path uses
  /// `generated` to decide it's safe to wipe + recreate an unreadable file.
  ///
  /// A null read is taken as "no key yet" and MINTS a new one — which, if a DB
  /// exists, authorises that wipe. A transient secure-storage hiccup that
  /// returns null for a key that actually exists would therefore orphan + then
  /// destroy a perfectly good database. So re-read a few times before concluding
  /// the key is genuinely absent. (A read that THROWS already propagates and
  /// never reaches the mint path, so only the null case needs guarding.)
  Future<({String key, bool generated})> _ensureMasterKey() async {
    for (var attempt = 0; attempt < _masterKeyReadAttempts; attempt++) {
      final existing = await _secureStorage.getString(dbMasterKeyKey);
      if (existing != null && existing.length >= 64) {
        return (key: existing, generated: false);
      }
      if (attempt < _masterKeyReadAttempts - 1) {
        await Future<void>.delayed(
            Duration(milliseconds: 100 * (attempt + 1)));
      }
    }
    // Consistently absent → genuinely no key (a fresh install, or the OS dropped
    // the keystore entry). Mint + persist; `generated: true` lets the open path
    // wipe a provably-orphaned unreadable DB.
    final rng = Random.secure();
    final bytes = List<int>.generate(32, (_) => rng.nextInt(256));
    final hex = bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    await _secureStorage.putString(dbMasterKeyKey, hex);
    return (key: hex, generated: true);
  }

  /// How many times [_ensureMasterKey] re-reads secure storage before deciding
  /// the key is absent — guards a transient null read from clobbering a key that
  /// actually exists (which would then doom the on-disk DB).
  static const int _masterKeyReadAttempts = 3;

  @override
  void dispose() {
    _wsSub?.cancel();
    _disappearingSweepTimer?.cancel();
    _catchupRetryTimer?.cancel();
    _typingService.clear();
    _stateSync.dispose();
    _supervisorSub?.cancel();
    _supervisor.removeListener(_onSupervisorStateChanged);
    // Fire-and-forget — dispose() is sync. The supervisor's stop() and the
    // WS disconnect both await internally; without an explicit `disconnect()`
    // call by the caller, these run unawaited.
    _supervisor.stop();
    _ws.disconnect();
    super.dispose();
  }
}
