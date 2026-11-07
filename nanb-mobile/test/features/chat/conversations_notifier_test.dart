import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:nanb_chat/core/crypto/add_member_result.dart';
import 'package:nanb_chat/core/crypto/conversation_crypto_state.dart';
import 'package:nanb_chat/core/crypto/crypto_bridge.dart';
import 'package:nanb_chat/core/crypto/delivered_receipt.dart';
import 'package:nanb_chat/core/push/local_notifications.dart';
import 'package:nanb_chat/core/crypto/decrypt_mls_result.dart';
import 'package:nanb_chat/core/crypto/mls_exceptions.dart';
import 'package:nanb_chat/core/crypto/sealed_envelope.dart';
import 'package:nanb_chat/core/crypto/sealed_inner.dart';
import 'package:nanb_chat/core/db/app_database.dart';
import 'package:nanb_chat/core/models/account.dart';
import 'package:nanb_chat/core/models/device.dart';
import 'package:nanb_chat/core/models/api_error.dart';
import 'package:nanb_chat/core/models/envelope.dart';
import 'package:nanb_chat/core/push/push_kind.dart';
import 'package:nanb_chat/core/models/jwt_session.dart';
import 'package:nanb_chat/core/network/api_client.dart';
import 'package:nanb_chat/core/network/connection_state.dart';
import 'package:nanb_chat/core/network/ws_client.dart';
import 'package:nanb_chat/core/network/ws_connection_event.dart';
import 'package:nanb_chat/core/network/ws_reconnect_supervisor.dart';
import 'package:nanb_chat/core/secure_storage/secure_storage.dart';
import 'package:nanb_chat/features/chat/conversations_notifier.dart';
import 'package:nanb_chat/features/chat/models/message_control.dart';
import 'package:nanb_chat/features/chat/media_pipeline.dart';
import 'package:nanb_chat/features/chat/pending_upload_staging.dart';
import 'package:nanb_chat/features/chat/services/temp_media_store.dart';
import 'package:nanb_chat/features/chat/video/video_thumbnail_generator.dart';
import 'package:nanb_chat/features/chat/video/video_thumbnail_loader.dart';
import 'package:nanb_chat/features/chat/models/chat_message.dart';
import 'package:nanb_chat/features/chat/models/history_backfill.dart';
import 'package:nanb_chat/features/chat/models/reply_ref.dart';
import 'package:nanb_chat/features/calls/models/call_signal.dart';
import 'package:nanb_chat/features/chat/models/conversation.dart';
import 'package:nanb_chat/features/chat/models/conversation_kind.dart';
import 'package:nanb_chat/features/chat/models/system_event.dart';
import 'package:nanb_chat/features/chat/models/crypto_mode.dart';
import 'package:nanb_chat/features/chat/models/group_member.dart';
import 'package:nanb_chat/features/chat/models/message_kind.dart';
import 'package:nanb_chat/core/push/notification_permission_gate.dart';
import 'package:nanb_chat/core/push/push_token_provider.dart';
import 'package:nanb_chat/core/push/push_token_registrar.dart';
import 'package:nanb_chat/features/onboarding/session_repository.dart';

class _MockApi extends Mock implements ApiClient {}

/// No-op video thumbnail generator. Constructed because the notifier requires
/// a [VideoThumbnailLoader], but no test in this file exercises the thumbnail
/// path so the generator is never invoked.
class _NoopVideoThumbnailGenerator implements VideoThumbnailGenerator {
  @override
  Future<Uint8List?> generate(String videoPath) async => null;
}

/// Test double that records uploads and serves them back from an in-memory
/// store on download — no real network or AES involved.
class _FakeMediaPipeline implements MediaPipeline {
  final Map<String, _FakeBlob> _store = {};
  int idCounter = 0;
  @override
  Future<MediaDescriptor> upload({
    required MessageKind kind,
    required List<int> plaintext,
    required String mimeType,
    String? filename,
    List<int>? waveform,
    int? durationMs,
    List<String>? authorizedAccountIds,
  }) async {
    final id = 'media-${++idCounter}';
    final key = List<int>.filled(32, 0xAB);
    final sha = List<int>.filled(32, 0xCD);
    _store[id] = _FakeBlob(plaintext, sha);
    return MediaDescriptor(
      kind: kind,
      mediaId: id,
      key: key,
      sha256: sha,
      sizeBytes: plaintext.length,
      mimeType: mimeType,
      filename: filename,
      waveform: waveform,
    );
  }

  @override
  Future<List<int>> download(MediaDescriptor descriptor) async {
    final blob = _store[descriptor.mediaId];
    if (blob == null) throw StateError('test: unknown media ${descriptor.mediaId}');
    return blob.bytes;
  }
}

class _FakeBlob {
  _FakeBlob(this.bytes, this.sha);
  final List<int> bytes;
  final List<int> sha;
}

class _FakeWs implements WsClient {
  final List<Map<String, dynamic>> ephemeralFrames = [];
  @override
  void sendEphemeral(Map<String, dynamic> frame) => ephemeralFrames.add(frame);
  final StreamController<Envelope> _controller = StreamController<Envelope>.broadcast();
  bool connected = false;
  String? connectedJwt;
  int connectCalls = 0;
  int disconnectCalls = 0;

  @override
  Stream<Envelope> get envelopes => _controller.stream;

  @override
  Stream<void> get disconnects => const Stream<void>.empty();

  @override
  Future<bool> probe({Duration timeout = const Duration(seconds: 5)}) async =>
      false;

  @override
  Future<void> connect(String jwt) async {
    connectCalls++;
    connectedJwt = jwt;
    connected = true;
  }

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
    connected = false;
  }

  // --- WS-send (Phase 2) ---
  /// Frames passed to [sendAndAwaitAck], captured for assertions.
  final List<Map<String, dynamic>> sentFrames = [];

  /// When set, [sendAndAwaitAck] resolves with this (the WS happy path). When
  /// null (the default), it throws [WsNotConnectedException] so the notifier's
  /// `_submit` falls back to the HTTP `api.submitMessage` mock — which is what
  /// the bulk of the send tests assert against.
  ({String envelopeId, DateTime serverTs})? wsAckResult;

  @override
  bool get isConnected => connected;

  /// Envelopes a socket drain returns. Null (default) means the socket refuses
  /// the drain, so the notifier falls back to HTTP — the pre-existing behaviour
  /// of every test that doesn't care about this path.
  List<Envelope>? catchupOverSocketResult;
  int catchupOverSocketCalls = 0;

  /// The `since` of every socket drain request, in order.
  final List<DateTime?> catchupOverSocketSinces = [];

  @override
  Future<List<Envelope>> catchupOverSocket(
    String clientRef, {
    int? limit,
    DateTime? since,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    catchupOverSocketCalls++;
    catchupOverSocketSinces.add(since);
    final r = catchupOverSocketResult;
    if (r == null) throw const WsNotConnectedException();
    return r;
  }

  @override
  Future<({String envelopeId, DateTime serverTs})> sendAndAwaitAck(
    Map<String, dynamic> frame,
    String clientRef, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    sentFrames.add(frame);
    final r = wsAckResult;
    if (!connected || r == null) throw const WsNotConnectedException();
    return r;
  }

  /// Envelope-id lists passed to [sendAckFrame], captured for assertions.
  final List<List<String>> ackFrames = [];

  /// Whether [sendAckFrame] "succeeds" over WS. Default false → the notifier's
  /// `ack` falls back to the HTTP `api.ackMessages` mock (preserving existing
  /// ack assertions); a WS-ack test flips it true.
  bool wsAckSucceeds = false;

  @override
  bool sendAckFrame(List<String> envelopeIds) {
    ackFrames.add(envelopeIds);
    return wsAckSucceeds;
  }

  void push(Envelope env) => _controller.add(env);

  Future<void> dispose() async => _controller.close();
}

/// Mimics the production supervisor flow tightly enough that existing
/// notifier tests asserting `ws.connectCalls == 1` keep working. `start()`
/// reads the session, calls `ws.connect(jwt)`, transitions to connected,
/// and emits `Reconnected`. `stop()` does NOT call `ws.disconnect()` here
/// because `ConversationsNotifier.disconnect()` calls `_ws.disconnect()`
/// directly after `_supervisor.stop()` — double-calling would break the
/// `ws.disconnectCalls == 1` assertions.
///
/// Test-only helpers `emitReconnected()` and `emitSignedOut()` simulate
/// the corresponding events without touching the WS, so tests of the
/// notifier's reaction to those events don't have to wrangle a fresh
/// connect lifecycle.
class _FakeSupervisor extends ChangeNotifier implements WsReconnectSupervisor {
  _FakeSupervisor({required this.wsClient, required this.sessions});

  final WsClient wsClient;
  final SessionRepository sessions;

  ConnectionState _state = ConnectionState.connecting;
  final _eventsCtrl = StreamController<WsConnectionEvent>.broadcast();
  int startCalls = 0;
  int stopCalls = 0;
  int appResumedCalls = 0;
  bool _disposed = false;

  @override
  ConnectionState get state => _state;

  @override
  Stream<WsConnectionEvent> get events => _eventsCtrl.stream;

  @override
  Future<void> start() async {
    startCalls++;
    final s = await sessions.current();
    if (s == null) return;
    await wsClient.connect(s.jwt);
    _state = ConnectionState.connected;
    notifyListeners();
    _eventsCtrl.add(const Reconnected());
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    _state = ConnectionState.connecting;
    notifyListeners();
  }

  @override
  void onAppResumed() {
    appResumedCalls++;
  }

  /// Mirrors the real supervisor: leaves the terminal signedOut state (and
  /// only that state) when onboarding establishes new credentials.
  @override
  void clearSignedOut() {
    if (_state != ConnectionState.signedOut) return;
    _state = ConnectionState.connecting;
    notifyListeners();
  }

  @override
  void forceReconnect({String source = 'unknown'}) {}

  @override
  Future<void> verifyConnectionOrReconnect() async {}

  void emitReconnected() {
    _state = ConnectionState.connected;
    notifyListeners();
    _eventsCtrl.add(const Reconnected());
  }

  void emitSignedOut() {
    _state = ConnectionState.signedOut;
    notifyListeners();
    _eventsCtrl.add(const SignedOut());
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _eventsCtrl.close();
    super.dispose();
  }
}

class _PassthroughCrypto implements CryptoBridge, SealOpener {
  /// Who CoreCrypto says is in any group. Empty means this device isn't a member.
  Set<String> memberDeviceIds = const {};

  @override
  Future<Set<String>> groupMemberDeviceIds(String groupId) async =>
      memberDeviceIds;

  @override
  Future<bool> consumeMlsStoreReset() async {
    final was = storeResetPending;
    storeResetPending = false;
    return was;
  }

  /// What the next [consumeMlsStoreReset] reports.
  bool storeResetPending = false;

  /// Sealed-sender (Phase 1): what [openSealed] returns. Defaults to echoing the
  /// input, so a test can push a sealed envelope whose ciphertext is already the
  /// SealedInner-encoded inner record. Set [throwOnOpenSealed] to model a blob
  /// not addressed to us.
  List<int>? sealedOpenReturn;
  bool throwOnOpenSealed = false;

  @override
  Future<List<int>> openSealed(List<int> sealed) async {
    if (throwOnOpenSealed) throw StateError('not for us');
    return sealedOpenReturn ?? sealed;
  }

  int encryptCalls = 0;
  int decryptCalls = 0;
  int mlsDecryptCalls = 0;
  int processWelcomeCalls = 0;
  int currentEpochCalls = 0;
  String processWelcomeResult = 'stub-group';

  /// When non-null, `currentEpoch` throws this instead of returning [currentEpochResult].
  Exception? currentEpochError;

  /// Returned by `currentEpoch` when [currentEpochError] is null.
  int currentEpochResult = 0;

  /// When set, `currentEpoch` blocks on this before returning. Reconcile probes
  /// every MLS conversation through it, so holding this open holds the whole
  /// MLS reconcile — and with it the gate that catchup waits on — open too.
  Completer<void>? currentEpochGate;

  @override
  Future<IdentityHandle> generateIdentity({List<int>? seed}) async =>
      IdentityHandle(id: 'h', publicKey: const [], x25519PublicKey: const []);

  /// What [currentIdentity] returns. Null models "no identity yet"; set it to
  /// give the device a sealing key the republish path can actually publish.
  IdentityHandle? identity;

  @override
  Future<IdentityHandle?> currentIdentity() async => identity;

  @override
  Future<List<int>> signWithIdentity(IdentityHandle handle, List<int> payload) async =>
      List<int>.filled(64, 0);

  @override
  Future<List<int>> mintKeyPackage(IdentityHandle handle) async => const <int>[];

  @override
  Future<ConversationCryptoState> initConversationCrypto({
    required String conversationId,
    required List<int> peerX25519PubKey,
  }) async {
    return ConversationCryptoState(
      conversationId: conversationId,
      sendCounter: 0,
      sendChainKey: List<int>.filled(32, 0),
      recvCounter: 0,
      recvChainKey: List<int>.filled(32, 0),
    );
  }

  @override
  Future<EncryptResult> encryptMessage({
    required ConversationCryptoState state,
    required List<int> plaintext,
  }) async {
    encryptCalls++;
    return EncryptResult(
      ciphertext: List<int>.from(plaintext),
      newState: state.copyWith(sendCounter: state.sendCounter + 1),
    );
  }

  /// When set, where a decrypt leaves the receive chain.
  int? ratchetRecvCounter;

  @override
  Future<DecryptResult> decryptMessage({
    required ConversationCryptoState state,
    required List<int> ciphertext,
  }) async {
    decryptCalls++;
    return DecryptResult(
      plaintext: List<int>.from(ciphertext),
      newState: state.copyWith(
          recvCounter: ratchetRecvCounter ?? state.recvCounter + 1),
    );
  }

  final List<String> clearedConversations = [];
  @override
  void clearConversationCrypto(String conversationId) {
    clearedConversations.add(conversationId);
  }

  @override
  Future<void> wipe() async {}

  @override
  Future<List<int>?> rawIdentitySeed() async => List<int>.filled(32, 0);

  @override
  Future<void> mlsInit() async {}

  @override
  Future<void> mlsEnsureClient(String deviceId) async {}

  @override
  Future<void> mlsInitReadOnly() async {}

  @override
  Future<void> mlsWipe() async {}

  int mintKeyPackagesCalls = 0;
  int? mintKeyPackagesLastCount;

  @override
  Future<List<List<int>>> mintKeyPackages({int count = 100}) async {
    mintKeyPackagesCalls++;
    mintKeyPackagesLastCount = count;
    return List.generate(count, (i) => List<int>.filled(64, i & 0xff));
  }

  /// Group ids CoreCrypto has NO local group for (store rebuilt, restored
  /// from phrase): [encrypt] throws "Couldn't find conversation" for them
  /// until [createGroup] builds the group again.
  final Set<String> missingGroups = {};

  @override
  Future<String> createGroup({required String conversationId}) async {
    missingGroups.remove(conversationId);
    return conversationId;
  }

  @override
  Future<AddMemberResult> addMembers({
    required String groupId,
    required List<List<int>> peerKeyPackages,
  }) async =>
      AddMemberResult(welcome: const [], commit: const []);

  @override
  Future<AddMemberResult> addMember({
    required String groupId,
    required List<int> peerKeyPackage,
  }) async => AddMemberResult(
        welcome: List<int>.filled(32, 0xAB),
        commit: List<int>.filled(32, 0xCC),
      );

  /// When set, [processWelcome] throws this every call (e.g. a non-MLS error
  /// that the welcome handler doesn't swallow → a poison envelope).
  Object? processWelcomeError;

  @override
  Future<String> processWelcome(List<int> welcomeBytes) async {
    processWelcomeCalls++;
    if (processWelcomeError != null) throw processWelcomeError!;
    return processWelcomeResult;
  }

  @override
  Future<void> processCommit({
    required String groupId,
    required List<int> commitBytes,
  }) async {}

  @override
  Future<int> currentEpoch(String groupId) async {
    currentEpochCalls++;
    final gate = currentEpochGate;
    if (gate != null) await gate.future;
    final err = currentEpochError;
    if (err != null) throw err;
    return currentEpochResult;
  }

  @override
  Future<List<int>> encrypt({
    required String groupId,
    required List<int> plaintext,
  }) async {
    if (missingGroups.contains(groupId)) {
      throw const MlsUnknownGroupException(
          "Couldn't find conversation");
    }
    return List<int>.from(plaintext);
  }

  @override
  Future<List<int>> decrypt({
    required String groupId,
    required List<int> ciphertext,
  }) async {
    mlsDecryptCalls++;
    return List<int>.from(ciphertext);
  }

  final List<({String localGroupId, List<int> foreignWelcome})> replaceGroupCalls = [];

  /// When set, [replaceGroup] throws this every call (e.g. an
  /// [MlsArgumentException] to simulate a permanently-invalid poison Welcome).
  Object? replaceGroupError;

  @override
  Future<String> replaceGroup({
    required String localGroupId,
    required List<int> foreignWelcome,
  }) async {
    replaceGroupCalls.add((localGroupId: localGroupId, foreignWelcome: foreignWelcome));
    if (replaceGroupError != null) throw replaceGroupError!;
    return localGroupId;
  }

  int wipeGroupCalls = 0;

  @override
  Future<void> wipeGroup(String groupId) async {
    wipeGroupCalls++;
  }

  @override
  Future<List<int>> removeMember({
    required String groupId,
    required String targetDeviceId,
  }) async => List<int>.filled(32, 0xCD);

  int decryptAndInspectCalls = 0;

  /// When set, [decryptAndInspect] throws this — models a diverged group that
  /// can't decrypt the peer's ciphertext (split brain).
  Object? decryptAndInspectError;

  /// When set, [decryptAndInspect] reports this as the MLS-authenticated sender
  /// (the credential's client id). Lets a test prove the receive path attributes
  /// the sender from the credential, not the transport `senderDeviceId`.
  /// Sealed-sender Phase 0.
  String? decryptSenderClientId;

  @override
  Future<DecryptMlsResult> decryptAndInspect({
    required String groupId,
    required List<int> ciphertext,
  }) async {
    decryptAndInspectCalls++;
    final err = decryptAndInspectError;
    if (err != null) throw err;
    return DecryptMlsResult(
      plaintext: List<int>.from(ciphertext),
      selfRemoved: false,
      newEpoch: 0,
      senderClientId: decryptSenderClientId,
    );
  }
}

/// Crypto stub that models the real ratchet's rejection of stale counters:
/// the first ciphertext byte is the sender's counter, and `decryptMessage`
/// only succeeds when it lines up with the recv counter. `initConversationCrypto`
/// always re-seeds to recvCounter 0. This lets a test drive the re-key recovery
/// path — a "wiped" peer that restarts at counter 0 fails against an advanced
/// chain but decrypts after the recovery re-init.
class _CounterCrypto extends _PassthroughCrypto {
  @override
  Future<ConversationCryptoState> initConversationCrypto({
    required String conversationId,
    required List<int> peerX25519PubKey,
  }) async {
    return ConversationCryptoState(
      conversationId: conversationId,
      sendCounter: 0,
      sendChainKey: List<int>.filled(32, 0),
      recvCounter: 0,
      recvChainKey: List<int>.filled(32, 0),
    );
  }

  @override
  Future<DecryptResult> decryptMessage({
    required ConversationCryptoState state,
    required List<int> ciphertext,
  }) async {
    decryptCalls++;
    final counter = ciphertext.isEmpty ? -1 : ciphertext[0];
    if (counter != state.recvCounter) {
      throw StateError('counter mismatch ($counter != ${state.recvCounter})');
    }
    // A chain seeded from different key material (anything but the fresh
    // all-zero root [initConversationCrypto] derives) can't open it either.
    if (state.recvChainKey.any((b) => b != 0)) {
      throw StateError('recv chain key mismatch');
    }
    return DecryptResult(
      plaintext: ciphertext.sublist(1),
      newState: state.copyWith(recvCounter: state.recvCounter + 1),
    );
  }
}

/// Ratchet fake that models a real chain's message counter: the first
/// ciphertext byte is the counter, a chain may skip ahead to it (as the real
/// one does within its catch-up window), and the advanced state records
/// `counter + 1` — so a test can tell a peer's RESTARTED chain (counter 0) from
/// one that is simply continuing.
class _ChainCounterCrypto extends _PassthroughCrypto {
  @override
  Future<DecryptResult> decryptMessage({
    required ConversationCryptoState state,
    required List<int> ciphertext,
  }) async {
    decryptCalls++;
    final counter = ciphertext.isEmpty ? -1 : ciphertext[0];
    if (counter < state.recvCounter) {
      throw StateError('replay or stale counter ($counter < ${state.recvCounter})');
    }
    return DecryptResult(
      plaintext: ciphertext.sublist(1),
      newState: state.copyWith(recvCounter: counter + 1),
    );
  }
}

const _myDeviceId = 'me-dev';
const _peerAccountId = 'peer-acc';
const _peerUsername = 'peer';

Account _peerAccount({String accountId = _peerAccountId, String username = _peerUsername}) {
  return Account(
    accountId: accountId,
    username: username,
    identityPubKey: const [9, 8, 7],
    // Non-empty so the conversation has a peer X25519 key and the ratchet
    // can init / encrypt without falling back to the placeholder branch.
    x25519PubKey: const <int>[1, 2, 3],
    // Matches the inbound envelopes' senderDeviceId so a 1:1's peerDeviceId
    // equals the sender — i.e. the primary-device ('') ratchet, as in reality.
    deviceId: 'peer-dev',
  );
}

Envelope _envelope({
  String envelopeId = 'env-1',
  String conversationId = '',
  String senderDeviceId = 'peer-dev',
  String envelopeType = EnvelopeType.mlsApplication,
  List<int> ciphertext = const [104, 105], // "hi"
  DateTime? serverTs,
}) {
  return Envelope(
    envelopeId: envelopeId,
    version: 'v1',
    domain: 'nanb.link',
    envelopeType: envelopeType,
    conversationId: conversationId,
    senderDeviceId: senderDeviceId,
    recipientAccountId: 'me-acc',
    recipientDeviceId: _myDeviceId,
    ciphertext: ciphertext,
    serverTs: serverTs ?? DateTime.utc(2026, 5, 7, 12),
  );
}

/// Captures the conversation ids that a local notification was raised for.
class _FakeLocalNotifications implements LocalNotifications {
  final List<String> shownConvoIds = [];
  final List<int> cancelledIds = [];

  @override
  Future<void> cancel(int id) async {
    cancelledIds.add(id);
  }

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
    required String conversationId,
  }) async {
    shownConvoIds.add(conversationId);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Stands in for a SQLCipher DB whose on-disk file can't be opened with the
/// supplied key — the wrong/lost-key situation that wedged start-up. It honours
/// the production [AppDatabase.open] contract: throw
/// [DatabaseUnreadableException] unless the caller opts into a wipe+recreate
/// (`recreateIfUnreadable: true`), in which case it "recreates" and opens clean
/// (delegating to the in-memory base).
class _UnreadableDb extends AppDatabaseInMemory {
  int openCalls = 0;
  bool? lastRecreateIfUnreadable;

  @override
  Future<void> open({
    required String masterKeyHex,
    bool recreateIfUnreadable = false,
  }) async {
    openCalls++;
    lastRecreateIfUnreadable = recreateIfUnreadable;
    if (!recreateIfUnreadable) {
      throw const DatabaseUnreadableException(
        'nanb.db',
        'file is not a database (code 26)',
      );
    }
    await super.open(masterKeyHex: masterKeyHex);
  }
}

/// A secure store that returns null on the FIRST read of the DB master key
/// (simulating a transient keystore hiccup) then behaves normally — so a
/// pre-existing key is found on a retry rather than clobbered + regenerated.
class _FlakyOnceSecureStorage extends SecureStorageInMemory {
  int _keyReads = 0;

  @override
  Future<String?> getString(String key) async {
    if (key == ConversationsNotifier.dbMasterKeyKey && _keyReads++ == 0) {
      return null;
    }
    return super.getString(key);
  }
}

/// Strips the outermost `{"_cid":...}` header that every visible send now
/// prepends (the resend-dedup client message id, which carries a dynamic
/// outboxId), so wire-format assertions can test the payload the header wraps.
/// Returns the decoded body unchanged when no cid header is present (e.g.
/// controls / call signals, which don't carry one).
String _stripCid(List<int> ciphertext) {
  final s = utf8.decode(ciphertext);
  if (!s.startsWith('{"_cid"')) return s;
  final nl = s.indexOf('\n');
  return nl < 0 ? s : s.substring(nl + 1);
}

void main() {
  setUpAll(() {
    registerFallbackValue(SubmitMessagePayload(
      conversationId: 'x',
      envelopeType: EnvelopeType.mlsApplication,
      recipientAccountId: 'x',
      recipientDeviceId: 'x',
      ciphertext: const [],
    ));
    registerFallbackValue(<int>[]); // for submitSealedUnauthenticated's UAK arg
  });

  late _MockApi api;
  late _FakeWs ws;
  late _PassthroughCrypto crypto;
  late SecureStorageInMemory storage;
  late SessionRepository sessions;
  late AppDatabaseInMemory db;
  late _FakeMediaPipeline media;
  late _FakeSupervisor supervisor;
  late _FakeLocalNotifications notifications;
  late ConversationsNotifier notifier;

  const session = JwtSession(
    accountId: 'me-acc',
    deviceId: _myDeviceId,
    jwt: 'jwt-token',
    username: 'me',
  );

  ConversationsNotifier buildNotifier({
    Duration? Function()? ttlProvider,
    bool Function()? readReceiptsEnabled,
    ({bool screenshots, bool forwarding}) Function()? privacyFlagsProvider,
    AppDatabase? database,
    SecureStorage? secureStorage,
    TempMediaStore? tempMediaStore,
  }) =>
      ConversationsNotifier(
        apiClient: api,
        wsClient: ws,
        supervisor: supervisor,
        crypto: crypto,
        sessions: sessions,
        database: database ?? db,
        secureStorage: secureStorage ?? storage,
        media: media,
        pushRegistrar: PushTokenRegistrar(api: api, provider: PushTokenProviderStub()),
        notificationPermissionGate: NotificationPermissionGate(
          seam: NotificationPermissionSeamStub(),
          storage: storage,
        ),
        videoThumbnailLoader: VideoThumbnailLoader(
          generator: _NoopVideoThumbnailGenerator(),
        ),
        pendingUploadStaging: PendingUploadStagingInMemory(),
        tempMediaStore: tempMediaStore,
        ttlProvider: ttlProvider,
        readReceiptsEnabledProvider: readReceiptsEnabled,
        privacyFlagsProvider: privacyFlagsProvider,
        localNotifications: notifications,
        // Don't sleep the suite through the submit backoff.
        submitRetryDelay: (_) async {},
      );

  setUp(() {
    api = _MockApi();
    ws = _FakeWs();
    crypto = _PassthroughCrypto();
    storage = SecureStorageInMemory();
    sessions = SessionRepository(storage);
    db = AppDatabaseInMemory();
    media = _FakeMediaPipeline();
    supervisor = _FakeSupervisor(wsClient: ws, sessions: sessions);
    notifications = _FakeLocalNotifications();
    notifier = buildNotifier();
    when(() => api.catchupMessages(since: any(named: 'since'), limit: any(named: 'limit')))
        .thenAnswer((_) async => <Envelope>[]);
    // Default: the directory confirms one device on each side, which is what
    // lets the single-peer migration run. Multi-device tests override these.
    when(() => api.lookupAccount(any()))
        .thenAnswer((_) async => _peerAccount());
    when(() => api.listDevices()).thenAnswer((_) async => const <Device>[]);
    // Default: peer has no KeyPackage available → MlsMigrator stays on ratchet.
    // Tests that exercise MLS migration override this stub explicitly.
    when(() => api.lookupKeyPackage(any()))
        .thenThrow(const KeyPackageExhaustedException('pool empty'));
    // Default: server pool is above the low-water mark (10) → replenishment
    // is a no-op in tests that don't care about it. Individual tests override.
    when(() => api.keyPackageCount()).thenAnswer((_) async => 50);
    // Default: accept any submit (covers the delivery/read receipt controls
    // that inbound 1:1 messages now fire). Send tests override with their own
    // captured-arg stubs.
    when(() => api.submitMessage(any())).thenAnswer((_) async =>
        SubmitMessageResult(envelopeId: 'srv-env', serverTs: DateTime.utc(2026)));
    when(() => api.ackMessages(any())).thenAnswer((_) async => 1);
  });

  tearDown(() async {
    notifier.dispose();
    supervisor.dispose();
    await ws.dispose();
  });

  group('connect / disconnect', () {
    test('connect with no stored session is a no-op', () async {
      await notifier.connect();
      expect(ws.connectCalls, equals(0));
      expect(ws.connected, isFalse);
      expect(db.isOpen, isFalse);
    });

    test('connect with stored session opens db, ws, sets bearer, subscribes', () async {
      await sessions.save(session);
      await notifier.connect();
      expect(ws.connectCalls, equals(1));
      expect(ws.connectedJwt, equals('jwt-token'));
      expect(db.isOpen, isTrue);
      verify(() => api.setBearerToken('jwt-token')).called(1);
    });

    test('connect generates a 64-hex-char master key and persists it', () async {
      await sessions.save(session);
      await notifier.connect();
      final key = await storage.getString(ConversationsNotifier.dbMasterKeyKey);
      expect(key, isNotNull);
      expect(key!.length, equals(64));
      expect(RegExp(r'^[0-9a-f]+$').hasMatch(key), isTrue);
    });

    test('connect reuses an existing master key when one is stored', () async {
      await sessions.save(session);
      await storage.putString(
        ConversationsNotifier.dbMasterKeyKey,
        '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff',
      );
      await notifier.connect();
      final key = await storage.getString(ConversationsNotifier.dbMasterKeyKey);
      expect(key, equals('00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff'));
    });

    test('connect is idempotent — second call does not reconnect', () async {
      await sessions.save(session);
      await notifier.connect();
      await notifier.connect();
      expect(ws.connectCalls, equals(1));
    });

    test(
        'catchUpIfNeeded re-runs catchup and settles the gate after the initial '
        'attempt fails', () async {
      // The first catchup (driven by connect's Reconnected) fails, so the gate
      // stays unsettled — exactly what leaves a deep-linked, not-yet-synced
      // conversation stuck on the loader. A later catchUpIfNeeded (app resume or
      // the manual Retry) must retry and settle it.
      var calls = 0;
      when(() => api.catchupMessages(since: any(named: 'since'), limit: any(named: 'limit')))
          .thenAnswer((_) async {
        calls++;
        if (calls == 1) throw Exception('transient catchup failure');
        return <Envelope>[];
      });
      await sessions.save(session);
      await notifier.connect();
      await pumpEventQueue();
      expect(notifier.catchupSettled, isFalse);

      await notifier.catchUpIfNeeded();
      await pumpEventQueue();
      expect(notifier.catchupSettled, isTrue,
          reason: 'a retry after a failed initial catchup must settle the gate '
              'so the conversation loader resolves instead of spinning forever');
    });

    test('an envelope whose sender never resolves is eventually acked',
        () async {
      // This path deliberately does NOT ack, so catchup can re-deliver the
      // envelope once the conversation is seeded. That is correct while seeding
      // can still happen — and an infinite loop when it never will: measured
      // on-device, 24 such envelopes were re-fetched and re-decrypted on every
      // launch for a day, burning ~900ms of every catchup.
      await sessions.save(session);
      await notifier.connect();
      await pumpEventQueue();
      when(() => api.ackMessages(any())).thenAnswer((_) async => 1);
      when(() => api.lookupAccountByDevice('ghost-dev'))
          .thenThrow(Exception('sender cannot be resolved'));

      for (var i = 0; i < 5; i++) {
        ws.push(_envelope(
          envelopeId: 'ghost-1', // SAME id: this is a redelivery, not new mail
          conversationId: '1to1:zzz-acc:me-acc',
          senderDeviceId: 'ghost-dev',
          envelopeType: EnvelopeType.mlsApplication,
          ciphertext: const [9, 9, 9],
        ));
        await pumpEventQueue();
      }

      verify(() => api.ackMessages(any(that: contains('ghost-1'))))
          .called(greaterThan(0));
    });

    test('catchup drains over the socket when one is live', () async {
      // POST /messages/catchup fires right after connect, alongside the rest of
      // the connect fan-out, so it can't reuse a pooled connection and pays a
      // full TLS setup — measured at 644-957ms for a query the server answers in
      // under 10ms. The socket is already warm.
      ws.connected = true;
      ws.catchupOverSocketResult = const <Envelope>[];
      await sessions.save(session);

      await notifier.connect();
      await pumpEventQueue();

      expect(ws.catchupOverSocketCalls, greaterThan(0));
      verifyNever(() => api.catchupMessages(
          since: any(named: 'since'), limit: any(named: 'limit')));
    });

    test('catchup falls back to HTTP when the socket drain fails', () async {
      // A drain is a pure READ that consumes nothing, so re-issuing it over HTTP
      // can never double-deliver — the worst case is the old behaviour. Leaving
      // the backlog undrained would be far worse.
      ws.connected = true;
      ws.catchupOverSocketResult = null; // socket refuses
      await sessions.save(session);

      await notifier.connect();
      await pumpEventQueue();

      expect(ws.catchupOverSocketCalls, greaterThan(0));
      verify(() => api.catchupMessages(
          since: any(named: 'since'), limit: any(named: 'limit'))).called(greaterThan(0));
    });

    test('catchup fetches its first page without waiting for MLS reconcile',
        () async {
      // The fetch needs nothing but the socket; only PROCESSING needs reconcile
      // to have landed. Awaiting the gate before the fetch left the round trip
      // idle for the whole of reconcile — 268-941ms of dead time on every cold
      // start of a Pixel 10, and considerably more over Tor.
      ws.connected = true;
      ws.catchupOverSocketResult = const <Envelope>[];
      await sessions.save(session);
      when(() => api.lookupAccount(_peerUsername))
          .thenAnswer((_) async => _peerAccount());
      await notifier.connect();
      // Reconcile only probes MLS conversations, so give it one to block on.
      final convoId = await notifier.startConversation(
        myDeviceId: _myDeviceId,
        username: _peerUsername,
      );
      ws.push(_envelope(
        conversationId: convoId,
        envelopeType: EnvelopeType.mlsApplication,
        ciphertext: utf8.encode('to mls'),
      ));
      await pumpEventQueue();
      expect(notifier.byId(convoId)!.cryptoMode, equals(CryptoMode.mls));
      await notifier.disconnect();

      final hold = Completer<void>();
      crypto.currentEpochGate = hold;
      final before = ws.catchupOverSocketCalls;

      final connecting = notifier.connect();
      await pumpEventQueue();

      expect(ws.catchupOverSocketCalls, greaterThan(before),
          reason: 'the first page must be in flight while reconcile is still '
              'running, not queued behind it');

      hold.complete();
      await connecting;
      await pumpEventQueue();
    });

    test('a drain that finds nothing never reports a backlog', () async {
      // The chat list's "Catching up…" veil keys on this. `catchupSettled` is
      // re-armed at the top of connect(), before anything knows whether there
      // IS a backlog, so a veil keyed on that alone covered the list on every
      // cold start — including this one, which fetches nothing.
      ws.connected = true;
      ws.catchupOverSocketResult = const <Envelope>[];
      await sessions.save(session);
      var peak = 0;
      notifier.addListener(() {
        if (notifier.catchupBacklog > peak) peak = notifier.catchupBacklog;
      });

      await notifier.connect();
      await pumpEventQueue();

      expect(peak, equals(0));
    });

    test('a drain publishes the fetched page as backlog while it runs',
        () async {
      ws.connected = true;
      ws.catchupOverSocketResult = [
        _envelope(envelopeId: 'backlog-1'),
        _envelope(envelopeId: 'backlog-2'),
      ];
      await sessions.save(session);
      var peak = 0;
      notifier.addListener(() {
        if (notifier.catchupBacklog > peak) peak = notifier.catchupBacklog;
      });

      await notifier.connect();
      await pumpEventQueue();

      expect(peak, equals(2));
    });

    test('backlog returns to zero once the drain is over', () async {
      // A count that outlived its drain would leave the veil up over a list
      // nothing is still rearranging.
      ws.connected = true;
      ws.catchupOverSocketResult = [_envelope(envelopeId: 'backlog-1')];
      await sessions.save(session);

      await notifier.connect();
      await pumpEventQueue();

      expect(notifier.catchupBacklog, equals(0));
    });

    test('catchUpIfNeeded is a no-op once the gate has settled', () async {
      await sessions.save(session);
      await notifier.connect();
      await pumpEventQueue();
      expect(notifier.catchupSettled, isTrue); // initial catchup succeeded
      clearInteractions(api);

      await notifier.catchUpIfNeeded();
      await pumpEventQueue();

      verifyNever(() => api.catchupMessages(since: any(named: 'since'), limit: any(named: 'limit')));
    });

    test('connect recreates an unreadable DB when the master key was freshly generated', () async {
      await sessions.save(session);
      final unreadable = _UnreadableDb();
      notifier = buildNotifier(database: unreadable);
      // No stored master key → a fresh one is minted, so any leftover on-disk
      // file is encrypted with a key that no longer exists (provably
      // unrecoverable). open() is therefore cleared to wipe + recreate.
      await notifier.connect();
      expect(unreadable.lastRecreateIfUnreadable, isTrue);
      expect(unreadable.isOpen, isTrue);
      expect(notifier.databaseDegradedToMemory, isFalse);
      // Start-up reached the supervisor rather than wedging on the open failure.
      expect(supervisor.startCalls, equals(1));
    });

    test('connect degrades to in-memory when an unreadable DB cannot be safely wiped', () async {
      await sessions.save(session);
      // A key already on disk → open() is NOT allowed to wipe (the file may hold
      // recoverable history), so it throws and the notifier must fall back.
      await storage.putString(
        ConversationsNotifier.dbMasterKeyKey,
        '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff',
      );
      final unreadable = _UnreadableDb();
      notifier = buildNotifier(database: unreadable);
      await notifier.connect();
      expect(unreadable.lastRecreateIfUnreadable, isFalse);
      expect(unreadable.isOpen, isFalse); // the on-disk file was neither opened nor wiped
      expect(notifier.databaseDegradedToMemory, isTrue);
      // Start-up still completed via the in-memory fallback.
      expect(supervisor.startCalls, equals(1));
    });

    test('recoverDegradedDatabase wipes the unreadable DB and restores '
        'persistence', () async {
      await sessions.save(session);
      await storage.putString(
        ConversationsNotifier.dbMasterKeyKey,
        '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff',
      );
      final unreadable = _UnreadableDb();
      notifier = buildNotifier(database: unreadable);
      await notifier.connect();
      expect(notifier.databaseDegradedToMemory, isTrue);

      // The user taps Reset on the degraded-mode banner.
      await notifier.recoverDegradedDatabase();
      expect(notifier.databaseDegradedToMemory, isFalse);
      // The on-disk DB was reopened with the explicit wipe authorisation and is
      // now the live store.
      expect(unreadable.lastRecreateIfUnreadable, isTrue);
      expect(unreadable.isOpen, isTrue);
    });

    test('a transient null read does NOT clobber an existing master key '
        '(the retry finds it instead of minting + wiping the DB)', () async {
      await sessions.save(session);
      const realKey =
          'aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899';
      final flaky = _FlakyOnceSecureStorage();
      await flaky.putString(ConversationsNotifier.dbMasterKeyKey, realKey);
      // A normal DB (the shared in-memory `db`) opens fine — the point is that a
      // one-off null read must not regenerate the key (which would orphan a real
      // on-disk DB and then authorise its wipe).
      notifier = buildNotifier(secureStorage: flaky);
      await notifier.connect();
      expect(notifier.databaseDegradedToMemory, isFalse);
      expect(
        await flaky.getString(ConversationsNotifier.dbMasterKeyKey),
        realKey,
        reason: 'the existing key survived the transient null read',
      );
    });

    test('disconnect closes ws, cancels subscription, clears bearer', () async {
      await sessions.save(session);
      await notifier.connect();
      await notifier.disconnect();
      expect(ws.disconnectCalls, equals(1));
      verify(() => api.setBearerToken(null)).called(1);
      // DB stays open across disconnect — only ws is torn down.
      expect(db.isOpen, isTrue);
    });

    test('disconnect after connect lets a reconnect succeed', () async {
      await sessions.save(session);
      await notifier.connect();
      await notifier.disconnect();
      await notifier.connect();
      expect(ws.connectCalls, equals(2));
    });

    test(
        'resetForAccountSwitch tears the session down so the NEXT account '
        'connects fresh (sign-out → new account regression)', () async {
      await sessions.save(session);
      await notifier.connect();
      expect(ws.connectCalls, equals(1));
      expect(ws.connectedJwt, equals('jwt-token'));

      // Sign out: wipe + full session teardown.
      await notifier.resetForAccountSwitch();
      verify(() => api.setBearerToken(null)).called(1);
      expect(notifier.conversations, isEmpty);

      // A different account signs in on the same process. Without the
      // teardown, `_connected` stayed true and this connect() no-oped — the
      // shared ApiClient kept the OLD account's JWT and the WS stayed on
      // its socket, so sends went out as the previous user until a full
      // app restart.
      const second = JwtSession(
        accountId: 'other-acc',
        deviceId: 'other-dev',
        jwt: 'jwt-2',
        username: 'other',
      );
      await sessions.save(second);
      await notifier.connect();
      expect(ws.connectCalls, equals(2));
      expect(ws.connectedJwt, equals('jwt-2'));
      verify(() => api.setBearerToken('jwt-2')).called(1);
    });
  });

  group('manual sign-out (keep data)', () {
    test(
        'signOutKeepingData disconnects + raises the gate but keeps the '
        'session, the open DB, and the master key', () async {
      await sessions.save(session);
      await notifier.connect();
      expect(ws.connectCalls, equals(1));

      await notifier.signOutKeepingData();

      // The gate is up (in-memory + persisted) so the router holds /welcome
      // and a cold restart stays signed out.
      expect(notifier.manuallySignedOut, isTrue);
      expect(await sessions.isSignedOut(), isTrue);
      // The live connection is torn down...
      expect(ws.disconnectCalls, equals(1));
      verify(() => api.setBearerToken(null)).called(1);
      // ...but NOTHING is wiped — the session, the open DB, and the SQLCipher
      // master key all survive. That is what preserves chat history across a
      // sign-out (unlike resetForAccountSwitch, which tears all three down).
      expect(await sessions.current(), equals(session));
      expect(db.isOpen, isTrue);
      expect(
        await storage.getString(ConversationsNotifier.dbMasterKeyKey),
        isNotNull,
      );
    });

    test('resumeAfterSignOut clears the gate and reconnects the same session',
        () async {
      await sessions.save(session);
      await notifier.connect();
      await notifier.signOutKeepingData();
      expect(notifier.manuallySignedOut, isTrue);

      await notifier.resumeAfterSignOut();

      expect(notifier.manuallySignedOut, isFalse);
      expect(await sessions.isSignedOut(), isFalse);
      // The SAME device id reconnects — no fresh-device churn, no group re-add.
      expect(ws.connectCalls, equals(2));
      expect(ws.connectedJwt, equals('jwt-token'));
    });

    test(
        'clearSignedOutForNewSession drops the gate so onboarding can reach '
        'the chat list', () async {
      // Onboarding (create / restore / link) establishes NEW credentials, so
      // the gate must not survive into the navigation that follows. It used to:
      // the router bounced the post-create `go(chatList)` back to /welcome and
      // the user had to force-quit the app to get in.
      await sessions.save(session);
      await notifier.connect();
      await notifier.signOutKeepingData();
      expect(notifier.manuallySignedOut, isTrue);

      notifier.clearSignedOutForNewSession();

      expect(notifier.manuallySignedOut, isFalse);
    });

    test('clearSignedOutForNewSession notifies so the router re-evaluates',
        () async {
      // The caller navigates immediately afterwards, so the redirect must see
      // the cleared gate on THIS frame — an async/deferred notify would let the
      // stale gate win the race.
      await sessions.save(session);
      await notifier.connect();
      await notifier.signOutKeepingData();
      var notified = 0;
      void listener() => notified++;
      notifier.addListener(listener);

      notifier.clearSignedOutForNewSession();

      expect(notified, greaterThan(0));
      notifier.removeListener(listener);
    });

    test('loadSignedOutGate hydrates the in-memory gate from storage at boot',
        () async {
      await sessions.save(session);
      await sessions.setSignedOut(true);
      // Fresh notifier hasn't read the persisted flag yet.
      expect(notifier.manuallySignedOut, isFalse);

      await notifier.loadSignedOutGate();

      expect(notifier.manuallySignedOut, isTrue);
    });
  });

  group('hydration on connect', () {
    test('rehydrates conversations + messages persisted earlier', () async {
      // Pre-seed the DB as if a previous session had persisted state.
      await db.open(masterKeyHex: 'k');
      final preExistingConvo = Conversation(
        id: 'convo-A',
        peerUsername: 'alice',
        peerAccountId: 'alice-acc',
        peerDeviceId: 'alice-dev',
        peerIdentityPubKey: const [1, 2, 3],
        messages: const [],
        unreadCount: 0,
      );
      await db.upsertConversation(preExistingConvo);
      await db.upsertMessages('convo-A', [
        ChatMessage(
          envelopeId: 'env-old',
          conversationId: 'convo-A',
          senderDeviceId: 'alice-dev',
          body: 'persisted message',
          serverTs: DateTime.utc(2026, 5, 6),
          mine: false,
        ),
      ]);

      await sessions.save(session);
      await notifier.connect();

      final restored = notifier.byId('convo-A');
      expect(restored, isNotNull);
      expect(restored!.peerUsername, equals('alice'));
      expect(restored.messages.length, equals(1));
      expect(restored.messages.single.body, equals('persisted message'));
    });

    test('hydrates only once — a second connect does not double-load', () async {
      await sessions.save(session);
      await notifier.connect();
      await notifier.disconnect();

      // Mutate the DB out-of-band — the second connect should NOT pick this up
      // (hydration is idempotent within a single notifier lifetime).
      await db.upsertConversation(Conversation(
        id: 'sneaky',
        peerUsername: 'sneak',
        peerAccountId: 's',
        peerDeviceId: 's',
        peerIdentityPubKey: const [],
        messages: const [],
        unreadCount: 0,
      ));

      await notifier.connect();
      expect(notifier.byId('sneaky'), isNull);
    });
  });

  group('startConversation', () {
    test('looks up account, creates conversation, persists row', () async {
      await sessions.save(session);
      await notifier.connect();
      when(() => api.lookupAccount(_peerUsername))
          .thenAnswer((_) async => _peerAccount());

      final id = await notifier.startConversation(
        myDeviceId: _myDeviceId,
        username: _peerUsername,
      );

      // Conversation ID is derived from both account IDs (our 'me-acc' from
      // the session + the peer's), so both participants converge on the same id.
      expect(id, equals(Conversation.oneToOneId('me-acc', _peerAccountId)));
      final convo = notifier.byId(id);
      expect(convo, isNotNull);
      expect(convo!.peerUsername, equals(_peerUsername));

      // Persisted to DB.
      final loaded = await db.loadConversations();
      expect(loaded.where((c) => c.id == id).length, equals(1));
    });

    test('idempotent for a known peer — second call returns the same id', () async {
      await sessions.save(session);
      await notifier.connect();
      when(() => api.lookupAccount(_peerUsername))
          .thenAnswer((_) async => _peerAccount());

      final id1 = await notifier.startConversation(
        myDeviceId: _myDeviceId,
        username: _peerUsername,
      );
      final id2 = await notifier.startConversation(
        myDeviceId: _myDeviceId,
        username: _peerUsername,
      );

      expect(id1, equals(id2));
      expect(notifier.conversations.length, equals(1));
    });

    test('propagates ApiError on lookup failure', () async {
      await sessions.save(session);
      await notifier.connect();
      when(() => api.lookupAccount(any())).thenThrow(
        const ApiError(code: 'account_not_found', message: 'no', statusCode: 404),
      );

      expect(
        () => notifier.startConversation(myDeviceId: _myDeviceId, username: 'nope'),
        throwsA(isA<ApiError>().having((e) => e.code, 'code', 'account_not_found')),
      );
    });

    test('a send fired while the transport is still coming up survives',
        () async {
      // The built-in-Tor window: until Arti binds its SOCKS port the fail-closed
      // sentinel refuses the connection, and at the instant Tor connects the
      // rebuilt API client has no bearer yet. Both surface as a TRANSIENT
      // ApiError (no HTTP status). This used to destroy the message —
      // _submitOutbox marks the outbox row failed on ANY throw — so a message
      // typed while Tor was connecting was lost until the user tapped retry.
      await sessions.save(session);
      await notifier.connect();
      when(() => api.lookupAccount(_peerUsername))
          .thenAnswer((_) async => _peerAccount());
      when(() => api.ackMessages(any())).thenAnswer((_) async => 1);
      final convoId = await notifier.startConversation(
        myDeviceId: _myDeviceId,
        username: _peerUsername,
      );

      var submitCalls = 0;
      when(() => api.submitMessage(any())).thenAnswer((_) async {
        submitCalls++;
        if (submitCalls < 3) {
          throw const ApiError(
              code: 'network', message: 'connection refused'); // no statusCode
        }
        return SubmitMessageResult(
            envelopeId: 'env-late', serverTs: DateTime.utc(2026, 7, 14));
      });

      await notifier.sendMessage(
        conversationId: convoId,
        myDeviceId: _myDeviceId,
        text: 'sent while tor was connecting',
      );
      await pumpEventQueue();

      expect(submitCalls, 3);
      final msg = notifier.byId(convoId)!.messages.last;
      expect(msg.failed, isFalse);
      expect(msg.envelopeId, equals('env-late'));
    });

    test('a 1:1 send hitting account_not_found re-resolves the peer + retries',
        () async {
      // The peer wiped + restored from their recovery phrase, so the device our
      // conversation addresses is revoked: the first send bounces with
      // account_not_found. The client must re-resolve the peer's CURRENT device
      // and retry, instead of dead-ending the message as failed.
      await sessions.save(session);
      await notifier.connect();
      when(() => api.lookupAccount(_peerUsername))
          .thenAnswer((_) async => _peerAccount());
      when(() => api.ackMessages(any())).thenAnswer((_) async => 1);
      final convoId = await notifier.startConversation(
        myDeviceId: _myDeviceId,
        username: _peerUsername,
      );

      var submitCalls = 0;
      when(() => api.submitMessage(any())).thenAnswer((_) async {
        submitCalls++;
        if (submitCalls == 1) {
          throw const ApiError(
              code: 'account_not_found', message: 'gone', statusCode: 404);
        }
        return SubmitMessageResult(
            envelopeId: 'env-ok', serverTs: DateTime.utc(2026, 5, 9));
      });

      await notifier.sendMessage(
        conversationId: convoId,
        myDeviceId: _myDeviceId,
        text: 'resume',
      );
      await pumpEventQueue();

      // Retried (≥2 submit attempts) and the message landed — not dead-ended.
      expect(submitCalls, greaterThanOrEqualTo(2));
      final msg = notifier.byId(convoId)!.messages.last;
      expect(msg.failed, isFalse);
      expect(msg.envelopeId, equals('env-ok'));
      // The peer was re-resolved during recovery (once more than the initial
      // startConversation lookup).
      verify(() => api.lookupAccount(_peerUsername))
          .called(greaterThanOrEqualTo(2));
    });

    test('a 1:1 send dead-ends as failed when the peer can no longer be resolved',
        () async {
      // account_not_found AND the whole account is gone (lookup fails too) —
      // recovery is impossible, so the message must surface as failed.
      await sessions.save(session);
      await notifier.connect();
      when(() => api.lookupAccount(_peerUsername))
          .thenAnswer((_) async => _peerAccount());
      when(() => api.ackMessages(any())).thenAnswer((_) async => 1);
      final convoId = await notifier.startConversation(
        myDeviceId: _myDeviceId,
        username: _peerUsername,
      );

      when(() => api.submitMessage(any())).thenThrow(const ApiError(
          code: 'account_not_found', message: 'gone', statusCode: 404));
      // Now the account itself is unresolvable.
      when(() => api.lookupAccount(_peerUsername)).thenThrow(const ApiError(
          code: 'account_not_found', message: 'gone', statusCode: 404));

      // The unrecoverable send surfaces (the message is marked failed first).
      try {
        await notifier.sendMessage(
          conversationId: convoId,
          myDeviceId: _myDeviceId,
          text: 'resume',
        );
      } catch (_) {/* expected: re-thrown after marking the message failed */}
      await pumpEventQueue();

      expect(notifier.byId(convoId)!.messages.last.failed, isTrue);
    });

    // On-device 2026-10-21: a contact started after launch rang as "Unknown"
    // while the app was in the background — the caller-name mirror the push
    // isolate reads was only written at hydration.
    test('a new 1:1 reaches the background call-name mirror right away',
        () async {
      await sessions.save(session);
      await notifier.connect();
      when(() => api.lookupAccount(_peerUsername))
          .thenAnswer((_) async => _peerAccount());

      final id = await notifier.startConversation(
        myDeviceId: _myDeviceId,
        username: _peerUsername,
      );
      await pumpEventQueue();

      final raw =
          await storage.getString(ConversationsNotifier.callPeerNamesKey);
      final names = (jsonDecode(raw!) as Map).cast<String, String>();
      expect(names[id], isNotEmpty);
    });

    test('creates a NON-pending conversation (local user initiated)', () async {
      await sessions.save(session);
      await notifier.connect();
      when(() => api.lookupAccount(_peerUsername))
          .thenAnswer((_) async => _peerAccount());

      final id = await notifier.startConversation(
        myDeviceId: _myDeviceId,
        username: _peerUsername,
      );

      expect(notifier.byId(id)!.pending, isFalse);
      final loaded = await db.loadConversations();
      expect(loaded.singleWhere((c) => c.id == id).pending, isFalse);
    });
  });

  group('history backfill (receive)', () {
    setUp(() {
      // me-dev-2 is one of OUR devices, so the own-device guard accepts a
      // backfill from it.
      when(() => api.listDevices()).thenAnswer((_) async => [
            const Device(
                deviceId: _myDeviceId, accountId: 'me-acc', devicePubKey: []),
            const Device(
                deviceId: 'me-dev-2',
                accountId: 'me-acc',
                devicePubKey: [],
                x25519PubKey: [7, 7, 7]),
          ]);
    });

    String seedMlsConvoBf() {
      const convoId = 'mls-convo-bf';
      notifier.seed(Conversation(
        id: convoId,
        peerUsername: _peerUsername,
        peerAccountId: _peerAccountId,
        peerDeviceId: 'peer-dev',
        peerIdentityPubKey: const [9, 8, 7],
        peerX25519PubKey: const [1, 2, 3],
        messages: const [],
        unreadCount: 0,
        cryptoMode: CryptoMode.mls,
      ));
      return convoId;
    }

    List<int> backfillCipher(String convoId) {
      final payload = HistoryBackfill(
        conversationId: convoId,
        seq: 1,
        total: 1,
        messages: const [
          BackfillMessage(
            envelopeId: 'hist-1',
            serverTsMs: 1700000000000,
            senderDeviceId: 'peer-dev',
            mine: false,
            kind: MessageKind.text,
            body: 'old peer msg',
          ),
          BackfillMessage(
            envelopeId: 'hist-2',
            serverTsMs: 1700000001000,
            senderDeviceId: _myDeviceId,
            mine: true,
            kind: MessageKind.text,
            body: 'old my msg',
          ),
        ],
      ).encode();
      return utf8.encode(payload);
    }

    Future<void> connectWithKnownDevices() async {
      // Pre-seed the known-own-devices set so connect()'s reconcile doesn't
      // treat me-dev-2 as newly-linked (which would fire the SENDER side).
      await storage.putString(ConversationsNotifier.knownOwnDevicesKey,
          jsonEncode([_myDeviceId, 'me-dev-2']));
      await sessions.save(session);
      await notifier.connect();
      await pumpEventQueue();
    }

    test('stores backfilled history from an own device, no unread bump',
        () async {
      await connectWithKnownDevices();
      final convoId = seedMlsConvoBf();

      ws.push(_envelope(
        envelopeId: 'carrier-1',
        conversationId: convoId,
        senderDeviceId: 'me-dev-2',
        envelopeType: EnvelopeType.mlsApplication,
        ciphertext: backfillCipher(convoId),
      ));
      await pumpEventQueue();

      final convo = notifier.byId(convoId)!;
      expect(convo.messages.map((m) => m.envelopeId),
          containsAll(['hist-1', 'hist-2']));
      expect(convo.unreadCount, 0, reason: 'backfill is history, not new mail');
      final m1 = convo.messages.firstWhere((m) => m.envelopeId == 'hist-1');
      final m2 = convo.messages.firstWhere((m) => m.envelopeId == 'hist-2');
      expect(m1.mine, isFalse);
      expect(m2.mine, isTrue, reason: 'original mine attribution preserved');
      expect(m1.serverTs.isBefore(m2.serverTs), isTrue);
      final loaded = await db.loadMessages(convoId, limit: 50);
      expect(loaded.map((m) => m.envelopeId), containsAll(['hist-1', 'hist-2']));
    });

    test('skips a replayed message it already has under another envelope id',
        () async {
      await connectWithKnownDevices();
      final convoId = seedMlsConvoBf();
      notifier.seed(notifier.byId(convoId)!.copyWith(messages: [
        ChatMessage(
          envelopeId: 'my-copy',
          conversationId: convoId,
          senderDeviceId: 'peer-dev',
          body: 'already here',
          serverTs: DateTime.utc(2026, 11, 7),
          mine: false,
          clientMsgId: 'cid-1',
        ),
      ]));
      final payload = HistoryBackfill(
        conversationId: convoId,
        seq: 1,
        total: 1,
        messages: const [
          BackfillMessage(
            envelopeId: 'siblings-copy',
            serverTsMs: 1762473600000,
            senderDeviceId: 'peer-dev',
            mine: false,
            kind: MessageKind.text,
            body: 'already here',
            clientMsgId: 'cid-1',
          ),
        ],
      ).encode();

      ws.push(_envelope(
        envelopeId: 'carrier-dup',
        conversationId: convoId,
        senderDeviceId: 'me-dev-2',
        envelopeType: EnvelopeType.mlsApplication,
        ciphertext: utf8.encode(payload),
      ));
      await pumpEventQueue();

      expect(notifier.byId(convoId)!.messages.where((m) => m.body == 'already here'),
          hasLength(1));
    });

    test('follower (larger account) ADOPTS a Welcome rather than winning the '
        'device-id tiebreaker (split-brain convergence)', () async {
      await connectWithKnownDevices();
      // self is 'me-acc'; peer 'aaa-acc' < 'me-acc' → we are the deterministic-
      // migration FOLLOWER, so any Welcome the leader sends is authoritative —
      // adopt it instead of "winning" the tiebreak and stranding undecryptable.
      const convoId = '1to1:aaa-acc:me-acc';
      notifier.seed(Conversation(
        id: convoId,
        peerUsername: _peerUsername,
        peerAccountId: 'aaa-acc',
        peerDeviceId: 'peer-dev',
        peerIdentityPubKey: const [9, 8, 7],
        peerX25519PubKey: const [1, 2, 3],
        messages: const [],
        unreadCount: 0,
        cryptoMode: CryptoMode.mls,
      ));
      when(() => api.ackMessages(any())).thenAnswer((_) async => 1);

      // sender 'peer-dev' > our 'me-dev', so the device-id tiebreaker alone
      // would say "we win" and IGNORE this Welcome (the old deadlock).
      ws.push(_envelope(
        conversationId: convoId,
        senderDeviceId: 'peer-dev',
        envelopeType: EnvelopeType.mlsWelcome,
        ciphertext: const [4, 5, 6, 7],
      ));
      await pumpEventQueue();

      expect(crypto.replaceGroupCalls.map((c) => c.localGroupId),
          contains(convoId),
          reason: 'the follower must adopt the leader Welcome, not ignore it');
    });

    test('leader with no decrypt failures KEEPS its own group (the '
        'simultaneous-migration tiebreak still holds)', () async {
      await connectWithKnownDevices();
      // peer 'zzz-acc' > our 'me-acc' → we are the LEADER. With nothing failing,
      // a peer Welcome is a migration collision, not a recovery: keep ours.
      const convoId = '1to1:me-acc:zzz-acc';
      notifier.seed(Conversation(
        id: convoId,
        peerUsername: _peerUsername,
        peerAccountId: 'zzz-acc',
        peerDeviceId: 'peer-dev',
        peerIdentityPubKey: const [9, 8, 7],
        peerX25519PubKey: const [1, 2, 3],
        messages: const [],
        unreadCount: 0,
        cryptoMode: CryptoMode.mls,
      ));
      when(() => api.ackMessages(any())).thenAnswer((_) async => 1);

      ws.push(_envelope(
        conversationId: convoId,
        senderDeviceId: 'peer-dev',
        envelopeType: EnvelopeType.mlsWelcome,
        ciphertext: const [4, 5, 6, 7],
      ));
      await pumpEventQueue();

      expect(crypto.replaceGroupCalls.map((c) => c.localGroupId),
          isNot(contains(convoId)),
          reason: 'the leader owns the canonical group when nothing is failing');
    });

    // THE "we can see each other but nothing is ever delivered" bug.
    //
    // The peer signed out / switched phones / deleted the thread, so it lost
    // its MLS state. OUR group is untouched and still decrypts everything we
    // have, so we accumulate NO decrypt failures — the only evidence the
    // previous test relies on. The peer rebuilds and sends a Welcome; the role
    // rule discarded it, every time, forever. Both sides then sat sending into
    // groups the other could not open, and the only escape was deleting both
    // chats (or making new accounts).
    //
    // A collision produces exactly ONE Welcome per side, so a second one can
    // only mean the peer cannot use our group. The leader yields to it.
    test('leader adopts a REPEAT Welcome even with nothing failing locally '
        '(a peer that lost its MLS state has no other way to say so)', () async {
      await connectWithKnownDevices();
      const convoId = '1to1:me-acc:zzz-acc'; // peer > us → we are the LEADER
      notifier.seed(Conversation(
        id: convoId,
        peerUsername: _peerUsername,
        peerAccountId: 'zzz-acc',
        peerDeviceId: 'peer-dev',
        peerIdentityPubKey: const [9, 8, 7],
        peerX25519PubKey: const [1, 2, 3],
        messages: const [],
        unreadCount: 0,
        cryptoMode: CryptoMode.mls,
      ));
      when(() => api.ackMessages(any())).thenAnswer((_) async => 1);

      // First Welcome: the tiebreak still holds, so we keep our group.
      ws.push(_envelope(
        conversationId: convoId,
        senderDeviceId: 'peer-dev',
        envelopeType: EnvelopeType.mlsWelcome,
        ciphertext: const [4, 5, 6, 7],
      ));
      await pumpEventQueue();
      expect(crypto.replaceGroupCalls.map((c) => c.localGroupId),
          isNot(contains(convoId)),
          reason: 'one discard preserves the simultaneous-migration tiebreak');

      // Second Welcome: the peer rebuilt AGAIN, which a collision never does.
      ws.push(_envelope(
        conversationId: convoId,
        senderDeviceId: 'peer-dev',
        envelopeType: EnvelopeType.mlsWelcome,
        ciphertext: const [8, 9, 10, 11],
      ));
      await pumpEventQueue();

      expect(crypto.replaceGroupCalls.map((c) => c.localGroupId),
          contains(convoId),
          reason: 'the role rule is not converging — join the peer group');
    });

    // The escape hatch must not fire on its own: a leader whose group is
    // demonstrably live (it just decrypted a peer message) starts over, so an
    // occasional collision months apart never accumulates into a spurious
    // adopt.
    test('a successful decrypt resets the discarded-Welcome tally', () async {
      await connectWithKnownDevices();
      const convoId = '1to1:me-acc:zzz-acc';
      notifier.seed(Conversation(
        id: convoId,
        peerUsername: _peerUsername,
        peerAccountId: 'zzz-acc',
        peerDeviceId: 'peer-dev',
        peerIdentityPubKey: const [9, 8, 7],
        peerX25519PubKey: const [1, 2, 3],
        messages: const [],
        unreadCount: 0,
        cryptoMode: CryptoMode.mls,
      ));
      when(() => api.ackMessages(any())).thenAnswer((_) async => 1);

      ws.push(_envelope(
        conversationId: convoId,
        senderDeviceId: 'peer-dev',
        envelopeType: EnvelopeType.mlsWelcome,
        ciphertext: const [4, 5, 6, 7],
      ));
      await pumpEventQueue();
      // Our group works fine — a peer message decrypts.
      ws.push(_envelope(
        conversationId: convoId,
        senderDeviceId: 'peer-dev',
        envelopeType: EnvelopeType.mlsApplication,
        ciphertext: const [2, 2, 2],
      ));
      await pumpEventQueue();

      ws.push(_envelope(
        conversationId: convoId,
        senderDeviceId: 'peer-dev',
        envelopeType: EnvelopeType.mlsWelcome,
        ciphertext: const [8, 9, 10, 11],
      ));
      await pumpEventQueue();

      expect(crypto.replaceGroupCalls.map((c) => c.localGroupId),
          isNot(contains(convoId)),
          reason: 'the tally restarts once our group is proven live');
    });

    // "They switched phones." The peer restored on a NEW device, so our row
    // still addresses the OLD one. Re-establishment would mint a Welcome and
    // post it to a phone that no longer exists: the rebuild lands nowhere, and
    // the thread just stays silent with no error to show for it.
    test('re-establishment re-points a 1:1 at the peer device that is actually '
        'talking to us', () async {
      await connectWithKnownDevices();
      const convoId = '1to1:me-acc:zzz-acc'; // us < peer → we are the LEADER
      notifier.seed(Conversation(
        id: convoId,
        peerUsername: _peerUsername,
        peerAccountId: 'zzz-acc',
        peerDeviceId: 'peer-dev-old',
        peerIdentityPubKey: const [9, 8, 7],
        peerX25519PubKey: const [1, 2, 3],
        messages: const [],
        unreadCount: 0,
        cryptoMode: CryptoMode.mls,
      ));
      when(() => api.ackMessages(any())).thenAnswer((_) async => 1);
      // The server is authoritative that the new device belongs to the SAME
      // peer account — without that we must not re-point (welcoming a
      // stranger's device into the 1:1 would hand them every future message).
      when(() => api.lookupAccountByDevice('peer-dev-new'))
          .thenAnswer((_) async => _peerAccount(accountId: 'zzz-acc'));

      // Enough undecryptable messages from the NEW device to trip
      // re-establishment.
      crypto.decryptAndInspectError = const MlsDecryptException('diverged');
      for (var i = 0; i < 4; i++) {
        ws.push(_envelope(
          envelopeId: 'undec-$i',
          conversationId: convoId,
          senderDeviceId: 'peer-dev-new',
          envelopeType: EnvelopeType.mlsApplication,
          ciphertext: const [1, 1, 1],
        ));
        await pumpEventQueue();
      }
      crypto.decryptAndInspectError = null;
      await pumpEventQueue();

      expect(notifier.byId(convoId)!.peerDeviceId, equals('peer-dev-new'),
          reason: 'the rebuild must be addressed at the phone they now use');
    });

    // The re-point is a Welcome target, so an UNVERIFIED device must never win
    // it — that would be a group hijack.
    test('re-establishment does NOT re-point at a device the server will not '
        'attribute to the peer account', () async {
      await connectWithKnownDevices();
      const convoId = '1to1:me-acc:zzz-acc';
      notifier.seed(Conversation(
        id: convoId,
        peerUsername: _peerUsername,
        peerAccountId: 'zzz-acc',
        peerDeviceId: 'peer-dev-old',
        peerIdentityPubKey: const [9, 8, 7],
        peerX25519PubKey: const [1, 2, 3],
        messages: const [],
        unreadCount: 0,
        cryptoMode: CryptoMode.mls,
      ));
      when(() => api.ackMessages(any())).thenAnswer((_) async => 1);
      // Belongs to somebody else entirely.
      when(() => api.lookupAccountByDevice('stranger-dev'))
          .thenAnswer((_) async => _peerAccount(accountId: 'stranger-acc'));

      crypto.decryptAndInspectError = const MlsDecryptException('diverged');
      for (var i = 0; i < 4; i++) {
        ws.push(_envelope(
          envelopeId: 'hijack-$i',
          conversationId: convoId,
          senderDeviceId: 'stranger-dev',
          envelopeType: EnvelopeType.mlsApplication,
          ciphertext: const [1, 1, 1],
        ));
        await pumpEventQueue();
      }
      crypto.decryptAndInspectError = null;
      await pumpEventQueue();

      expect(notifier.byId(convoId)!.peerDeviceId, equals('peer-dev-old'));
    });

    test('leader that CANNOT DECRYPT the peer adopts their Welcome instead of '
        'stranding them forever', () async {
      await connectWithKnownDevices();
      // Same leader role as above, but this time we have been failing to
      // decrypt the peer. That is asymmetric evidence of real split brain: the
      // peer rebuilt (maybeReestablish forces it even from a follower) and our
      // holding our own group is exactly what left their messages unacked and
      // invisible forever. Observed live: iPhone follower -> Pixel leader.
      const convoId = '1to1:me-acc:zzz-acc';
      notifier.seed(Conversation(
        id: convoId,
        peerUsername: _peerUsername,
        peerAccountId: 'zzz-acc',
        peerDeviceId: 'peer-dev',
        peerIdentityPubKey: const [9, 8, 7],
        peerX25519PubKey: const [1, 2, 3],
        messages: const [],
        unreadCount: 0,
        cryptoMode: CryptoMode.mls,
      ));
      when(() => api.ackMessages(any())).thenAnswer((_) async => 1);

      // One undecryptable application envelope from the peer builds the streak.
      crypto.decryptAndInspectError = const MlsDecryptException('diverged');
      ws.push(_envelope(
        conversationId: convoId,
        senderDeviceId: 'peer-dev',
        envelopeType: EnvelopeType.mlsApplication,
        ciphertext: const [1, 1, 1],
      ));
      await pumpEventQueue();
      crypto.decryptAndInspectError = null;

      ws.push(_envelope(
        conversationId: convoId,
        senderDeviceId: 'peer-dev',
        envelopeType: EnvelopeType.mlsWelcome,
        ciphertext: const [4, 5, 6, 7],
      ));
      await pumpEventQueue();

      expect(crypto.replaceGroupCalls.map((c) => c.localGroupId),
          contains(convoId),
          reason: 'a leader that cannot decrypt must yield to the peer group');
    });

    test('a redelivered, already-decrypted envelope does not tear the group '
        'down', () async {
      await connectWithKnownDevices();
      final convoId = seedMlsConvoBf();
      when(() => api.ackMessages(any())).thenAnswer((_) async => 1);

      // The ack for this message never landed, so the server hands it back.
      // CoreCrypto refuses to decrypt it twice — an error that looks exactly
      // like split brain. Three of them in a row used to wipe and rebuild a
      // healthy group (the Welcome loop where the push arrives but the message
      // never does).
      ws.push(_envelope(
        envelopeId: 'mls-dup',
        conversationId: convoId,
        senderDeviceId: 'peer-dev',
        envelopeType: EnvelopeType.mlsApplication,
        ciphertext: utf8.encode('first delivery'),
      ));
      await pumpEventQueue();
      crypto.decryptAndInspectError = const MlsDecryptException('duplicate');
      for (var i = 0; i < 3; i++) {
        ws.push(_envelope(
          envelopeId: 'mls-dup',
          conversationId: convoId,
          senderDeviceId: 'peer-dev',
          envelopeType: EnvelopeType.mlsApplication,
          ciphertext: utf8.encode('first delivery'),
        ));
        await pumpEventQueue();
      }
      await pumpEventQueue();

      expect(crypto.wipeGroupCalls, equals(0),
          reason: 'a replay of a processed envelope is not split brain');
    });

    test('a redelivered, already-decrypted envelope is acked so it stops '
        'coming back', () async {
      await connectWithKnownDevices();
      final convoId = seedMlsConvoBf();
      when(() => api.ackMessages(any())).thenAnswer((_) async => 1);
      ws.push(_envelope(
        envelopeId: 'mls-dup',
        conversationId: convoId,
        senderDeviceId: 'peer-dev',
        envelopeType: EnvelopeType.mlsApplication,
        ciphertext: utf8.encode('first delivery'),
      ));
      await pumpEventQueue();
      clearInteractions(api);
      crypto.decryptAndInspectError = const MlsDecryptException('duplicate');

      ws.push(_envelope(
        envelopeId: 'mls-dup',
        conversationId: convoId,
        senderDeviceId: 'peer-dev',
        envelopeType: EnvelopeType.mlsApplication,
        ciphertext: utf8.encode('first delivery'),
      ));
      await pumpEventQueue();

      verify(() => api.ackMessages(any(that: contains('mls-dup')))).called(1);
    });

    test('MLS sender is attributed from the credential, not the transport field',
        () async {
      await connectWithKnownDevices();
      final convoId = seedMlsConvoBf();
      when(() => api.ackMessages(any())).thenAnswer((_) async => 1);

      // The server-assigned transport sender is 'peer-dev', but MLS authenticates
      // the sender as 'peer-authed-dev'. Sealed-sender Phase 0: the stored message
      // must carry the CREDENTIAL's sender, so the transport field is removable
      // (and a server can't mis-attribute by stamping a different sender).
      crypto.decryptSenderClientId = 'peer-authed-dev';
      ws.push(_envelope(
        envelopeId: 'mls-1',
        conversationId: convoId,
        senderDeviceId: 'peer-dev',
        envelopeType: EnvelopeType.mlsApplication,
        ciphertext: utf8.encode('hello from mls'),
      ));
      await pumpEventQueue();

      final msg = notifier
          .byId(convoId)!
          .messages
          .firstWhere((m) => m.envelopeId == 'mls-1');
      expect(msg.senderDeviceId, equals('peer-authed-dev'),
          reason: 'sender comes from the MLS credential, not the transport field');
      expect(msg.body, equals('hello from mls'));
      expect(msg.mine, isFalse);
    });

    test('MLS self-sync is detected from the credential sender', () async {
      await connectWithKnownDevices();
      final convoId = seedMlsConvoBf();
      when(() => api.ackMessages(any())).thenAnswer((_) async => 1);

      // Transport says 'peer-dev' (not ours), but MLS authenticates the sender as
      // our own 'me-dev-2' → the copy must render as `mine` (self-sync) off the
      // credential, not be mis-attributed to the peer from the transport field.
      crypto.decryptSenderClientId = 'me-dev-2';
      ws.push(_envelope(
        envelopeId: 'mls-self',
        conversationId: convoId,
        senderDeviceId: 'peer-dev',
        envelopeType: EnvelopeType.mlsApplication,
        ciphertext: utf8.encode('my own message'),
      ));
      await pumpEventQueue();

      final msg = notifier
          .byId(convoId)!
          .messages
          .firstWhere((m) => m.envelopeId == 'mls-self');
      expect(msg.mine, isTrue,
          reason: 'self-sync recognised from the credential sender (me-dev-2)');
      expect(msg.senderDeviceId, equals('me-dev-2'));
    });

    test('a 1:1 MLS message from a device outside the peer directory is dropped '
        '(Welcome-hijack guard)', () async {
      await connectWithKnownDevices();
      final convoId = seedMlsConvoBf();
      when(() => api.ackMessages(any())).thenAnswer((_) async => 1);
      // The peer's registered device directory lists only their real devices.
      when(() => api.lookupAccount(_peerUsername)).thenAnswer((_) async =>
          const Account(
            accountId: _peerAccountId,
            username: _peerUsername,
            identityPubKey: [9, 8, 7],
            x25519PubKey: [1, 2, 3],
            deviceId: 'peer-dev',
            devices: [
              AccountDevice(deviceId: 'peer-dev'),
              AccountDevice(deviceId: 'peer-dev-2'),
            ],
          ));
      // MLS authenticates the sender as a device that is NOT registered to the
      // peer — a group a stranger built and injected. It must not render.
      crypto.decryptSenderClientId = 'stranger-dev';
      ws.push(_envelope(
        envelopeId: 'mls-hijack',
        conversationId: convoId,
        senderDeviceId: 'peer-dev',
        envelopeType: EnvelopeType.mlsApplication,
        ciphertext: utf8.encode('malicious'),
      ));
      await pumpEventQueue();

      expect(
        notifier.byId(convoId)!.messages.any((m) => m.envelopeId == 'mls-hijack'),
        isFalse,
        reason: 'a sender outside the peer directory is dropped, not shown as '
            'the peer',
      );
    });

    test('a 1:1 MLS message from a registered peer device still renders',
        () async {
      await connectWithKnownDevices();
      final convoId = seedMlsConvoBf();
      when(() => api.ackMessages(any())).thenAnswer((_) async => 1);
      when(() => api.lookupAccount(_peerUsername)).thenAnswer((_) async =>
          const Account(
            accountId: _peerAccountId,
            username: _peerUsername,
            identityPubKey: [9, 8, 7],
            x25519PubKey: [1, 2, 3],
            deviceId: 'peer-dev',
            devices: [
              AccountDevice(deviceId: 'peer-dev'),
              AccountDevice(deviceId: 'peer-dev-2'),
            ],
          ));
      // A real second device of the peer (in the directory) → not foreign.
      crypto.decryptSenderClientId = 'peer-dev-2';
      ws.push(_envelope(
        envelopeId: 'mls-ok',
        conversationId: convoId,
        senderDeviceId: 'peer-dev',
        envelopeType: EnvelopeType.mlsApplication,
        ciphertext: utf8.encode('hi from my other device'),
      ));
      await pumpEventQueue();

      final msg = notifier
          .byId(convoId)!
          .messages
          .firstWhere((m) => m.envelopeId == 'mls-ok');
      expect(msg.senderDeviceId, equals('peer-dev-2'));
      expect(msg.mine, isFalse);
    });

    test('an inbound unsend from the peer does not delete our own message',
        () async {
      await connectWithKnownDevices();
      const convoId = 'mls-unsend-guard';
      crypto.decryptSenderClientId = null; // control attributed from transport
      notifier.seed(Conversation(
        id: convoId,
        peerUsername: _peerUsername,
        peerAccountId: _peerAccountId,
        peerDeviceId: 'peer-dev',
        peerIdentityPubKey: const [9, 8, 7],
        peerX25519PubKey: const [1, 2, 3],
        messages: [
          ChatMessage(
            envelopeId: 'mine-1',
            conversationId: convoId,
            senderDeviceId: _myDeviceId,
            body: 'my message',
            serverTs: DateTime.utc(2026, 1, 1),
            mine: true,
            kind: MessageKind.text,
          ),
        ],
        unreadCount: 0,
        cryptoMode: CryptoMode.mls,
      ));
      await db.upsertConversation(notifier.byId(convoId)!);
      await db.upsertMessages(convoId, notifier.byId(convoId)!.messages);
      when(() => api.ackMessages(any())).thenAnswer((_) async => 1);

      // The peer names our own message's id in an unsend — must be ignored.
      ws.push(_envelope(
        envelopeId: 'ctrl-unsend',
        conversationId: convoId,
        senderDeviceId: 'peer-dev',
        envelopeType: EnvelopeType.mlsApplication,
        ciphertext: utf8.encode(const MessageControl.unsend('mine-1').encode()),
      ));
      await pumpEventQueue();

      expect(
        notifier.byId(convoId)!.messages.any((m) => m.envelopeId == 'mine-1'),
        isTrue,
        reason: 'the peer cannot delete a message we authored',
      );
    });

    test('a sealed envelope is unwrapped and its inner message dispatched',
        () async {
      await connectWithKnownDevices();
      final convoId = seedMlsConvoBf();
      when(() => api.ackMessages(any())).thenAnswer((_) async => 1);

      // The real inner (an MLS application message), encoded as it rides inside
      // the sealed blob. The fake opener echoes its input, so the OUTER envelope
      // ciphertext is exactly this encoded inner record.
      final innerBytes = SealedInner(
        conversationId: convoId,
        envelopeType: EnvelopeType.mlsApplication,
        senderDeviceId: 'peer-dev',
        ciphertext: utf8.encode('sealed hello'),
      ).encode();

      // Outer sealed envelope: opaque to the server (no real conversation/sender).
      ws.push(_envelope(
        envelopeId: 'sealed-1',
        conversationId: '',
        senderDeviceId: '',
        envelopeType: EnvelopeType.sealed,
        ciphertext: innerBytes,
      ));
      await pumpEventQueue();

      final msg = notifier
          .byId(convoId)!
          .messages
          .firstWhere((m) => m.envelopeId == 'sealed-1');
      expect(msg.body, equals('sealed hello'),
          reason: 'the inner envelope was unwrapped and dispatched');
      expect(msg.senderDeviceId, equals('peer-dev'));
      expect(msg.mine, isFalse);
    });

    test('a sealed envelope we cannot open yields no message', () async {
      await connectWithKnownDevices();
      final convoId = seedMlsConvoBf();
      when(() => api.ackMessages(any())).thenAnswer((_) async => 1);
      crypto.throwOnOpenSealed = true; // model a blob not addressed to us

      ws.push(_envelope(
        envelopeId: 'sealed-bad',
        conversationId: '',
        senderDeviceId: '',
        envelopeType: EnvelopeType.sealed,
        ciphertext: const [1, 2, 3],
      ));
      await pumpEventQueue();

      expect(notifier.byId(convoId)!.messages, isEmpty,
          reason: 'an unopenable sealed blob yields no message');
    });

    test('a sealed envelope we cannot open is NOT acked on the first failure',
        () async {
      // Acking here destroys the message. A device whose sealing keypair was
      // regenerated fails to open EVERY inbound envelope, so an immediate ack
      // silently shredded the whole conversation while the sender saw a normal
      // delivery. Leave it on the server so it can redeliver once we repair.
      await connectWithKnownDevices();
      seedMlsConvoBf();
      when(() => api.ackMessages(any())).thenAnswer((_) async => 1);
      crypto.throwOnOpenSealed = true;

      ws.push(_envelope(
        envelopeId: 'sealed-bad',
        conversationId: '',
        senderDeviceId: '',
        envelopeType: EnvelopeType.sealed,
        ciphertext: const [1, 2, 3],
      ));
      await pumpEventQueue();

      verifyNever(() => api.ackMessages(any(that: contains('sealed-bad'))));
    });

    test('failing to open a sealed envelope republishes our sealing key',
        () async {
      // Peers seal to the copy the SERVER holds, so republishing is the only
      // thing that can end the outage — the device is the only party that knows
      // its real key.
      await connectWithKnownDevices();
      seedMlsConvoBf();
      when(() => api.ackMessages(any())).thenAnswer((_) async => 1);
      crypto.identity = IdentityHandle(
        id: 'h',
        publicKey: const [],
        x25519PublicKey: List<int>.filled(32, 9),
      );
      crypto.throwOnOpenSealed = true;
      clearInteractions(api);

      ws.push(_envelope(
        envelopeId: 'sealed-bad',
        conversationId: '',
        senderDeviceId: '',
        envelopeType: EnvelopeType.sealed,
        ciphertext: const [1, 2, 3],
      ));
      await pumpEventQueue();

      verify(() => api.reportSealedCapability(
          x25519PubKey: List<int>.filled(32, 9))).called(1);
    });

    test('dedups on envelope id (idempotent re-send)', () async {
      await connectWithKnownDevices();
      final convoId = seedMlsConvoBf();

      ws.push(_envelope(
        envelopeId: 'carrier-1',
        conversationId: convoId,
        senderDeviceId: 'me-dev-2',
        envelopeType: EnvelopeType.mlsApplication,
        ciphertext: backfillCipher(convoId),
      ));
      await pumpEventQueue();
      ws.push(_envelope(
        envelopeId: 'carrier-2',
        conversationId: convoId,
        senderDeviceId: 'me-dev-2',
        envelopeType: EnvelopeType.mlsApplication,
        ciphertext: backfillCipher(convoId),
      ));
      await pumpEventQueue();

      final msgs = notifier.byId(convoId)!.messages;
      expect(msgs.where((m) => m.envelopeId == 'hist-1').length, 1);
      expect(msgs.where((m) => m.envelopeId == 'hist-2').length, 1);
    });

    test('ignores a backfill from a NON-own (peer) device', () async {
      await connectWithKnownDevices();
      final convoId = seedMlsConvoBf();

      // 'peer-dev' is NOT one of our devices — a peer must not inject history.
      ws.push(_envelope(
        envelopeId: 'carrier-x',
        conversationId: convoId,
        senderDeviceId: 'peer-dev',
        envelopeType: EnvelopeType.mlsApplication,
        ciphertext: backfillCipher(convoId),
      ));
      await pumpEventQueue();

      expect(notifier.byId(convoId)!.messages, isEmpty);
    });
  });

  group('message requests', () {
    test('inbound from a resolvable unknown sender creates a PENDING conversation', () async {
      await sessions.save(session);
      await notifier.connect();
      final convoId = Conversation.oneToOneId('me-acc', _peerAccountId);
      when(() => api.lookupAccountByDevice('peer-dev'))
          .thenAnswer((_) async => _peerAccount());

      ws.push(_envelope(
        conversationId: convoId,
        senderDeviceId: 'peer-dev',
        envelopeType: EnvelopeType.textLegacy,
      ));
      await pumpEventQueue();

      final convo = notifier.byId(convoId);
      expect(convo, isNotNull);
      expect(convo!.peerUsername, equals(_peerUsername));
      expect(convo.pending, isTrue,
          reason: 'inbound-created conversations are message requests');
      // Pending survives a restart.
      final loaded = await db.loadConversations();
      expect(loaded.singleWhere((c) => c.id == convoId).pending, isTrue);
    });

    test('a request from a linked device uses that device own X25519 key',
        () async {
      await sessions.save(session);
      await notifier.connect();
      final convoId = Conversation.oneToOneId('me-acc', _peerAccountId);
      when(() => api.lookupAccountByDevice('peer-linked')).thenAnswer((_) async =>
          const Account(
            accountId: _peerAccountId,
            username: _peerUsername,
            identityPubKey: [9, 8, 7],
            x25519PubKey: [1, 2, 3],
            deviceId: 'peer-dev',
            devices: [
              AccountDevice(deviceId: 'peer-dev', x25519PubKey: [1, 2, 3]),
              AccountDevice(deviceId: 'peer-linked', x25519PubKey: [4, 5, 6]),
            ],
          ));

      ws.push(_envelope(
        conversationId: convoId,
        senderDeviceId: 'peer-linked',
        envelopeType: EnvelopeType.textLegacy,
      ));
      await pumpEventQueue();

      expect(notifier.byId(convoId)!.peerX25519PubKey, [4, 5, 6]);
    });

    test('unresolvable unknown-sender placeholder is pending too', () async {
      await sessions.save(session);
      await notifier.connect();
      // lookupAccountByDevice unstubbed → resolution fails → placeholder.

      ws.push(_envelope(
        conversationId: 'unknown-convo',
        senderDeviceId: 'stranger',
        envelopeType: EnvelopeType.textLegacy,
      ));
      await pumpEventQueue();

      expect(notifier.byId('unknown-convo')!.pending, isTrue);
    });

    test('self-sync from our own device for a chat we hold no copy of creates no request',
        () async {
      await sessions.save(session);
      when(() => api.listDevices()).thenAnswer((_) async => [
            const Device(
                deviceId: _myDeviceId, accountId: 'me-acc', devicePubKey: []),
            const Device(
                deviceId: 'me-dev-2',
                accountId: 'me-acc',
                devicePubKey: [],
                x25519PubKey: [7, 7, 7]),
          ]);
      await notifier.connect();
      final convoId = Conversation.oneToOneId('me-acc', _peerAccountId);

      ws.push(_envelope(
        envelopeId: 'sibling-sync-1',
        conversationId: convoId,
        senderDeviceId: 'me-dev-2',
        envelopeType: EnvelopeType.textLegacy,
      ));
      await pumpEventQueue();

      expect(notifier.byId(convoId), isNull);
    });

    test('self-sync from our own device is acked so it cannot come back', () async {
      await sessions.save(session);
      when(() => api.listDevices()).thenAnswer((_) async => [
            const Device(
                deviceId: _myDeviceId, accountId: 'me-acc', devicePubKey: []),
            const Device(
                deviceId: 'me-dev-2',
                accountId: 'me-acc',
                devicePubKey: [],
                x25519PubKey: [7, 7, 7]),
          ]);
      when(() => api.ackMessages(any())).thenAnswer((_) async => 1);
      await notifier.connect();
      final convoId = Conversation.oneToOneId('me-acc', _peerAccountId);

      ws.push(_envelope(
        envelopeId: 'sibling-sync-2',
        conversationId: convoId,
        senderDeviceId: 'me-dev-2',
        envelopeType: EnvelopeType.textLegacy,
      ));
      await pumpEventQueue();

      verify(() => api.ackMessages(any(that: contains('sibling-sync-2'))))
          .called(greaterThanOrEqualTo(1));
    });

    test('an unknown stub left by an older build is cleared by the next self-sync',
        () async {
      await sessions.save(session);
      when(() => api.listDevices()).thenAnswer((_) async => [
            const Device(
                deviceId: _myDeviceId, accountId: 'me-acc', devicePubKey: []),
            const Device(
                deviceId: 'me-dev-2',
                accountId: 'me-acc',
                devicePubKey: [],
                x25519PubKey: [7, 7, 7]),
          ]);
      await notifier.connect();
      final convoId = Conversation.oneToOneId('me-acc', _peerAccountId);
      notifier.seed(Conversation(
        id: convoId,
        peerUsername: 'unknown',
        peerAccountId: '',
        peerDeviceId: 'me-dev-2',
        peerIdentityPubKey: const [],
        messages: const [],
        unreadCount: 1,
        pending: true,
      ));

      ws.push(_envelope(
        envelopeId: 'sibling-sync-3',
        conversationId: convoId,
        senderDeviceId: 'me-dev-2',
        envelopeType: EnvelopeType.textLegacy,
      ));
      await pumpEventQueue();

      expect(notifier.byId(convoId), isNull);
    });

    test('a real stranger is still a request after the self-sync guard', () async {
      await sessions.save(session);
      when(() => api.listDevices()).thenAnswer((_) async => [
            const Device(
                deviceId: _myDeviceId, accountId: 'me-acc', devicePubKey: []),
          ]);
      await notifier.connect();
      final convoId = Conversation.oneToOneId('me-acc', _peerAccountId);
      when(() => api.lookupAccountByDevice('peer-dev'))
          .thenAnswer((_) async => _peerAccount());

      ws.push(_envelope(
        conversationId: convoId,
        senderDeviceId: 'peer-dev',
        envelopeType: EnvelopeType.textLegacy,
      ));
      await pumpEventQueue();

      expect(notifier.byId(convoId)!.pending, isTrue);
    });

    test('acceptMessageRequest flips pending and persists', () async {
      await sessions.save(session);
      await notifier.connect();
      final convoId = Conversation.oneToOneId('me-acc', _peerAccountId);
      when(() => api.lookupAccountByDevice('peer-dev'))
          .thenAnswer((_) async => _peerAccount());
      ws.push(_envelope(
        conversationId: convoId,
        senderDeviceId: 'peer-dev',
        envelopeType: EnvelopeType.textLegacy,
      ));
      await pumpEventQueue();
      expect(notifier.byId(convoId)!.pending, isTrue);

      await notifier.acceptMessageRequest(convoId);

      expect(notifier.byId(convoId)!.pending, isFalse);
      final loaded = await db.loadConversations();
      expect(loaded.singleWhere((c) => c.id == convoId).pending, isFalse);
    });

    test('rejectMessageRequest BLOCKS the conversation (kept + un-rejectable), '
        'not delete', () async {
      await sessions.save(session);
      await notifier.connect();
      when(() => api.ackMessages(any())).thenAnswer((_) async => 1);
      final convoId = Conversation.oneToOneId('me-acc', _peerAccountId);
      when(() => api.lookupAccountByDevice('peer-dev'))
          .thenAnswer((_) async => _peerAccount());
      ws.push(_envelope(
        conversationId: convoId,
        senderDeviceId: 'peer-dev',
        envelopeType: EnvelopeType.textLegacy,
      ));
      await pumpEventQueue();
      // The held envelope re-delivers via the refetch and decrypts.
      ws.push(_envelope(
        envelopeId: 'env-2',
        conversationId: convoId,
        senderDeviceId: 'peer-dev',
        envelopeType: EnvelopeType.textLegacy,
      ));
      await pumpEventQueue();
      expect(notifier.byId(convoId)!.messages, isNotEmpty);

      await notifier.rejectMessageRequest(convoId);
      await pumpEventQueue();

      // Reject = persistent block (NOT delete): the conversation is kept so the
      // first message stays visible and the user can un-reject (unblock) later.
      final convo = notifier.byId(convoId);
      expect(convo, isNotNull, reason: 'reject keeps the conversation');
      expect(convo!.blocked, isTrue,
          reason: 'rejected = blocked: stop receiving + send guard');
      expect(convo.pending, isFalse, reason: 'decided request, no longer pending');
      expect(convo.messages, isNotEmpty,
          reason: 'first message preserved for review / un-reject');
      // "Can't send to someone you rejected" — sendMessage guards on isBlocked.
      expect(notifier.isBlocked(convoId), isTrue);
    });

    test('accepting a request self-syncs the decision to our own other devices',
        () async {
      await sessions.save(session);
      when(() => api.listDevices()).thenAnswer((_) async => [
            const Device(
                deviceId: _myDeviceId, accountId: 'me-acc', devicePubKey: []),
            const Device(
                deviceId: 'me-dev-2',
                accountId: 'me-acc',
                devicePubKey: [],
                x25519PubKey: [7, 7, 7]),
          ]);
      await notifier.connect();
      final convoId = Conversation.oneToOneId('me-acc', _peerAccountId);
      when(() => api.lookupAccountByDevice('peer-dev'))
          .thenAnswer((_) async => _peerAccount());
      ws.push(_envelope(
        conversationId: convoId,
        senderDeviceId: 'peer-dev',
        envelopeType: EnvelopeType.textLegacy,
      ));
      await pumpEventQueue();

      await notifier.acceptMessageRequest(convoId);
      await pumpEventQueue();

      // A control rode out to our OWN other device (receipts go to the peer,
      // never to me-dev-2 — so any submit to me-dev-2 is the self-control).
      final sent = verify(() => api.submitMessage(captureAny()))
          .captured
          .cast<SubmitMessagePayload>();
      expect(sent.where((p) => p.recipientDeviceId == 'me-dev-2'), isNotEmpty,
          reason: 'accept should fan the decision to our own other device');
    });

    test('reconnect re-confirms a delivered receipt to the peer (heals lost ✓✓)',
        () async {
      await sessions.save(session);
      await notifier.connect();
      // A normal, sendable 1:1 holding one INBOUND (peer) message whose
      // receive-time delivered receipt was lost on a flaky socket (the bug).
      // peerX25519PubKey present so the control can encrypt + submit.
      notifier.seed(Conversation(
        id: 'seeded',
        peerUsername: 'peer',
        peerAccountId: 'p',
        peerDeviceId: 'pd',
        peerIdentityPubKey: const [],
        peerX25519PubKey: const [1, 2, 3],
        messages: [
          ChatMessage(
            envelopeId: 'in-1',
            conversationId: 'seeded',
            senderDeviceId: 'pd',
            body: 'hi',
            serverTs: DateTime.utc(2026, 5, 9),
            mine: false,
          ),
        ],
        unreadCount: 1,
      ));
      when(() => api.submitMessage(any())).thenAnswer((_) async =>
          SubmitMessageResult(
              envelopeId: 'e', serverTs: DateTime.utc(2026, 5, 9)));
      clearInteractions(api);

      supervisor.emitReconnected();
      await pumpEventQueue();

      final sent = verify(() => api.submitMessage(captureAny()))
          .captured
          .cast<SubmitMessagePayload>();
      expect(sent.where((p) => p.recipientDeviceId == 'pd'), isNotEmpty,
          reason: 'reconnect must re-confirm the inbound message as delivered '
              'to the peer — healing a ✓ that never reached ✓✓');
    });

    test('reconnect sends no re-confirm when there are no inbound messages',
        () async {
      await sessions.save(session);
      when(() => api.listDevices()).thenAnswer((_) async => [
            const Device(
                deviceId: _myDeviceId, accountId: 'me-acc', devicePubKey: []),
          ]);
      await notifier.connect();
      clearInteractions(api);

      // No conversations / no inbound messages → nothing to re-confirm.
      supervisor.emitReconnected();
      await pumpEventQueue();

      verifyNever(() => api.submitMessage(any()));
    });

    test('reconnect re-asserts privacy flags to peers when a flag is ON',
        () async {
      // The user blocks forwarding. A peer that missed the live toggle
      // broadcast (offline then, no new message since) must converge on
      // reconnect — otherwise it keeps allowing forward/screenshot.
      notifier.dispose();
      notifier = buildNotifier(
        privacyFlagsProvider: () => (screenshots: false, forwarding: true),
      );
      await sessions.save(session);
      await notifier.connect();
      // A clean, sendable 1:1 with NO inbound messages, so the delivered-receipt
      // re-confirm sends nothing — any submit here is the privacy re-assert.
      notifier.seed(Conversation(
        id: 'seeded',
        peerUsername: 'peer',
        peerAccountId: 'p',
        peerDeviceId: 'pd',
        peerIdentityPubKey: const [],
        peerX25519PubKey: const [1, 2, 3],
        messages: const [],
        unreadCount: 0,
      ));
      when(() => api.submitMessage(any())).thenAnswer((_) async =>
          SubmitMessageResult(
              envelopeId: 'e', serverTs: DateTime.utc(2026, 5, 9)));
      clearInteractions(api);

      supervisor.emitReconnected();
      await pumpEventQueue();

      final sent = verify(() => api.submitMessage(captureAny()))
          .captured
          .cast<SubmitMessagePayload>();
      final privacyControls = sent
          .map((p) => MessageControl.tryDecode(utf8.decode(p.ciphertext)))
          .where((c) => c != null && c.isPrivacy)
          .toList();
      expect(privacyControls, isNotEmpty,
          reason: 'reconnect must re-broadcast the privacy flags to the peer');
      expect(privacyControls.first!.privacyForwarding, isTrue);
    });

    test('reconnect does NOT re-assert privacy flags when both are OFF',
        () async {
      // OFF is the default an unseen peer assumes, so re-asserting it every
      // reconnect would spam every 1:1 for users who never use the feature.
      notifier.dispose();
      notifier = buildNotifier(
        privacyFlagsProvider: () => (screenshots: false, forwarding: false),
      );
      await sessions.save(session);
      await notifier.connect();
      notifier.seed(Conversation(
        id: 'seeded',
        peerUsername: 'peer',
        peerAccountId: 'p',
        peerDeviceId: 'pd',
        peerIdentityPubKey: const [],
        peerX25519PubKey: const [1, 2, 3],
        messages: const [],
        unreadCount: 0,
      ));
      clearInteractions(api);

      supervisor.emitReconnected();
      await pumpEventQueue();

      verifyNever(() => api.submitMessage(any()));
    });

    test(
        'notifyPeerOfScreenshot sends a screenshot control when the peer '
        'blocks screenshots', () async {
      await sessions.save(session);
      await notifier.connect();
      notifier.seed(Conversation(
        id: 'seeded',
        peerUsername: 'peer',
        peerAccountId: 'p',
        peerDeviceId: 'pd',
        peerIdentityPubKey: const [],
        peerX25519PubKey: const [1, 2, 3],
        messages: const [],
        unreadCount: 0,
        peerBlocksScreenshots: true,
      ));
      when(() => api.submitMessage(any())).thenAnswer((_) async =>
          SubmitMessageResult(
              envelopeId: 'e', serverTs: DateTime.utc(2026, 5, 9)));
      clearInteractions(api);

      await notifier.notifyPeerOfScreenshot('seeded');
      await pumpEventQueue();

      final shots = verify(() => api.submitMessage(captureAny()))
          .captured
          .cast<SubmitMessagePayload>()
          .map((p) => MessageControl.tryDecode(utf8.decode(p.ciphertext)))
          .where((c) => c != null && c.isScreenshot)
          .toList();
      expect(shots, isNotEmpty,
          reason: 'a screenshot in a peer-protected 1:1 must notify the peer '
              '(the real protection on iOS, which cannot block the capture)');
    });

    test(
        'notifyPeerOfScreenshot also drops a "You took a screenshot" line on '
        'the screenshotter\'s own thread', () async {
      await sessions.save(session);
      await notifier.connect();
      notifier.seed(Conversation(
        id: 'seeded',
        peerUsername: 'peer',
        peerAccountId: 'p',
        peerDeviceId: 'pd',
        peerIdentityPubKey: const [],
        peerX25519PubKey: const [1, 2, 3],
        messages: const [],
        unreadCount: 0,
        peerBlocksScreenshots: true,
      ));
      when(() => api.submitMessage(any())).thenAnswer((_) async =>
          SubmitMessageResult(
              envelopeId: 'e', serverTs: DateTime.utc(2026, 5, 9)));

      await notifier.notifyPeerOfScreenshot('seeded');
      await pumpEventQueue();

      final notices = notifier
          .byId('seeded')!
          .messages
          .map((m) => SystemEvent.tryDecode(m.body))
          .whereType<SystemEvent>()
          .map((e) => e.displayText)
          .toList();
      expect(notices, contains('You took a screenshot'),
          reason: 'both ends of the chat should see the capture happened, so '
              "the screenshotter's own thread shows the notice too");
    });

    test(
        'notifyPeerOfScreenshot is a no-op when NEITHER side blocks '
        'screenshots', () async {
      // No screenshot protection is active for this chat (peer didn't ask and
      // the user's own block is off), so a capture notifies no one.
      await sessions.save(session);
      await notifier.connect();
      notifier.seed(Conversation(
        id: 'seeded',
        peerUsername: 'peer',
        peerAccountId: 'p',
        peerDeviceId: 'pd',
        peerIdentityPubKey: const [],
        peerX25519PubKey: const [1, 2, 3],
        messages: const [],
        unreadCount: 0,
      ));
      clearInteractions(api);

      await notifier.notifyPeerOfScreenshot('seeded');
      await pumpEventQueue();

      verifyNever(() => api.submitMessage(any()));
    });

    test(
        'notifyPeerOfScreenshot sends when the user\'s OWN screenshot block is '
        'on even if the peer never asked', () async {
      // The peer's flag may not have propagated to a freshly-restored device,
      // but the user's own block being on means protection is active for this
      // chat — so a capture must still tell the peer.
      notifier.dispose();
      notifier = buildNotifier(
        privacyFlagsProvider: () => (screenshots: true, forwarding: false),
      );
      await sessions.save(session);
      await notifier.connect();
      notifier.seed(Conversation(
        id: 'seeded',
        peerUsername: 'peer',
        peerAccountId: 'p',
        peerDeviceId: 'pd',
        peerIdentityPubKey: const [],
        peerX25519PubKey: const [1, 2, 3],
        messages: const [],
        unreadCount: 0,
        // peerBlocksScreenshots defaults to false — the peer never asked.
      ));
      when(() => api.submitMessage(any())).thenAnswer((_) async =>
          SubmitMessageResult(
              envelopeId: 'e', serverTs: DateTime.utc(2026, 5, 9)));
      clearInteractions(api);

      await notifier.notifyPeerOfScreenshot('seeded');
      await pumpEventQueue();

      final shots = verify(() => api.submitMessage(captureAny()))
          .captured
          .cast<SubmitMessagePayload>()
          .map((p) => MessageControl.tryDecode(utf8.decode(p.ciphertext)))
          .where((c) => c != null && c.isScreenshot)
          .toList();
      expect(shots, isNotEmpty,
          reason: "the user's own block being on keeps the peer informed even "
              'when their flag has not reached us');
    });

    test('notifyPeerOfScreenshot coalesces a burst into a single notice',
        () async {
      await sessions.save(session);
      await notifier.connect();
      notifier.seed(Conversation(
        id: 'seeded',
        peerUsername: 'peer',
        peerAccountId: 'p',
        peerDeviceId: 'pd',
        peerIdentityPubKey: const [],
        peerX25519PubKey: const [1, 2, 3],
        messages: const [],
        unreadCount: 0,
        peerBlocksScreenshots: true,
      ));
      when(() => api.submitMessage(any())).thenAnswer((_) async =>
          SubmitMessageResult(
              envelopeId: 'e', serverTs: DateTime.utc(2026, 5, 9)));
      clearInteractions(api);

      // A single capture can post the OS notification twice; both land within
      // the throttle window → the peer is told once.
      await notifier.notifyPeerOfScreenshot('seeded');
      await notifier.notifyPeerOfScreenshot('seeded');
      await pumpEventQueue();

      final shots = verify(() => api.submitMessage(captureAny()))
          .captured
          .cast<SubmitMessagePayload>()
          .map((p) => MessageControl.tryDecode(utf8.decode(p.ciphertext)))
          .where((c) => c != null && c.isScreenshot)
          .toList();
      expect(shots, hasLength(1));
    });

    test("an inbound screenshot control inserts a 'took a screenshot' pill",
        () async {
      await sessions.save(session);
      await notifier.connect();
      when(() => api.ackMessages(any())).thenAnswer((_) async => 1);
      final convoId = Conversation.oneToOneId('me-acc', _peerAccountId);
      when(() => api.lookupAccountByDevice('peer-dev'))
          .thenAnswer((_) async => _peerAccount());

      // A normal inbound message first, so the 1:1 exists.
      ws.push(_envelope(
        conversationId: convoId,
        senderDeviceId: 'peer-dev',
        envelopeType: EnvelopeType.textLegacy,
      ));
      await pumpEventQueue();

      // Then the peer's screenshot notice.
      ws.push(_envelope(
        envelopeId: 'env-shot',
        conversationId: convoId,
        senderDeviceId: 'peer-dev',
        envelopeType: EnvelopeType.textLegacy,
        ciphertext: utf8.encode(const MessageControl.screenshot().encode()),
      ));
      await pumpEventQueue();

      final shots = notifier
          .byId(convoId)!
          .messages
          .where((m) => m.kind == MessageKind.system)
          .map((m) => SystemEvent.tryDecode(m.body))
          .where((e) => e?.kind == SystemEventKind.screenshotTaken)
          .toList();
      expect(shots, hasLength(1),
          reason: 'the peer screenshotting our protected chat must surface an '
              'in-thread system line');
      expect(shots.first!.displayText, contains('took a screenshot'));
    });

    test('a request_decision from our own device clears pending here too',
        () async {
      await sessions.save(session);
      when(() => api.listDevices()).thenAnswer((_) async => [
            const Device(
                deviceId: _myDeviceId, accountId: 'me-acc', devicePubKey: []),
            const Device(
                deviceId: 'me-dev-2',
                accountId: 'me-acc',
                devicePubKey: [],
                x25519PubKey: [7, 7, 7]),
          ]);
      await notifier.connect();
      when(() => api.ackMessages(any())).thenAnswer((_) async => 1);
      final convoId = Conversation.oneToOneId('me-acc', _peerAccountId);
      when(() => api.lookupAccountByDevice('peer-dev'))
          .thenAnswer((_) async => _peerAccount());
      ws.push(_envelope(
        conversationId: convoId,
        senderDeviceId: 'peer-dev',
        envelopeType: EnvelopeType.textLegacy,
      ));
      await pumpEventQueue();
      expect(notifier.byId(convoId)!.pending, isTrue);

      // Our OWN other device relays an "accepted" decision.
      ws.push(_envelope(
        envelopeId: 'env-accept',
        conversationId: convoId,
        senderDeviceId: 'me-dev-2',
        envelopeType: EnvelopeType.textLegacy,
        ciphertext: utf8.encode(
            const MessageControl.requestDecision(RequestDecision.accepted)
                .encode()),
      ));
      await pumpEventQueue();

      expect(notifier.byId(convoId)!.pending, isFalse,
          reason: 'a sibling-device accept should clear our banner');
    });

    test('a self-synced copy of our own sent message does not bump unread',
        () async {
      await sessions.save(session);
      when(() => api.listDevices()).thenAnswer((_) async => [
            const Device(
                deviceId: _myDeviceId, accountId: 'me-acc', devicePubKey: []),
            const Device(
                deviceId: 'me-dev-2',
                accountId: 'me-acc',
                devicePubKey: [],
                x25519PubKey: [7, 7, 7]),
          ]);
      await notifier.connect();
      when(() => api.ackMessages(any())).thenAnswer((_) async => 1);
      final convoId = Conversation.oneToOneId('me-acc', _peerAccountId);
      when(() => api.lookupAccountByDevice('peer-dev'))
          .thenAnswer((_) async => _peerAccount());
      ws.push(_envelope(
        envelopeId: 'env-first',
        conversationId: convoId,
        senderDeviceId: 'peer-dev',
        envelopeType: EnvelopeType.textLegacy,
      ));
      await pumpEventQueue();
      notifier.markRead(convoId);
      expect(notifier.byId(convoId)!.unreadCount, 0);

      ws.push(_envelope(
        envelopeId: 'env-mine',
        conversationId: convoId,
        senderDeviceId: 'me-dev-2',
        envelopeType: EnvelopeType.textLegacy,
        ciphertext: utf8.encode('sent from my other phone'),
      ));
      await pumpEventQueue();

      expect(notifier.byId(convoId)!.messages.last.mine, isTrue);
      expect(notifier.byId(convoId)!.unreadCount, 0);
    });

    test('a request_decision forged by the PEER is ignored', () async {
      await sessions.save(session);
      await notifier.connect();
      when(() => api.ackMessages(any())).thenAnswer((_) async => 1);
      final convoId = Conversation.oneToOneId('me-acc', _peerAccountId);
      when(() => api.lookupAccountByDevice('peer-dev'))
          .thenAnswer((_) async => _peerAccount());
      ws.push(_envelope(
        conversationId: convoId,
        senderDeviceId: 'peer-dev',
        envelopeType: EnvelopeType.textLegacy,
      ));
      await pumpEventQueue();
      expect(notifier.byId(convoId)!.pending, isTrue);

      // The PEER tries to resolve our request — must NOT be honored.
      ws.push(_envelope(
        envelopeId: 'env-forge',
        conversationId: convoId,
        senderDeviceId: 'peer-dev',
        envelopeType: EnvelopeType.textLegacy,
        ciphertext: utf8.encode(
            const MessageControl.requestDecision(RequestDecision.accepted)
                .encode()),
      ));
      await pumpEventQueue();

      expect(notifier.byId(convoId)!.pending, isTrue,
          reason: 'a peer cannot resolve our message request');
    });

    test('deleteConversation removes a normal (non-pending) conversation', () async {
      await sessions.save(session);
      await notifier.connect();
      when(() => api.lookupAccount(_peerUsername))
          .thenAnswer((_) async => _peerAccount());
      final convoId = await notifier.startConversation(
        myDeviceId: _myDeviceId,
        username: _peerUsername,
      );
      expect(notifier.byId(convoId)!.pending, isFalse);

      await notifier.deleteConversation(convoId);

      expect(notifier.byId(convoId), isNull);
      final loaded = await db.loadConversations();
      expect(loaded.where((c) => c.id == convoId), isEmpty);
      expect(crypto.clearedConversations, contains(convoId));
      expect(await db.loadConversationCryptoState(convoId), isNull);
    });

    test('startConversation with a pending peer is an implicit accept', () async {
      await sessions.save(session);
      await notifier.connect();
      final convoId = Conversation.oneToOneId('me-acc', _peerAccountId);
      when(() => api.lookupAccountByDevice('peer-dev'))
          .thenAnswer((_) async => _peerAccount());
      ws.push(_envelope(
        conversationId: convoId,
        senderDeviceId: 'peer-dev',
        envelopeType: EnvelopeType.textLegacy,
      ));
      await pumpEventQueue();
      expect(notifier.byId(convoId)!.pending, isTrue);

      when(() => api.lookupAccount(_peerUsername))
          .thenAnswer((_) async => _peerAccount());
      final id = await notifier.startConversation(
        myDeviceId: _myDeviceId,
        username: _peerUsername,
      );

      expect(id, equals(convoId));
      expect(notifier.byId(convoId)!.pending, isFalse,
          reason: 'deliberately reaching out accepts the pending request');
    });

    test('mls_application for a ratchet-mode convo adopts a surviving MLS group', () async {
      // Reject-then-re-message: reject deletes the conversation row but the
      // CoreCrypto group (Welcome acked long ago) survives. The re-request
      // recreates the row ratchet-mode; the next mls_application must flip
      // the row to MLS and decrypt instead of black-holing.
      await sessions.save(session);
      await notifier.connect();
      when(() => api.lookupAccount(_peerUsername))
          .thenAnswer((_) async => _peerAccount());
      when(() => api.ackMessages(any())).thenAnswer((_) async => 1);
      final convoId = await notifier.startConversation(
        myDeviceId: _myDeviceId,
        username: _peerUsername,
      );
      expect(notifier.byId(convoId)!.cryptoMode, CryptoMode.ratchet);

      // _PassthroughCrypto.currentEpoch succeeds by default = group opens.
      ws.push(_envelope(
        conversationId: convoId,
        envelopeType: EnvelopeType.mlsApplication,
        ciphertext: utf8.encode('via mls'),
      ));
      await pumpEventQueue();

      final convo = notifier.byId(convoId)!;
      expect(convo.cryptoMode, CryptoMode.mls);
      expect(convo.messages.single.body, equals('via mls'));
    });

    test('mls_application for a ratchet-mode convo still drops when no group exists', () async {
      await sessions.save(session);
      await notifier.connect();
      when(() => api.lookupAccount(_peerUsername))
          .thenAnswer((_) async => _peerAccount());
      when(() => api.ackMessages(any())).thenAnswer((_) async => 1);
      final convoId = await notifier.startConversation(
        myDeviceId: _myDeviceId,
        username: _peerUsername,
      );
      crypto.currentEpochError = Exception('no group');

      ws.push(_envelope(
        conversationId: convoId,
        envelopeType: EnvelopeType.mlsApplication,
        ciphertext: utf8.encode('lost'),
      ));
      await pumpEventQueue();

      final convo = notifier.byId(convoId)!;
      expect(convo.cryptoMode, CryptoMode.ratchet);
      expect(convo.messages, isEmpty);
    });
  });

  group('inbound notifications', () {
    // A known (non-placeholder) 1:1 so the inbound message takes the normal
    // append path (an unknown sender goes to the silent message-request path).
    Future<String> establishConvo() async {
      await sessions.save(session);
      await notifier.connect();
      when(() => api.lookupAccount(_peerUsername))
          .thenAnswer((_) async => _peerAccount());
      return notifier.startConversation(
        myDeviceId: _myDeviceId,
        username: _peerUsername,
      );
    }

    void pushInbound(String convoId) => ws.push(_envelope(
          conversationId: convoId,
          senderDeviceId: 'peer-dev',
          envelopeType: EnvelopeType.textLegacy,
        ));

    test('raises a notification while backgrounded', () async {
      final convoId = await establishConvo();
      notifier.appInForeground = false;
      pushInbound(convoId);
      await pumpEventQueue();
      expect(notifications.shownConvoIds, contains(convoId),
          reason: 'a backgrounded inbound message (arriving over the live '
              'socket) must notify — FCM never fires while the socket is up');
    });

    test('raises a notification while foreground but viewing a DIFFERENT chat',
        () async {
      final convoId = await establishConvo();
      notifier.appInForeground = true;
      notifier.setOpenConversation('1to1:me-acc:someone-else');
      pushInbound(convoId);
      await pumpEventQueue();
      expect(notifications.shownConvoIds, contains(convoId));
    });

    test('no notification while foreground + viewing that exact chat',
        () async {
      final convoId = await establishConvo();
      notifier.appInForeground = true;
      notifier.setOpenConversation(convoId);
      pushInbound(convoId);
      await pumpEventQueue();
      expect(notifications.shownConvoIds, isEmpty,
          reason: 'the user is reading this thread — they already see it');
    });

    test('opening a thread dismisses the notification for that conversation',
        () async {
      final convoId = await establishConvo();
      notifier.setOpenConversation(convoId);
      expect(notifications.cancelledIds, [convoId.hashCode]);
    });

    test('no notification for a backlog message delivered via catchup',
        () async {
      final convoId = await establishConvo();
      // Backgrounded — an identical LIVE push notifies (see the backgrounded
      // test above); the ONLY difference here is that the message arrives via
      // the reconnect catchup, not the live socket.
      notifier.appInForeground = false;
      when(() => api.catchupMessages(since: any(named: 'since'), limit: any(named: 'limit'))).thenAnswer(
        (_) async => [
          _envelope(
            conversationId: convoId,
            senderDeviceId: 'peer-dev',
            envelopeType: EnvelopeType.textLegacy,
          ),
        ],
      );

      supervisor.emitReconnected();
      await pumpEventQueue();

      // The message is delivered + stored...
      expect(notifier.byId(convoId)!.messages.where((m) => !m.mine), isNotEmpty,
          reason: 'catchup must still deliver + persist the backlog message');
      // ...but silently: re-notifying a backlog message that the FCM wakeup
      // already alerted while the app was offline is the "tapped the push, app
      // reconnected, got pinged again" duplicate.
      expect(notifications.shownConvoIds, isEmpty,
          reason: 'a catchup/backlog message must not raise a notification');
    });

    test('a catchup backlog coalesces into ONE rebuild, not one per message',
        () async {
      final convoId = await establishConvo();
      // Six distinct backlog messages arrive together on the reconnect catchup.
      // Without coalescing the appender pulses the host once per message — an
      // O(K) full-UI rebuild storm; the drain now batches those pulses into a
      // single notifyListeners fired when the whole backlog has settled.
      const k = 6;
      when(() => api.catchupMessages(since: any(named: 'since'), limit: any(named: 'limit'))).thenAnswer(
        (_) async => [
          for (var i = 0; i < k; i++)
            _envelope(
              envelopeId: 'catchup-$i',
              conversationId: convoId,
              senderDeviceId: 'peer-dev',
              envelopeType: EnvelopeType.textLegacy,
              ciphertext: [104, 105, 48 + i], // "hi0".."hi5" — distinct bodies
            ),
        ],
      );

      var notifyCount = 0;
      notifier.addListener(() => notifyCount++);

      supervisor.emitReconnected();
      await pumpEventQueue();

      // Every backlog message still lands + persists...
      expect(notifier.byId(convoId)!.messages.where((m) => !m.mine).length, k,
          reason: 'every backlog message must still be delivered + persisted');
      // ...but the listener fired FEWER times than there were messages — proof
      // the per-message pulses were coalesced (a fixed handful of connection /
      // gate / batch notifies, never one-per-message, which would be >= k).
      expect(notifyCount, lessThan(k),
          reason: 'the catchup drain must coalesce per-message rebuilds into '
              'a single settle-time notification');
    });
  });

  group('sendMessage', () {
    Future<String> seedConvo() async {
      await sessions.save(session);
      await notifier.connect();
      when(() => api.lookupAccount(_peerUsername))
          .thenAnswer((_) async => _peerAccount());
      return notifier.startConversation(
        myDeviceId: _myDeviceId,
        username: _peerUsername,
      );
    }

    test('throws StateError when conversation is missing', () async {
      expect(
        () => notifier.sendMessage(
          conversationId: 'unknown',
          myDeviceId: _myDeviceId,
          text: 'hi',
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('throws StateError when conversation has no peer X25519 key', () async {
      // A legacy conversation seeded directly with no peer key — init would
      // fail in production. The notifier surfaces a clear StateError instead
      // of crashing or sending plaintext.
      notifier.seed(Conversation(
        id: 'legacy',
        peerUsername: 'old-peer',
        peerAccountId: 'old',
        peerDeviceId: 'old-d',
        peerIdentityPubKey: const [],
        // peerX25519PubKey defaults to empty
        messages: const [],
        unreadCount: 0,
      ));

      await expectLater(
        notifier.sendMessage(
          conversationId: 'legacy',
          myDeviceId: _myDeviceId,
          text: 'hi',
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('initializes ratchet state on first send for a seeded conversation', () async {
      // seed() doesn't init crypto state. First sendMessage must do so via
      // _loadOrInitCryptoState — exercises the DB-empty + peer-key-present
      // branch.
      notifier.seed(Conversation(
        id: 'seeded',
        peerUsername: 'peer',
        peerAccountId: 'p',
        peerDeviceId: 'pd',
        peerIdentityPubKey: const [],
        peerX25519PubKey: const [1, 2, 3],
        messages: const [],
        unreadCount: 0,
      ));
      when(() => api.submitMessage(any())).thenAnswer((_) async =>
          SubmitMessageResult(envelopeId: 'e', serverTs: DateTime.utc(2026, 5, 9)));

      await notifier.sendMessage(
        conversationId: 'seeded',
        myDeviceId: _myDeviceId,
        text: 'first',
      );

      // After the first send the ratchet state is persisted with sendCounter=1.
      final loaded = await db.loadConversationCryptoState('seeded');
      expect(loaded, isNotNull);
      expect(loaded!.sendCounter, equals(1));
    });

    test('send seals the envelope when sealedSenderEnabled (round-trips)',
        () async {
      await sessions.save(session);
      await notifier.connect();
      notifier.sealedSenderEnabled = true;
      when(() => api.submitMessage(any())).thenAnswer((_) async =>
          SubmitMessageResult(envelopeId: 'e', serverTs: DateTime.utc(2026, 5, 9)));

      // A real peer X25519 keypair so the seal is genuinely openable.
      final x = X25519();
      final peerKp = await x.newKeyPair();
      final peerPub = (await peerKp.extractPublicKey()).bytes;
      final peerPriv = await peerKp.extractPrivateKeyBytes();

      // The peer device must have advertised sealed-receive capability for the
      // gate to clear it; the warm-on-miss lookup surfaces that flag + key.
      when(() => api.lookupAccount('peer')).thenAnswer((_) async => Account(
            accountId: 'p',
            username: 'peer',
            identityPubKey: const [],
            x25519PubKey: peerPub,
            deviceId: 'pd',
            devices: [
              AccountDevice(
                  deviceId: 'pd', x25519PubKey: peerPub, supportsSealed: true),
            ],
          ));
      when(() => api.listDevices()).thenAnswer((_) async => const []);

      notifier.seed(Conversation(
        id: 'c-sealed',
        peerUsername: 'peer',
        peerAccountId: 'p',
        peerDeviceId: 'pd',
        peerIdentityPubKey: const [],
        peerX25519PubKey: peerPub,
        messages: const [],
        unreadCount: 0,
      ));

      await notifier.sendMessage(
        conversationId: 'c-sealed',
        myDeviceId: _myDeviceId,
        text: 'secret',
      );

      // The wire frame is sealed: opaque type, no conversation visible.
      final frame = ws.sentFrames.last;
      expect(frame['envelope_type'], equals(EnvelopeType.sealed));
      expect(frame['conversation_id'], equals(''));

      // ...and it round-trips: the recipient's key recovers the real inner.
      final blob = (frame['ciphertext'] as List).cast<int>();
      final innerBytes = await SealedEnvelope()
          .open(recipientX25519PrivKey: peerPriv, sealed: blob);
      final inner = SealedInner.decode(innerBytes);
      expect(inner.conversationId, equals('c-sealed'));
      expect(inner.senderDeviceId, equals(_myDeviceId));
      expect(inner.ciphertext, isNotEmpty);
    });

    test('send is NOT sealed when the flag is off', () async {
      await sessions.save(session);
      await notifier.connect();
      when(() => api.submitMessage(any())).thenAnswer((_) async =>
          SubmitMessageResult(envelopeId: 'e', serverTs: DateTime.utc(2026, 5, 9)));
      notifier.seed(Conversation(
        id: 'c-plain',
        peerUsername: 'peer',
        peerAccountId: 'p',
        peerDeviceId: 'pd',
        peerIdentityPubKey: const [],
        peerX25519PubKey: const [1, 2, 3],
        messages: const [],
        unreadCount: 0,
      ));
      await notifier.sendMessage(
        conversationId: 'c-plain',
        myDeviceId: _myDeviceId,
        text: 'hi',
      );
      expect(ws.sentFrames.last['envelope_type'],
          isNot(equals(EnvelopeType.sealed)));
      expect(ws.sentFrames.last['conversation_id'], equals('c-plain'));
    });

    test('seals a peer device using its per-device X25519 (multi-device)',
        () async {
      await sessions.save(session);
      await notifier.connect();
      notifier.sealedSenderEnabled = true;
      when(() => api.submitMessage(any())).thenAnswer((_) async =>
          SubmitMessageResult(envelopeId: 'e', serverTs: DateTime.utc(2026, 5, 9)));

      // The per-device key (keyB) deliberately differs from the account-level
      // key (keyA). A successful open with keyB proves the seal used the
      // PER-DEVICE cache (the multi-device fix), not the account-level fallback.
      final x = X25519();
      final kpB = await x.newKeyPair();
      final pubB = (await kpB.extractPublicKey()).bytes;
      final privB = await kpB.extractPrivateKeyBytes();
      final keyA = List<int>.filled(32, 7);

      when(() => api.lookupAccount('peer')).thenAnswer((_) async => Account(
            accountId: 'pa',
            username: 'peer',
            identityPubKey: const [],
            x25519PubKey: keyA,
            deviceId: 'pd',
            devices: [
              AccountDevice(
                  deviceId: 'pd', x25519PubKey: pubB, supportsSealed: true),
            ],
          ));
      final convoId = await notifier.startConversation(
          myDeviceId: _myDeviceId, username: 'peer');

      await notifier.sendMessage(
          conversationId: convoId, myDeviceId: _myDeviceId, text: 'multi');

      final frame = ws.sentFrames.last;
      expect(frame['envelope_type'], equals(EnvelopeType.sealed));
      final blob = (frame['ciphertext'] as List).cast<int>();
      final inner = SealedInner.decode(await SealedEnvelope()
          .open(recipientX25519PrivKey: privB, sealed: blob));
      expect(inner.conversationId, equals(convoId),
          reason: 'opened with the per-device key -> resolved from _peerDevices');
    });

    test('does NOT seal a peer device that has not advertised capability',
        () async {
      await sessions.save(session);
      await notifier.connect();
      notifier.sealedSenderEnabled = true;
      when(() => api.submitMessage(any())).thenAnswer((_) async =>
          SubmitMessageResult(envelopeId: 'e', serverTs: DateTime.utc(2026, 5, 9)));

      final x = X25519();
      final kp = await x.newKeyPair();
      final pub = (await kp.extractPublicKey()).bytes;

      // The peer has an X25519 key but supportsSealed defaults false — the gate
      // must withhold sealing so an old-build recipient isn't stranded.
      when(() => api.lookupAccount('peer')).thenAnswer((_) async => Account(
            accountId: 'pa',
            username: 'peer',
            identityPubKey: const [],
            x25519PubKey: pub,
            deviceId: 'pd',
            devices: [AccountDevice(deviceId: 'pd', x25519PubKey: pub)],
          ));
      when(() => api.listDevices()).thenAnswer((_) async => const []);
      final convoId = await notifier.startConversation(
          myDeviceId: _myDeviceId, username: 'peer');

      await notifier.sendMessage(
          conversationId: convoId, myDeviceId: _myDeviceId, text: 'no seal');

      final frame = ws.sentFrames.last;
      expect(frame['envelope_type'], isNot(equals(EnvelopeType.sealed)),
          reason: 'capability unconfirmed -> unsealed fallback');
      expect(frame['conversation_id'], equals(convoId));
    });

    // ── Sealed-sender Phase 2: unidentified access ──────────────────────────
    // Stub for the unauthenticated sealed deposit. Default returns a result; set
    // [unauthShouldThrow] to model a 403/429 so the client falls back to authed.
    Future<String> startConvoWithSealedPeer({required List<int> peerPub}) async {
      when(() => api.lookupAccount('peer')).thenAnswer((_) async => Account(
            accountId: 'pa',
            username: 'peer',
            identityPubKey: const [],
            x25519PubKey: peerPub,
            deviceId: 'pd',
            devices: [
              AccountDevice(
                  deviceId: 'pd', x25519PubKey: peerPub, supportsSealed: true),
            ],
          ));
      when(() => api.listDevices()).thenAnswer((_) async => const []);
      return notifier.startConversation(myDeviceId: _myDeviceId, username: 'peer');
    }

    test('Phase 2: with the peer UAK, a sealed send goes over the unauth path',
        () async {
      await sessions.save(session);
      await notifier.connect();
      notifier.sealedSenderEnabled = true;
      notifier.unidentifiedAccessEnabled = true;
      when(() => api.submitMessage(any())).thenAnswer((_) async =>
          SubmitMessageResult(envelopeId: 'e', serverTs: DateTime.utc(2026, 5, 9)));

      final x = X25519();
      final kp = await x.newKeyPair();
      final pub = (await kp.extractPublicKey()).bytes;
      final convoId = await startConvoWithSealedPeer(peerPub: pub);

      // The peer shares their UAK over E2EE (inbound access_key control from the
      // peer device). The fake crypto echoes ciphertext→plaintext on decrypt.
      final peerUak = List<int>.generate(32, (i) => 200 - i);
      ws.push(_envelope(
        envelopeId: 'uak-ctrl-1',
        conversationId: convoId,
        senderDeviceId: 'pd',
        envelopeType: EnvelopeType.textLegacy,
        ciphertext: utf8.encode(MessageControl.accessKey(peerUak).encode()),
      ));
      await pumpEventQueue();

      List<int>? presentedKey;
      when(() => api.submitSealedUnauthenticated(any(), any()))
          .thenAnswer((inv) async {
        presentedKey = inv.positionalArguments[1] as List<int>;
        return SubmitMessageResult(
            envelopeId: 'u', serverTs: DateTime.utc(2026, 5, 9));
      });

      await notifier.sendMessage(
          conversationId: convoId, myDeviceId: _myDeviceId, text: 'unauth hi');

      verify(() => api.submitSealedUnauthenticated(any(), any())).called(1);
      expect(presentedKey, equals(peerUak),
          reason: 'presented the peer-shared UAK on the unauth path');
    });

    test('Phase 2: unauth failure falls back to the authenticated send',
        () async {
      await sessions.save(session);
      await notifier.connect();
      notifier.sealedSenderEnabled = true;
      notifier.unidentifiedAccessEnabled = true;

      final x = X25519();
      final kp = await x.newKeyPair();
      final pub = (await kp.extractPublicKey()).bytes;
      final convoId = await startConvoWithSealedPeer(peerPub: pub);

      final peerUak = List<int>.generate(32, (i) => i + 1);
      ws.push(_envelope(
        envelopeId: 'uak-ctrl-2',
        conversationId: convoId,
        senderDeviceId: 'pd',
        envelopeType: EnvelopeType.textLegacy,
        ciphertext: utf8.encode(MessageControl.accessKey(peerUak).encode()),
      ));
      await pumpEventQueue();

      // The unauth deposit is rejected (e.g. 403/429) → must fall back to authed.
      when(() => api.submitSealedUnauthenticated(any(), any()))
          .thenThrow(Exception('403 access denied'));
      var authedSent = false;
      when(() => api.submitMessage(any())).thenAnswer((_) async {
        authedSent = true;
        return SubmitMessageResult(
            envelopeId: 'e', serverTs: DateTime.utc(2026, 5, 9));
      });

      await notifier.sendMessage(
          conversationId: convoId, myDeviceId: _myDeviceId, text: 'fallback hi');

      verify(() => api.submitSealedUnauthenticated(any(), any())).called(1);
      expect(authedSent, isTrue,
          reason: 'unauth failure must not drop the message — authed fallback');
    });

    Future<String> sealedConvoWithPeerUak() async {
      await sessions.save(session);
      await notifier.connect();
      notifier.sealedSenderEnabled = true;
      notifier.unidentifiedAccessEnabled = true;
      when(() => api.submitMessage(any())).thenAnswer((_) async =>
          SubmitMessageResult(envelopeId: 'e', serverTs: DateTime.utc(2026)));
      final kp = await X25519().newKeyPair();
      final pub = (await kp.extractPublicKey()).bytes;
      final convoId = await startConvoWithSealedPeer(peerPub: pub);
      ws.push(_envelope(
        envelopeId: 'uak-ctrl-backoff',
        conversationId: convoId,
        senderDeviceId: 'pd',
        envelopeType: EnvelopeType.textLegacy,
        ciphertext: utf8.encode(
            MessageControl.accessKey(List<int>.filled(32, 5)).encode()),
      ));
      await pumpEventQueue();
      return convoId;
    }

    // On-device 2026-10-21: an unauth deposit that couldn't connect cost a call
    // ring 10s, and every later call signal would pay it again.
    test('Phase 2: an unreachable unauth path is skipped for the next sends',
        () async {
      final convoId = await sealedConvoWithPeerUak();
      when(() => api.submitSealedUnauthenticated(any(), any())).thenThrow(
          const ApiError(code: 'network', message: 'connect timeout'));

      await notifier.sendMessage(
          conversationId: convoId, myDeviceId: _myDeviceId, text: 'one');
      await notifier.sendMessage(
          conversationId: convoId, myDeviceId: _myDeviceId, text: 'two');

      verify(() => api.submitSealedUnauthenticated(any(), any())).called(1);
    });

    test('Phase 2: a refused unauth deposit (403) does not back off',
        () async {
      final convoId = await sealedConvoWithPeerUak();
      when(() => api.submitSealedUnauthenticated(any(), any())).thenThrow(
          const ApiError(code: 'forbidden', message: 'no', statusCode: 403));

      await notifier.sendMessage(
          conversationId: convoId, myDeviceId: _myDeviceId, text: 'one');
      await notifier.sendMessage(
          conversationId: convoId, myDeviceId: _myDeviceId, text: 'two');

      verify(() => api.submitSealedUnauthenticated(any(), any())).called(2);
    });

    test('encrypts plaintext and submits to server', () async {
      final convoId = await seedConvo();
      when(() => api.submitMessage(any())).thenAnswer((_) async =>
          SubmitMessageResult(envelopeId: 'env-42', serverTs: DateTime.utc(2026, 5, 8)));

      await notifier.sendMessage(
        conversationId: convoId,
        myDeviceId: _myDeviceId,
        text: 'hi there',
      );

      expect(crypto.encryptCalls, equals(1));
      final captured = verify(() => api.submitMessage(captureAny())).captured.single
          as SubmitMessagePayload;
      expect(captured.conversationId, equals(convoId));
      expect(captured.recipientAccountId, equals(_peerAccountId));
      // lookupKeyPackage returns KeyPackageExhaustedException by default in
      // setUp, so MlsMigrator falls back to the ratchet path → text_legacy.
      expect(captured.envelopeType, equals(EnvelopeType.textLegacy));
      expect(_stripCid(captured.ciphertext), equals('hi there'));
    });

    test('content sends carry the retention TTL as ttl_seconds', () async {
      // Rebuild with a ttlProvider — the shared notifier has none.
      notifier.dispose();
      notifier = buildNotifier(ttlProvider: () => const Duration(days: 7));
      final convoId = await seedConvo();
      when(() => api.submitMessage(any())).thenAnswer((_) async =>
          SubmitMessageResult(envelopeId: 'env-42', serverTs: DateTime.utc(2026, 5, 8)));

      await notifier.sendMessage(
        conversationId: convoId,
        myDeviceId: _myDeviceId,
        text: 'expiring text',
      );

      final captured = verify(() => api.submitMessage(captureAny()))
          .captured
          .single as SubmitMessagePayload;
      expect(captured.ttlSeconds, equals(7 * 24 * 3600));
    });

    test('sends without a ttlProvider omit ttl_seconds (server default)',
        () async {
      final convoId = await seedConvo();
      when(() => api.submitMessage(any())).thenAnswer((_) async =>
          SubmitMessageResult(envelopeId: 'env-42', serverTs: DateTime.utc(2026, 5, 8)));

      await notifier.sendMessage(
        conversationId: convoId,
        myDeviceId: _myDeviceId,
        text: 'default retention',
      );

      final captured = verify(() => api.submitMessage(captureAny()))
          .captured
          .single as SubmitMessagePayload;
      expect(captured.ttlSeconds, isNull);
    });

    test('a send goes over the WebSocket when connected (no HTTP POST)',
        () async {
      final convoId = await seedConvo(); // connects → ws.connected == true
      ws.wsAckResult =
          (envelopeId: 'env-ws', serverTs: DateTime.utc(2026, 5, 9, 10));

      await notifier.sendMessage(
        conversationId: convoId,
        myDeviceId: _myDeviceId,
        text: 'over the socket',
      );

      // Sent as a `send` frame on the live socket — NOT a fresh HTTP POST.
      expect(ws.sentFrames, hasLength(1));
      expect(ws.sentFrames.single['type'], equals('send'));
      expect(ws.sentFrames.single['client_ref'], isNotNull);
      expect(ws.sentFrames.single['conversation_id'], equals(convoId));
      verifyNever(() => api.submitMessage(any()));

      // The bubble reconciles to the WS-assigned envelope id.
      final msg = notifier
          .byId(convoId)!
          .messages
          .firstWhere((m) => m.body == 'over the socket');
      expect(msg.envelopeId, equals('env-ws'));
    });

    test('a send falls back to HTTP POST when the socket is down', () async {
      final convoId = await seedConvo();
      ws.connected = false; // socket dropped after connect → not sendable
      when(() => api.submitMessage(any())).thenAnswer((_) async =>
          SubmitMessageResult(
              envelopeId: 'env-http', serverTs: DateTime.utc(2026, 5, 9)));

      await notifier.sendMessage(
        conversationId: convoId,
        myDeviceId: _myDeviceId,
        text: 'over http',
      );

      expect(ws.sentFrames, isEmpty);
      verify(() => api.submitMessage(any())).called(1);
    });

    test('ack goes over the WebSocket when connected (no HTTP ack)', () async {
      await sessions.save(session);
      await notifier.connect(); // ws.connected == true
      ws.wsAckSucceeds = true;

      await notifier.ack(['env-a', 'env-b']);

      expect(ws.ackFrames, equals([
        ['env-a', 'env-b']
      ]));
      verifyNever(() => api.ackMessages(any()));
    });

    test('ack falls back to HTTP when the socket can not take it', () async {
      await sessions.save(session);
      await notifier.connect();
      ws.wsAckSucceeds = false; // WS frame not sent → HTTP
      when(() => api.ackMessages(any())).thenAnswer((_) async => 1);

      await notifier.ack(['env-c']);

      expect(ws.ackFrames, hasLength(1)); // WS was attempted first
      verify(() => api.ackMessages(['env-c'])).called(1);
    });

    test('reply prepends the reply header to the wire body + records it locally',
        () async {
      final convoId = await seedConvo();
      when(() => api.submitMessage(any())).thenAnswer((_) async =>
          SubmitMessageResult(envelopeId: 'env-99', serverTs: DateTime.utc(2026)));

      final original = ChatMessage(
        envelopeId: 'orig-1',
        conversationId: convoId,
        senderDeviceId: 'peer-dev',
        body: 'original text',
        serverTs: DateTime.utc(2026, 5, 7),
        mine: false,
      );

      await notifier.sendMessage(
        conversationId: convoId,
        myDeviceId: _myDeviceId,
        text: 'my reply',
        replyTo: original,
      );

      // Wire body = passthrough ciphertext: reply header + body.
      final captured = verify(() => api.submitMessage(captureAny()))
          .captured
          .single as SubmitMessagePayload;
      final split = ReplyRef.split(_stripCid(captured.ciphertext));
      expect(split, isNotNull);
      final (ref, body) = split!;
      expect(ref.envelopeId, 'orig-1');
      expect(ref.preview, 'original text');
      expect(body, 'my reply');

      // Optimistic message records the reply for rendering the quoted bar.
      final sent = notifier.byId(convoId)!.messages.last;
      expect(sent.replyToEnvelopeId, 'orig-1');
      expect(sent.replyToPreview, 'original text');
      expect(sent.body, 'my reply');
    });

    test('replaces outbox entry with server-acked envelope on success', () async {
      final convoId = await seedConvo();
      when(() => api.submitMessage(any())).thenAnswer((_) async =>
          SubmitMessageResult(envelopeId: 'env-42', serverTs: DateTime.utc(2026, 5, 8)));

      await notifier.sendMessage(
        conversationId: convoId,
        myDeviceId: _myDeviceId,
        text: 'hi',
      );

      final messages = notifier.byId(convoId)!.messages;
      expect(messages.length, equals(1));
      final ChatMessage acked = messages.single;
      expect(acked.envelopeId, equals('env-42'));
      expect(acked.outboxId, equals(''));
      expect(acked.body, equals('hi'));
      expect(acked.mine, isTrue);

      // DB shows only the acked entry — outbox row removed.
      final loaded = await db.loadConversations();
      final dbConvo = loaded.firstWhere((c) => c.id == convoId);
      expect(dbConvo.messages.length, equals(1));
      expect(dbConvo.messages.single.envelopeId, equals('env-42'));
    });

    test('marks message failed flag on submit error and persists it', () async {
      final convoId = await seedConvo();
      when(() => api.submitMessage(any())).thenThrow(Exception('network down'));

      await expectLater(
        notifier.sendMessage(
          conversationId: convoId,
          myDeviceId: _myDeviceId,
          text: 'hi',
        ),
        throwsException,
      );

      final messages = notifier.byId(convoId)!.messages;
      expect(messages.length, equals(1));
      expect(messages.single.body, equals('hi'),
          reason: 'body must stay intact — failure surfaces via the flag, not body mutation');
      expect(messages.single.failed, isTrue);

      // Failed flag persisted too.
      final loaded = await db.loadConversations();
      final dbConvo = loaded.firstWhere((c) => c.id == convoId);
      expect(dbConvo.messages.single.failed, isTrue);
      expect(dbConvo.messages.single.body, equals('hi'));
    });

    test('a failed text send is auto-resent on the next reconnect', () async {
      final convoId = await seedConvo();
      // First send dies at the network (e.g. Tor still bootstrapping) — the row
      // is marked failed, exactly as the previous test asserts.
      when(() => api.submitMessage(any()))
          .thenThrow(Exception('tor bootstrapping'));
      await expectLater(
        notifier.sendMessage(
          conversationId: convoId,
          myDeviceId: _myDeviceId,
          text: 'delayed hi',
        ),
        throwsException,
      );
      expect(notifier.byId(convoId)!.messages.single.failed, isTrue);

      // The socket comes back and the network now accepts sends.
      when(() => api.submitMessage(any())).thenAnswer((_) async =>
          SubmitMessageResult(
              envelopeId: 'env-healed', serverTs: DateTime.utc(2026, 5, 9)));
      clearInteractions(api);

      supervisor.emitReconnected();
      await pumpEventQueue();

      // The failed message was replayed WITHOUT any manual retry tap: the row
      // clears its failed flag and picks up the real server envelope id.
      final healed = notifier.byId(convoId)!.messages.single;
      expect(healed.failed, isFalse,
          reason: 'reconnect must auto-resend a failed text, not wait on a tap');
      expect(healed.envelopeId, equals('env-healed'));
      expect(healed.body, equals('delayed hi'));
    });

    // MlsMigrator integration: ratchet → MLS migration on first send.
    // Peer has a KeyPackage → migrator returns welcomeBytes + mls_application.
    // ConversationsNotifier must submit mls_welcome FIRST, then mls_application,
    // then flip the conversation's cryptoMode to MLS.
    test('firstSendOnRatchetConvoMigrates_SubmitsWelcomeAndApplication', () async {
      final convoId = await seedConvo();
      // Peer has a KeyPackage available.
      when(() => api.lookupKeyPackage(any())).thenAnswer(
        (_) async => FetchKeyPackageResult(
          keyPackage: List<int>.filled(64, 0xBB),
          replenishNeeded: false,
          remainingForUser: 9,
        ),
      );

      // Track submission order.
      final submittedTypes = <String>[];
      var callIndex = 0;
      when(() => api.submitMessage(any())).thenAnswer((inv) async {
        final payload = inv.positionalArguments.first as SubmitMessagePayload;
        submittedTypes.add(payload.envelopeType);
        callIndex++;
        return SubmitMessageResult(
          envelopeId: 'env-mls-$callIndex',
          serverTs: DateTime.utc(2026, 5, 15),
        );
      });

      await notifier.sendMessage(
        conversationId: convoId,
        myDeviceId: _myDeviceId,
        text: 'migrating',
      );

      // Welcome must be submitted before application.
      expect(submittedTypes, equals(['mls_welcome', 'mls_application']));

      // Conversation cryptoMode flipped to MLS in memory.
      expect(notifier.byId(convoId)!.cryptoMode, equals(CryptoMode.mls));

      // CryptoMode persisted to DB.
      final loaded = await db.loadConversations();
      final dbConvo = loaded.firstWhere((c) => c.id == convoId);
      expect(dbConvo.cryptoMode, equals(CryptoMode.mls));

      // Legacy ratchet state cleared from DB.
      final ratchetState = await db.loadConversationCryptoState(convoId);
      expect(ratchetState, isNull);
    });

    // MlsMigrator integration: convo already on MLS → no Welcome, single
    // mls_application envelope, cryptoMode stays MLS.
    test('mlsConvo_SkipsWelcome_SubmitsSingleMlsApplication', () async {
      final convoId = await seedConvo();
      // Manually flip the conversation to MLS mode.
      final mlsConvo = notifier.byId(convoId)!.copyWith(cryptoMode: CryptoMode.mls);
      notifier.seed(mlsConvo);

      final submittedTypes = <String>[];
      when(() => api.submitMessage(any())).thenAnswer((inv) async {
        final payload = inv.positionalArguments.first as SubmitMessagePayload;
        submittedTypes.add(payload.envelopeType);
        return SubmitMessageResult(
          envelopeId: 'env-mls-only',
          serverTs: DateTime.utc(2026, 5, 15),
        );
      });

      await notifier.sendMessage(
        conversationId: convoId,
        myDeviceId: _myDeviceId,
        text: 'already mls',
      );

      // Only one submit — no welcome.
      expect(submittedTypes, equals(['mls_application']));
      expect(notifier.byId(convoId)!.cryptoMode, equals(CryptoMode.mls));
    });

    // MlsMigrator integration: Welcome submit fails → application must NOT be
    // submitted and cryptoMode must stay ratchet.
    test('welcomeSubmitFails_DoesNotSubmitApplication_CryptoModeStaysRatchet', () async {
      final convoId = await seedConvo();
      when(() => api.lookupKeyPackage(any())).thenAnswer(
        (_) async => FetchKeyPackageResult(
          keyPackage: List<int>.filled(64, 0xCC),
          replenishNeeded: false,
          remainingForUser: 5,
        ),
      );

      final submittedTypes = <String>[];
      when(() => api.submitMessage(any())).thenAnswer((inv) async {
        final payload = inv.positionalArguments.first as SubmitMessagePayload;
        submittedTypes.add(payload.envelopeType);
        if (payload.envelopeType == 'mls_welcome') {
          throw Exception('welcome submit failed');
        }
        return SubmitMessageResult(
          envelopeId: 'env-should-not-reach',
          serverTs: DateTime.utc(2026, 5, 15),
        );
      });

      await expectLater(
        notifier.sendMessage(
          conversationId: convoId,
          myDeviceId: _myDeviceId,
          text: 'should fail',
        ),
        throwsException,
      );

      // Application envelope must NOT have been submitted.
      expect(submittedTypes, equals(['mls_welcome']));

      // CryptoMode stays ratchet.
      expect(notifier.byId(convoId)!.cryptoMode, equals(CryptoMode.ratchet));
    });

    // MlsMigrator integration: peer's KeyPackage pool is exhausted → migrator
    // falls back to ratchet → text_legacy envelope, cryptoMode stays ratchet.
    test('peerKpExhausted_StaysOnRatchet_SubmitsTextLegacy', () async {
      final convoId = await seedConvo();
      when(() => api.lookupKeyPackage(any()))
          .thenThrow(const KeyPackageExhaustedException('pool empty'));

      final submittedTypes = <String>[];
      when(() => api.submitMessage(any())).thenAnswer((inv) async {
        final payload = inv.positionalArguments.first as SubmitMessagePayload;
        submittedTypes.add(payload.envelopeType);
        return SubmitMessageResult(
          envelopeId: 'env-legacy',
          serverTs: DateTime.utc(2026, 5, 15),
        );
      });

      await notifier.sendMessage(
        conversationId: convoId,
        myDeviceId: _myDeviceId,
        text: 'legacy fallback',
      );

      // Single submit with text_legacy envelope type.
      expect(submittedTypes, equals(['text_legacy']));

      // CryptoMode stays ratchet — no migration occurred.
      expect(notifier.byId(convoId)!.cryptoMode, equals(CryptoMode.ratchet));
    });
  });

  // On-device 2026-10-21: a call to a peer who had reinstalled rang a DEAD
  // device — signals went to the row's stale peerDeviceId while messages
  // (fanned out to the directory) still arrived — and hung on "Calling…".
  group('control addressing on an MLS 1:1', () {
    Future<String> seedMlsWithStaleDevice() async {
      await sessions.save(session);
      await notifier.connect();
      const convoId = 'mls-addressing';
      notifier.seed(Conversation(
        id: convoId,
        peerUsername: _peerUsername,
        peerAccountId: _peerAccountId,
        peerDeviceId: 'old-dev',
        peerIdentityPubKey: const [9, 8, 7],
        peerX25519PubKey: const [1, 2, 3],
        messages: const [],
        unreadCount: 0,
        cryptoMode: CryptoMode.mls,
      ));
      when(() => api.lookupAccount(_peerUsername)).thenAnswer((_) async =>
          Account(
            accountId: _peerAccountId,
            username: _peerUsername,
            identityPubKey: const [9, 8, 7],
            x25519PubKey: const [1, 2, 3],
            deviceId: 'new-dev',
            devices: const [
              AccountDevice(deviceId: 'new-dev', x25519PubKey: [1, 2, 3]),
              AccountDevice(deviceId: 'tablet-dev', x25519PubKey: [4, 5, 6]),
            ],
          ));
      return convoId;
    }

    List<String> captureRecipientDevices({Set<String> failFor = const {}}) {
      final devices = <String>[];
      when(() => api.submitMessage(any())).thenAnswer((inv) async {
        final p = inv.positionalArguments.first as SubmitMessagePayload;
        devices.add(p.recipientDeviceId);
        if (failFor.contains(p.recipientDeviceId)) {
          throw const ApiError(
              code: 'account_not_found', message: 'gone', statusCode: 404);
        }
        return SubmitMessageResult(
            envelopeId: 'srv', serverTs: DateTime.utc(2026));
      });
      return devices;
    }

    test('an all-devices control reaches every current peer device', () async {
      final convoId = await seedMlsWithStaleDevice();
      final devices = captureRecipientDevices();

      await notifier.sendControl(convoId, 'ring', allPeerDevices: true);

      expect(devices, unorderedEquals(['new-dev', 'tablet-dev']));
    });

    test('a directed control reaches only the named device', () async {
      final convoId = await seedMlsWithStaleDevice();
      final devices = captureRecipientDevices();

      await notifier.sendControl(convoId, 'answer', toDeviceId: 'tablet-dev');

      expect(devices, ['tablet-dev']);
    });

    test('one dead device does not fail an all-devices control', () async {
      final convoId = await seedMlsWithStaleDevice();
      final devices = captureRecipientDevices(failFor: {'new-dev'});

      await notifier.sendControl(convoId, 'ring', allPeerDevices: true);

      expect(devices, contains('tablet-dev'));
    });

    test('an all-devices control fails when no device is reachable', () async {
      final convoId = await seedMlsWithStaleDevice();
      captureRecipientDevices(failFor: {'new-dev', 'tablet-dev'});

      await expectLater(
        notifier.sendControl(convoId, 'ring', allPeerDevices: true),
        throwsA(isA<ApiError>()),
      );
    });

    test('an unaddressed control still goes to the row device', () async {
      final convoId = await seedMlsWithStaleDevice();
      final devices = captureRecipientDevices();

      await notifier.sendControl(convoId, 'receipt');

      expect(devices, ['old-dev']);
    });
  });

  // The screenshot bug: an MLS 1:1 whose LOCAL group is gone (CoreCrypto store
  // rebuilt by an app update / restore) threw "Couldn't find conversation" on
  // every send, and the only way out was a new account.
  group('send to an MLS 1:1 whose local group is gone', () {
    Future<String> seedLostGroupConvo({String peerAccountId = _peerAccountId}) async {
      await sessions.save(session); // accountId 'me-acc'
      await notifier.connect();
      when(() => api.ackMessages(any())).thenAnswer((_) async => 1);
      when(() => api.lookupKeyPackage(any())).thenAnswer(
        (_) async => FetchKeyPackageResult(
          keyPackage: List<int>.filled(64, 0xBB),
          replenishNeeded: false,
          remainingForUser: 9,
        ),
      );
      const convoId = 'mls-lost-group';
      notifier.seed(Conversation(
        id: convoId,
        peerUsername: _peerUsername,
        peerAccountId: peerAccountId,
        peerDeviceId: 'peer-dev',
        peerIdentityPubKey: const [9, 8, 7],
        peerX25519PubKey: const [1, 2, 3],
        messages: const [],
        unreadCount: 0,
        cryptoMode: CryptoMode.mls,
      ));
      crypto.missingGroups.add(convoId);
      return convoId;
    }

    List<String> captureSubmittedTypes() {
      final types = <String>[];
      when(() => api.submitMessage(any())).thenAnswer((inv) async {
        types.add(
            (inv.positionalArguments.first as SubmitMessagePayload).envelopeType);
        return SubmitMessageResult(
            envelopeId: 'srv-${types.length}', serverTs: DateTime.utc(2026));
      });
      return types;
    }

    test('the message is delivered instead of failing', () async {
      final convoId = await seedLostGroupConvo();
      captureSubmittedTypes();

      await notifier.sendMessage(
          conversationId: convoId, myDeviceId: _myDeviceId, text: 'SO BIG');
      await pumpEventQueue();

      final msg = notifier.byId(convoId)!.messages.last;
      expect(msg.failed, isFalse);
      expect(msg.body, 'SO BIG');
    });

    test('a fresh Welcome is shipped to the peer with the message', () async {
      final convoId = await seedLostGroupConvo();
      final types = captureSubmittedTypes();

      await notifier.sendMessage(
          conversationId: convoId, myDeviceId: _myDeviceId, text: 'hi');
      await pumpEventQueue();

      expect(types.where((t) => t == EnvelopeType.mlsWelcome), hasLength(1));
    });

    test('the conversation is MLS again after the rebuild', () async {
      final convoId = await seedLostGroupConvo();
      captureSubmittedTypes();

      await notifier.sendMessage(
          conversationId: convoId, myDeviceId: _myDeviceId, text: 'hi');
      await pumpEventQueue();

      expect(notifier.byId(convoId)!.cryptoMode, CryptoMode.mls);
    });

    test('the migration follower (larger account id) also rebuilds', () async {
      // 'aaa-acc' < 'me-acc' → WE are the follower, which the role rule
      // normally keeps on ratchet. A stranded follower must still rebuild.
      final convoId = await seedLostGroupConvo(peerAccountId: 'aaa-acc');
      final types = captureSubmittedTypes();

      await notifier.sendMessage(
          conversationId: convoId, myDeviceId: _myDeviceId, text: 'hi');
      await pumpEventQueue();

      expect(types, contains(EnvelopeType.mlsWelcome));
      expect(notifier.byId(convoId)!.messages.last.failed, isFalse);
    });

    test('a queued re-establishment does not wipe the rebuilt group', () async {
      // A send that queued on the conversation lock BEFORE a re-establishment
      // rebuilds the group first. The re-establishment queued behind it must
      // stand down, or it wipes the fresh group and ships a second Welcome.
      final convoId = await seedLostGroupConvo();
      crypto.missingGroups.remove(convoId); // group still present for send A
      final types = <String>[];
      final holdFirstSubmit = Completer<void>();
      when(() => api.submitMessage(any())).thenAnswer((inv) async {
        types.add(
            (inv.positionalArguments.first as SubmitMessagePayload).envelopeType);
        if (types.length == 1) await holdFirstSubmit.future;
        return SubmitMessageResult(
            envelopeId: 'srv-${types.length}', serverTs: DateTime.utc(2026));
      });

      // A holds the lock (parked in submit); B queues behind it.
      final sendA = notifier.sendMessage(
          conversationId: convoId, myDeviceId: _myDeviceId, text: 'a');
      await pumpEventQueue();
      final sendB = notifier.sendMessage(
          conversationId: convoId, myDeviceId: _myDeviceId, text: 'b');
      await pumpEventQueue();
      // Now the store loses the group, and reconcile queues a re-establish
      // behind B.
      crypto.missingGroups.add(convoId);
      crypto.currentEpochError = const MlsUnknownGroupException('no group');
      await notifier.reconcileMlsConversations();
      await pumpEventQueue();
      crypto.currentEpochError = null;

      holdFirstSubmit.complete();
      await sendA;
      await sendB;
      await pumpEventQueue(times: 100);

      expect(types.where((t) => t == EnvelopeType.mlsWelcome), hasLength(1));
    });

    test('a group with no local group still fails (only a member can re-add)',
        () async {
      await sessions.save(session);
      await notifier.connect();
      const groupId = 'group:lost';
      notifier.seed(Conversation(
        id: groupId,
        peerUsername: '',
        peerAccountId: '',
        peerDeviceId: '',
        peerIdentityPubKey: const [],
        peerX25519PubKey: const [],
        messages: const [],
        unreadCount: 0,
        kind: ConversationKind.group,
        groupName: 'Lost',
        members: const [
          GroupMember(
            accountId: 'other-acc',
            username: 'o',
            deviceId: 'other-dev',
            identityPubKey: [1],
            x25519PubKey: [2],
            isAdmin: false,
            isSelf: false,
          ),
        ],
        cryptoMode: CryptoMode.mls,
      ));
      crypto.missingGroups.add(groupId);
      captureSubmittedTypes();

      await expectLater(
        notifier.sendMessage(
            conversationId: groupId, myDeviceId: _myDeviceId, text: 'hi'),
        throwsA(isA<MlsUnknownGroupException>()),
      );
      expect(notifier.byId(groupId)!.messages.last.failed, isTrue);
    });
  });

  group('incoming envelopes', () {
    test('mlsHandshake for unknown convo drops silently without creating a conversation', () async {
      await sessions.save(session);
      await notifier.connect();

      ws.push(_envelope(envelopeType: EnvelopeType.mlsHandshake));
      await pumpEventQueue();

      expect(notifier.conversations, isEmpty);
      expect(crypto.decryptCalls, equals(0));
    });

    test('appends decrypted message, bumps unread, persists (text_legacy on ratchet convo)', () async {
      await sessions.save(session);
      await notifier.connect();
      when(() => api.lookupAccount(_peerUsername))
          .thenAnswer((_) async => _peerAccount());
      final convoId = await notifier.startConversation(
        myDeviceId: _myDeviceId,
        username: _peerUsername,
      );

      when(() => api.ackMessages(any())).thenAnswer((_) async => 1);

      ws.push(_envelope(
        conversationId: convoId,
        senderDeviceId: 'peer-dev',
        envelopeType: EnvelopeType.textLegacy,
      ));
      await pumpEventQueue();

      final convo = notifier.byId(convoId)!;
      expect(convo.messages.length, equals(1));
      expect(convo.messages.single.body, equals('hi'));
      expect(convo.messages.single.mine, isFalse);
      expect(convo.unreadCount, equals(1));
      verify(() => api.ackMessages(['env-1'])).called(1);

      // Persisted.
      final loaded = await db.loadConversations();
      final dbConvo = loaded.firstWhere((c) => c.id == convoId);
      expect(dbConvo.messages.length, equals(1));
      expect(dbConvo.unreadCount, equals(1));
    });

    // On-device 2026-10-21: the FIRST message of a brand-new contact request
    // rendered "Secure session re-established" — there was never a session to
    // re-establish. A mismatch before anything was ever received is a
    // first-contact seeding difference, not a peer reset, so no notice.
    test('a first-contact recovery decrypts without a re-established notice',
        () async {
      crypto = _CounterCrypto();
      notifier = buildNotifier();
      await sessions.save(session);
      await notifier.connect();
      when(() => api.lookupAccount(_peerUsername))
          .thenAnswer((_) async => _peerAccount());
      when(() => api.ackMessages(any())).thenAnswer((_) async => 1);
      final convoId = await notifier.startConversation(
        myDeviceId: _myDeviceId,
        username: _peerUsername,
      );
      // Nothing received yet, but the stored chain was seeded differently.
      await db.saveConversationCryptoState(ConversationCryptoState(
        conversationId: convoId,
        sendCounter: 0,
        sendChainKey: List<int>.filled(32, 0),
        recvCounter: 0,
        recvChainKey: List<int>.filled(32, 7),
      ));

      ws.push(_envelope(
        envelopeId: 'first',
        conversationId: convoId,
        envelopeType: EnvelopeType.textLegacy,
        ciphertext: [0, ...utf8.encode('hello')],
      ));
      await pumpEventQueue();

      final convo = notifier.byId(convoId)!;
      expect(convo.messages.any((m) => m.body == 'hello'), isTrue);
      expect(
        convo.messages
            .where((m) => m.kind == MessageKind.system)
            .map((m) => SystemEvent.tryDecode(m.body))
            .where((e) => e?.kind == SystemEventKind.sessionReestablished),
        isEmpty,
      );
    });

    test('recovers when a wiped peer resets its ratchet (re-key reconciliation)',
        () async {
      // Counter-aware crypto: a stale counter throws, mirroring the real
      // chain rejecting a peer that restarted at 0.
      crypto = _CounterCrypto();
      notifier = buildNotifier();
      await sessions.save(session);
      await notifier.connect();
      when(() => api.lookupAccount(_peerUsername))
          .thenAnswer((_) async => _peerAccount());
      when(() => api.ackMessages(any())).thenAnswer((_) async => 1);
      final convoId = await notifier.startConversation(
        myDeviceId: _myDeviceId,
        username: _peerUsername,
      );

      // Pre-seed an already-advanced SEND chain (we've sent 7) so we can prove
      // recovery preserves it — resetting it would regress below what the peer
      // has accepted and cause a mutual-reset storm.
      await db.saveConversationCryptoState(ConversationCryptoState(
        conversationId: convoId,
        sendCounter: 7,
        sendChainKey: List<int>.filled(32, 9),
        recvCounter: 0,
        recvChainKey: List<int>.filled(32, 0),
      ));

      // Peer sends three in-order messages: recv counter advances 0 → 3.
      for (var i = 0; i < 3; i++) {
        ws.push(_envelope(
          envelopeId: 'env-$i',
          conversationId: convoId,
          envelopeType: EnvelopeType.textLegacy,
          ciphertext: [i, ...utf8.encode('m$i')],
        ));
        await pumpEventQueue();
      }
      expect(notifier.byId(convoId)!.messages.length, equals(3));

      // Peer wipes + restores from the same phrase: fresh ratchet, counter 0.
      // Against our advanced chain this fails — recovery re-inits and decrypts.
      ws.push(_envelope(
        envelopeId: 'env-after-wipe',
        conversationId: convoId,
        senderDeviceId: 'peer-dev',
        envelopeType: EnvelopeType.textLegacy,
        ciphertext: [0, ...utf8.encode('after wipe')],
      ));
      await pumpEventQueue();

      final convo = notifier.byId(convoId)!;
      // The post-wipe message decrypted...
      expect(
        convo.messages.any((m) => m.body == 'after wipe'),
        isTrue,
        reason: 'recovered message should be appended',
      );
      // ...a "session re-established" system line was injected once...
      final sysEvents = convo.messages
          .where((m) => m.kind == MessageKind.system)
          .map((m) => SystemEvent.tryDecode(m.body))
          .where((e) => e?.kind == SystemEventKind.sessionReestablished)
          .toList();
      expect(sysEvents.length, equals(1));
      // ...the stale skip cache was cleared, and the flag is down.
      expect(crypto.clearedConversations, contains(convoId));
      expect(convo.needsReestablishment, isFalse);
      verify(() => api.ackMessages(['env-after-wipe'])).called(1);

      // Recovery is recv-only: the SEND chain is preserved (key untouched,
      // counter never reset below the seeded 7 — delivery receipts may advance
      // it further) while the recv chain re-seeded to 1.
      final state = await db.loadConversationCryptoState(convoId);
      expect(state!.sendChainKey, equals(List<int>.filled(32, 9)));
      expect(state.sendCounter, greaterThanOrEqualTo(7));
      expect(state.recvCounter, equals(1));
    });

    test('drops an undecryptable envelope without touching the ratchet (no false recovery)',
        () async {
      crypto = _CounterCrypto();
      notifier = buildNotifier();
      await sessions.save(session);
      await notifier.connect();
      when(() => api.lookupAccount(_peerUsername))
          .thenAnswer((_) async => _peerAccount());
      when(() => api.ackMessages(any())).thenAnswer((_) async => 1);
      final convoId = await notifier.startConversation(
        myDeviceId: _myDeviceId,
        username: _peerUsername,
      );

      // First message lands (counter 0), advancing recv to 1.
      ws.push(_envelope(
        envelopeId: 'env-0',
        conversationId: convoId,
        envelopeType: EnvelopeType.textLegacy,
        ciphertext: [0, ...utf8.encode('hi')],
      ));
      await pumpEventQueue();

      // Garbage that decrypts under NEITHER the live chain (counter 5 ≠ 1)
      // NOR a fresh re-init (counter 5 ≠ 0) → dropped, no system line, no
      // recovered message.
      ws.push(_envelope(
        envelopeId: 'env-garbage',
        conversationId: convoId,
        envelopeType: EnvelopeType.textLegacy,
        ciphertext: [5, ...utf8.encode('nope')],
      ));
      await pumpEventQueue();

      final convo = notifier.byId(convoId)!;
      expect(convo.messages.length, equals(1));
      expect(
        convo.messages.any((m) => m.kind == MessageKind.system),
        isFalse,
      );
    });

    test('deleteMessageLocal removes the message in-memory and from the DB', () async {
      await sessions.save(session);
      await notifier.connect();
      when(() => api.lookupAccount(_peerUsername))
          .thenAnswer((_) async => _peerAccount());
      final convoId = await notifier.startConversation(
        myDeviceId: _myDeviceId,
        username: _peerUsername,
      );
      when(() => api.ackMessages(any())).thenAnswer((_) async => 1);
      ws.push(_envelope(
        conversationId: convoId,
        envelopeType: EnvelopeType.textLegacy,
      ));
      await pumpEventQueue();

      final msg = notifier.byId(convoId)!.messages.single;
      await notifier.deleteMessageLocal(convoId, msg);

      expect(notifier.byId(convoId)!.messages, isEmpty);
      final loaded = await db.loadConversations();
      expect(loaded.firstWhere((c) => c.id == convoId).messages, isEmpty);
    });

    test('inbound unsend control deletes the referenced message and leaves no bubble', () async {
      await sessions.save(session);
      await notifier.connect();
      when(() => api.lookupAccount(_peerUsername))
          .thenAnswer((_) async => _peerAccount());
      final convoId = await notifier.startConversation(
        myDeviceId: _myDeviceId,
        username: _peerUsername,
      );
      when(() => api.ackMessages(any())).thenAnswer((_) async => 1);

      // Peer sends a normal message (env-1, "hi").
      ws.push(_envelope(
        conversationId: convoId,
        envelopeType: EnvelopeType.textLegacy,
      ));
      await pumpEventQueue();
      expect(notifier.byId(convoId)!.messages.single.envelopeId, 'env-1');

      // Peer then unsends it: a control envelope (env-2) targeting env-1.
      ws.push(_envelope(
        envelopeId: 'env-2',
        conversationId: convoId,
        envelopeType: EnvelopeType.textLegacy,
        ciphertext: utf8.encode(const MessageControl.unsend('env-1').encode()),
      ));
      await pumpEventQueue();

      // The referenced message is gone and the control itself left no bubble.
      expect(notifier.byId(convoId)!.messages, isEmpty);
      verify(() => api.ackMessages(['env-2'])).called(1);
    });

    test('delivery/read receipts advance outgoing message status (monotonic)',
        () async {
      await sessions.save(session);
      await notifier.connect();
      when(() => api.lookupAccount(_peerUsername))
          .thenAnswer((_) async => _peerAccount());
      final convoId = await notifier.startConversation(
        myDeviceId: _myDeviceId,
        username: _peerUsername,
      );

      // Send a message → outgoing message, server-assigned id 'srv-env',
      // starts in the `sent` state.
      await notifier.sendMessage(
        conversationId: convoId,
        myDeviceId: _myDeviceId,
        text: 'hi there',
      );
      await pumpEventQueue();
      final sent = notifier.byId(convoId)!.messages.firstWhere((m) => m.mine);
      expect(sent.deliveryStatus, MessageDeliveryStatus.sent);
      final eid = sent.envelopeId;

      ChatMessage mineById() =>
          notifier.byId(convoId)!.messages.firstWhere((m) => m.envelopeId == eid);

      // Peer's "delivered" receipt → delivered.
      ws.push(_envelope(
        envelopeId: 'rcpt-1',
        conversationId: convoId,
        envelopeType: EnvelopeType.textLegacy,
        ciphertext: utf8.encode(
            MessageControl.receipt(ReceiptKind.delivered, [eid]).encode()),
      ));
      await pumpEventQueue();
      expect(mineById().deliveryStatus, MessageDeliveryStatus.delivered);

      // Then "read" → read.
      ws.push(_envelope(
        envelopeId: 'rcpt-2',
        conversationId: convoId,
        envelopeType: EnvelopeType.textLegacy,
        ciphertext: utf8
            .encode(MessageControl.receipt(ReceiptKind.read, [eid]).encode()),
      ));
      await pumpEventQueue();
      expect(mineById().deliveryStatus, MessageDeliveryStatus.read);

      // A late "delivered" must NOT downgrade a read message (monotonic).
      ws.push(_envelope(
        envelopeId: 'rcpt-3',
        conversationId: convoId,
        envelopeType: EnvelopeType.textLegacy,
        ciphertext: utf8.encode(
            MessageControl.receipt(ReceiptKind.delivered, [eid]).encode()),
      ));
      await pumpEventQueue();
      expect(mineById().deliveryStatus, MessageDeliveryStatus.read);

      // Receipt controls leave no visible bubble.
      expect(
        notifier.byId(convoId)!.messages.where((m) => !m.mine),
        isEmpty,
      );
    });

    test(
        'a server delivery_status frame advances an outgoing message to '
        'delivered (transport-level receipt)', () async {
      await sessions.save(session);
      await notifier.connect();
      when(() => api.lookupAccount(_peerUsername))
          .thenAnswer((_) async => _peerAccount());
      final convoId = await notifier.startConversation(
        myDeviceId: _myDeviceId,
        username: _peerUsername,
      );

      await notifier.sendMessage(
        conversationId: convoId,
        myDeviceId: _myDeviceId,
        text: 'hi there',
      );
      await pumpEventQueue();
      final sent = notifier.byId(convoId)!.messages.firstWhere((m) => m.mine);
      expect(sent.deliveryStatus, MessageDeliveryStatus.sent);
      final eid = sent.envelopeId;

      ChatMessage mineById() => notifier
          .byId(convoId)!
          .messages
          .firstWhere((m) => m.envelopeId == eid);

      // The server relays a transport "delivered": an ephemeral, server-
      // originated frame whose ciphertext is the delivered envelope id (NOT a
      // MessageControl). It funnels through the same monotonic receipt path.
      ws.push(_envelope(
        envelopeId: '', // ephemeral — never stored/acked
        conversationId: convoId,
        envelopeType: EnvelopeType.deliveryStatus,
        ciphertext: utf8.encode(eid),
      ));
      await pumpEventQueue();
      expect(mineById().deliveryStatus, MessageDeliveryStatus.delivered);

      // Leaves no bubble and never enters the peer-message list.
      expect(
        notifier.byId(convoId)!.messages.where((m) => !m.mine),
        isEmpty,
      );
    });

    test('a late delivery_status frame never downgrades a read message',
        () async {
      await sessions.save(session);
      await notifier.connect();
      when(() => api.lookupAccount(_peerUsername))
          .thenAnswer((_) async => _peerAccount());
      final convoId = await notifier.startConversation(
        myDeviceId: _myDeviceId,
        username: _peerUsername,
      );
      await notifier.sendMessage(
        conversationId: convoId,
        myDeviceId: _myDeviceId,
        text: 'hi there',
      );
      await pumpEventQueue();
      final eid =
          notifier.byId(convoId)!.messages.firstWhere((m) => m.mine).envelopeId;
      ChatMessage mineById() => notifier
          .byId(convoId)!
          .messages
          .firstWhere((m) => m.envelopeId == eid);

      // Peer's end-to-end "read" lands first (the durable backstop receipt).
      ws.push(_envelope(
        envelopeId: 'rcpt-read',
        conversationId: convoId,
        envelopeType: EnvelopeType.textLegacy,
        ciphertext: utf8
            .encode(MessageControl.receipt(ReceiptKind.read, [eid]).encode()),
      ));
      await pumpEventQueue();
      expect(mineById().deliveryStatus, MessageDeliveryStatus.read);

      // A late transport delivered must NOT pull a read message back.
      ws.push(_envelope(
        envelopeId: '',
        conversationId: convoId,
        envelopeType: EnvelopeType.deliveryStatus,
        ciphertext: utf8.encode(eid),
      ));
      await pumpEventQueue();
      expect(mineById().deliveryStatus, MessageDeliveryStatus.read);
    });

    test(
        'a sealed, signed delivered_receipt (bg isolate, closed-app) advances '
        'to delivered — and a forged one is ignored', () async {
      // The peer's account identity key — what they sign the receipt with and
      // what the conversation stores to verify it.
      final signerKp = await Ed25519().newKeyPair();
      final signerPub = (await signerKp.extractPublicKey()).bytes;
      await sessions.save(session);
      await notifier.connect();
      when(() => api.lookupAccount(_peerUsername)).thenAnswer((_) async =>
          Account(
            accountId: _peerAccountId,
            username: _peerUsername,
            identityPubKey: signerPub,
            x25519PubKey: const [1, 2, 3],
            deviceId: 'peer-dev',
          ));
      final convoId = await notifier.startConversation(
          myDeviceId: _myDeviceId, username: _peerUsername);
      await notifier.sendMessage(
          conversationId: convoId, myDeviceId: _myDeviceId, text: 'hi there');
      await pumpEventQueue();
      final eid =
          notifier.byId(convoId)!.messages.firstWhere((m) => m.mine).envelopeId;
      ChatMessage mineById() => notifier
          .byId(convoId)!
          .messages
          .firstWhere((m) => m.envelopeId == eid);
      expect(mineById().deliveryStatus, MessageDeliveryStatus.sent);

      // A receipt signed by the WRONG key must NOT advance status (unforgeable).
      final imposterKp = await Ed25519().newKeyPair();
      final forgedSig = await Ed25519().sign(
          DeliveredReceipt.signingBytes(convoId, eid),
          keyPair: imposterKp);
      ws.push(_envelope(
        envelopeId: 'rcpt-forged',
        conversationId: convoId,
        envelopeType: EnvelopeType.deliveredReceipt,
        ciphertext: DeliveredReceipt(
                deliveredEnvelopeId: eid,
                conversationId: convoId,
                signature: forgedSig.bytes)
            .encode(),
      ));
      await pumpEventQueue();
      expect(mineById().deliveryStatus, MessageDeliveryStatus.sent,
          reason: 'a forged (wrong-key) receipt must be dropped');

      // The genuine receipt, signed by the conversation peer, advances it.
      final sig = await Ed25519()
          .sign(DeliveredReceipt.signingBytes(convoId, eid), keyPair: signerKp);
      ws.push(_envelope(
        envelopeId: 'rcpt-sealed',
        conversationId: convoId,
        envelopeType: EnvelopeType.deliveredReceipt,
        ciphertext: DeliveredReceipt(
                deliveredEnvelopeId: eid,
                conversationId: convoId,
                signature: sig.bytes)
            .encode(),
      ));
      await pumpEventQueue();
      expect(mineById().deliveryStatus, MessageDeliveryStatus.delivered);
      // Never rendered as a chat bubble.
      expect(notifier.byId(convoId)!.messages.where((m) => !m.mine), isEmpty);
    });

    test('sendTyping emits an ephemeral frame addressed to the 1:1 peer', () async {
      await sessions.save(session);
      await notifier.connect();
      when(() => api.lookupAccount(_peerUsername))
          .thenAnswer((_) async => _peerAccount());
      final convoId = await notifier.startConversation(
        myDeviceId: _myDeviceId,
        username: _peerUsername,
      );
      final peerDev = notifier.byId(convoId)!.peerDeviceId;

      notifier.sendTyping(convoId, true);

      expect(ws.ephemeralFrames, isNotEmpty);
      final f = ws.ephemeralFrames.last;
      expect(f['type'], 'typing');
      expect(f['conversation_id'], convoId);
      expect(f['recipient_device_id'], peerDev);
      expect(f['is_typing'], true);
    });

    test('inbound typing signal flips isPeerTyping; the stop signal clears it',
        () async {
      await sessions.save(session);
      await notifier.connect();
      when(() => api.lookupAccount(_peerUsername))
          .thenAnswer((_) async => _peerAccount());
      final convoId = await notifier.startConversation(
        myDeviceId: _myDeviceId,
        username: _peerUsername,
      );

      expect(notifier.isPeerTyping(convoId), isFalse);

      ws.push(_envelope(
        conversationId: convoId,
        envelopeType: EnvelopeType.typing,
        ciphertext: const [1],
      ));
      await pumpEventQueue();
      expect(notifier.isPeerTyping(convoId), isTrue);

      ws.push(_envelope(
        envelopeId: 'env-stop',
        conversationId: convoId,
        envelopeType: EnvelopeType.typing,
        ciphertext: const [0],
      ));
      await pumpEventQueue();
      expect(notifier.isPeerTyping(convoId), isFalse);

      // A typing envelope is ephemeral: never rendered, never acked.
      expect(notifier.byId(convoId)!.messages, isEmpty);
      verifyNever(() => api.ackMessages(any()));
    });

    test('multi-device 1:1 send fans out a ciphertext to every peer device', () async {
      await sessions.save(session);
      await notifier.connect();
      // Peer has two devices (primary peer-dev + linked peer-dev-2).
      final peerAcc = Account(
        accountId: _peerAccountId,
        username: _peerUsername,
        identityPubKey: const [9, 8, 7],
        x25519PubKey: const [1, 2, 3],
        deviceId: 'peer-dev',
        devices: const [
          AccountDevice(deviceId: 'peer-dev', x25519PubKey: [1, 2, 3]),
          AccountDevice(deviceId: 'peer-dev-2', x25519PubKey: [4, 5, 6]),
        ],
      );
      when(() => api.lookupAccount(_peerUsername))
          .thenAnswer((_) async => peerAcc);
      // Only this device on my account → no self-sync target.
      when(() => api.listDevices()).thenAnswer((_) async => [
            const Device(
                deviceId: _myDeviceId, accountId: 'me-acc', devicePubKey: []),
          ]);
      final convoId = await notifier.startConversation(
        myDeviceId: _myDeviceId,
        username: _peerUsername,
      );

      await notifier.sendMessage(
        conversationId: convoId,
        myDeviceId: _myDeviceId,
        text: 'hello devices',
      );
      await pumpEventQueue();

      final sent = verify(() => api.submitMessage(captureAny()))
          .captured
          .cast<SubmitMessagePayload>()
          .where((p) => p.envelopeType == EnvelopeType.textLegacy)
          .toList();
      final deviceIds = sent.map((p) => p.recipientDeviceId).toSet();
      expect(deviceIds, containsAll(['peer-dev', 'peer-dev-2']));
    });

    test('multi-device 1:1 migrates to MLS, fanning Welcome+app to every peer device',
        () async {
      await sessions.save(session);
      await notifier.connect();
      final peerAcc = Account(
        accountId: _peerAccountId,
        username: _peerUsername,
        identityPubKey: const [9, 8, 7],
        x25519PubKey: const [1, 2, 3],
        deviceId: 'peer-dev',
        devices: const [
          AccountDevice(deviceId: 'peer-dev', x25519PubKey: [1, 2, 3]),
          AccountDevice(deviceId: 'peer-dev-2', x25519PubKey: [4, 5, 6]),
        ],
      );
      when(() => api.lookupAccount(_peerUsername))
          .thenAnswer((_) async => peerAcc);
      when(() => api.listDevices()).thenAnswer((_) async => [
            const Device(
                deviceId: _myDeviceId, accountId: 'me-acc', devicePubKey: []),
          ]);
      // Peer has published key packages for BOTH devices → migrate to MLS.
      when(() => api.lookupDeviceKeyPackages(_peerUsername))
          .thenAnswer((_) async => const [
                DeviceKeyPackageResult(deviceId: 'peer-dev', keyPackage: [1]),
                DeviceKeyPackageResult(deviceId: 'peer-dev-2', keyPackage: [2]),
              ]);
      // My own account ('me') has no other devices.
      when(() => api.lookupDeviceKeyPackages('me'))
          .thenAnswer((_) async => const []);

      final convoId = await notifier.startConversation(
        myDeviceId: _myDeviceId,
        username: _peerUsername,
      );
      await notifier.sendMessage(
        conversationId: convoId,
        myDeviceId: _myDeviceId,
        text: 'hello mls',
      );
      await pumpEventQueue();

      final sent = verify(() => api.submitMessage(captureAny()))
          .captured
          .cast<SubmitMessagePayload>();
      final welcomeDevs = sent
          .where((p) => p.envelopeType == EnvelopeType.mlsWelcome)
          .map((p) => p.recipientDeviceId)
          .toSet();
      final appDevs = sent
          .where((p) => p.envelopeType == EnvelopeType.mlsApplication)
          .map((p) => p.recipientDeviceId)
          .toSet();
      expect(welcomeDevs, containsAll(['peer-dev', 'peer-dev-2']),
          reason: 'Welcome must reach every peer device');
      expect(appDevs, containsAll(['peer-dev', 'peer-dev-2']),
          reason: 'the MLS ciphertext must reach every peer device');
      expect(sent.where((p) => p.envelopeType == EnvelopeType.textLegacy),
          isEmpty,
          reason: 'fully migrated — no ratchet fallback');
      expect(notifier.byId(convoId)!.cryptoMode, CryptoMode.mls);
    });

    Future<String> startFirstContactWithSibling(String siblingId) async {
      await sessions.save(session);
      await notifier.connect();
      final peerAcc = Account(
        accountId: _peerAccountId,
        username: _peerUsername,
        identityPubKey: const [9, 8, 7],
        x25519PubKey: const [1, 2, 3],
        deviceId: 'peer-dev',
        devices: const [
          AccountDevice(deviceId: 'peer-dev', x25519PubKey: [1, 2, 3]),
        ],
      );
      when(() => api.lookupAccount(_peerUsername))
          .thenAnswer((_) async => peerAcc);
      when(() => api.listDevices()).thenAnswer((_) async => [
            const Device(
                deviceId: _myDeviceId, accountId: 'me-acc', devicePubKey: []),
            Device(
                deviceId: siblingId,
                accountId: 'me-acc',
                devicePubKey: const [],
                x25519PubKey: const [7, 7, 7]),
          ]);
      when(() => api.lookupDeviceKeyPackages(_peerUsername))
          .thenAnswer((_) async => const [
                DeviceKeyPackageResult(deviceId: 'peer-dev', keyPackage: [1]),
              ]);
      when(() => api.lookupDeviceKeyPackages('me')).thenAnswer((_) async => [
            DeviceKeyPackageResult(deviceId: siblingId, keyPackage: const [3]),
          ]);
      final convoId = await notifier.startConversation(
        myDeviceId: _myDeviceId,
        username: _peerUsername,
      );
      await notifier.sendMessage(
        conversationId: convoId,
        myDeviceId: _myDeviceId,
        text: 'hello from a sibling',
      );
      await pumpEventQueue();
      return convoId;
    }

    group('when the directory cannot confirm a single device', () {
      late List<SubmitMessagePayload> sent;

      Future<String> startChat({String rowDevice = 'peer-dev'}) async {
        await sessions.save(session);
        await notifier.connect();
        sent = [];
        when(() => api.submitMessage(any())).thenAnswer((inv) async {
          sent.add(inv.positionalArguments.first as SubmitMessagePayload);
          return SubmitMessageResult(
              envelopeId: 'srv-\${sent.length}', serverTs: DateTime.utc(2026));
        });
        when(() => api.lookupKeyPackage(any())).thenAnswer(
          (_) async => FetchKeyPackageResult(
            keyPackage: List<int>.filled(64, 0xBB),
            replenishNeeded: false,
            remainingForUser: 9,
          ),
        );
        when(() => api.lookupAccount(_peerUsername)).thenAnswer((_) async => Account(
              accountId: _peerAccountId,
              username: _peerUsername,
              identityPubKey: const [9, 8, 7],
              x25519PubKey: const [1, 2, 3],
              deviceId: rowDevice,
              devices: const [
                AccountDevice(deviceId: 'peer-dev', x25519PubKey: [1, 2, 3]),
              ],
            ));
        return notifier.startConversation(
          myDeviceId: _myDeviceId,
          username: _peerUsername,
        );
      }

      Iterable<String> welcomed() => sent
          .where((p) => p.envelopeType == EnvelopeType.mlsWelcome)
          .map((p) => p.recipientDeviceId);

      test('a failed own-device lookup builds no one-device group', () async {
        final convoId = await startChat();
        when(() => api.listDevices()).thenThrow(Exception('offline'));

        await notifier.sendMessage(
            conversationId: convoId, myDeviceId: _myDeviceId, text: 'hi');
        await pumpEventQueue();

        expect(welcomed(), isEmpty);
      });

      test('the message still goes out on ratchet', () async {
        final convoId = await startChat();
        when(() => api.listDevices()).thenThrow(Exception('offline'));

        await notifier.sendMessage(
            conversationId: convoId, myDeviceId: _myDeviceId, text: 'hi');
        await pumpEventQueue();

        expect(sent.map((p) => p.envelopeType), [EnvelopeType.textLegacy]);
      });

      test('a row pointing at an old device invites the real one', () async {
        final convoId = await startChat(rowDevice: 'peer-old');
        when(() => api.lookupDeviceKeyPackages(_peerUsername))
            .thenAnswer((_) async => const [
                  DeviceKeyPackageResult(deviceId: 'peer-dev', keyPackage: [1]),
                ]);

        await notifier.sendMessage(
            conversationId: convoId, myDeviceId: _myDeviceId, text: 'hi');
        await pumpEventQueue();

        expect(welcomed(), ['peer-dev']);
      });

      test('a confirmed single device still takes the simple path', () async {
        final convoId = await startChat();

        await notifier.sendMessage(
            conversationId: convoId, myDeviceId: _myDeviceId, text: 'hi');
        await pumpEventQueue();

        verifyNever(() => api.lookupDeviceKeyPackages(any()));
      });
    });

    test('a sibling device with a smaller id starts the MLS group, not this one',
        () async {
      final convoId = await startFirstContactWithSibling('a-dev');

      final sent = verify(() => api.submitMessage(captureAny()))
          .captured
          .cast<SubmitMessagePayload>();
      expect(sent.where((p) => p.envelopeType == EnvelopeType.mlsWelcome),
          isEmpty);
      expect(notifier.byId(convoId)!.cryptoMode, CryptoMode.ratchet);
    });

    test('a sibling that is not elected takes over once the grace has passed',
        () async {
      // The elected sibling may not hold this chat at all (a self-synced first
      // message creates no row on it), so deferring forever strands the chat
      // on ratchet.
      notifier.siblingInitiatorGrace = Duration.zero;

      final convoId = await startFirstContactWithSibling('a-dev');

      expect(notifier.byId(convoId)!.cryptoMode, CryptoMode.mls);
    });

    test('the smallest-id device starts the MLS group and welcomes its sibling',
        () async {
      await startFirstContactWithSibling('z-dev');

      final sent = verify(() => api.submitMessage(captureAny()))
          .captured
          .cast<SubmitMessagePayload>();
      final welcomed = sent
          .where((p) => p.envelopeType == EnvelopeType.mlsWelcome)
          .map((p) => p.recipientDeviceId)
          .toSet();
      expect(welcomed, containsAll(['peer-dev', 'z-dev']));
    });

    test('a failed Welcome submit excludes that device from the app fan-out',
        () async {
      // Regression: on first contact the migration fanned the Welcome to every
      // device but SWALLOWED individual Welcome-submit failures, then sent the
      // application message to every device anyway. A device whose Welcome was
      // dropped (flaky network) got ciphertext for a group it was never
      // welcomed into → undecryptable → the first message was lost and the
      // failed decrypt churned re-establishment. The app must go ONLY to
      // devices that actually received their Welcome.
      await sessions.save(session);
      await notifier.connect();
      final peerAcc = Account(
        accountId: _peerAccountId,
        username: _peerUsername,
        identityPubKey: const [9, 8, 7],
        x25519PubKey: const [1, 2, 3],
        deviceId: 'peer-dev',
        devices: const [
          AccountDevice(deviceId: 'peer-dev', x25519PubKey: [1, 2, 3]),
          AccountDevice(deviceId: 'peer-dev-2', x25519PubKey: [4, 5, 6]),
        ],
      );
      when(() => api.lookupAccount(_peerUsername))
          .thenAnswer((_) async => peerAcc);
      when(() => api.listDevices()).thenAnswer((_) async => [
            const Device(
                deviceId: _myDeviceId, accountId: 'me-acc', devicePubKey: []),
          ]);
      when(() => api.lookupDeviceKeyPackages(_peerUsername))
          .thenAnswer((_) async => const [
                DeviceKeyPackageResult(deviceId: 'peer-dev', keyPackage: [1]),
                DeviceKeyPackageResult(deviceId: 'peer-dev-2', keyPackage: [2]),
              ]);
      when(() => api.lookupDeviceKeyPackages('me'))
          .thenAnswer((_) async => const []);
      // The Welcome submit to peer-dev-2 fails; everything else succeeds.
      when(() => api.submitMessage(any())).thenAnswer((inv) async {
        final p = inv.positionalArguments[0] as SubmitMessagePayload;
        if (p.envelopeType == EnvelopeType.mlsWelcome &&
            p.recipientDeviceId == 'peer-dev-2') {
          throw Exception('welcome submit dropped');
        }
        return SubmitMessageResult(
            envelopeId: 'srv-env', serverTs: DateTime.utc(2026));
      });

      final convoId = await notifier.startConversation(
        myDeviceId: _myDeviceId,
        username: _peerUsername,
      );
      await notifier.sendMessage(
        conversationId: convoId,
        myDeviceId: _myDeviceId,
        text: 'hello mls',
      );
      await pumpEventQueue();

      final sent = verify(() => api.submitMessage(captureAny()))
          .captured
          .cast<SubmitMessagePayload>();
      final appDevs = sent
          .where((p) => p.envelopeType == EnvelopeType.mlsApplication)
          .map((p) => p.recipientDeviceId)
          .toSet();
      expect(appDevs, contains('peer-dev'),
          reason: 'the welcomed device still gets the message');
      expect(appDevs, isNot(contains('peer-dev-2')),
          reason: 'a device whose Welcome failed must be excluded from the '
              'app fan-out, not stranded with undecryptable ciphertext');
    });

    test('migration whose app submit fails still flips the convo to MLS', () async {
      await sessions.save(session);
      await notifier.connect();
      final peerAcc = Account(
        accountId: _peerAccountId,
        username: _peerUsername,
        identityPubKey: const [9, 8, 7],
        x25519PubKey: const [1, 2, 3],
        deviceId: 'peer-dev',
        devices: const [
          AccountDevice(deviceId: 'peer-dev', x25519PubKey: [1, 2, 3]),
          AccountDevice(deviceId: 'peer-dev-2', x25519PubKey: [4, 5, 6]),
        ],
      );
      when(() => api.lookupAccount(_peerUsername))
          .thenAnswer((_) async => peerAcc);
      when(() => api.listDevices()).thenAnswer((_) async => [
            const Device(
                deviceId: _myDeviceId, accountId: 'me-acc', devicePubKey: []),
          ]);
      when(() => api.lookupDeviceKeyPackages(_peerUsername))
          .thenAnswer((_) async => const [
                DeviceKeyPackageResult(deviceId: 'peer-dev', keyPackage: [1]),
                DeviceKeyPackageResult(deviceId: 'peer-dev-2', keyPackage: [2]),
              ]);
      when(() => api.lookupDeviceKeyPackages('me'))
          .thenAnswer((_) async => const []);
      // Welcomes land, but every application submit drops (flapping network).
      when(() => api.submitMessage(any())).thenAnswer((inv) async {
        final p = inv.positionalArguments[0] as SubmitMessagePayload;
        if (p.envelopeType == EnvelopeType.mlsApplication) {
          throw Exception('app submit dropped');
        }
        return SubmitMessageResult(
            envelopeId: 'srv-env', serverTs: DateTime.utc(2026));
      });

      final convoId = await notifier.startConversation(
        myDeviceId: _myDeviceId,
        username: _peerUsername,
      );
      try {
        await notifier.sendMessage(
          conversationId: convoId,
          myDeviceId: _myDeviceId,
          text: 'hello mls',
        );
      } on Exception {/* the failed send is the scenario under test */}
      await pumpEventQueue();

      expect(notifier.byId(convoId)!.cryptoMode, CryptoMode.mls,
          reason: 'the Welcomes were accepted, so the group exists on the peer '
              '— a retry must encrypt into it, not build a second group');
    });

    test('multi-device MLS migration adds own other device (self-sync member)',
        () async {
      await sessions.save(session);
      await notifier.connect();
      // Single-device peer, but MY account has a second device → still
      // multi-device, so we migrate and add our own other device as a member.
      when(() => api.lookupAccount(_peerUsername)).thenAnswer((_) async =>
          Account(
            accountId: _peerAccountId,
            username: _peerUsername,
            identityPubKey: const [9, 8, 7],
            x25519PubKey: const [1, 2, 3],
            deviceId: 'peer-dev',
            devices: const [
              AccountDevice(deviceId: 'peer-dev', x25519PubKey: [1, 2, 3]),
            ],
          ));
      when(() => api.listDevices()).thenAnswer((_) async => [
            const Device(
                deviceId: _myDeviceId, accountId: 'me-acc', devicePubKey: []),
            const Device(
                deviceId: 'me-dev-2',
                accountId: 'me-acc',
                devicePubKey: [],
                x25519PubKey: [7, 7, 7]),
          ]);
      when(() => api.lookupDeviceKeyPackages(_peerUsername))
          .thenAnswer((_) async => const [
                DeviceKeyPackageResult(deviceId: 'peer-dev', keyPackage: [1]),
              ]);
      when(() => api.lookupDeviceKeyPackages('me'))
          .thenAnswer((_) async => const [
                DeviceKeyPackageResult(deviceId: _myDeviceId, keyPackage: [8]),
                DeviceKeyPackageResult(deviceId: 'me-dev-2', keyPackage: [9]),
              ]);

      final convoId = await notifier.startConversation(
        myDeviceId: _myDeviceId,
        username: _peerUsername,
      );
      await notifier.sendMessage(
        conversationId: convoId,
        myDeviceId: _myDeviceId,
        text: 'self sync me',
      );
      await pumpEventQueue();

      final appDevs = verify(() => api.submitMessage(captureAny()))
          .captured
          .cast<SubmitMessagePayload>()
          .where((p) => p.envelopeType == EnvelopeType.mlsApplication)
          .map((p) => p.recipientDeviceId)
          .toSet();
      // Peer device + my OTHER device (not my own sending device).
      expect(appDevs, containsAll(['peer-dev', 'me-dev-2']));
      expect(appDevs, isNot(contains(_myDeviceId)),
          reason: 'never fan a copy back to the sending device');
    });

    group('self-sync copies never raise a banner on our own other device', () {
      Future<String> setUpSiblingChat() async {
        await sessions.save(session);
        await notifier.connect();
        when(() => api.lookupAccount(_peerUsername)).thenAnswer((_) async =>
            Account(
              accountId: _peerAccountId,
              username: _peerUsername,
              identityPubKey: const [9, 8, 7],
              x25519PubKey: const [1, 2, 3],
              deviceId: 'peer-dev',
              devices: const [
                AccountDevice(deviceId: 'peer-dev', x25519PubKey: [1, 2, 3]),
              ],
            ));
        when(() => api.listDevices()).thenAnswer((_) async => [
              const Device(
                  deviceId: _myDeviceId, accountId: 'me-acc', devicePubKey: []),
              const Device(
                  deviceId: 'me-dev-2',
                  accountId: 'me-acc',
                  devicePubKey: [],
                  x25519PubKey: [7, 7, 7]),
            ]);
        when(() => api.lookupDeviceKeyPackages(_peerUsername))
            .thenAnswer((_) async => const [
                  DeviceKeyPackageResult(deviceId: 'peer-dev', keyPackage: [1]),
                ]);
        when(() => api.lookupDeviceKeyPackages('me'))
            .thenAnswer((_) async => const [
                  DeviceKeyPackageResult(deviceId: _myDeviceId, keyPackage: [8]),
                  DeviceKeyPackageResult(deviceId: 'me-dev-2', keyPackage: [9]),
                ]);
        return notifier.startConversation(
          myDeviceId: _myDeviceId,
          username: _peerUsername,
        );
      }

      Map<String, String?> appPushKindByDevice() => {
            for (final p in verify(() => api.submitMessage(captureAny()))
                .captured
                .cast<SubmitMessagePayload>()
                .where((p) => p.envelopeType == EnvelopeType.mlsApplication))
              p.recipientDeviceId: p.pushKind,
          };

      test('the first (migrating) send is silent to our other device only',
          () async {
        final convoId = await setUpSiblingChat();

        await notifier.sendMessage(
            conversationId: convoId, myDeviceId: _myDeviceId, text: 'one');
        await pumpEventQueue();

        final kinds = appPushKindByDevice();
        expect(kinds['me-dev-2'], PushKind.silent);
        expect(kinds['peer-dev'], isNull,
            reason: 'the peer must still get a normal wakeup');
      });

      test('a later send on the established MLS 1:1 is silent to our other '
          'device only', () async {
        final convoId = await setUpSiblingChat();
        await notifier.sendMessage(
            conversationId: convoId, myDeviceId: _myDeviceId, text: 'one');
        await pumpEventQueue();
        clearInteractions(api);

        await notifier.sendMessage(
            conversationId: convoId, myDeviceId: _myDeviceId, text: 'two');
        await pumpEventQueue();

        final kinds = appPushKindByDevice();
        expect(kinds['me-dev-2'], PushKind.silent);
        expect(kinds['peer-dev'], isNull);
      });
    });

    group('a chat started on our other device', () {
      late String convoId;

      setUp(() async {
        await sessions.save(session);
        when(() => api.listDevices()).thenAnswer((_) async => [
              const Device(
                  deviceId: _myDeviceId, accountId: 'me-acc', devicePubKey: []),
              const Device(
                  deviceId: 'me-dev-2',
                  accountId: 'me-acc',
                  devicePubKey: [],
                  x25519PubKey: [7, 7, 7]),
            ]);
        when(() => api.lookupAccountById(_peerAccountId))
            .thenAnswer((_) async => _peerAccount());
        when(() => api.ackMessages(any())).thenAnswer((_) async => 1);
        await notifier.connect();
        await pumpEventQueue();
        convoId = Conversation.oneToOneId('me-acc', _peerAccountId);
      });

      void pushFromSibling(String body, String envelopeId) => ws.push(_envelope(
            conversationId: convoId,
            envelopeType: EnvelopeType.textLegacy,
            senderDeviceId: 'me-dev-2',
            envelopeId: envelopeId,
            ciphertext: utf8.encode(body),
          ));

      test('shows its first message here, as ours', () async {
        pushFromSibling('hi from my other phone', 'sib-1');
        await pumpEventQueue(times: 50);

        final msgs = notifier.byId(convoId)!.messages;
        expect(msgs.where((m) => m.body == 'hi from my other phone' && m.mine),
            hasLength(1));
      });

      test('is not listed as a request', () async {
        pushFromSibling('hi from my other phone', 'sib-2');
        await pumpEventQueue(times: 50);

        expect(notifier.byId(convoId)!.pending, isFalse);
      });

      test('control traffic for a chat we deleted still creates nothing',
          () async {
        pushFromSibling(
            MessageControl.receipt(ReceiptKind.read, const ['x']).encode(),
            'sib-3');
        await pumpEventQueue(times: 50);

        expect(notifier.byId(convoId), isNull);
      });
    });

    test('a newly-linked own device is added to existing MLS 1:1 groups',
        () async {
      await sessions.save(session);
      crypto.memberDeviceIds = {_myDeviceId, 'peer-dev'};
      // An MLS 1:1 already exists with the peer (migrated before the link).
      final convoId = Conversation.oneToOneId('me-acc', _peerAccountId);
      notifier.seed(Conversation(
        id: convoId,
        peerUsername: _peerUsername,
        peerAccountId: _peerAccountId,
        peerDeviceId: 'peer-dev',
        peerIdentityPubKey: const [],
        messages: const [],
        unreadCount: 0,
        cryptoMode: CryptoMode.mls,
      ));
      when(() => api.lookupAccount(_peerUsername))
          .thenAnswer((_) async => _peerAccount());
      when(() => api.listDevices()).thenAnswer((_) async => [
            const Device(
                deviceId: _myDeviceId, accountId: 'me-acc', devicePubKey: []),
            const Device(
                deviceId: 'me-dev-2',
                accountId: 'me-acc',
                devicePubKey: [],
                x25519PubKey: [7, 7, 7]),
          ]);
      when(() => api.lookupDeviceKeyPackages('me'))
          .thenAnswer((_) async => const [
                DeviceKeyPackageResult(deviceId: 'me-dev-2', keyPackage: [9]),
              ]);

      await notifier.connect();
      await pumpEventQueue();

      final sent = verify(() => api.submitMessage(captureAny()))
          .captured
          .cast<SubmitMessagePayload>();
      expect(
          sent.any((p) =>
              p.envelopeType == EnvelopeType.mlsWelcome &&
              p.recipientDeviceId == 'me-dev-2'),
          isTrue,
          reason: 'the newly-linked device should get a Welcome');
      expect(
          sent.any((p) =>
              p.envelopeType == EnvelopeType.mlsHandshake &&
              p.recipientDeviceId == 'peer-dev'),
          isTrue,
          reason: 'existing members should get the Commit');
    });

    test(
        'a devices_changed frame adds a device linked while already connected, '
        'without a reconnect', () async {
      await sessions.save(session);
      crypto.memberDeviceIds = {_myDeviceId, 'peer-dev'};
      notifier.seed(Conversation(
        id: Conversation.oneToOneId('me-acc', _peerAccountId),
        peerUsername: _peerUsername,
        peerAccountId: _peerAccountId,
        peerDeviceId: 'peer-dev',
        peerIdentityPubKey: const [],
        messages: const [],
        unreadCount: 0,
        cryptoMode: CryptoMode.mls,
      ));
      when(() => api.lookupAccount(_peerUsername))
          .thenAnswer((_) async => _peerAccount());
      // Connected while only our own device exists.
      when(() => api.listDevices()).thenAnswer((_) async => [
            const Device(
                deviceId: _myDeviceId, accountId: 'me-acc', devicePubKey: []),
          ]);
      when(() => api.lookupDeviceKeyPackages('me'))
          .thenAnswer((_) async => const [
                DeviceKeyPackageResult(deviceId: 'me-dev-2', keyPackage: [9]),
              ]);
      await notifier.connect();
      await pumpEventQueue();
      // Nothing sent yet — we only knew our own device.
      verifyNever(() => api.submitMessage(any()));

      // A second device is linked while we stay connected; the server pushes
      // the ephemeral devices_changed frame.
      when(() => api.listDevices()).thenAnswer((_) async => [
            const Device(
                deviceId: _myDeviceId, accountId: 'me-acc', devicePubKey: []),
            const Device(
                deviceId: 'me-dev-2',
                accountId: 'me-acc',
                devicePubKey: [],
                x25519PubKey: [7, 7, 7]),
          ]);
      ws.push(_envelope(
        envelopeId: '',
        conversationId: '',
        envelopeType: EnvelopeType.devicesChanged,
        ciphertext: const [],
      ));
      await pumpEventQueue();

      final welcomedDev2 = verify(() => api.submitMessage(captureAny()))
          .captured
          .cast<SubmitMessagePayload>()
          .any((p) =>
              p.envelopeType == EnvelopeType.mlsWelcome &&
              p.recipientDeviceId == 'me-dev-2');
      expect(welcomedDev2, isTrue,
          reason: 'the new device must get its Welcome without a reconnect');
    });

    test('reconcile fetches a FRESH key package per group (single-use packages)',
        () async {
      // Two already-migrated MLS 1:1s. An MLS key package is single-use, so the
      // new device must get a DISTINCT package per group — a reused one makes
      // the 2nd Welcome invalid (the bug this guards against).
      await sessions.save(session);
      crypto.memberDeviceIds = {_myDeviceId, 'peer-dev'};
      for (final p in const [
        (acc: _peerAccountId, user: _peerUsername, dev: 'peer-dev'),
        (acc: 'peer2-acc', user: 'peer2', dev: 'peer2-dev'),
      ]) {
        notifier.seed(Conversation(
          id: Conversation.oneToOneId('me-acc', p.acc),
          peerUsername: p.user,
          peerAccountId: p.acc,
          peerDeviceId: p.dev,
          peerIdentityPubKey: const [],
          messages: const [],
          unreadCount: 0,
          cryptoMode: CryptoMode.mls,
        ));
      }
      when(() => api.lookupAccount(_peerUsername))
          .thenAnswer((_) async => _peerAccount());
      when(() => api.lookupAccount('peer2')).thenAnswer(
          (_) async => _peerAccount(accountId: 'peer2-acc', username: 'peer2'));
      when(() => api.listDevices()).thenAnswer((_) async => [
            const Device(
                deviceId: _myDeviceId, accountId: 'me-acc', devicePubKey: []),
            const Device(
                deviceId: 'me-dev-2',
                accountId: 'me-acc',
                devicePubKey: [],
                x25519PubKey: [7, 7, 7]),
          ]);
      when(() => api.lookupDeviceKeyPackages('me'))
          .thenAnswer((_) async => const [
                DeviceKeyPackageResult(deviceId: 'me-dev-2', keyPackage: [9]),
              ]);

      await notifier.connect();
      await pumpEventQueue();

      // One fetch PER conversation — not a single reused fetch.
      verify(() => api.lookupDeviceKeyPackages('me')).called(2);
      // A Welcome to the new device for EACH group.
      final welcomes = verify(() => api.submitMessage(captureAny()))
          .captured
          .cast<SubmitMessagePayload>()
          .where((p) =>
              p.envelopeType == EnvelopeType.mlsWelcome &&
              p.recipientDeviceId == 'me-dev-2')
          .length;
      expect(welcomes, 2);
    });

    test('inbound from a non-primary peer device decrypts via its own ratchet',
        () async {
      await sessions.save(session);
      await notifier.connect();
      when(() => api.ackMessages(any())).thenAnswer((_) async => 1);
      final peerAcc = Account(
        accountId: _peerAccountId,
        username: _peerUsername,
        identityPubKey: const [9, 8, 7],
        x25519PubKey: const [1, 2, 3],
        deviceId: 'peer-dev',
        devices: const [
          AccountDevice(deviceId: 'peer-dev', x25519PubKey: [1, 2, 3]),
          AccountDevice(deviceId: 'peer-dev-2', x25519PubKey: [4, 5, 6]),
        ],
      );
      when(() => api.lookupAccount(_peerUsername))
          .thenAnswer((_) async => peerAcc);
      final convoId = await notifier.startConversation(
        myDeviceId: _myDeviceId,
        username: _peerUsername,
      );

      // Inbound from the peer's SECOND device (not the convo's primary).
      ws.push(_envelope(
        envelopeId: 'env-d2',
        conversationId: convoId,
        senderDeviceId: 'peer-dev-2',
        envelopeType: EnvelopeType.textLegacy,
        ciphertext: const [104, 105], // "hi" (passthrough crypto)
      ));
      await pumpEventQueue();

      final msgs = notifier.byId(convoId)!.messages;
      expect(msgs.any((m) => m.body == 'hi' && !m.mine), isTrue,
          reason: 'message from the non-primary peer device should decrypt');
    });

    test('inbound from my own other device renders as mine (self-sync)',
        () async {
      await sessions.save(session);
      await notifier.connect();
      when(() => api.ackMessages(any())).thenAnswer((_) async => 1);
      when(() => api.lookupAccount(_peerUsername))
          .thenAnswer((_) async => _peerAccount());
      // My account has a second device (self-sync source).
      when(() => api.listDevices()).thenAnswer((_) async => [
            const Device(
                deviceId: _myDeviceId, accountId: 'me-acc', devicePubKey: []),
            const Device(
                deviceId: 'me-dev-2',
                accountId: 'me-acc',
                devicePubKey: [],
                x25519PubKey: [7, 7, 7]),
          ]);
      final convoId = await notifier.startConversation(
        myDeviceId: _myDeviceId,
        username: _peerUsername,
      );

      // A copy of my own send, relayed from my other device.
      ws.push(_envelope(
        envelopeId: 'env-self',
        conversationId: convoId,
        senderDeviceId: 'me-dev-2',
        envelopeType: EnvelopeType.textLegacy,
        ciphertext: const [121, 111], // "yo"
      ));
      await pumpEventQueue();

      final msg = notifier
          .byId(convoId)!
          .messages
          .firstWhere((m) => m.body == 'yo');
      expect(msg.mine, isTrue, reason: 'self-synced copy should render as mine');
    });

    test('creates placeholder conversation when sender is unknown and does NOT ack', () async {
      await sessions.save(session);
      await notifier.connect();
      when(() => api.ackMessages(any())).thenAnswer((_) async => 1);

      ws.push(_envelope(
        conversationId: 'unknown-convo',
        senderDeviceId: 'stranger',
        envelopeType: EnvelopeType.textLegacy,
      ));
      await pumpEventQueue();

      final convo = notifier.byId('unknown-convo');
      expect(convo, isNotNull);
      expect(convo!.peerUsername, equals('unknown'));
      expect(convo.peerDeviceId, equals('stranger'));
      expect(convo.unreadCount, equals(1));
      // Crucial: an unknown-peer envelope must NOT be acked. Acking would
      // let the server drop it and the user could never see the real message
      // after starting a conversation with the peer.
      verifyNever(() => api.ackMessages(any()));
    });

    test('does not append when no session is stored', () async {
      // Inject the subscription manually by listening to ws.envelopes
      // directly. connect() exits early without a session, so the notifier
      // never wires the listener — exercising the early-return branch.
      final sub = ws.envelopes.listen((_) {});
      ws.push(_envelope(conversationId: 'x'));
      await pumpEventQueue();
      await sub.cancel();
      expect(notifier.conversations, isEmpty);
    });

    test('ack failure does not crash the receive path', () async {
      await sessions.save(session);
      await notifier.connect();
      when(() => api.lookupAccount(_peerUsername))
          .thenAnswer((_) async => _peerAccount());
      final convoId = await notifier.startConversation(
        myDeviceId: _myDeviceId,
        username: _peerUsername,
      );

      when(() => api.ackMessages(any())).thenThrow(Exception('flaky'));

      ws.push(_envelope(
        conversationId: convoId,
        envelopeType: EnvelopeType.textLegacy,
      ));
      await pumpEventQueue();

      // Message still appended even though ack failed silently.
      expect(notifier.byId(convoId)!.messages.length, equals(1));
    });
  });

  group('inbound envelope routing (§9.2 dispatch table)', () {
    // Helper: seed a ratchet-mode conversation via startConversation.
    Future<String> seedRatchetConvo() async {
      await sessions.save(session);
      await notifier.connect();
      when(() => api.lookupAccount(_peerUsername))
          .thenAnswer((_) async => _peerAccount());
      return notifier.startConversation(
        myDeviceId: _myDeviceId,
        username: _peerUsername,
      );
    }

    // Helper: seed an MLS-mode conversation directly.
    String seedMlsConvo() {
      const convoId = 'mls-convo-1';
      notifier.seed(Conversation(
        id: convoId,
        peerUsername: _peerUsername,
        peerAccountId: _peerAccountId,
        peerDeviceId: 'peer-dev',
        peerIdentityPubKey: const [9, 8, 7],
        peerX25519PubKey: const [1, 2, 3],
        messages: const [],
        unreadCount: 0,
        cryptoMode: CryptoMode.mls,
      ));
      return convoId;
    }

    test('inbound_mls_welcome_RatchetConvo_FlipsToMls', () async {
      final convoId = await seedRatchetConvo();
      expect(notifier.byId(convoId)!.cryptoMode, equals(CryptoMode.ratchet));

      // Give the convo a ratchet crypto state so we can verify it gets cleared.
      await db.saveConversationCryptoState(
        ConversationCryptoState(
          conversationId: convoId,
          sendCounter: 0,
          sendChainKey: List<int>.filled(32, 0),
          recvCounter: 0,
          recvChainKey: List<int>.filled(32, 0),
        ),
      );

      // processWelcome on _PassthroughCrypto returns 'stub-group' but we want
      // it to return the convoId so §7.3 mismatch logic is exercised when they
      // differ. The convoId won't match 'stub-group' — that's fine; we still
      // flip mode based on the conversationId from the envelope.
      ws.push(_envelope(
        conversationId: convoId,
        envelopeType: EnvelopeType.mlsWelcome,
        ciphertext: const [1, 2, 3],
      ));
      await pumpEventQueue();

      expect(notifier.byId(convoId)!.cryptoMode, equals(CryptoMode.mls));

      // Ratchet state must be cleared.
      final ratchetState = await db.loadConversationCryptoState(convoId);
      expect(ratchetState, isNull);

      // Persisted.
      final loaded = await db.loadConversations();
      final dbConvo = loaded.firstWhere((c) => c.id == convoId);
      expect(dbConvo.cryptoMode, equals(CryptoMode.mls));
    });

    test('a Welcome from our own other device replaces our group', () async {
      // The leader rule is about accounts. Discarding this one left a device on
      // a dead group, sending messages nobody could read.
      when(() => api.listDevices()).thenAnswer((_) async => const [
            Device(deviceId: _myDeviceId, accountId: 'me-acc', devicePubKey: []),
            Device(deviceId: 'me-dev-2', accountId: 'me-acc', devicePubKey: []),
          ]);
      await sessions.save(session);
      await notifier.connect();
      await pumpEventQueue();
      final convoId = seedMlsConvo();

      ws.push(_envelope(
        conversationId: convoId,
        envelopeType: EnvelopeType.mlsWelcome,
        senderDeviceId: 'me-dev-2',
        ciphertext: const [1, 2, 3],
      ));
      await pumpEventQueue();

      expect(crypto.replaceGroupCalls.map((c) => c.localGroupId), [convoId]);
    });

    test("a ratchet message from the peer's other device is delivered", () async {
      when(() => api.lookupAccount(_peerUsername)).thenAnswer((_) async => Account(
            accountId: _peerAccountId,
            username: _peerUsername,
            identityPubKey: const [9, 8, 7],
            x25519PubKey: const [1, 2, 3],
            deviceId: 'peer-dev',
            devices: const [
              AccountDevice(deviceId: 'peer-dev', x25519PubKey: [1, 2, 3]),
              AccountDevice(deviceId: 'peer-dev-2', x25519PubKey: [4, 5, 6]),
            ],
          ));
      await sessions.save(session);
      await notifier.connect();
      await pumpEventQueue();
      final convoId = seedMlsConvo();

      ws.push(_envelope(
        conversationId: convoId,
        envelopeType: EnvelopeType.textLegacy,
        senderDeviceId: 'peer-dev-2',
        envelopeId: 'other-device-1',
        ciphertext: utf8.encode('from their other phone'),
      ));
      await pumpEventQueue(times: 100);

      expect(notifier.byId(convoId)!.messages.map((m) => m.body),
          contains('from their other phone'));
    });

    test("a ratchet message from the peer's other device forces no rebuild",
        () async {
      when(() => api.lookupAccount(_peerUsername)).thenAnswer((_) async => Account(
            accountId: _peerAccountId,
            username: _peerUsername,
            identityPubKey: const [9, 8, 7],
            x25519PubKey: const [1, 2, 3],
            deviceId: 'peer-dev',
            devices: const [
              AccountDevice(deviceId: 'peer-dev', x25519PubKey: [1, 2, 3]),
              AccountDevice(deviceId: 'peer-dev-2', x25519PubKey: [4, 5, 6]),
            ],
          ));
      await sessions.save(session);
      await notifier.connect();
      await pumpEventQueue();
      final convoId = seedMlsConvo();

      ws.push(_envelope(
        conversationId: convoId,
        envelopeType: EnvelopeType.textLegacy,
        senderDeviceId: 'peer-dev-2',
        envelopeId: 'other-device-2',
        ciphertext: utf8.encode('still in touch'),
      ));
      await pumpEventQueue(times: 100);

      expect(notifier.byId(convoId)!.cryptoMode, CryptoMode.mls);
    });

    test('inbound_mls_welcome_MlsConvo_IsIdempotent', () async {
      await sessions.save(session);
      await notifier.connect();
      // Drain the post-connect catchup so its one-shot "catchup settled" pulse
      // doesn't bleed into the notify count we measure for the Welcome below.
      await pumpEventQueue();
      final convoId = seedMlsConvo();

      var notifyCount = 0;
      notifier.addListener(() => notifyCount++);
      notifyCount = 0;

      ws.push(_envelope(
        conversationId: convoId,
        envelopeType: EnvelopeType.mlsWelcome,
        ciphertext: const [1, 2, 3],
      ));
      await pumpEventQueue();

      // Still MLS — no change.
      expect(notifier.byId(convoId)!.cryptoMode, equals(CryptoMode.mls));
      // No state mutation → no notifyListeners call.
      expect(notifyCount, equals(0));
    });

    // Spec §9.3 tiebreaker: own deviceId 'me-dev' < sender 'peer-dev' → we win.
    test('simultaneous_migration_lowerOwnDeviceId_wins_ignoresForeignWelcome', () async {
      await sessions.save(session); // session.deviceId == 'me-dev'
      await notifier.connect();
      final convoId = seedMlsConvo();

      ws.push(_envelope(
        conversationId: convoId,
        envelopeType: EnvelopeType.mlsWelcome,
        senderDeviceId: 'peer-dev', // 'me-dev' < 'peer-dev' → we win
        ciphertext: const [0xAB, 0xCD],
      ));
      await pumpEventQueue();

      // replaceGroup must NOT have been called — we win the tiebreaker.
      expect(crypto.replaceGroupCalls, isEmpty);
      // Conversation stays MLS, unchanged.
      expect(notifier.byId(convoId)!.cryptoMode, equals(CryptoMode.mls));
    });

    // Spec §9.3 tiebreaker: own deviceId 'me-dev' > sender 'aaa-dev' → we lose.
    test('simultaneous_migration_higherOwnDeviceId_loses_callsReplaceGroup', () async {
      await sessions.save(session); // session.deviceId == 'me-dev'
      await notifier.connect();
      final convoId = seedMlsConvo();

      const foreignWelcome = [0x11, 0x22, 0x33];
      ws.push(_envelope(
        conversationId: convoId,
        envelopeType: EnvelopeType.mlsWelcome,
        senderDeviceId: 'aaa-dev', // 'me-dev' > 'aaa-dev' → we lose
        ciphertext: foreignWelcome,
      ));
      await pumpEventQueue();

      // replaceGroup must have been called with the foreign Welcome bytes.
      expect(crypto.replaceGroupCalls, hasLength(1));
      expect(crypto.replaceGroupCalls.single.localGroupId, equals(convoId));
      expect(crypto.replaceGroupCalls.single.foreignWelcome, equals(foreignWelcome));
    });

    // Peer-reset re-establishment: an ESTABLISHED 1:1 (has received a real
    // message) that gets a fresh Welcome means the peer reset (e.g. restored
    // from their recovery phrase, wiping their MLS store). We must ADOPT
    // their new group via replaceGroup even though our deviceId 'me-dev' <
    // sender 'peer-dev' would otherwise WIN the simultaneous-migration
    // tiebreak and strand every inbound message under our now-dead group.
    test('established_convo_adopts_foreign_welcome_on_peer_reset', () async {
      await sessions.save(session); // session.deviceId == 'me-dev'
      await notifier.connect();
      const convoId = 'mls-convo-reset';
      notifier.seed(Conversation(
        id: convoId,
        peerUsername: _peerUsername,
        peerAccountId: _peerAccountId,
        peerDeviceId: 'peer-dev',
        peerIdentityPubKey: const [9, 8, 7],
        peerX25519PubKey: const [1, 2, 3],
        // A real RECEIVED message → the group was proven working.
        messages: [
          ChatMessage(
            envelopeId: 'old-1',
            conversationId: convoId,
            senderDeviceId: 'peer-dev',
            body: 'hi from before the reset',
            serverTs: DateTime.utc(2026, 6, 1),
            mine: false,
          ),
        ],
        unreadCount: 0,
        cryptoMode: CryptoMode.mls,
      ));

      const foreignWelcome = [0x55, 0x66, 0x77];
      ws.push(_envelope(
        conversationId: convoId,
        envelopeType: EnvelopeType.mlsWelcome,
        senderDeviceId: 'peer-dev', // 'me-dev' < 'peer-dev' → old tiebreak would WIN
        ciphertext: foreignWelcome,
      ));
      await pumpEventQueue();

      // Adopted the peer's new group despite winning the tiebreak.
      expect(crypto.replaceGroupCalls, hasLength(1));
      expect(crypto.replaceGroupCalls.single.localGroupId, equals(convoId));
      expect(
          crypto.replaceGroupCalls.single.foreignWelcome, equals(foreignWelcome));
    });

    // Poison-Welcome guard: a re-establishment Welcome that is PERMANENTLY
    // invalid (replaceGroup throws MlsArgumentException — e.g. built on an
    // already-consumed single-use key package) must be ACKED so it stops
    // redelivering. Leaving it unacked deadlocks catchup convergence forever.
    Conversation establishedResetConvo(String convoId) => Conversation(
          id: convoId,
          peerUsername: _peerUsername,
          peerAccountId: _peerAccountId,
          peerDeviceId: 'peer-dev',
          peerIdentityPubKey: const [9, 8, 7],
          peerX25519PubKey: const [1, 2, 3],
          messages: [
            ChatMessage(
              envelopeId: 'old-1',
              conversationId: convoId,
              senderDeviceId: 'peer-dev',
              body: 'hi from before the reset',
              serverTs: DateTime.utc(2026, 6, 1),
              mine: false,
            ),
          ],
          unreadCount: 0,
          cryptoMode: CryptoMode.mls,
        );

    test('established_convo_acks_permanently_invalid_reestablishment_welcome',
        () async {
      when(() => api.ackMessages(any())).thenAnswer((_) async => 1);
      await sessions.save(session); // session.deviceId == 'me-dev'
      await notifier.connect();
      const convoId = 'mls-convo-poison';
      notifier.seed(establishedResetConvo(convoId));

      // The incoming Welcome is structurally invalid → replaceGroup always throws.
      crypto.replaceGroupError = const MlsArgumentException('stale key package');

      ws.push(_envelope(
        envelopeId: 'env-poison',
        conversationId: convoId,
        envelopeType: EnvelopeType.mlsWelcome,
        senderDeviceId: 'peer-dev',
        ciphertext: const [0x55, 0x66, 0x77],
      ));
      await pumpEventQueue();

      // Adoption was attempted and failed permanently...
      expect(crypto.replaceGroupCalls, hasLength(1));
      // ...so the poison Welcome is ACKED (dropped), not left to redeliver.
      verify(() => api.ackMessages(['env-poison'])).called(1);
    });

    test('established_convo_retries_transient_reestablishment_welcome_failure',
        () async {
      when(() => api.ackMessages(any())).thenAnswer((_) async => 1);
      await sessions.save(session);
      await notifier.connect();
      const convoId = 'mls-convo-transient';
      notifier.seed(establishedResetConvo(convoId));

      // A transient failure (SQLite/FS busy) must NOT be acked — retry later.
      crypto.replaceGroupError = const MlsIoException('db busy');

      ws.push(_envelope(
        envelopeId: 'env-transient',
        conversationId: convoId,
        envelopeType: EnvelopeType.mlsWelcome,
        senderDeviceId: 'peer-dev',
        ciphertext: const [0x55, 0x66, 0x77],
      ));
      await pumpEventQueue();

      expect(crypto.replaceGroupCalls, hasLength(1));
      // Left unacked → redelivered next catchup.
      verifyNever(() => api.ackMessages(['env-transient']));
    });

    // A PENDING 1:1 (inbound message request — we're the receiver, never a
    // migration initiator) adopts a fresh Welcome even with no received
    // message yet. This is the delete-then-peer-re-establishes / peer-reset
    // path where our local group is a stale orphan.
    test('pending_request_adopts_foreign_welcome', () async {
      await sessions.save(session); // 'me-dev' < 'peer-dev' → old tiebreak WINS
      await notifier.connect();
      const convoId = 'mls-convo-pending';
      notifier.seed(Conversation(
        id: convoId,
        peerUsername: _peerUsername,
        peerAccountId: _peerAccountId,
        peerDeviceId: 'peer-dev',
        peerIdentityPubKey: const [9, 8, 7],
        peerX25519PubKey: const [1, 2, 3],
        messages: const [], // no received message yet…
        unreadCount: 0,
        cryptoMode: CryptoMode.mls,
        pending: true, // …but it's an inbound request → we're the receiver
      ));

      const foreignWelcome = [0x99, 0xAA];
      ws.push(_envelope(
        conversationId: convoId,
        envelopeType: EnvelopeType.mlsWelcome,
        senderDeviceId: 'peer-dev',
        ciphertext: foreignWelcome,
      ));
      await pumpEventQueue();

      expect(crypto.replaceGroupCalls, hasLength(1));
      expect(
          crypto.replaceGroupCalls.single.foreignWelcome, equals(foreignWelcome));
    });

    // The genuine race is unaffected: a FRESH migration WE initiated (not
    // pending, no received message yet) still uses the deterministic tiebreak.
    test('fresh_simultaneous_migration_still_tiebreaks_not_adopts', () async {
      await sessions.save(session); // 'me-dev' < 'peer-dev' → we win
      await notifier.connect();
      final convoId = seedMlsConvo(); // messages: []

      ws.push(_envelope(
        conversationId: convoId,
        envelopeType: EnvelopeType.mlsWelcome,
        senderDeviceId: 'peer-dev',
        ciphertext: const [0xAB, 0xCD],
      ));
      await pumpEventQueue();

      // No adopt — the tiebreak governs the genuine fresh race.
      expect(crypto.replaceGroupCalls, isEmpty);
      expect(notifier.byId(convoId)!.cryptoMode, equals(CryptoMode.mls));
    });

    // Split-brain self-heal: repeated inbound decrypt failures from a real
    // peer trigger a deterministic re-establishment (the lower deviceId side
    // wipes its diverged group and re-migrates, sending a fresh Welcome).
    test('repeated_decrypt_failures_trigger_reestablishment', () async {
      await sessions.save(session); // session.deviceId == 'me-dev'
      await notifier.connect();
      final convoId = seedMlsConvo(); // peerDeviceId 'peer-dev' > 'me-dev' → WE initiate
      // The diverged group can't decrypt the peer's ciphertext.
      crypto.decryptAndInspectError =
          const MlsArgumentException('cannot decrypt');
      // Re-migration needs a peer KeyPackage.
      when(() => api.lookupKeyPackage(any())).thenAnswer(
        (_) async => FetchKeyPackageResult(
          keyPackage: List<int>.filled(64, 0xBB),
          replenishNeeded: false,
          remainingForUser: 9,
        ),
      );
      final submittedTypes = <String>[];
      when(() => api.submitMessage(any())).thenAnswer((inv) async {
        final p = inv.positionalArguments.first as SubmitMessagePayload;
        submittedTypes.add(p.envelopeType);
        return SubmitMessageResult(
            envelopeId: 'srv', serverTs: DateTime.utc(2026));
      });

      // Below threshold (3): no re-establishment yet.
      ws.push(_envelope(
          conversationId: convoId, senderDeviceId: 'peer-dev', envelopeId: 'a'));
      ws.push(_envelope(
          conversationId: convoId, senderDeviceId: 'peer-dev', envelopeId: 'b'));
      await pumpEventQueue();
      expect(crypto.wipeGroupCalls, equals(0));
      expect(submittedTypes, isEmpty);

      // Confirm decrypt was actually attempted + failed (not short-circuited).
      expect(crypto.decryptAndInspectCalls, equals(2));

      // Third failure crosses the threshold → re-establish.
      ws.push(_envelope(
          conversationId: convoId, senderDeviceId: 'peer-dev', envelopeId: 'c'));
      await pumpEventQueue(times: 100);

      expect(crypto.wipeGroupCalls, greaterThanOrEqualTo(1));
      // A fresh Welcome went to the peer to carry the new group.
      expect(submittedTypes, contains(EnvelopeType.mlsWelcome));
    });

    // Who rebuilds first must follow the same account role that decides whose
    // Welcome survives. Ordering by device id instead made the follower rebuild
    // at once while the leader discarded every rebuild it sent (live ping-pong).
    group('re-establishment order follows the account role', () {
      Future<void> seedAndFail({
        required String convoId,
        required String peerAccountId,
        required String peerDeviceId,
      }) async {
        await sessions.save(session); // account 'me-acc', device 'me-dev'
        await notifier.connect();
        notifier.seed(Conversation(
          id: convoId,
          peerUsername: _peerUsername,
          peerAccountId: peerAccountId,
          peerDeviceId: peerDeviceId,
          peerIdentityPubKey: const [9, 8, 7],
          peerX25519PubKey: const [1, 2, 3],
          messages: const [],
          unreadCount: 0,
          cryptoMode: CryptoMode.mls,
        ));
        when(() => api.ackMessages(any())).thenAnswer((_) async => 1);
        when(() => api.lookupKeyPackage(any())).thenAnswer(
          (_) async => FetchKeyPackageResult(
            keyPackage: List<int>.filled(64, 0xBB),
            replenishNeeded: false,
            remainingForUser: 9,
          ),
        );
        when(() => api.submitMessage(any())).thenAnswer((_) async =>
            SubmitMessageResult(
                envelopeId: 'srv', serverTs: DateTime.utc(2026)));
        crypto.decryptAndInspectError = const MlsDecryptException('diverged');
        for (var i = 0; i < 3; i++) {
          ws.push(_envelope(
            envelopeId: 'undec-$i',
            conversationId: convoId,
            senderDeviceId: peerDeviceId,
            envelopeType: EnvelopeType.mlsApplication,
            ciphertext: const [1, 1, 1],
          ));
          await pumpEventQueue();
        }
        await pumpEventQueue(times: 100);
      }

      test('the leader rebuilds at once even with the higher device id',
          () async {
        // me-acc < zzz-acc: we lead. Our 'me-dev' > 'aaa-dev' (old rule waited).
        await seedAndFail(
          convoId: '1to1:me-acc:zzz-acc',
          peerAccountId: 'zzz-acc',
          peerDeviceId: 'aaa-dev',
        );

        expect(crypto.wipeGroupCalls, greaterThanOrEqualTo(1));
      });

      test('the follower waits for the leader even with the lower device id',
          () async {
        // aaa-acc < me-acc: we follow. Our 'me-dev' < 'zzz-dev' (old rule went first).
        await seedAndFail(
          convoId: '1to1:aaa-acc:me-acc',
          peerAccountId: 'aaa-acc',
          peerDeviceId: 'zzz-dev',
        );

        expect(crypto.wipeGroupCalls, equals(0));
      });
    });

    // Churn guard: an MLS application message we can never decrypt (sealed to a
    // dead epoch) stays unacked otherwise and redelivers on every reconnect,
    // each redelivery re-triggering re-establishment. After the cap it must be
    // acked+dropped. Peer deviceId 'aaa-dev' < 'me-dev' → WE are the higher id,
    // so re-establishment parks on its grace delay (never completes under
    // pumpEventQueue) and doesn't wipe the group — keeping every delivery on the
    // decrypt-failure path under test.
    test('undecryptable_app_message_acked_after_cap_to_stop_churn', () async {
      when(() => api.ackMessages(any())).thenAnswer((_) async => 1);
      await sessions.save(session); // session.deviceId == 'me-dev'
      await notifier.connect();
      const convoId = 'mls-convo-churn';
      notifier.seed(Conversation(
        id: convoId,
        peerUsername: _peerUsername,
        peerAccountId: _peerAccountId,
        peerDeviceId: 'aaa-dev',
        peerIdentityPubKey: const [9, 8, 7],
        peerX25519PubKey: const [1, 2, 3],
        messages: const [],
        unreadCount: 0,
        cryptoMode: CryptoMode.mls,
      ));
      // Permanently undecryptable — sealed to a group/epoch we don't hold.
      crypto.decryptAndInspectError =
          const MlsUnknownGroupException("Couldn't find conversation");

      // Same envelope redelivered 4× (under the cap of 5) → NOT acked yet.
      for (var i = 0; i < 4; i++) {
        ws.push(_envelope(
            conversationId: convoId,
            senderDeviceId: 'aaa-dev',
            envelopeId: 'poison-app'));
        await pumpEventQueue();
      }
      verifyNever(() => api.ackMessages(['poison-app']));
      // It really was attempted + failed each time (not short-circuited).
      expect(crypto.decryptAndInspectCalls, equals(4));

      // 5th delivery hits the cap → ack+drop so it stops redelivering forever.
      ws.push(_envelope(
          conversationId: convoId,
          senderDeviceId: 'aaa-dev',
          envelopeId: 'poison-app'));
      await pumpEventQueue();
      verify(() => api.ackMessages(['poison-app'])).called(1);
    });

    // Restore case: we have NO local group (CoreCrypto store wiped) but the
    // peer keeps sending MLS under the old group. The "ratchet-mode, no
    // group" drop path must ALSO drive re-establishment so future messages
    // decrypt — not just the diverged-group decrypt path.
    test('no_local_group_after_restore_triggers_reestablishment', () async {
      final convoId =
          await seedRatchetConvo(); // ratchet, peerDeviceId 'peer-dev' > 'me-dev'
      // currentEpoch throws → we hold no group for this convo.
      crypto.currentEpochError = const MlsUnknownGroupException('no group');
      when(() => api.lookupKeyPackage(any())).thenAnswer(
        (_) async => FetchKeyPackageResult(
          keyPackage: List<int>.filled(64, 0xBB),
          replenishNeeded: false,
          remainingForUser: 9,
        ),
      );
      final submittedTypes = <String>[];
      when(() => api.submitMessage(any())).thenAnswer((inv) async {
        final p = inv.positionalArguments.first as SubmitMessagePayload;
        submittedTypes.add(p.envelopeType);
        return SubmitMessageResult(
            envelopeId: 'srv', serverTs: DateTime.utc(2026));
      });

      for (final id in ['x', 'y', 'z']) {
        ws.push(_envelope(
            conversationId: convoId, senderDeviceId: 'peer-dev', envelopeId: id));
        await pumpEventQueue();
      }
      await pumpEventQueue(times: 100);

      // Re-migrated: a fresh Welcome went to the peer.
      expect(submittedTypes, contains(EnvelopeType.mlsWelcome));
    });

    Future<List<String>> followerLosesItsGroup() async {
      await sessions.save(session);
      await notifier.connect();
      // The peer's account id sorts BEFORE ours, so we are the follower.
      when(() => api.lookupAccount(_peerUsername)).thenAnswer((_) async =>
          const Account(
            accountId: 'aaa-acc',
            username: _peerUsername,
            identityPubKey: [9, 8, 7],
            x25519PubKey: [1, 2, 3],
            deviceId: 'peer-dev',
          ));
      final convoId = await notifier.startConversation(
        myDeviceId: _myDeviceId,
        username: _peerUsername,
      );
      crypto.currentEpochError = const MlsUnknownGroupException('no group');
      when(() => api.lookupKeyPackage(any())).thenAnswer(
        (_) async => FetchKeyPackageResult(
          keyPackage: List<int>.filled(64, 0xBB),
          replenishNeeded: false,
          remainingForUser: 9,
        ),
      );
      final submittedTypes = <String>[];
      when(() => api.submitMessage(any())).thenAnswer((inv) async {
        submittedTypes.add(
            (inv.positionalArguments.first as SubmitMessagePayload).envelopeType);
        return SubmitMessageResult(
            envelopeId: 'srv', serverTs: DateTime.utc(2026));
      });
      ws.push(_envelope(
          conversationId: convoId,
          senderDeviceId: 'peer-dev',
          envelopeId: 'follower-1'));
      // The follower first gives the leader a grace window to rebuild.
      await Future<void>.delayed(const Duration(seconds: 8));
      await pumpEventQueue(times: 100);
      return submittedTypes;
    }

    test('a follower that lost its group does not build a group of its own',
        () async {
      final submittedTypes = await followerLosesItsGroup();

      expect(submittedTypes, isNot(contains(EnvelopeType.mlsWelcome)));
    });

    test('a follower that lost its group tells the leader over ratchet',
        () async {
      final submittedTypes = await followerLosesItsGroup();

      expect(submittedTypes, contains(EnvelopeType.textLegacy));
    });

    // Regression, measured on-device 2026-08-20: the peer deleted the thread
    // and re-accepted it as a ratchet-mode request while we kept sending MLS,
    // so every message we sent was undecryptable there. Making that wait for a
    // THIRD failure left the 1:1 one-way dead for ~10 minutes and silently lost
    // three messages — recovering only once both apps were restarted. "We hold
    // no group" is definitive evidence, not a noisy signal, so ONE is enough.
    test('a single no-group failure re-establishes without awaiting a streak',
        () async {
      final convoId =
          await seedRatchetConvo(); // peerDeviceId 'peer-dev' > 'me-dev'
      // currentEpoch throws → we hold no group for this convo.
      crypto.currentEpochError = const MlsUnknownGroupException('no group');
      when(() => api.lookupKeyPackage(any())).thenAnswer(
        (_) async => FetchKeyPackageResult(
          keyPackage: List<int>.filled(64, 0xBB),
          replenishNeeded: false,
          remainingForUser: 9,
        ),
      );
      final submittedTypes = <String>[];
      when(() => api.submitMessage(any())).thenAnswer((inv) async {
        submittedTypes.add(
            (inv.positionalArguments.first as SubmitMessagePayload).envelopeType);
        return SubmitMessageResult(
            envelopeId: 'srv', serverTs: DateTime.utc(2026));
      });

      // ONE undecryptable envelope — not three.
      ws.push(_envelope(
          conversationId: convoId,
          senderDeviceId: 'peer-dev',
          envelopeId: 'only-one'));
      await pumpEventQueue(times: 100);

      expect(submittedTypes, contains(EnvelopeType.mlsWelcome));
    });

    // The MIRROR of the case above, and the other half of the same outage. A
    // peer stranded without our group falls back to the v1 ratchet, so its
    // messages arrive as text_legacy for a 1:1 we still hold as MLS. That was
    // dropped on the floor — never decrypted, never acked (so it redelivered
    // forever), and nothing re-established. Measured on-device 2026-08-20:
    // ratchet envelopes to an MLS-mode peer were acked 0 times out of 12.
    test('a ratchet message for an mls-mode 1:1 re-establishes the group',
        () async {
      await sessions.save(session);
      await notifier.connect();
      final convoId = seedMlsConvo(); // peerDeviceId 'peer-dev' > 'me-dev'
      when(() => api.lookupKeyPackage(any())).thenAnswer(
        (_) async => FetchKeyPackageResult(
          keyPackage: List<int>.filled(64, 0xBB),
          replenishNeeded: false,
          remainingForUser: 9,
        ),
      );
      final submittedTypes = <String>[];
      when(() => api.submitMessage(any())).thenAnswer((inv) async {
        submittedTypes.add(
            (inv.positionalArguments.first as SubmitMessagePayload).envelopeType);
        return SubmitMessageResult(
            envelopeId: 'srv', serverTs: DateTime.utc(2026));
      });

      ws.push(_envelope(
          conversationId: convoId,
          senderDeviceId: 'peer-dev',
          envelopeType: EnvelopeType.textLegacy,
          envelopeId: 'legacy-1'));
      await pumpEventQueue(times: 100);

      expect(submittedTypes, contains(EnvelopeType.mlsWelcome));
    });

    // ...and one we can't open must NOT be acked: it stays on the server for a
    // later redelivery (bounded by the catchup backstop). A ratchet message we
    // CAN open is delivered on the spot — see the "first message of a new
    // contact" group.
    test('an undecryptable ratchet message for an mls-mode 1:1 is left unacked',
        () async {
      // Counter-aware crypto: counter 5 never opens on a fresh chain.
      crypto = _CounterCrypto();
      notifier = buildNotifier();
      when(() => api.ackMessages(any())).thenAnswer((_) async => 1);
      await sessions.save(session);
      await notifier.connect();
      final convoId = seedMlsConvo();
      when(() => api.lookupKeyPackage(any())).thenAnswer(
        (_) async => FetchKeyPackageResult(
          keyPackage: List<int>.filled(64, 0xBB),
          replenishNeeded: false,
          remainingForUser: 9,
        ),
      );

      ws.push(_envelope(
          conversationId: convoId,
          senderDeviceId: 'peer-dev',
          envelopeType: EnvelopeType.textLegacy,
          envelopeId: 'legacy-keep',
          ciphertext: [5, ...utf8.encode('x')]));
      await pumpEventQueue(times: 100);

      verifyNever(() => api.ackMessages(['legacy-keep']));
    });

    // The LEADER half of the same standoff. We are 'me-acc' < 'peer-acc', so we
    // keep our own group and DISCARD the peer's rebuild Welcome. If we then
    // cannot decrypt them, those two facts together prove the group we kept is
    // the broken one — one failure is enough, and waiting for the streak is
    // what left the leader stalled on-device 2026-08-20 while the peer's
    // cooldown withheld the second Welcome that would have made it yield.
    test('a decrypt failure after discarding their Welcome re-establishes at once',
        () async {
      when(() => api.ackMessages(any())).thenAnswer((_) async => 1);
      await sessions.save(session);
      await notifier.connect();
      final convoId = seedMlsConvo(); // peerDeviceId 'peer-dev' > 'me-dev'
      when(() => api.lookupKeyPackage(any())).thenAnswer(
        (_) async => FetchKeyPackageResult(
          keyPackage: List<int>.filled(64, 0xBB),
          replenishNeeded: false,
          remainingForUser: 9,
        ),
      );
      final submittedTypes = <String>[];
      when(() => api.submitMessage(any())).thenAnswer((inv) async {
        submittedTypes.add(
            (inv.positionalArguments.first as SubmitMessagePayload).envelopeType);
        return SubmitMessageResult(
            envelopeId: 'srv', serverTs: DateTime.utc(2026));
      });

      // Their rebuild Welcome — as the leader we keep our group and discard it.
      ws.push(_envelope(
        conversationId: convoId,
        senderDeviceId: 'peer-dev',
        envelopeType: EnvelopeType.mlsWelcome,
        envelopeId: 'their-rebuild',
      ));
      await pumpEventQueue(times: 20);
      expect(submittedTypes, isEmpty, reason: 'the leader keeps its own group');

      // Now a SINGLE undecryptable message from them — sealed to the group we
      // just refused. One is enough.
      crypto.decryptAndInspectError =
          const MlsArgumentException('cannot decrypt');
      ws.push(_envelope(
          conversationId: convoId,
          senderDeviceId: 'peer-dev',
          envelopeId: 'one-failure'));
      await pumpEventQueue(times: 100);

      expect(submittedTypes, contains(EnvelopeType.mlsWelcome));
    });

    // Proactive heal on connect: a restored client holds NO group for an
    // MLS-mode 1:1. reconcile (run during connect) must kick off
    // re-establishment immediately — WITHOUT waiting for the peer's messages
    // to fail to decrypt 3× — so a fresh Welcome reaches the peer before any
    // of their messages are lost.
    test('reconcile proactively re-establishes a 1:1 we hold no group for',
        () async {
      await sessions.save(session);
      await notifier.connect();
      // mls-mode, peerDeviceId 'peer-dev' > 'me-dev' → we're the lower id, so
      // we re-establish at once (no grace wait). reconcile iterates all convos,
      // so we don't need the id here.
      seedMlsConvo();
      // currentEpoch throws → CoreCrypto holds no group (post-restore wipe).
      crypto.currentEpochError = const MlsUnknownGroupException('no group');
      when(() => api.lookupKeyPackage(any())).thenAnswer(
        (_) async => FetchKeyPackageResult(
          keyPackage: List<int>.filled(64, 0xBB),
          replenishNeeded: false,
          remainingForUser: 9,
        ),
      );
      final submittedTypes = <String>[];
      when(() => api.submitMessage(any())).thenAnswer((inv) async {
        submittedTypes.add(
            (inv.positionalArguments.first as SubmitMessagePayload).envelopeType);
        return SubmitMessageResult(
            envelopeId: 'srv', serverTs: DateTime.utc(2026));
      });

      // No inbound messages at all — the heal is driven purely by reconcile.
      await notifier.reconcileMlsConversations();
      await pumpEventQueue(times: 100);

      expect(crypto.wipeGroupCalls, greaterThanOrEqualTo(1));
      expect(submittedTypes, contains(EnvelopeType.mlsWelcome));
    });

    // First contact: the first app message can fail a few times before its
    // Welcome lands. A Welcome must clear the failure streak so we don't
    // re-establish (which would re-key away that first message).
    test('a_welcome_clears_the_decrypt_failure_streak', () async {
      await sessions.save(session);
      await notifier.connect();
      final convoId = await seedRatchetConvo();
      crypto.currentEpochError = const MlsUnknownGroupException('no group yet');
      final submittedTypes = <String>[];
      when(() => api.submitMessage(any())).thenAnswer((inv) async {
        submittedTypes.add(
            (inv.positionalArguments.first as SubmitMessagePayload).envelopeType);
        return SubmitMessageResult(
            envelopeId: 'srv', serverTs: DateTime.utc(2026));
      });

      // Two app failures (the Welcome is still in flight).
      ws.push(_envelope(
          conversationId: convoId, senderDeviceId: 'peer-dev', envelopeId: 'a'));
      ws.push(_envelope(
          conversationId: convoId, senderDeviceId: 'peer-dev', envelopeId: 'b'));
      await pumpEventQueue();
      // The Welcome lands → group established, streak reset to 0.
      ws.push(_envelope(
          conversationId: convoId,
          senderDeviceId: 'peer-dev',
          envelopeType: EnvelopeType.mlsWelcome,
          envelopeId: 'w'));
      await pumpEventQueue();
      // One more failure — but the streak restarted at the Welcome, so it's
      // failure #1, well below the threshold → NO re-establishment.
      crypto.decryptAndInspectError =
          const MlsArgumentException('still settling');
      ws.push(_envelope(
          conversationId: convoId, senderDeviceId: 'peer-dev', envelopeId: 'c'));
      await pumpEventQueue(times: 50);

      expect(submittedTypes, isNot(contains(EnvelopeType.mlsWelcome)));
    });

    test('inbound_mls_welcome_UnknownConvo_CreatesPlaceholderMls', () async {
      await sessions.save(session);
      await notifier.connect();

      ws.push(_envelope(
        conversationId: 'brand-new-convo',
        envelopeType: EnvelopeType.mlsWelcome,
        ciphertext: const [1, 2, 3],
      ));
      await pumpEventQueue();

      final convo = notifier.byId('brand-new-convo');
      expect(convo, isNotNull);
      expect(convo!.cryptoMode, equals(CryptoMode.mls));
      expect(convo.peerUsername, equals('unknown'));

      // Persisted.
      final loaded = await db.loadConversations();
      expect(loaded.where((c) => c.id == 'brand-new-convo').length, equals(1));
    });

    test('inbound_mls_application_MlsConvo_DecryptsAndAppends', () async {
      await sessions.save(session);
      await notifier.connect();
      final convoId = seedMlsConvo();
      when(() => api.ackMessages(any())).thenAnswer((_) async => 1);

      // _PassthroughCrypto.decrypt returns ciphertext unchanged, so
      // sending the UTF-8 bytes of 'hello' will decode back to 'hello'.
      ws.push(_envelope(
        conversationId: convoId,
        envelopeType: EnvelopeType.mlsApplication,
        ciphertext: 'hello'.codeUnits,
      ));
      await pumpEventQueue();

      final convo = notifier.byId(convoId)!;
      expect(convo.messages.length, equals(1));
      expect(convo.messages.single.body, equals('hello'));
      expect(convo.unreadCount, equals(1));
      verify(() => api.ackMessages(any())).called(1);
    });

    test('inbound_mls_application_RatchetConvo_DropsSilently', () async {
      final convoId = await seedRatchetConvo();
      expect(notifier.byId(convoId)!.cryptoMode, equals(CryptoMode.ratchet));
      // No CoreCrypto group for this conversation — without it the envelope
      // is undecryptable and must drop. (When a group DOES survive — e.g. a
      // rejected request coming back — the convo flips to MLS instead; see
      // the message-requests group.)
      crypto.currentEpochError = Exception('no group');

      ws.push(_envelope(
        conversationId: convoId,
        envelopeType: EnvelopeType.mlsApplication,
        ciphertext: 'hello'.codeUnits,
      ));
      await pumpEventQueue();

      // No message appended.
      expect(notifier.byId(convoId)!.messages, isEmpty);
      // No ack.
      verifyNever(() => api.ackMessages(any()));
    });

    test('inbound_mls_handshake_MlsConvo_AdvancesGroupState', () async {
      await sessions.save(session);
      await notifier.connect();
      final convoId = seedMlsConvo();

      ws.push(_envelope(
        conversationId: convoId,
        envelopeType: EnvelopeType.mlsHandshake,
        ciphertext: const [0xAB, 0xCD],
      ));
      await pumpEventQueue();

      // Handshake messages don't produce a visible message.
      expect(notifier.byId(convoId)!.messages, isEmpty);
      // The bridge's decryptAndInspect was called to advance group state.
      expect(crypto.decryptAndInspectCalls, equals(1));
    });

    test('inbound_text_legacy_RatchetConvo_GoesThroughLegacyPath', () async {
      final convoId = await seedRatchetConvo();
      when(() => api.ackMessages(any())).thenAnswer((_) async => 1);

      ws.push(_envelope(
        conversationId: convoId,
        envelopeType: EnvelopeType.textLegacy,
        ciphertext: 'legacy msg'.codeUnits,
      ));
      await pumpEventQueue();

      final convo = notifier.byId(convoId)!;
      expect(convo.messages.length, equals(1));
      expect(convo.messages.single.body, equals('legacy msg'));
      expect(crypto.decryptCalls, greaterThanOrEqualTo(1));
    });

    test('inbound_text_legacy_MlsConvo_Undecryptable_DropsSilently', () async {
      // Counter-aware crypto: this ciphertext doesn't open on a fresh chain.
      crypto = _CounterCrypto();
      notifier = buildNotifier();
      await sessions.save(session);
      await notifier.connect();
      final convoId = seedMlsConvo();

      ws.push(_envelope(
        conversationId: convoId,
        envelopeType: EnvelopeType.textLegacy,
        ciphertext: 'legacy from old sender'.codeUnits,
      ));
      await pumpEventQueue();

      // No message appended (it doesn't open) and not acked.
      expect(notifier.byId(convoId)!.messages, isEmpty);
      verifyNever(() => api.ackMessages(any()));
    });
  });

  group('markRead', () {
    test('zeros the unread count on an existing conversation and persists', () async {
      await db.open(masterKeyHex: 'k');
      final seeded = Conversation(
        id: 'c',
        peerUsername: 'p',
        peerAccountId: 'pa',
        peerDeviceId: 'pd',
        peerIdentityPubKey: const [],
        messages: const [],
        unreadCount: 3,
      );
      notifier.seed(seeded);
      await db.upsertConversation(seeded);

      notifier.markRead('c');
      expect(notifier.byId('c')!.unreadCount, equals(0));

      // Persisted (unawaited future drains via pumpEventQueue).
      await pumpEventQueue();
      final loaded = await db.loadConversations();
      expect(loaded.firstWhere((c) => c.id == 'c').unreadCount, equals(0));
    });

    test('is a no-op when conversation is unknown', () {
      notifier.markRead('missing');
      expect(notifier.byId('missing'), isNull);
    });

    test('is a no-op when count is already zero', () {
      notifier.seed(Conversation(
        id: 'c',
        peerUsername: 'p',
        peerAccountId: 'pa',
        peerDeviceId: 'pd',
        peerIdentityPubKey: const [],
        messages: const [],
        unreadCount: 0,
      ));
      notifier.markRead('c');
      expect(notifier.byId('c')!.unreadCount, equals(0));
    });

    test('does NOT send a read receipt when the user opted out', () async {
      notifier = buildNotifier(readReceiptsEnabled: () => false);
      await sessions.save(session);
      await notifier.connect();
      when(() => api.lookupAccount(_peerUsername))
          .thenAnswer((_) async => _peerAccount());
      final convoId = await notifier.startConversation(
        myDeviceId: _myDeviceId,
        username: _peerUsername,
      );
      // Inbound message → unread, with an envelope id a read receipt would
      // reference. (Its delivered-receipt is cleared below.)
      ws.push(_envelope(
        conversationId: convoId,
        senderDeviceId: 'peer-dev',
        envelopeId: 'in-1',
        envelopeType: EnvelopeType.textLegacy,
      ));
      await pumpEventQueue();
      clearInteractions(api);

      notifier.markRead(convoId);
      await pumpEventQueue();

      // Read receipts off → opening the thread emits nothing to the sender.
      verifyNever(() => api.submitMessage(any()));
    });

    test('DOES send a read receipt by default (receipts on)', () async {
      await sessions.save(session);
      await notifier.connect();
      when(() => api.lookupAccount(_peerUsername))
          .thenAnswer((_) async => _peerAccount());
      final convoId = await notifier.startConversation(
        myDeviceId: _myDeviceId,
        username: _peerUsername,
      );
      ws.push(_envelope(
        conversationId: convoId,
        senderDeviceId: 'peer-dev',
        envelopeId: 'in-1',
        envelopeType: EnvelopeType.textLegacy,
      ));
      await pumpEventQueue();
      clearInteractions(api);

      notifier.markRead(convoId);
      await pumpEventQueue();

      verify(() => api.submitMessage(any())).called(greaterThanOrEqualTo(1));
    });
  });

  group('sendImage', () {
    Future<String> seedImgConvo() async {
      await sessions.save(session);
      await notifier.connect();
      when(() => api.lookupAccount(_peerUsername))
          .thenAnswer((_) async => _peerAccount());
      return notifier.startConversation(
        myDeviceId: _myDeviceId,
        username: _peerUsername,
      );
    }

    test('uploads, sends a descriptor message, caches bytes for the bubble', () async {
      final convoId = await seedImgConvo();
      when(() => api.submitMessage(any())).thenAnswer((_) async =>
          SubmitMessageResult(envelopeId: 'env-img', serverTs: DateTime.utc(2026, 5, 9)));

      final imageBytes = List<int>.generate(20, (i) => i);
      await notifier.sendImage(
        conversationId: convoId,
        myDeviceId: _myDeviceId,
        imageBytes: imageBytes,
        mimeType: 'image/jpeg',
        caption: 'lake',
      );
      await notifier.waitForUploads(convoId);

      final m = notifier.byId(convoId)!.messages.single;
      expect(m.envelopeId, equals('env-img'));
      expect(m.kind.name, equals('image'));
      expect(m.body, equals('lake'));
      expect(m.mediaMime, equals('image/jpeg'));
      expect(m.mediaSize, equals(imageBytes.length));
      expect(m.uploading, isFalse);
      expect(await notifier.mediaBytesFor(m), equals(imageBytes));
    });

    test('throws StateError when conversation is missing', () async {
      expect(
        () => notifier.sendImage(
          conversationId: 'unknown',
          myDeviceId: _myDeviceId,
          imageBytes: const [1, 2, 3],
          mimeType: 'image/jpeg',
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('marks the message as failed when submitMessage throws', () async {
      final convoId = await seedImgConvo();
      when(() => api.submitMessage(any())).thenThrow(Exception('network down'));

      await notifier.sendImage(
        conversationId: convoId,
        myDeviceId: _myDeviceId,
        imageBytes: const [1, 2, 3],
        mimeType: 'image/jpeg',
        caption: 'fail caption',
      );
      await notifier.waitForUploads(convoId);

      final m = notifier.byId(convoId)!.messages.single;
      expect(m.failed, isTrue);
      expect(m.uploading, isFalse);
      expect(m.body, equals('fail caption'),
          reason: 'caption stays intact — failure is signalled via the failed flag');
      expect(m.kind.name, equals('image'));
    });

    test('mediaBytesFor returns null for text messages', () async {
      final m = ChatMessage(
        envelopeId: 'e',
        conversationId: 'c',
        senderDeviceId: 's',
        body: 'hi',
        serverTs: DateTime.utc(2026, 5, 9),
        mine: false,
      );
      expect(await notifier.mediaBytesFor(m), isNull);
    });

    test('with empty caption, wire body is descriptor only (no separator)', () async {
      final convoId = await seedImgConvo();
      when(() => api.submitMessage(any())).thenAnswer((_) async =>
          SubmitMessageResult(envelopeId: 'env-empty-cap', serverTs: DateTime.utc(2026, 5, 9)));

      await notifier.sendImage(
        conversationId: convoId,
        myDeviceId: _myDeviceId,
        imageBytes: const [9, 9, 9],
        mimeType: 'image/jpeg',
        // caption defaults to ''
      );
      await notifier.waitForUploads(convoId);

      final captured = verify(() => api.submitMessage(captureAny())).captured.single
          as SubmitMessagePayload;
      final wire = _stripCid(captured.ciphertext);
      expect(wire.contains('\n'), isFalse);
      expect(wire.startsWith('{"k":"image"'), isTrue);
    });

    test('marks message failed on legacy conversation with no peer X25519 key', () async {
      // Seed directly so peerX25519PubKey is empty — no init-crypto path.
      notifier.seed(Conversation(
        id: 'legacy-img',
        peerUsername: 'old-peer',
        peerAccountId: 'old',
        peerDeviceId: 'old-d',
        peerIdentityPubKey: const [],
        messages: const [],
        unreadCount: 0,
      ));

      await notifier.sendImage(
        conversationId: 'legacy-img',
        myDeviceId: _myDeviceId,
        imageBytes: const [1, 2, 3],
        mimeType: 'image/jpeg',
      );
      await notifier.waitForUploads('legacy-img');

      final m = notifier.byId('legacy-img')!.messages.single;
      expect(m.failed, isTrue);
      expect(m.uploading, isFalse);
    });
  });

  group('sendFile', () {
    Future<String> seedFileConvo() async {
      await sessions.save(session);
      await notifier.connect();
      when(() => api.lookupAccount(_peerUsername))
          .thenAnswer((_) async => _peerAccount());
      return notifier.startConversation(
        myDeviceId: _myDeviceId,
        username: _peerUsername,
      );
    }

    test('uploads file bytes + appends message with kind=file + mediaFilename', () async {
      final convoId = await seedFileConvo();
      when(() => api.submitMessage(any())).thenAnswer((_) async =>
          SubmitMessageResult(envelopeId: 'env-file', serverTs: DateTime.utc(2026, 5, 18)));

      await notifier.sendFile(
        conversationId: convoId,
        myDeviceId: _myDeviceId,
        fileBytes: const [9, 9, 9],
        mimeType: 'application/pdf',
        filename: 'spec.pdf',
      );
      await notifier.waitForUploads(convoId);

      final m = notifier.byId(convoId)!.messages.single;
      expect(m.kind, MessageKind.file);
      expect(m.mediaFilename, 'spec.pdf');
      expect(m.mediaMime, 'application/pdf');
      expect(m.mediaSize, 3);
      expect(m.uploading, isFalse);
    });

    test('a caption is kept on the sent file message', () async {
      final convoId = await seedFileConvo();
      when(() => api.submitMessage(any())).thenAnswer((_) async =>
          SubmitMessageResult(envelopeId: 'env-file2', serverTs: DateTime.utc(2026, 5, 18)));

      await notifier.sendFile(
        conversationId: convoId,
        myDeviceId: _myDeviceId,
        fileBytes: const [9, 9, 9],
        mimeType: 'application/pdf',
        filename: 'spec.pdf',
        caption: 'here is the spec',
      );
      await notifier.waitForUploads(convoId);

      expect(notifier.byId(convoId)!.messages.single.body, 'here is the spec');
    });

    test('throws StateError when conversation is missing', () async {
      expect(
        () => notifier.sendFile(
          conversationId: 'no-such-convo',
          myDeviceId: _myDeviceId,
          fileBytes: const [0],
          mimeType: 'application/octet-stream',
          filename: 'x.bin',
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('sendVideo', () {
    Future<String> seedVideoConvo() async {
      await sessions.save(session);
      await notifier.connect();
      when(() => api.lookupAccount(_peerUsername))
          .thenAnswer((_) async => _peerAccount());
      return notifier.startConversation(
        myDeviceId: _myDeviceId,
        username: _peerUsername,
      );
    }

    test('uploads video bytes + appends message with kind=video + caption', () async {
      final convoId = await seedVideoConvo();
      when(() => api.submitMessage(any())).thenAnswer((_) async =>
          SubmitMessageResult(envelopeId: 'env-vid', serverTs: DateTime.utc(2026, 5, 18)));

      await notifier.sendVideo(
        conversationId: convoId,
        myDeviceId: _myDeviceId,
        videoBytes: const [7, 7, 7, 7],
        mimeType: 'video/mp4',
        caption: 'check this out',
      );
      await notifier.waitForUploads(convoId);

      final m = notifier.byId(convoId)!.messages.single;
      expect(m.kind, MessageKind.video);
      expect(m.body, 'check this out');
      expect(m.mediaSize, 4);
      expect(m.mediaMime, 'video/mp4');
      expect(m.uploading, isFalse);
    });

    test('with empty caption stores empty body + descriptor-only wire body', () async {
      final convoId = await seedVideoConvo();
      when(() => api.submitMessage(any())).thenAnswer((_) async =>
          SubmitMessageResult(envelopeId: 'env-vid-2', serverTs: DateTime.utc(2026, 5, 18)));

      await notifier.sendVideo(
        conversationId: convoId,
        myDeviceId: _myDeviceId,
        videoBytes: const [0],
        mimeType: 'video/mp4',
      );
      await notifier.waitForUploads(convoId);

      expect(notifier.byId(convoId)!.messages.single.body, '');
      final captured = verify(() => api.submitMessage(captureAny())).captured.single
          as SubmitMessagePayload;
      final wire = _stripCid(captured.ciphertext);
      expect(wire.contains('\n'), isFalse);
      expect(wire.startsWith('{"k":"video"'), isTrue);
    });
  });

  group('sendVoice', () {
    Future<String> seedVoiceConvo() async {
      await sessions.save(session);
      await notifier.connect();
      when(() => api.lookupAccount(_peerUsername))
          .thenAnswer((_) async => _peerAccount());
      return notifier.startConversation(
        myDeviceId: _myDeviceId,
        username: _peerUsername,
      );
    }

    test('uploads voice bytes + appends message with kind=voice + audio/mp4 mime', () async {
      final convoId = await seedVoiceConvo();
      when(() => api.submitMessage(any())).thenAnswer((_) async =>
          SubmitMessageResult(envelopeId: 'env-voice', serverTs: DateTime.utc(2026, 5, 18)));

      await notifier.sendVoice(
        conversationId: convoId,
        myDeviceId: _myDeviceId,
        voiceBytes: const [4, 4, 4, 4, 4],
      );
      await notifier.waitForUploads(convoId);

      final m = notifier.byId(convoId)!.messages.single;
      expect(m.kind, MessageKind.voice);
      expect(m.body, '');
      expect(m.mediaSize, 5);
      expect(m.mediaMime, 'audio/mp4');
      expect(m.uploading, isFalse);
    });

    test('throws StateError when conversation is missing', () async {
      expect(
        () => notifier.sendVoice(
          conversationId: 'no-such-convo',
          myDeviceId: _myDeviceId,
          voiceBytes: const [0],
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('inbound media descriptor', () {
    test('_onEnvelope parses a descriptor body into an image-kind message', () async {
      await sessions.save(session);
      await notifier.connect();
      when(() => api.lookupAccount(_peerUsername))
          .thenAnswer((_) async => _peerAccount());
      final convoId = await notifier.startConversation(
        myDeviceId: _myDeviceId,
        username: _peerUsername,
      );
      when(() => api.ackMessages(any())).thenAnswer((_) async => 1);

      final imgBytes = List<int>.generate(8, (i) => i + 50);
      final descriptor = await media.upload(
        kind: MessageKind.image,
        plaintext: imgBytes,
        mimeType: 'image/png',
      );
      final wireBody = '${descriptor.toJson()}\nbeach photo';
      ws.push(_envelope(
        envelopeId: 'env-img-rx',
        conversationId: convoId,
        senderDeviceId: 'peer-dev',
        envelopeType: EnvelopeType.textLegacy,
        ciphertext: wireBody.codeUnits,
      ));
      await pumpEventQueue();

      final m = notifier.byId(convoId)!.messages.single;
      expect(m.kind.name, equals('image'));
      expect(m.body, equals('beach photo'));
      expect(m.mediaId, equals(descriptor.mediaId));
      expect(m.mediaSize, equals(imgBytes.length));
      expect(await notifier.mediaBytesFor(m), equals(imgBytes));
    });

    test('descriptor without caption parses with empty body', () async {
      await sessions.save(session);
      await notifier.connect();
      when(() => api.lookupAccount(_peerUsername))
          .thenAnswer((_) async => _peerAccount());
      final convoId = await notifier.startConversation(
        myDeviceId: _myDeviceId,
        username: _peerUsername,
      );
      when(() => api.ackMessages(any())).thenAnswer((_) async => 1);

      final descriptor = await media.upload(
        kind: MessageKind.image,
        plaintext: const [1, 2, 3],
        mimeType: 'image/jpeg',
      );
      ws.push(_envelope(
        envelopeId: 'env-img-nocap',
        conversationId: convoId,
        senderDeviceId: 'peer-dev',
        envelopeType: EnvelopeType.textLegacy,
        ciphertext: descriptor.toJson().codeUnits,
      ));
      await pumpEventQueue();

      final m = notifier.byId(convoId)!.messages.single;
      expect(m.kind.name, equals('image'));
      expect(m.body, equals(''));
    });

    test('malformed descriptor falls back to text rendering', () async {
      await sessions.save(session);
      await notifier.connect();
      when(() => api.lookupAccount(_peerUsername))
          .thenAnswer((_) async => _peerAccount());
      final convoId = await notifier.startConversation(
        myDeviceId: _myDeviceId,
        username: _peerUsername,
      );
      when(() => api.ackMessages(any())).thenAnswer((_) async => 1);

      const bogus = '{"k":"image"-not-json';
      ws.push(_envelope(
        envelopeId: 'env-bogus',
        conversationId: convoId,
        senderDeviceId: 'peer-dev',
        envelopeType: EnvelopeType.textLegacy,
        ciphertext: bogus.codeUnits,
      ));
      await pumpEventQueue();

      final m = notifier.byId(convoId)!.messages.single;
      expect(m.kind.name, equals('text'));
      expect(m.body, equals(bogus));
    });
  });

  group('inbound system event', () {
    test('inbound message with _system payload becomes kind=system ChatMessage', () async {
      await sessions.save(session);
      await notifier.connect();
      when(() => api.lookupAccount(_peerUsername))
          .thenAnswer((_) async => _peerAccount());
      final convoId = await notifier.startConversation(
        myDeviceId: _myDeviceId,
        username: _peerUsername,
      );
      when(() => api.ackMessages(any())).thenAnswer((_) async => 1);

      const systemJson =
          '{"_system":"member_joined","account_id":"acc-1","username":"@lin","epoch":13}';
      ws.push(_envelope(
        envelopeId: 'env-sys-1',
        conversationId: convoId,
        senderDeviceId: 'peer-dev',
        envelopeType: EnvelopeType.textLegacy,
        ciphertext: systemJson.codeUnits,
      ));
      await pumpEventQueue();

      final m = notifier.byId(convoId)!.messages.single;
      expect(m.kind, equals(MessageKind.system));
      expect(m.body, equals(systemJson));
    });

    test('inbound message with plain text stays kind=text', () async {
      await sessions.save(session);
      await notifier.connect();
      when(() => api.lookupAccount(_peerUsername))
          .thenAnswer((_) async => _peerAccount());
      final convoId = await notifier.startConversation(
        myDeviceId: _myDeviceId,
        username: _peerUsername,
      );
      when(() => api.ackMessages(any())).thenAnswer((_) async => 1);

      const plaintext = 'hello world';
      ws.push(_envelope(
        envelopeId: 'env-text-1',
        conversationId: convoId,
        senderDeviceId: 'peer-dev',
        envelopeType: EnvelopeType.textLegacy,
        ciphertext: plaintext.codeUnits,
      ));
      await pumpEventQueue();

      final m = notifier.byId(convoId)!.messages.single;
      expect(m.kind, equals(MessageKind.text));
      expect(m.body, equals(plaintext));
    });

    test('a resend with the same client id is deduplicated to one message',
        () async {
      await sessions.save(session);
      await notifier.connect();
      when(() => api.lookupAccount(_peerUsername))
          .thenAnswer((_) async => _peerAccount());
      final convoId = await notifier.startConversation(
        myDeviceId: _myDeviceId,
        username: _peerUsername,
      );
      when(() => api.ackMessages(any())).thenAnswer((_) async => 1);

      // Two envelopes (distinct server ids) carrying the SAME `_cid` header from
      // the same sender device — an original and its lost-ack resend. The fake
      // crypto echoes ciphertext→plaintext.
      const wire = '{"_cid":"outbox-1"}\nhello world';
      ws.push(_envelope(
        envelopeId: 'env-orig',
        conversationId: convoId,
        senderDeviceId: 'peer-dev',
        envelopeType: EnvelopeType.textLegacy,
        ciphertext: wire.codeUnits,
      ));
      await pumpEventQueue();
      ws.push(_envelope(
        envelopeId: 'env-resend',
        conversationId: convoId,
        senderDeviceId: 'peer-dev',
        envelopeType: EnvelopeType.textLegacy,
        ciphertext: wire.codeUnits,
      ));
      await pumpEventQueue();

      final msgs = notifier.byId(convoId)!.messages;
      expect(msgs.length, equals(1),
          reason: 'the resend must not render a second bubble');
      expect(msgs.single.body, equals('hello world'),
          reason: 'the `_cid` header is stripped from the rendered body');
      expect(msgs.single.clientMsgId, equals('outbox-1'));
    });

    group('at-least-once delivery', () {
      // The peer's account sorts BEFORE ours: we are the follower and adopt.
      const followerPeerAccount = 'aaa-acc';
      const convoId = '1to1:aaa-acc:me-acc';
      // The peer's account sorts AFTER ours: we are the leader and rebuild.
      const leaderPeerAccount = 'zzz-acc';
      const leaderConvoId = '1to1:me-acc:zzz-acc';

      Future<void> seedMlsChat({
        List<ChatMessage> messages = const [],
        String id = convoId,
        String peerAccountId = followerPeerAccount,
      }) async {
        await sessions.save(session);
        await notifier.connect();
        when(() => api.ackMessages(any())).thenAnswer((_) async => 1);
        when(() => api.lookupAccount(_peerUsername))
            .thenAnswer((_) async => _peerAccount());
        when(() => api.submitMessage(any())).thenAnswer((_) async =>
            SubmitMessageResult(
                envelopeId: 'srv-env', serverTs: DateTime.utc(2026)));
        notifier.resendSettleDelay = Duration.zero;
        notifier.seed(Conversation(
          id: id,
          peerUsername: _peerUsername,
          peerAccountId: peerAccountId,
          peerDeviceId: 'peer-dev',
          peerIdentityPubKey: const [9, 8, 7],
          peerX25519PubKey: const [1, 2, 3],
          messages: messages,
          unreadCount: 0,
          cryptoMode: CryptoMode.mls,
        ));
      }

      ChatMessage unconfirmed() => ChatMessage(
            envelopeId: 'sent-1',
            conversationId: convoId,
            senderDeviceId: _myDeviceId,
            clientMsgId: 'cid-1',
            body: 'are you there',
            serverTs: DateTime.now().toUtc(),
            mine: true,
          );

      List<String> submittedBodies() =>
          verify(() => api.submitMessage(captureAny()))
              .captured
              .cast<SubmitMessagePayload>()
              .map((p) => utf8.decode(p.ciphertext, allowMalformed: true))
              .toList();

      Future<void> adoptPeerWelcome() async {
        ws.push(_envelope(
          envelopeId: 'welcome-1',
          conversationId: convoId,
          senderDeviceId: 'peer-dev',
          envelopeType: EnvelopeType.mlsWelcome,
        ));
        await pumpEventQueue();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await pumpEventQueue();
      }

      Future<void> receiveRebuildRequest({DateTime? serverTs}) async {
        await seedMlsChat(id: leaderConvoId, peerAccountId: leaderPeerAccount);
        when(() => api.lookupKeyPackage(any())).thenAnswer((_) async =>
            FetchKeyPackageResult(
                keyPackage: List<int>.filled(64, 0xBB),
                replenishNeeded: false,
                remainingForUser: 9));
        // Well along its chain, so only the request itself can explain a rebuild.
        crypto.ratchetRecvCounter = 7;
        ws.push(_envelope(
          envelopeId: 'request',
          conversationId: leaderConvoId,
          senderDeviceId: 'peer-dev',
          envelopeType: EnvelopeType.textLegacy,
          ciphertext:
              utf8.encode(const MessageControl.reestablish().encode()),
          serverTs: serverTs,
        ));
        await pumpEventQueue();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await pumpEventQueue();
      }

      test('a rebuild request over ratchet makes the leader rebuild', () async {
        // It may be the only signal: a follower holding a dead Welcome has
        // nothing else it can send, and no later message would be read as one.
        await receiveRebuildRequest();

        expect(crypto.wipeGroupCalls, greaterThan(0));
      });

      Future<int> rebuildsAfterASecondRequest({required bool decryptOk}) async {
        await sessions.save(session);
        await notifier.connect();
        when(() => api.ackMessages(any())).thenAnswer((_) async => 1);
        when(() => api.lookupAccount(_peerUsername))
            .thenAnswer((_) async => _peerAccount());
        when(() => api.lookupKeyPackage(any())).thenAnswer((_) async =>
            FetchKeyPackageResult(
                keyPackage: List<int>.filled(64, 0xBB),
                replenishNeeded: false,
                remainingForUser: 9));
        when(() => api.submitMessage(any())).thenAnswer((_) async =>
            SubmitMessageResult(
                envelopeId: 'srv-env', serverTs: DateTime.utc(2026)));
        notifier.rebuildWaits = const [Duration(milliseconds: 200)];
        notifier.seed(Conversation(
          id: leaderConvoId,
          peerUsername: _peerUsername,
          peerAccountId: leaderPeerAccount,
          peerDeviceId: 'peer-dev',
          peerIdentityPubKey: const [9, 8, 7],
          peerX25519PubKey: const [1, 2, 3],
          messages: const [],
          unreadCount: 0,
          cryptoMode: CryptoMode.mls,
        ));
        // The peer's first request: we rebuild, and the limit starts running.
        crypto.decryptAndInspectError =
            const MlsUnknownGroupException('no group');
        ws.push(_envelope(
            envelopeId: 'first',
            conversationId: leaderConvoId,
            senderDeviceId: 'peer-dev'));
        await pumpEventQueue();
        // It couldn't open that Welcome and asks again, inside the limit.
        ws.push(_envelope(
          envelopeId: 'second',
          conversationId: leaderConvoId,
          senderDeviceId: 'peer-dev',
          envelopeType: EnvelopeType.mlsApplication,
        ));
        await pumpEventQueue();
        final before = crypto.wipeGroupCalls;
        if (decryptOk) {
          // The group turns out to work after all.
          crypto.decryptAndInspectError = null;
          ws.push(_envelope(
            envelopeId: 'works',
            conversationId: leaderConvoId,
            senderDeviceId: 'peer-dev',
          ));
          await pumpEventQueue();
        }
        await Future<void>.delayed(const Duration(milliseconds: 350));
        await pumpEventQueue();
        return crypto.wipeGroupCalls - before;
      }

      test('a forced rebuild refused by the limit retries when it can', () async {
        // Otherwise a peer holding a dead Welcome waits forever.
        expect(await rebuildsAfterASecondRequest(decryptOk: false), greaterThan(0));
      });

      test('a decrypted message cancels the waiting rebuild', () async {
        expect(await rebuildsAfterASecondRequest(decryptOk: true), 0);
      });

      test('a Welcome with a dead key package does not wipe the group', () async {
        // It can never open, and the group we hold still works.
        await seedMlsChat();
        crypto.replaceGroupError =
            const MlsOrphanWelcomeException('no matching key package');

        await adoptPeerWelcome();

        expect(crypto.wipeGroupCalls, 0);
      });

      test('a Welcome with a dead key package is acked', () async {
        await seedMlsChat();
        crypto.replaceGroupError =
            const MlsOrphanWelcomeException('no matching key package');

        await adoptPeerWelcome();

        verify(() => api.ackMessages(['welcome-1'])).called(1);
      });

      test('a Welcome with a dead key package replaces the published pool',
          () async {
        await seedMlsChat();
        crypto.replaceGroupError =
            const MlsOrphanWelcomeException('no matching key package');
        when(() => api.publishKeyPackages(any(), reset: true))
            .thenAnswer((_) async => 1);

        await adoptPeerWelcome();

        verify(() => api.publishKeyPackages(any(), reset: true)).called(1);
      });

      test('a message older than the joined group does not trigger a rebuild',
          () async {
        // Sealed to the group we just replaced: it can never open, and that says
        // nothing about the group we hold. Rebuilding over it re-keys the chat.
        await seedMlsChat();
        ws.push(_envelope(
          envelopeId: 'welcome-new',
          conversationId: convoId,
          senderDeviceId: 'peer-dev',
          envelopeType: EnvelopeType.mlsWelcome,
          serverTs: DateTime.utc(2026, 6, 2),
        ));
        await pumpEventQueue();
        crypto.decryptAndInspectError = const MlsArgumentException('old epoch');

        for (var i = 0; i < 4; i++) {
          ws.push(_envelope(
            envelopeId: 'old-$i',
            conversationId: convoId,
            senderDeviceId: 'peer-dev',
            serverTs: DateTime.utc(2026, 6, 1),
          ));
          await pumpEventQueue();
        }
        await Future<void>.delayed(const Duration(seconds: 7));
        await pumpEventQueue();

        expect(crypto.wipeGroupCalls, 0);
      });

      test('a message newer than the joined group still counts as a failure',
          () async {
        await seedMlsChat();
        ws.push(_envelope(
          envelopeId: 'welcome-new',
          conversationId: convoId,
          senderDeviceId: 'peer-dev',
          envelopeType: EnvelopeType.mlsWelcome,
          serverTs: DateTime.utc(2026, 6, 2),
        ));
        await pumpEventQueue();
        crypto.decryptAndInspectError = const MlsArgumentException('broken');

        for (var i = 0; i < 4; i++) {
          ws.push(_envelope(
            envelopeId: 'new-$i',
            conversationId: convoId,
            senderDeviceId: 'peer-dev',
            serverTs: DateTime.utc(2026, 6, 3),
          ));
          await pumpEventQueue();
        }
        await Future<void>.delayed(const Duration(seconds: 7));
        await pumpEventQueue();

        expect(crypto.wipeGroupCalls, greaterThan(0));
      });

      test('a reconnect re-sends a message unconfirmed past the first wait',
          () async {
        await seedMlsChat(messages: [
          unconfirmed().copyWith(
            serverTs: DateTime.now().toUtc().subtract(const Duration(hours: 1)),
          ),
        ]);

        supervisor.emitReconnected();
        await pumpEventQueue();

        expect(submittedBodies().where((b) => b.contains('"_cid":"cid-1"')),
            isNotEmpty);
      });

      test('a sent message keeps its client id once the server accepts it',
          () async {
        await sessions.save(session);
        await notifier.connect();
        when(() => api.lookupAccount(_peerUsername))
            .thenAnswer((_) async => _peerAccount());
        when(() => api.submitMessage(any())).thenAnswer((_) async =>
            SubmitMessageResult(
                envelopeId: 'srv-env', serverTs: DateTime.utc(2026)));
        final id = await notifier.startConversation(
          myDeviceId: _myDeviceId,
          username: _peerUsername,
        );

        await notifier.sendMessage(
            conversationId: id, myDeviceId: _myDeviceId, text: 'hi');

        expect(notifier.byId(id)!.messages.single.clientMsgId, isNotNull);
      });

      test('adopting a Welcome re-sends a message the peer never confirmed',
          () async {
        await seedMlsChat(messages: [unconfirmed()]);

        await adoptPeerWelcome();

        expect(submittedBodies().where((b) => b.contains('"_cid":"cid-1"')),
            isNotEmpty);
      });

      test('a delivered tick from the transport does not stop the resend',
          () async {
        // The iOS extension acknowledges a push before decrypting anything, so
        // this is exactly what a phone that lost its group sends back.
        await seedMlsChat(messages: [unconfirmed()]);
        ws.push(_envelope(
          conversationId: convoId,
          senderDeviceId: 'peer-dev',
          envelopeType: EnvelopeType.deliveryStatus,
          ciphertext: utf8.encode('sent-1'),
        ));
        await pumpEventQueue();

        await adoptPeerWelcome();

        expect(submittedBodies().where((b) => b.contains('"_cid":"cid-1"')),
            isNotEmpty);
      });

      test('an end-to-end receipt stops the resend', () async {
        await seedMlsChat(messages: [unconfirmed()]);
        ws.push(_envelope(
          envelopeId: 'receipt-1',
          conversationId: convoId,
          senderDeviceId: 'peer-dev',
          envelopeType: EnvelopeType.mlsApplication,
          ciphertext: utf8.encode(
              MessageControl.receipt(ReceiptKind.delivered, ['cid-1']).encode()),
        ));
        await pumpEventQueue();

        await adoptPeerWelcome();

        verifyNever(() => api.submitMessage(any()));
      });

      test('the delivered receipt names the client id as well', () async {
        await seedMlsChat();

        ws.push(_envelope(
          envelopeId: 'in-1',
          conversationId: convoId,
          senderDeviceId: 'peer-dev',
          envelopeType: EnvelopeType.mlsApplication,
          ciphertext: utf8.encode('{"_cid":"peer-cid"}\nhello'),
        ));
        await pumpEventQueue();

        expect(
            submittedBodies().where(
                (b) => b.contains('"in-1"') && b.contains('"peer-cid"')),
            isNotEmpty);
      });

      test('a duplicate message is confirmed again', () async {
        // Otherwise a sender whose first receipt was lost keeps resending.
        await seedMlsChat();
        final wire = utf8.encode('{"_cid":"peer-cid"}\nhello');
        ws.push(_envelope(
          envelopeId: 'in-1',
          conversationId: convoId,
          senderDeviceId: 'peer-dev',
          envelopeType: EnvelopeType.mlsApplication,
          ciphertext: wire,
        ));
        await pumpEventQueue();
        clearInteractions(api);
        when(() => api.submitMessage(any())).thenAnswer((_) async =>
            SubmitMessageResult(
                envelopeId: 'srv-env', serverTs: DateTime.utc(2026)));

        ws.push(_envelope(
          envelopeId: 'in-1-resend',
          conversationId: convoId,
          senderDeviceId: 'peer-dev',
          envelopeType: EnvelopeType.mlsApplication,
          ciphertext: wire,
        ));
        await pumpEventQueue();

        expect(
            submittedBodies().where(
                (b) => b.contains('"in-1-resend"') && b.contains('"peer-cid"')),
            isNotEmpty);
      });

      test('an undecryptable envelope is not dropped before the fifth catchup',
          () async {
        // Each drain used to count it twice, destroying it on the third.
        await seedMlsChat();
        crypto.decryptAndInspectError = const MlsArgumentException('bad epoch');
        when(() => api.catchupMessages(
            since: any(named: 'since'),
            limit: any(named: 'limit'))).thenAnswer((_) async => [
              _envelope(
                  envelopeId: 'poison',
                  conversationId: convoId,
                  senderDeviceId: 'peer-dev'),
            ]);

        for (var i = 0; i < 4; i++) {
          supervisor.emitReconnected();
          await pumpEventQueue();
        }

        verifyNever(() => api.ackMessages(['poison']));
      });

      test('an undecryptable envelope is dropped on the fifth catchup',
          () async {
        await seedMlsChat();
        crypto.decryptAndInspectError = const MlsArgumentException('bad epoch');
        when(() => api.catchupMessages(
            since: any(named: 'since'),
            limit: any(named: 'limit'))).thenAnswer((_) async => [
              _envelope(
                  envelopeId: 'poison',
                  conversationId: convoId,
                  senderDeviceId: 'peer-dev'),
            ]);

        for (var i = 0; i < 5; i++) {
          supervisor.emitReconnected();
          await pumpEventQueue();
        }

        verify(() => api.ackMessages(['poison'])).called(1);
      });

      test('a rebuilt store replaces its key packages before the catchup',
          () async {
        // The catchup is what makes a peer rebuild the chat; a Welcome built from
        // a package of the destroyed store can never be opened.
        await seedMlsChat();
        final calls = <String>[];
        crypto.storeResetPending = true;
        when(() => api.publishKeyPackages(any(), reset: true))
            .thenAnswer((_) async {
          calls.add('replace');
          return 1;
        });
        when(() => api.catchupMessages(
            since: any(named: 'since'),
            limit: any(named: 'limit'))).thenAnswer((_) async {
          calls.add('catchup');
          return const [];
        });

        supervisor.emitReconnected();
        await pumpEventQueue();

        expect(calls.first, 'replace');
        expect(calls, contains('catchup'));
      });

      Future<void> losesGroupWithElectedSibling() async {
        // Before connect: the own-device list is cached there.
        when(() => api.listDevices()).thenAnswer((_) async => [
              const Device(
                  deviceId: _myDeviceId,
                  accountId: 'me-acc',
                  devicePubKey: []),
              const Device(
                  deviceId: 'a-dev',
                  accountId: 'me-acc',
                  devicePubKey: [],
                  x25519PubKey: [7, 7, 7]),
            ]);
        await seedMlsChat(id: leaderConvoId, peerAccountId: leaderPeerAccount);
        when(() => api.lookupAccount(_peerUsername)).thenAnswer((_) async =>
            const Account(
              accountId: leaderPeerAccount,
              username: _peerUsername,
              identityPubKey: [9, 8, 7],
              x25519PubKey: [1, 2, 3],
              deviceId: 'peer-dev',
              devices: [
                AccountDevice(deviceId: 'peer-dev', x25519PubKey: [1, 2, 3]),
              ],
            ));
        when(() => api.lookupDeviceKeyPackages(_peerUsername))
            .thenAnswer((_) async => const [
                  DeviceKeyPackageResult(deviceId: 'peer-dev', keyPackage: [1]),
                ]);
        when(() => api.lookupDeviceKeyPackages('me'))
            .thenAnswer((_) async => const [
                  DeviceKeyPackageResult(deviceId: 'a-dev', keyPackage: [3]),
                ]);
        notifier.siblingInitiatorGrace = const Duration(milliseconds: 50);
        crypto.decryptAndInspectError =
            const MlsUnknownGroupException('no group');
        ws.push(_envelope(
          envelopeId: 'poison',
          conversationId: leaderConvoId,
          senderDeviceId: 'peer-dev',
        ));
        await pumpEventQueue();
      }

      Iterable<SubmitMessagePayload> submittedWelcomes() =>
          verify(() => api.submitMessage(captureAny()))
              .captured
              .cast<SubmitMessagePayload>()
              .where((p) => p.envelopeType == EnvelopeType.mlsWelcome);

      test('a forced rebuild refused by the election retries after the grace',
          () async {
        // The elected sibling can be a closed web tab, so nothing else would
        // rebuild the chat until the user happened to send something.
        await losesGroupWithElectedSibling();

        await Future<void>.delayed(const Duration(milliseconds: 700));
        await pumpEventQueue();

        expect(submittedWelcomes(), isNotEmpty);
      });

      test('the retry stands down if the elected sibling rebuilt first',
          () async {
        await losesGroupWithElectedSibling();
        ws.push(_envelope(
          envelopeId: 'sibling-welcome',
          conversationId: leaderConvoId,
          senderDeviceId: 'a-dev',
          envelopeType: EnvelopeType.mlsWelcome,
        ));
        await pumpEventQueue();

        await Future<void>.delayed(const Duration(milliseconds: 700));
        await pumpEventQueue();

        expect(submittedWelcomes(), isEmpty);
      });
    });

    test('inbound message with JSON that lacks _system key stays kind=text', () async {
      await sessions.save(session);
      await notifier.connect();
      when(() => api.lookupAccount(_peerUsername))
          .thenAnswer((_) async => _peerAccount());
      final convoId = await notifier.startConversation(
        myDeviceId: _myDeviceId,
        username: _peerUsername,
      );
      when(() => api.ackMessages(any())).thenAnswer((_) async => 1);

      const benignJson = '{"foo":"bar"}';
      ws.push(_envelope(
        envelopeId: 'env-json-1',
        conversationId: convoId,
        senderDeviceId: 'peer-dev',
        envelopeType: EnvelopeType.textLegacy,
        ciphertext: benignJson.codeUnits,
      ));
      await pumpEventQueue();

      final m = notifier.byId(convoId)!.messages.single;
      expect(m.kind, equals(MessageKind.text));
      expect(m.body, equals(benignJson));
    });
  });

  group('runDisappearingSweep', () {
    test('null TTL is a no-op', () async {
      await db.open(masterKeyHex: 'k');
      final now = DateTime.now().toUtc();
      final old = now.subtract(const Duration(days: 8));
      notifier.seed(Conversation(
        id: 'c',
        peerUsername: 'p',
        peerAccountId: 'pa',
        peerDeviceId: 'pd',
        peerIdentityPubKey: const [],
        messages: [
          ChatMessage(
            envelopeId: 'old-1',
            conversationId: 'c',
            senderDeviceId: 'p',
            body: 'old',
            serverTs: old,
            mine: false,
          ),
        ],
        unreadCount: 0,
      ));
      await notifier.runDisappearingSweep(null);
      expect(notifier.byId('c')!.messages, hasLength(1));
    });

    test('drops messages older than now - ttl from memory and DB', () async {
      await db.open(masterKeyHex: 'k');
      final now = DateTime.now().toUtc();
      final old = now.subtract(const Duration(days: 8));
      final fresh = now.subtract(const Duration(hours: 1));
      final convo = Conversation(
        id: 'c',
        peerUsername: 'p',
        peerAccountId: 'pa',
        peerDeviceId: 'pd',
        peerIdentityPubKey: const [],
        messages: [
          ChatMessage(
            envelopeId: 'old-1',
            conversationId: 'c',
            senderDeviceId: 'p',
            body: 'old',
            serverTs: old,
            mine: false,
          ),
          ChatMessage(
            envelopeId: 'new-1',
            conversationId: 'c',
            senderDeviceId: 'p',
            body: 'new',
            serverTs: fresh,
            mine: false,
          ),
        ],
        unreadCount: 0,
      );
      notifier.seed(convo);
      await db.upsertConversation(convo);
      await db.upsertMessages('c', convo.messages);

      // 1-week TTL → only "new" survives.
      await notifier.runDisappearingSweep(const Duration(days: 7));

      expect(notifier.byId('c')!.messages.map((m) => m.envelopeId), equals(['new-1']));
      final loaded = await db.loadConversations();
      expect(loaded.single.messages.map((m) => m.envelopeId), equals(['new-1']));
    });

    test('sweep deletes at the SHORTER of the sender timer and local retention',
        () async {
      await db.open(masterKeyHex: 'k');
      final now = DateTime.now().toUtc();
      final convo = Conversation(
        id: 'c',
        peerUsername: 'p',
        peerAccountId: 'pa',
        peerDeviceId: 'pd',
        peerIdentityPubKey: const [],
        messages: [
          // Sender's short timer already elapsed → swept (sender's timer is the
          // shorter of the two).
          ChatMessage(
            envelopeId: 'sender-elapsed',
            conversationId: 'c',
            senderDeviceId: 'p',
            body: 'gone',
            serverTs: now.subtract(const Duration(minutes: 1)),
            expiresAt: now.subtract(const Duration(seconds: 1)),
            mine: false,
          ),
          // Sent 30 days ago with a LONG sender timer (not elapsed), but the
          // local 7-day retention is shorter → swept retroactively. This is the
          // model-B change: the current local setting applies to old messages.
          ChatMessage(
            envelopeId: 'local-shorter',
            conversationId: 'c',
            senderDeviceId: 'p',
            body: 'also gone',
            serverTs: now.subtract(const Duration(days: 30)),
            expiresAt: now.add(const Duration(days: 1)),
            mine: false,
          ),
          // Fresh, and BOTH timers are in the future → survives.
          ChatMessage(
            envelopeId: 'survivor',
            conversationId: 'c',
            senderDeviceId: 'p',
            body: 'stays',
            serverTs: now.subtract(const Duration(minutes: 1)),
            expiresAt: now.add(const Duration(days: 1)),
            mine: false,
          ),
        ],
        unreadCount: 0,
      );
      notifier.seed(convo);
      await db.upsertConversation(convo);
      await db.upsertMessages('c', convo.messages);

      // Local default = 7 days (no per-conversation override), applied
      // retroactively and capped by each message's sender timer.
      await notifier.runDisappearingSweep(const Duration(days: 7));

      expect(notifier.byId('c')!.messages.map((m) => m.envelopeId),
          equals(['survivor']));
      final loaded = await db.loadConversations();
      expect(loaded.single.messages.map((m) => m.envelopeId),
          equals(['survivor']));
    });

    test('does not notify when nothing was dropped', () async {
      await db.open(masterKeyHex: 'k');
      notifier.seed(Conversation(
        id: 'c',
        peerUsername: 'p',
        peerAccountId: 'pa',
        peerDeviceId: 'pd',
        peerIdentityPubKey: const [],
        messages: [
          ChatMessage(
            envelopeId: 'recent',
            conversationId: 'c',
            senderDeviceId: 'p',
            body: 'recent',
            serverTs: DateTime.now().toUtc(),
            mine: false,
          ),
        ],
        unreadCount: 0,
      ));
      var notifyCount = 0;
      notifier.addListener(() => notifyCount++);
      await notifier.runDisappearingSweep(const Duration(days: 7));
      expect(notifyCount, equals(0));
    });
  });

  group('setVerified', () {
    test('flips the verified flag and persists it', () async {
      await db.open(masterKeyHex: 'k');
      final seeded = Conversation(
        id: 'c',
        peerUsername: 'p',
        peerAccountId: 'pa',
        peerDeviceId: 'pd',
        peerIdentityPubKey: const [],
        peerX25519PubKey: const [1, 2, 3],
        messages: const [],
        unreadCount: 0,
      );
      notifier.seed(seeded);
      await db.upsertConversation(seeded);

      await notifier.setVerified('c', true);

      expect(notifier.byId('c')!.verified, isTrue);
      final loaded = await db.loadConversations();
      expect(loaded.firstWhere((c) => c.id == 'c').verified, isTrue);
    });

    test('is a no-op when the value is already set', () async {
      var notifyCount = 0;
      notifier.addListener(() => notifyCount++);
      notifier.seed(Conversation(
        id: 'c',
        peerUsername: 'p',
        peerAccountId: 'pa',
        peerDeviceId: 'pd',
        peerIdentityPubKey: const [],
        messages: const [],
        unreadCount: 0,
        verified: true,
      ));
      notifyCount = 0; // discard the seed notification
      await notifier.setVerified('c', true);
      expect(notifyCount, equals(0));
    });

    test('is a no-op when conversation is missing', () async {
      await notifier.setVerified('missing', true);
      expect(notifier.byId('missing'), isNull);
    });
  });

  group('clearLocalData', () {
    test('wipes in-memory state and the underlying DB', () async {
      await db.open(masterKeyHex: 'k');
      final seeded = Conversation(
        id: 'c',
        peerUsername: 'p',
        peerAccountId: 'pa',
        peerDeviceId: 'pd',
        peerIdentityPubKey: const [],
        messages: const [],
        unreadCount: 0,
      );
      notifier.seed(seeded);
      await db.upsertConversation(seeded);

      await notifier.clearLocalData();

      expect(notifier.conversations, isEmpty);
      final loaded = await db.loadConversations();
      expect(loaded, isEmpty);
    });
  });

  group('decrypted-media temp cleanup', () {
    test('deleteMessageLocal reclaims the message\'s temp media', () async {
      final store = TempMediaStoreInMemory();
      final n = buildNotifier(tempMediaStore: store);
      addTearDown(n.dispose);
      await sessions.save(session);
      await n.connect();
      when(() => api.lookupAccount(_peerUsername))
          .thenAnswer((_) async => _peerAccount());
      final convoId = await n.startConversation(
        myDeviceId: _myDeviceId,
        username: _peerUsername,
      );
      ws.push(_envelope(
        conversationId: convoId,
        envelopeType: EnvelopeType.textLegacy,
      ));
      await pumpEventQueue();

      final msg = n.byId(convoId)!.messages.single;
      await n.deleteMessageLocal(convoId, msg);

      expect(store.deletedEnvelopes, contains(msg.envelopeId));
    });

    test('clearLocalData sweeps all temp media on sign-out', () async {
      final store = TempMediaStoreInMemory();
      final n = buildNotifier(tempMediaStore: store);
      addTearDown(n.dispose);
      await db.open(masterKeyHex: 'k');

      await n.clearLocalData();

      expect(store.sweepAllCount, 1);
    });
  });

  group('resetLocalDatabase', () {
    test('deletes the DB file, master key, and lets a fresh connect rehydrate empty', () async {
      await sessions.save(session);
      await notifier.connect();
      // Hydration is now true and a master key was written.
      expect(await storage.getString(ConversationsNotifier.dbMasterKeyKey), isNotNull);

      await notifier.resetLocalDatabase();

      expect(notifier.conversations, isEmpty);
      expect(db.isOpen, isFalse);
      expect(await storage.getString(ConversationsNotifier.dbMasterKeyKey), isNull);

      // After a tear-down, a fresh connect starts clean and re-derives the key.
      await notifier.disconnect();
      await notifier.connect();
      expect(db.isOpen, isTrue);
      final newKey = await storage.getString(ConversationsNotifier.dbMasterKeyKey);
      expect(newKey, isNotNull);
      expect(newKey!.length, equals(64));
    });
  });

  group('conversations getter', () {
    ChatMessage msg(String id, DateTime ts, String convoId) => ChatMessage(
          envelopeId: id,
          conversationId: convoId,
          senderDeviceId: 'p',
          body: 'b',
          serverTs: ts,
          mine: false,
        );

    test('sorts by lastMessage.serverTs descending', () {
      notifier.seed(Conversation(
        id: 'old',
        peerUsername: 'a',
        peerAccountId: 'aa',
        peerDeviceId: 'ad',
        peerIdentityPubKey: const [],
        messages: [msg('1', DateTime.utc(2026, 1, 1), 'old')],
        unreadCount: 0,
      ));
      notifier.seed(Conversation(
        id: 'new',
        peerUsername: 'b',
        peerAccountId: 'bb',
        peerDeviceId: 'bd',
        peerIdentityPubKey: const [],
        messages: [msg('2', DateTime.utc(2026, 5, 1), 'new')],
        unreadCount: 0,
      ));

      final list = notifier.conversations;
      expect(list.first.id, equals('new'));
      expect(list.last.id, equals('old'));
    });

    test('falls back to alphabetical when both conversations are empty', () {
      notifier.seed(Conversation(
        id: 'b',
        peerUsername: 'beta',
        peerAccountId: 'b',
        peerDeviceId: 'b',
        peerIdentityPubKey: const [],
        messages: const [],
        unreadCount: 0,
      ));
      notifier.seed(Conversation(
        id: 'a',
        peerUsername: 'alpha',
        peerAccountId: 'a',
        peerDeviceId: 'a',
        peerIdentityPubKey: const [],
        messages: const [],
        unreadCount: 0,
      ));

      final list = notifier.conversations;
      expect(list.first.peerUsername, equals('alpha'));
      expect(list.last.peerUsername, equals('beta'));
    });

    test('places empty conversation after one with messages', () {
      notifier.seed(Conversation(
        id: 'with-msgs',
        peerUsername: 'a',
        peerAccountId: 'a',
        peerDeviceId: 'a',
        peerIdentityPubKey: const [],
        messages: [msg('1', DateTime.utc(2026, 5, 1), 'with-msgs')],
        unreadCount: 0,
      ));
      notifier.seed(Conversation(
        id: 'empty',
        peerUsername: 'b',
        peerAccountId: 'b',
        peerDeviceId: 'b',
        peerIdentityPubKey: const [],
        messages: const [],
        unreadCount: 0,
      ));

      final list = notifier.conversations;
      expect(list.first.id, equals('with-msgs'));
      expect(list.last.id, equals('empty'));
    });
  });

  group('ack', () {
    test('does not call api when envelopeIds is empty', () async {
      await notifier.ack(const []);
      verifyNever(() => api.ackMessages(any()));
    });

    test('swallows api errors silently (best-effort)', () async {
      when(() => api.ackMessages(any())).thenThrow(Exception('flaky'));
      await notifier.ack(['env-1']); // should not rethrow
      verify(() => api.ackMessages(['env-1'])).called(1);
    });
  });

  // The bug-fix lockdown group: small focused tests for the regressions the
  // 2026-05-09 code review uncovered. Each one asserts the property the
  // production code now upholds; if a future change re-introduces the bug,
  // the matching test fires.
  group('correctness regressions', () {
    Future<String> seedConvo() async {
      await sessions.save(session);
      await notifier.connect();
      when(() => api.lookupAccount(_peerUsername))
          .thenAnswer((_) async => _peerAccount());
      return notifier.startConversation(
        myDeviceId: _myDeviceId,
        username: _peerUsername,
      );
    }

    // The wire body must be UTF-8 encoded (not String.codeUnits) so emoji and
    // non-Latin characters survive the round-trip through the ratchet.
    test('UTF-8 round-trip: emoji body decodes correctly on receive', () async {
      final convoId = await seedConvo();
      const message = 'héllo 🎉 世界';
      // First simulate the OUTGOING leg captures UTF-8 bytes.
      when(() => api.submitMessage(any())).thenAnswer((_) async =>
          SubmitMessageResult(envelopeId: 'e1', serverTs: DateTime.utc(2026, 5, 9)));
      await notifier.sendMessage(
        conversationId: convoId,
        myDeviceId: _myDeviceId,
        text: message,
      );
      final captured = verify(() => api.submitMessage(captureAny())).captured.single
          as SubmitMessagePayload;
      // Multi-byte sequence — codeUnits would drop the high bytes.
      expect(captured.ciphertext.length, greaterThan(message.length));

      // Now simulate the RECEIVE leg with the same bytes.
      when(() => api.ackMessages(any())).thenAnswer((_) async => 1);
      ws.push(_envelope(
        envelopeId: 'env-utf8',
        conversationId: convoId,
        envelopeType: EnvelopeType.textLegacy,
        ciphertext: captured.ciphertext,
      ));
      await pumpEventQueue();
      final received = notifier.byId(convoId)!.messages
          .firstWhere((m) => m.envelopeId == 'env-utf8');
      expect(received.body, equals(message));
    });

    // If the network drops, the sender's chain MUST NOT advance — otherwise
    // a future retry would skip a slot the receiver is waiting on.
    test('submit failure leaves ratchet state un-advanced', () async {
      final convoId = await seedConvo();
      // Capture the ratchet state BEFORE the failed send.
      final before = await db.loadConversationCryptoState(convoId);
      expect(before, isNotNull);
      when(() => api.submitMessage(any())).thenThrow(Exception('network down'));

      await expectLater(
        notifier.sendMessage(
          conversationId: convoId,
          myDeviceId: _myDeviceId,
          text: 'hi',
        ),
        throwsException,
      );

      final after = await db.loadConversationCryptoState(convoId);
      expect(after!.sendCounter, equals(before!.sendCounter),
          reason: 'submit failure must NOT persist an advanced sender chain');
    });

    // clearLocalData must wipe the bridge's per-conversation skipped-key
    // cache too, otherwise a fresh login could decrypt envelopes destined
    // for the previous user's chain.
    test('clearLocalData clears the bridge skipped-key cache', () async {
      final convoId = await seedConvo();
      // Force a second conversation so we test the iteration.
      when(() => api.lookupAccount('peer2'))
          .thenAnswer((_) async => _peerAccount(accountId: 'a2', username: 'peer2'));
      final convoId2 = await notifier.startConversation(
        myDeviceId: _myDeviceId,
        username: 'peer2',
      );

      await notifier.clearLocalData();
      expect(crypto.clearedConversations, containsAll([convoId, convoId2]));
    });

    // Hydration only loads the last `messagesInitialPage` messages per
    // conversation. The remainder stays on disk and is reachable via
    // loadOlderMessages.
    test('hydrate loads last 50 messages per convo and flags hasMore', () async {
      // Seed 75 messages on disk for a conversation.
      final convo = Conversation(
        id: 'c-page',
        peerUsername: 'paged',
        peerAccountId: 'p',
        peerDeviceId: 'pd',
        peerIdentityPubKey: const [],
        peerX25519PubKey: const [1, 2, 3],
        messages: const [],
        unreadCount: 0,
      );
      await db.upsertConversation(convo);
      await db.upsertMessages('c-page', [
        for (var i = 0; i < 75; i++)
          ChatMessage(
            envelopeId: 'm$i',
            conversationId: 'c-page',
            senderDeviceId: 'pd',
            body: 'msg $i',
            serverTs: DateTime.utc(2026, 5, 1).add(Duration(minutes: i)),
            mine: false,
          ),
      ]);
      await sessions.save(session);

      // Cold-start hydrate via connect.
      await notifier.connect();

      final live = notifier.byId('c-page')!;
      expect(live.messages.length, equals(50),
          reason: 'hydrate must cap at the initial page size');
      expect(live.messages.first.envelopeId, equals('m25'));
      expect(live.messages.last.envelopeId, equals('m74'));
      expect(live.hasMoreOlderMessages, isTrue);
    });

    test('loadOlderMessages prepends a page and flips hasMore=false at the end', () async {
      final convo = Conversation(
        id: 'c-page',
        peerUsername: 'paged',
        peerAccountId: 'p',
        peerDeviceId: 'pd',
        peerIdentityPubKey: const [],
        peerX25519PubKey: const [1, 2, 3],
        messages: const [],
        unreadCount: 0,
      );
      await db.upsertConversation(convo);
      // 70 messages: hydrate keeps the newest 50, leaving 20 older on disk.
      // Single page-of-50 fetch should return those 20 + flip hasMore=false.
      await db.upsertMessages('c-page', [
        for (var i = 0; i < 70; i++)
          ChatMessage(
            envelopeId: 'm$i',
            conversationId: 'c-page',
            senderDeviceId: 'pd',
            body: 'msg $i',
            serverTs: DateTime.utc(2026, 5, 1).add(Duration(minutes: i)),
            mine: false,
          ),
      ]);
      await sessions.save(session);
      await notifier.connect();
      expect(notifier.byId('c-page')!.messages.length, equals(50));
      expect(notifier.byId('c-page')!.hasMoreOlderMessages, isTrue);

      await notifier.loadOlderMessages('c-page');

      final live = notifier.byId('c-page')!;
      expect(live.messages.length, equals(70));
      expect(live.messages.first.envelopeId, equals('m0'));
      expect(live.messages.last.envelopeId, equals('m69'));
      expect(live.hasMoreOlderMessages, isFalse,
          reason: 'fewer than page-size returned → no more pages');
    });

    test('loadOlderMessages is a no-op when hasMoreOlderMessages is false', () async {
      // Tiny conversation — fewer messages than initialPage, so hydrate
      // already loaded everything.
      final convoId = await seedConvo();
      final before = notifier.byId(convoId)!;
      expect(before.hasMoreOlderMessages, isFalse);

      await notifier.loadOlderMessages(convoId);

      final after = notifier.byId(convoId)!;
      // Identity-equal: the notifier returned without mutating state.
      expect(identical(before, after), isTrue);
    });

    // The disappearing sweep must drop cached media bytes for messages it
    // deletes, otherwise the byte cap can leak past the visible message
    // history.
    test('runDisappearingSweep evicts media bytes for swept messages', () async {
      final convoId = await seedConvo();
      // Inject a media message that's already older than the sweep TTL.
      notifier.seed(notifier.byId(convoId)!.copyWith(messages: [
        ChatMessage(
          envelopeId: 'old-img',
          conversationId: convoId,
          senderDeviceId: 'peer-dev',
          body: '',
          serverTs: DateTime.now().toUtc().subtract(const Duration(days: 30)),
          mine: false,
          kind: MessageKind.image,
          mediaId: 'mid',
          mediaKey: const [],
          mediaSha256: const [],
          mediaSize: 0,
          mediaMime: 'image/jpeg',
        ),
      ]));
      // Drop it from the conversation map by sweeping with a 1-day TTL.
      await notifier.runDisappearingSweep(const Duration(days: 1));
      expect(notifier.byId(convoId)!.messages, isEmpty);
    });
  });

  group('catchup on Reconnected event', () {
    test('Reconnected event triggers catchupMessages', () async {
      await sessions.save(session);
      when(() => api.catchupMessages(since: any(named: 'since'), limit: any(named: 'limit')))
          .thenAnswer((_) async => <Envelope>[]);
      await notifier.connect();
      // The initial Reconnected from start() triggers one catchup call.
      await Future<void>.delayed(Duration.zero);
      verify(() => api.catchupMessages(since: any(named: 'since'), limit: any(named: 'limit')))
          .called(greaterThanOrEqualTo(1));
    });

    // A device back from a long absence has more backlog than one page holds.
    // Catchup used to fetch exactly one page and stop, so the rest waited for
    // the next RECONNECT — several long "Catching up…" rounds for one backlog,
    // with everything past page one simply absent in between.
    test('catchup keeps paging while the server returns FULL pages', () async {
      await sessions.save(session);
      const pageSize = 200; // matches ConversationsNotifier._catchupPageSize
      var call = 0;
      when(() => api.catchupMessages(
          since: any(named: 'since'),
          limit: any(named: 'limit'))).thenAnswer((_) async {
        call++;
        if (call == 1) {
          return [
            for (var i = 0; i < pageSize; i++)
              _envelope(envelopeId: 'p1-$i', conversationId: '1to1:a:b'),
          ];
        }
        if (call == 2) {
          return [
            for (var i = 0; i < 3; i++)
              _envelope(envelopeId: 'p2-$i', conversationId: '1to1:a:b'),
          ];
        }
        return <Envelope>[];
      });

      await notifier.connect();
      await pumpEventQueue();

      expect(call, greaterThanOrEqualTo(2),
          reason: 'a FULL page means there is probably more to drain');
    });

    // ...but a SHORT page is the end of the backlog: stop there rather than
    // burning a round trip per catchup to confirm it.
    test('catchup stops after a short page', () async {
      await sessions.save(session);
      var call = 0;
      when(() => api.catchupMessages(
          since: any(named: 'since'),
          limit: any(named: 'limit'))).thenAnswer((_) async {
        call++;
        return [_envelope(envelopeId: 'only-1', conversationId: '1to1:a:b')];
      });

      await notifier.connect();
      await pumpEventQueue();

      expect(call, equals(1));
    });

    // Live 2026-11-07: an iPhone had 370 unacked envelopes, the oldest 200 ones
    // it could never open. Re-asking from the head returned those same 200 on
    // every page, so everything queued behind them — every message that came
    // in while the app was closed — was never fetched at all.
    test('a full page that is never consumed does not hide what is queued '
        'after it', () async {
      await sessions.save(session);
      final t0 = DateTime.utc(2026, 11, 1);
      final queue = [
        for (var i = 0; i < 200; i++)
          _envelope(
            envelopeId: 'dead-$i',
            conversationId: '1to1:a:b',
            serverTs: t0.add(Duration(seconds: i)),
          ),
        _envelope(
          envelopeId: 'behind-the-wall',
          conversationId: '1to1:a:b',
          serverTs: t0.add(const Duration(days: 6)),
        ),
      ];
      final returned = <String>{};
      // The server: oldest first from `since` (inclusive), and nothing is ever
      // consumed, so the head stays where it is.
      when(() => api.catchupMessages(
          since: any(named: 'since'),
          limit: any(named: 'limit'))).thenAnswer((inv) async {
        final since = inv.namedArguments[#since] as DateTime?;
        final page = queue
            .where((e) => since == null || !e.serverTs.isBefore(since))
            .take(200)
            .toList();
        returned.addAll(page.map((e) => e.envelopeId));
        return page;
      });

      await notifier.connect();
      await pumpEventQueue();

      expect(returned, contains('behind-the-wall'));
    });

    test('the socket drain asks for each next page from the newest envelope '
        'of the page before', () async {
      await sessions.save(session);
      ws.connected = true;
      final t0 = DateTime.utc(2026, 11, 1);
      ws.catchupOverSocketResult = [
        for (var i = 0; i < 200; i++)
          _envelope(
            envelopeId: 'p-$i',
            conversationId: '1to1:a:b',
            serverTs: t0.add(Duration(seconds: i)),
          ),
      ];

      await notifier.connect();
      await pumpEventQueue();

      expect(ws.catchupOverSocketSinces.take(2),
          [null, t0.add(const Duration(seconds: 199))]);
    });

    test('catchup passes no `since` floor so offline->24h backlog is not lost', () async {
      // The server returns only unacked, unexpired envelopes; a client-side
      // time floor would silently drop anything missed while offline longer
      // than the floor. Catchup must therefore pass since=null.
      await sessions.save(session);
      var sinceWasNull = false;
      when(() => api.catchupMessages(since: any(named: 'since'), limit: any(named: 'limit'))).thenAnswer((inv) async {
        sinceWasNull = inv.namedArguments[#since] == null;
        return <Envelope>[];
      });
      await notifier.connect();
      await Future<void>.delayed(Duration.zero);
      expect(sinceWasNull, isTrue,
          reason: 'catchup should pass no `since` floor');
    });

    test('SignedOut event clears local data and surfaces signedOut state', () async {
      await sessions.save(session);
      when(() => api.lookupAccount('peer'))
          .thenAnswer((_) async => Account(
                accountId: 'peer-acc',
                username: 'peer',
                identityPubKey: List<int>.filled(32, 7),
                x25519PubKey: List<int>.filled(32, 8),
              ));
      when(() => api.catchupMessages(since: any(named: 'since'), limit: any(named: 'limit')))
          .thenAnswer((_) async => <Envelope>[]);
      await notifier.connect();
      await notifier.startConversation(
        myDeviceId: _myDeviceId,
        username: 'peer',
      );
      expect(notifier.conversations, isNotEmpty);

      supervisor.emitSignedOut();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(notifier.connectionState, ConnectionState.signedOut);
      expect(notifier.conversations, isEmpty);
    });

    test('connectionState getter forwards supervisor state', () async {
      await sessions.save(session);
      when(() => api.catchupMessages(since: any(named: 'since'), limit: any(named: 'limit')))
          .thenAnswer((_) async => <Envelope>[]);
      await notifier.connect();
      expect(notifier.connectionState, ConnectionState.connected);
      supervisor.emitSignedOut();
      expect(notifier.connectionState, ConnectionState.signedOut);
    });

    test('catchup failure is swallowed (cursor not advanced)', () async {
      await sessions.save(session);
      when(() => api.catchupMessages(since: any(named: 'since'), limit: any(named: 'limit')))
          .thenThrow(StateError('network failed'));
      // Should not throw.
      await notifier.connect();
      await Future<void>.delayed(Duration.zero);
      // The notifier is still connected — catchup is best-effort.
      expect(notifier.connectionState, ConnectionState.connected);
    });

    test('ack-drops a persistently-failing envelope (poison-pill guard)',
        () async {
      await sessions.save(session);
      when(() => api.ackMessages(any())).thenAnswer((_) async => 1);
      // A Welcome whose processWelcome throws a NON-MLS error every time — the
      // handler doesn't swallow it, so without the guard it would re-deliver on
      // every catchup forever.
      crypto.processWelcomeError = Exception('boom');
      final poison = _envelope(
        envelopeId: 'poison-1',
        conversationId: '1to1:x:y',
        senderDeviceId: 'someone-dev',
        envelopeType: EnvelopeType.mlsWelcome,
        ciphertext: const [1, 2, 3],
      );
      when(() => api.catchupMessages(since: any(named: 'since'), limit: any(named: 'limit')))
          .thenAnswer((_) async => [poison]);

      await notifier.connect(); // catchup attempt #1 (start's Reconnected)
      await pumpEventQueue();
      for (var i = 0; i < 5; i++) {
        supervisor.emitReconnected(); // attempts #2..#6
        await pumpEventQueue();
      }

      // Once the failure count hit the cap it was ack-dropped, so it stops
      // re-delivering rather than looping forever.
      final ackedIds = verify(() => api.ackMessages(captureAny()))
          .captured
          .cast<List<String>>()
          .expand((l) => l)
          .toList();
      expect(ackedIds, contains('poison-1'));
    });
  });

  group('reconcileMlsConversations', () {
    test('known group keeps needsReestablishment false', () async {
      // Arrange: pre-seed DB with an MLS-mode conversation; bridge returns
      // a valid epoch → group is known.
      await db.open(masterKeyHex: 'k');
      final mlsConvo = Conversation(
        id: 'mls-known',
        peerUsername: 'alice',
        peerAccountId: 'alice-acc',
        peerDeviceId: 'alice-dev',
        peerIdentityPubKey: const [],
        messages: const [],
        unreadCount: 0,
        cryptoMode: CryptoMode.mls,
      );
      await db.upsertConversation(mlsConvo);
      crypto.currentEpochResult = 5;
      crypto.currentEpochError = null;

      await sessions.save(session);
      await notifier.connect();

      // Assert: conversation is present and not flagged.
      final convo = notifier.byId('mls-known');
      expect(convo, isNotNull);
      expect(convo!.needsReestablishment, isFalse);
    });

    test('MlsUnknownGroupException flags needsReestablishment', () async {
      // Arrange: pre-seed DB with an MLS-mode conversation; bridge throws
      // MlsUnknownGroupException → CoreCrypto doesn't know this group.
      await db.open(masterKeyHex: 'k');
      final mlsConvo = Conversation(
        id: 'mls-orphan',
        peerUsername: 'bob',
        peerAccountId: 'bob-acc',
        peerDeviceId: 'bob-dev',
        peerIdentityPubKey: const [],
        messages: const [],
        unreadCount: 0,
        cryptoMode: CryptoMode.mls,
      );
      await db.upsertConversation(mlsConvo);
      crypto.currentEpochError = const MlsUnknownGroupException('group not found');

      await sessions.save(session);
      await notifier.connect();

      // Assert: conversation is flagged for re-establishment.
      final convo = notifier.byId('mls-orphan');
      expect(convo, isNotNull);
      expect(convo!.needsReestablishment, isTrue);
    });

    test('ratchet-mode conversations are skipped — currentEpoch is not called', () async {
      // Arrange: pre-seed DB with a ratchet-mode conversation.
      await db.open(masterKeyHex: 'k');
      final ratchetConvo = Conversation(
        id: 'ratchet-convo',
        peerUsername: 'carol',
        peerAccountId: 'carol-acc',
        peerDeviceId: 'carol-dev',
        peerIdentityPubKey: const [],
        messages: const [],
        unreadCount: 0,
        cryptoMode: CryptoMode.ratchet,
      );
      await db.upsertConversation(ratchetConvo);

      await sessions.save(session);
      await notifier.connect();

      // Assert: bridge was never asked about the ratchet convo's epoch.
      expect(crypto.currentEpochCalls, equals(0));
      // And the convo is not flagged.
      final convo = notifier.byId('ratchet-convo');
      expect(convo, isNotNull);
      expect(convo!.needsReestablishment, isFalse);
    });
  });

  group('replenishKeyPackagesIfNeeded', () {
    test('below threshold: mints and publishes a refill batch', () async {
      // Count=5 is below the low-water mark of 10.
      when(() => api.keyPackageCount()).thenAnswer((_) async => 5);
      when(() => api.publishKeyPackages(any())).thenAnswer((_) async => 50);

      await notifier.replenishKeyPackagesIfNeeded();

      // mintKeyPackages should have been called with count=50.
      expect(crypto.mintKeyPackagesCalls, equals(1));
      expect(crypto.mintKeyPackagesLastCount, equals(50));
      // publishKeyPackages should have been called once with the minted packages.
      verify(() => api.publishKeyPackages(any())).called(1);
    });

    test('at threshold: no-op — mintKeyPackages is not called', () async {
      // Count=10 equals the low-water mark — no replenishment needed.
      when(() => api.keyPackageCount()).thenAnswer((_) async => 10);

      await notifier.replenishKeyPackagesIfNeeded();

      expect(crypto.mintKeyPackagesCalls, equals(0));
      verifyNever(() => api.publishKeyPackages(any()));
    });

    test('server error is swallowed — no exception propagates', () async {
      // keyPackageCount throws — failure must be non-fatal.
      when(() => api.keyPackageCount()).thenThrow(Exception('network error'));

      // Should complete without throwing.
      await expectLater(
        notifier.replenishKeyPackagesIfNeeded(),
        completes,
      );
      // No mint attempted after the count fetch failed.
      expect(crypto.mintKeyPackagesCalls, equals(0));
    });
  });

  group('block', () {
    Future<String> blockedConvo() async {
      await sessions.save(session);
      await notifier.connect();
      // Let connect()'s unawaited side-effects (own-device reconcile, push
      // bootstrap) settle before we seed + block, so they can't race the
      // assertions by rebuilding _byId.
      await pumpEventQueue();
      when(() => api.lookupAccount(_peerUsername))
          .thenAnswer((_) async => _peerAccount());
      final convoId = await notifier.startConversation(
        myDeviceId: _myDeviceId,
        username: _peerUsername,
      );
      await notifier.setBlocked(convoId, true);
      return convoId;
    }

    test('setBlocked sets the flag, persists, and mirrors to SecureStorage',
        () async {
      final convoId = await blockedConvo();

      expect(notifier.isBlocked(convoId), isTrue);

      // Mirrored for the FCM background isolate.
      final raw =
          await storage.getString(ConversationsNotifier.blockedConvosKey);
      expect(raw, isNotNull);
      expect((jsonDecode(raw!) as List).cast<String>(), contains(convoId));

      // Persisted to the DB.
      final loaded = await db.loadConversations();
      expect(loaded.firstWhere((c) => c.id == convoId).blocked, isTrue);
    });

    test('unblock clears the flag and the mirrored set', () async {
      final convoId = await blockedConvo();
      await notifier.setBlocked(convoId, false);

      expect(notifier.isBlocked(convoId), isFalse);
      final raw =
          await storage.getString(ConversationsNotifier.blockedConvosKey);
      expect((jsonDecode(raw!) as List), isEmpty);
      final loaded = await db.loadConversations();
      expect(loaded.firstWhere((c) => c.id == convoId).blocked, isFalse);
    });

    test(
        'inbound from a blocked contact is kept but silent: no unread bump, no receipt',
        () async {
      final convoId = await blockedConvo();
      when(() => api.ackMessages(any())).thenAnswer((_) async => 1);
      clearInteractions(api);

      ws.push(_envelope(
        conversationId: convoId,
        senderDeviceId: 'peer-dev',
        envelopeType: EnvelopeType.textLegacy,
      ));
      await pumpEventQueue();

      final convo = notifier.byId(convoId)!;
      // Message is decrypted + kept (crypto continuity / available on unblock)…
      expect(convo.messages.length, equals(1));
      expect(convo.messages.single.body, equals('hi'));
      // …but stays silent: no unread bump and no delivered receipt emitted.
      expect(convo.unreadCount, equals(0));
      verifyNever(() => api.submitMessage(any()));
    });

    test('sendMessage to a blocked conversation is a no-op', () async {
      final convoId = await blockedConvo();
      clearInteractions(api);

      await notifier.sendMessage(
        conversationId: convoId,
        myDeviceId: _myDeviceId,
        text: 'should not send',
      );

      verifyNever(() => api.submitMessage(any()));
      expect(notifier.byId(convoId)!.messages, isEmpty);
    });
  });

  group('per-conversation settings (mute / disappearing / clear)', () {
    Future<String> seedSimpleConvo({int disappearingTtl = -1}) async {
      const convoId = 'pcs-convo';
      notifier.seed(Conversation(
        id: convoId,
        peerUsername: _peerUsername,
        peerAccountId: _peerAccountId,
        peerDeviceId: 'peer-dev',
        peerIdentityPubKey: const [9, 8, 7],
        peerX25519PubKey: const [1, 2, 3],
        messages: [
          ChatMessage(
            envelopeId: 'm1',
            conversationId: convoId,
            senderDeviceId: 'peer-dev',
            body: 'old message',
            serverTs: DateTime.utc(2026, 5, 1),
            mine: false,
          ),
        ],
        unreadCount: 1,
        disappearingTtl: disappearingTtl,
      ));
      return convoId;
    }

    test('setMuted persists and isMuted reflects it', () async {
      final convoId = await seedSimpleConvo();
      expect(notifier.isMuted(convoId), isFalse);

      await notifier.setMuted(convoId, true);
      expect(notifier.isMuted(convoId), isTrue);
      var loaded = await db.loadConversations();
      expect(loaded.singleWhere((c) => c.id == convoId).muted, isTrue);

      await notifier.setMuted(convoId, false);
      expect(notifier.isMuted(convoId), isFalse);
      loaded = await db.loadConversations();
      expect(loaded.singleWhere((c) => c.id == convoId).muted, isFalse);
    });

    test('setDisappearingTtl persists; -1 reverts to the global default',
        () async {
      final convoId = await seedSimpleConvo();
      expect(notifier.disappearingTtlOf(convoId), -1);

      await notifier.setDisappearingTtl(convoId, 86400);
      expect(notifier.disappearingTtlOf(convoId), 86400);
      var loaded = await db.loadConversations();
      expect(
          loaded.singleWhere((c) => c.id == convoId).disappearingTtl, 86400);

      await notifier.setDisappearingTtl(convoId, -1);
      expect(notifier.disappearingTtlOf(convoId), -1);
      loaded = await db.loadConversations();
      expect(loaded.singleWhere((c) => c.id == convoId).disappearingTtl, -1);
    });

    test('setDisappearingTtl clamps a non-positive value to the default (-1)',
        () async {
      final convoId = await seedSimpleConvo();
      await notifier.setDisappearingTtl(convoId, 0);
      expect(notifier.disappearingTtlOf(convoId), -1);
    });

    test('clearMessages wipes the transcript but keeps the conversation',
        () async {
      final convoId = await seedSimpleConvo();
      expect(notifier.byId(convoId)!.messages, isNotEmpty);

      await notifier.clearMessages(convoId);

      final convo = notifier.byId(convoId);
      expect(convo, isNotNull, reason: 'the contact/conversation stays');
      expect(convo!.messages, isEmpty);
      expect(convo.unreadCount, 0);
      final loaded = await db.loadConversations();
      expect(loaded.singleWhere((c) => c.id == convoId).messages, isEmpty);
    });

    test(
        'a per-conversation disappearing override drives the _ttl header on '
        'send even with no global default', () async {
      await sessions.save(session);
      await notifier.connect();
      when(() => api.lookupAccount(_peerUsername))
          .thenAnswer((_) async => _peerAccount());
      final convoId = await notifier.startConversation(
        myDeviceId: _myDeviceId,
        username: _peerUsername,
      );
      await notifier.setDisappearingTtl(convoId, 3600);
      when(() => api.submitMessage(any())).thenAnswer((_) async =>
          SubmitMessageResult(
              envelopeId: 'env-ttl', serverTs: DateTime.utc(2026, 5, 8)));

      await notifier.sendMessage(
        conversationId: convoId,
        myDeviceId: _myDeviceId,
        text: 'secret',
      );

      final captured = verify(() => api.submitMessage(captureAny()))
          .captured
          .single as SubmitMessagePayload;
      expect(_stripCid(captured.ciphertext), '{"_ttl":3600}\nsecret');
      // Server retention matches the override too.
      expect(captured.ttlSeconds, 3600);
    });
  });

  group('view once', () {
    Future<String> startChat() async {
      await sessions.save(session);
      await notifier.connect();
      when(() => api.lookupAccount(_peerUsername))
          .thenAnswer((_) async => _peerAccount());
      when(() => api.ackMessages(any())).thenAnswer((_) async => 1);
      when(() => api.submitMessage(any())).thenAnswer((_) async =>
          SubmitMessageResult(
              envelopeId: 'env-sent', serverTs: DateTime.utc(2026, 11, 7)));
      return notifier.startConversation(
        myDeviceId: _myDeviceId,
        username: _peerUsername,
      );
    }

    Future<String> receiveViewOnce(String text) async {
      final convoId = await startChat();
      ws.push(_envelope(
        conversationId: convoId,
        senderDeviceId: 'peer-dev',
        envelopeType: EnvelopeType.textLegacy,
        envelopeId: 'env-once',
        ciphertext: utf8.encode('{"_cid":"peer-cid-1"}\n{"_once":1}\n$text'),
      ));
      await pumpEventQueue();
      return convoId;
    }

    test('a view-once send carries the marker', () async {
      final convoId = await startChat();

      await notifier.sendMessage(
        conversationId: convoId,
        myDeviceId: _myDeviceId,
        text: 'secret',
        viewOnce: true,
      );

      final captured = verify(() => api.submitMessage(captureAny()))
          .captured
          .last as SubmitMessagePayload;
      expect(_stripCid(captured.ciphertext), '{"_once":1}\nsecret');
    });

    test('an ordinary send has no marker', () async {
      final convoId = await startChat();

      await notifier.sendMessage(
        conversationId: convoId,
        myDeviceId: _myDeviceId,
        text: 'plain',
      );

      final captured = verify(() => api.submitMessage(captureAny()))
          .captured
          .last as SubmitMessagePayload;
      expect(_stripCid(captured.ciphertext), 'plain');
    });

    test('a received view-once message is flagged', () async {
      final convoId = await receiveViewOnce('secret');

      expect(notifier.byId(convoId)!.messages.single.viewOnce, isTrue);
    });

    test('an unopened view-once message expires within 14 days', () async {
      final convoId = await receiveViewOnce('secret');

      final m = notifier.byId(convoId)!.messages.single;
      expect(m.expiresAt, isNotNull);
      expect(m.expiresAt!.difference(m.serverTs).inDays, lessThanOrEqualTo(14));
    });

    test('opening it hands over the content once', () async {
      final convoId = await receiveViewOnce('secret');

      final content = await notifier.openViewOnce(convoId, 'env-once');

      expect(content!.text, 'secret');
    });

    test('opening it empties the message', () async {
      final convoId = await receiveViewOnce('secret');

      await notifier.openViewOnce(convoId, 'env-once');

      final m = notifier.byId(convoId)!.messages.single;
      expect(m.body, isEmpty);
      expect(m.viewOnceOpenedAt, isNotNull);
    });

    test('it cannot be opened twice', () async {
      final convoId = await receiveViewOnce('secret');
      await notifier.openViewOnce(convoId, 'env-once');

      expect(await notifier.openViewOnce(convoId, 'env-once'), isNull);
    });

    test('the sender is told it was opened', () async {
      final convoId = await receiveViewOnce('secret');

      await notifier.openViewOnce(convoId, 'env-once');
      await pumpEventQueue();

      final bodies = verify(() => api.submitMessage(captureAny()))
          .captured
          .cast<SubmitMessagePayload>()
          .map((p) => utf8.decode(p.ciphertext));
      expect(bodies.any((b) => b.contains('"view_once_opened"') &&
          b.contains('peer-cid-1')), isTrue);
    });

    test('our own view-once message cannot be opened here', () async {
      final convoId = await startChat();
      await notifier.sendMessage(
        conversationId: convoId,
        myDeviceId: _myDeviceId,
        text: 'secret',
        viewOnce: true,
      );
      final mine = notifier.byId(convoId)!.messages.single;

      expect(await notifier.openViewOnce(convoId, mine.envelopeId), isNull);
    });

    test('a view-once message cannot be forwarded', () async {
      final convoId = await receiveViewOnce('secret');
      final m = notifier.byId(convoId)!.messages.single;

      expect(
          await notifier.forwardMessage(
              source: m, targetConversationId: convoId),
          isFalse);
    });
  });

  group('group invites (accept / reject)', () {
    Conversation pendingGroup({List<GroupMember> members = const []}) =>
        Conversation(
          id: 'group:invited',
          peerUsername: '',
          peerAccountId: '',
          peerDeviceId: '',
          peerIdentityPubKey: const [],
          peerX25519PubKey: const [],
          messages: const [],
          unreadCount: 0,
          kind: ConversationKind.group,
          groupName: 'Invited Group',
          members: members,
          mlsEpoch: 1,
          cryptoMode: CryptoMode.mls,
          pending: true,
        );

    test('a group Welcome from someone else creates a PENDING group invite',
        () async {
      await sessions.save(session);
      await notifier.connect();

      ws.push(_envelope(
        conversationId: 'group:fresh-invite',
        senderDeviceId: 'peer-dev', // not one of our devices
        envelopeType: EnvelopeType.mlsWelcome,
        ciphertext: const [1, 2, 3],
      ));
      await pumpEventQueue();

      final convo = notifier.byId('group:fresh-invite');
      expect(convo, isNotNull);
      expect(convo!.kind, ConversationKind.group);
      expect(convo.pending, isTrue,
          reason: 'an invite from another account must be accepted first');
    });

    test('a self-synced group Welcome (our own device) is NOT pending',
        () async {
      await sessions.save(session);
      await notifier.connect();

      ws.push(_envelope(
        conversationId: 'group:self-join',
        senderDeviceId: _myDeviceId, // our own device pulled us in
        envelopeType: EnvelopeType.mlsWelcome,
        ciphertext: const [1, 2, 3],
      ));
      await pumpEventQueue();

      final convo = notifier.byId('group:self-join');
      expect(convo, isNotNull);
      expect(convo!.pending, isFalse,
          reason: 'we already joined elsewhere — just auto-join this device');
    });

    test(
        'a group application arriving before its Welcome creates a pending '
        'GROUP placeholder, not a 1:1 unknown-peer stub', () async {
      await sessions.save(session);
      await notifier.connect();

      ws.push(_envelope(
        conversationId: 'group:racy',
        senderDeviceId: 'peer-dev',
        envelopeType: EnvelopeType.mlsApplication,
        ciphertext: const [1, 2, 3],
      ));
      await pumpEventQueue();

      final convo = notifier.byId('group:racy');
      expect(convo, isNotNull);
      expect(convo!.kind, ConversationKind.group,
          reason: 'a group: id must never seed a 1:1 conversation');
      expect(convo.pending, isTrue);
      expect(convo.cryptoMode, CryptoMode.mls);
    });

    test(
        'a group Welcome upgrades a stale 1:1 unknown-peer stub under the '
        'group id to a group-kind conversation', () async {
      await sessions.save(session);
      await notifier.connect();
      // The stub an application-before-Welcome race used to leave behind
      // (kind 1:1, unknown peer, ratchet) — e.g. persisted by an older build.
      notifier.seed(const Conversation(
        id: 'group:stale-stub',
        peerUsername: 'unknown',
        peerAccountId: '',
        peerDeviceId: 'peer-dev',
        peerIdentityPubKey: [],
        messages: [],
        unreadCount: 1,
        pending: true,
      ));

      ws.push(_envelope(
        conversationId: 'group:stale-stub',
        senderDeviceId: 'peer-dev',
        envelopeType: EnvelopeType.mlsWelcome,
        ciphertext: const [1, 2, 3],
      ));
      await pumpEventQueue();

      final convo = notifier.byId('group:stale-stub');
      expect(convo, isNotNull);
      expect(convo!.kind, ConversationKind.group,
          reason: 'the Welcome proves this id is a group');
      expect(convo.cryptoMode, CryptoMode.mls);
      expect(convo.pending, isTrue,
          reason: 'still an invite from another account');
    });

    test(
        'a poison group Welcome (processWelcome + replaceGroup both fail) '
        'still leaves a group-kind placeholder so a re-add can repair it',
        () async {
      await sessions.save(session);
      await notifier.connect();
      crypto.processWelcomeError = const MlsArgumentException('consumed kp');
      crypto.replaceGroupError = const MlsArgumentException('conflict');
      addTearDown(() {
        crypto.processWelcomeError = null;
        crypto.replaceGroupError = null;
      });

      ws.push(_envelope(
        conversationId: 'group:poisoned',
        senderDeviceId: 'peer-dev',
        envelopeType: EnvelopeType.mlsWelcome,
        ciphertext: const [1, 2, 3],
      ));
      await pumpEventQueue();

      final convo = notifier.byId('group:poisoned');
      expect(convo, isNotNull,
          reason: 'the acked-as-consumed Welcome must leave a repair surface');
      expect(convo!.kind, ConversationKind.group);
      expect(convo.cryptoMode, CryptoMode.mls);
      expect(convo.pending, isTrue);
    });

    test(
        'a decrypted group_info repairs a 1:1-kind stub under a group id to '
        'group-kind with the broadcast name and roster', () async {
      await sessions.save(session);
      await notifier.connect();
      // Stub already flipped to MLS by a Welcome on an older build (group
      // state exists, kind never repaired).
      notifier.seed(const Conversation(
        id: 'group:flip-stub',
        peerUsername: 'unknown',
        peerAccountId: '',
        peerDeviceId: 'peer-dev',
        peerIdentityPubKey: [],
        messages: [],
        unreadCount: 0,
        cryptoMode: CryptoMode.mls,
        pending: true,
      ));
      final info = SystemEvent.groupInfo(
        groupName: 'Trip',
        members: const [
          GroupInfoMember(
            accountId: 'acc-admin',
            username: '@admin',
            deviceId: 'peer-dev',
            identityPubKey: [],
            x25519PubKey: [],
            isAdmin: true,
          ),
          GroupInfoMember(
            accountId: 'me-acc',
            username: '@me',
            deviceId: _myDeviceId,
            identityPubKey: [],
            x25519PubKey: [],
            isAdmin: false,
          ),
        ],
        epoch: 1,
      );

      ws.push(_envelope(
        conversationId: 'group:flip-stub',
        senderDeviceId: 'peer-dev',
        envelopeType: EnvelopeType.mlsApplication,
        ciphertext: utf8.encode(info.toJsonString()),
      ));
      await pumpEventQueue();

      final convo = notifier.byId('group:flip-stub');
      expect(convo, isNotNull);
      expect(convo!.kind, ConversationKind.group,
          reason: 'a decrypted group_info is proof this is a group');
      expect(convo.groupName, 'Trip');
      expect(convo.members, hasLength(2));
    });

    test('acceptGroupInvite clears pending and persists', () async {
      await sessions.save(session);
      await notifier.connect();
      notifier.seed(pendingGroup());
      expect(notifier.byId('group:invited')!.pending, isTrue);

      await notifier.acceptGroupInvite('group:invited');

      expect(notifier.byId('group:invited')!.pending, isFalse);
      final loaded = await db.loadConversations();
      expect(
          loaded.singleWhere((c) => c.id == 'group:invited').pending, isFalse);
    });

    test('rejectGroupInvite leaves the group and deletes it locally', () async {
      await sessions.save(session);
      await notifier.connect();
      notifier.seed(pendingGroup(members: const [
        GroupMember(
          accountId: 'me-acc',
          username: '@me',
          deviceId: _myDeviceId,
          identityPubKey: [],
          x25519PubKey: [],
          isAdmin: false,
          isSelf: true,
        ),
        GroupMember(
          accountId: 'acc-a',
          username: '@a',
          deviceId: 'dev-a',
          identityPubKey: [],
          x25519PubKey: [],
          isAdmin: true,
          isSelf: false,
        ),
      ]));

      await notifier.rejectGroupInvite('group:invited');

      // Self-leave removes the conversation locally…
      expect(notifier.byId('group:invited'), isNull);
      // …and fanned a removal Commit (mls_handshake) to the group.
      final commits = verify(() => api.submitMessage(captureAny()))
          .captured
          .cast<SubmitMessagePayload>()
          .where((p) => p.envelopeType == EnvelopeType.mlsHandshake);
      expect(commits, isNotEmpty);
    });
  });

  group('call signaling', () {
    Conversation callConvo({
      String id = 'mls-convo-call',
      bool pending = false,
      bool blocked = false,
      ConversationKind kind = ConversationKind.oneToOne,
    }) =>
        Conversation(
          id: id,
          peerUsername: _peerUsername,
          peerAccountId: _peerAccountId,
          peerDeviceId: 'peer-dev',
          peerIdentityPubKey: const [9, 8, 7],
          peerX25519PubKey: const [1, 2, 3],
          messages: const [],
          unreadCount: 0,
          cryptoMode: CryptoMode.mls,
          pending: pending,
          blocked: blocked,
          kind: kind,
        );

    test('inbound CallSignal is dispatched to onCallSignal, not rendered',
        () async {
      await sessions.save(session);
      await notifier.connect();
      notifier.seed(callConvo());
      final received = <CallSignal>[];
      String? gotConvoId;
      String? gotSender;
      notifier.onCallSignal = (cid, sig, sender) {
        gotConvoId = cid;
        gotSender = sender;
        received.add(sig);
      };

      ws.push(_envelope(
        conversationId: 'mls-convo-call',
        envelopeType: EnvelopeType.mlsApplication,
        ciphertext: utf8.encode(CallSignal.invite(
          callId: 'call-1',
          mediaKind: CallMediaKind.audio,
          fromDeviceId: 'peer-dev',
        ).encode()),
      ));
      await pumpEventQueue();

      expect(received.single.type, CallSignalType.invite);
      expect(received.single.callId, 'call-1');
      expect(gotConvoId, 'mls-convo-call');
      expect(gotSender, 'peer-dev');
      // Never rendered as a chat bubble.
      expect(notifier.byId('mls-convo-call')!.messages, isEmpty);
      // Carrier consumed.
      verify(() => api.ackMessages(any())).called(greaterThanOrEqualTo(1));
    });

    test('isCallable: accepted 1:1 yes; pending / blocked / group no', () {
      notifier.seed(callConvo(id: 'ok'));
      notifier.seed(callConvo(id: 'pend', pending: true));
      notifier.seed(callConvo(id: 'blk', blocked: true));
      notifier.seed(callConvo(id: 'grp', kind: ConversationKind.group));

      expect(notifier.isCallable('ok'), isTrue);
      expect(notifier.isCallable('pend'), isFalse);
      expect(notifier.isCallable('blk'), isFalse);
      expect(notifier.isCallable('grp'), isFalse);
      expect(notifier.isCallable('does-not-exist'), isFalse);
    });

    test('sendCallSignal submits an encrypted control to the peer device',
        () async {
      await sessions.save(session);
      await notifier.connect();
      notifier.seed(callConvo());
      clearInteractions(api);
      when(() => api.submitMessage(any())).thenAnswer((_) async =>
          SubmitMessageResult(
              envelopeId: 'env-call', serverTs: DateTime.utc(2026)));

      await notifier.sendCallSignal('mls-convo-call', CallSignal.ringing('call-1'));

      final captured = verify(() => api.submitMessage(captureAny()))
          .captured
          .single as SubmitMessagePayload;
      expect(captured.recipientAccountId, _peerAccountId);
      expect(captured.recipientDeviceId, 'peer-dev');
      expect(utf8.decode(captured.ciphertext),
          CallSignal.ringing('call-1').encode());
    });

    test('appendCallLog adds a local system call-log line', () async {
      notifier.seed(callConvo());
      await notifier.appendCallLog(
        conversationId: 'mls-convo-call',
        outgoing: true,
        outcome: 'completed',
        durationSeconds: 65,
      );
      final msgs = notifier.byId('mls-convo-call')!.messages;
      expect(msgs.single.kind, MessageKind.system);
      final ev = SystemEvent.tryDecode(msgs.single.body)!;
      expect(ev.kind, SystemEventKind.call);
      expect(ev.displayText, 'Outgoing call · 1:05');
    });
  });

  group('reactions', () {
    Conversation reactConvo() => Conversation(
          id: 'rc',
          peerUsername: _peerUsername,
          peerAccountId: _peerAccountId,
          peerDeviceId: 'peer-dev',
          peerIdentityPubKey: const [9, 8, 7],
          peerX25519PubKey: const [1, 2, 3],
          cryptoMode: CryptoMode.mls,
          messages: [
            ChatMessage(
              envelopeId: 'msg-1',
              conversationId: 'rc',
              senderDeviceId: 'peer-dev',
              body: 'hi',
              serverTs: DateTime.utc(2026, 5, 7, 12),
              mine: false,
            ),
          ],
          unreadCount: 0,
        );

    ChatMessage reactedMessage() => notifier
        .byId('rc')!
        .messages
        .firstWhere((m) => m.envelopeId == 'msg-1');

    test('react adds the current user reaction and persists it', () async {
      await sessions.save(session);
      await notifier.connect();
      final convo = reactConvo();
      notifier.seed(convo);
      await db.upsertConversation(convo);
      await db.upsertMessages('rc', convo.messages);

      await notifier.react(
          conversationId: 'rc', targetEnvelopeId: 'msg-1', emoji: '👍');
      await pumpEventQueue();

      expect(reactedMessage().reactions, {'me-acc': '👍'});
      final loaded = await db.loadMessages('rc', limit: 50);
      expect(loaded.firstWhere((m) => m.envelopeId == 'msg-1').reactions,
          {'me-acc': '👍'});
    });

    test('reacting with the same emoji again toggles it off', () async {
      await sessions.save(session);
      await notifier.connect();
      final convo = reactConvo();
      notifier.seed(convo);
      await db.upsertMessages('rc', convo.messages);

      await notifier.react(
          conversationId: 'rc', targetEnvelopeId: 'msg-1', emoji: '👍');
      await notifier.react(
          conversationId: 'rc', targetEnvelopeId: 'msg-1', emoji: '👍');
      await pumpEventQueue();

      expect(reactedMessage().reactions, isEmpty);
    });

    test('reacting with a different emoji replaces the previous one', () async {
      await sessions.save(session);
      await notifier.connect();
      final convo = reactConvo();
      notifier.seed(convo);
      await db.upsertMessages('rc', convo.messages);

      await notifier.react(
          conversationId: 'rc', targetEnvelopeId: 'msg-1', emoji: '👍');
      await notifier.react(
          conversationId: 'rc', targetEnvelopeId: 'msg-1', emoji: '❤️');
      await pumpEventQueue();

      expect(reactedMessage().reactions, {'me-acc': '❤️'});
    });

    test('react fans the reaction control out to the peer', () async {
      final submitted = <SubmitMessagePayload>[];
      when(() => api.submitMessage(any())).thenAnswer((inv) async {
        submitted.add(inv.positionalArguments.first as SubmitMessagePayload);
        return SubmitMessageResult(
            envelopeId: 'srv', serverTs: DateTime.utc(2026));
      });
      await sessions.save(session);
      await notifier.connect();
      final convo = reactConvo();
      notifier.seed(convo);
      await db.upsertMessages('rc', convo.messages);

      await notifier.react(
          conversationId: 'rc', targetEnvelopeId: 'msg-1', emoji: '👍');
      await pumpEventQueue();

      // A reaction control rode the encrypted path to the peer.
      final reaction = submitted
          .where((p) => p.conversationId == 'rc')
          .map((p) => MessageControl.tryDecode(utf8.decode(p.ciphertext)))
          .firstWhere((c) => c != null && c.isReaction, orElse: () => null);
      expect(reaction, isNotNull);
      expect(reaction!.reactionEmoji, '👍');
      expect(reaction.targetEnvelopeId, 'msg-1');
    });

    test('an inbound reaction from the peer is applied under the peer account',
        () async {
      await sessions.save(session);
      await notifier.connect();
      final convo = reactConvo();
      notifier.seed(convo);
      await db.upsertMessages('rc', convo.messages);

      ws.push(_envelope(
        envelopeId: 'react-env',
        conversationId: 'rc',
        senderDeviceId: 'peer-dev',
        envelopeType: EnvelopeType.mlsApplication,
        ciphertext: utf8.encode(
          const MessageControl.reaction(
                  targetEnvelopeId: 'msg-1', emoji: '😂')
              .encode(),
        ),
      ));
      await pumpEventQueue();

      // Keyed by the PEER's account id (not the device), and not rendered as a
      // new bubble.
      expect(reactedMessage().reactions, {_peerAccountId: '😂'});
      expect(notifier.byId('rc')!.messages.length, 1);
    });

    test('an inbound reaction to a not-loaded message persists to the DB',
        () async {
      await sessions.save(session);
      await notifier.connect();
      // Conversation loaded with NO messages in memory; the reaction target
      // lives only in the DB (older / scrolled out of the window).
      notifier.seed(reactConvo().copyWith(messages: const []));
      await db.upsertMessages('rc', [
        ChatMessage(
          envelopeId: 'old-msg',
          conversationId: 'rc',
          senderDeviceId: 'peer-dev',
          body: 'older',
          serverTs: DateTime.utc(2026),
          mine: false,
        ),
      ]);

      ws.push(_envelope(
        envelopeId: 'react-old',
        conversationId: 'rc',
        senderDeviceId: 'peer-dev',
        envelopeType: EnvelopeType.mlsApplication,
        ciphertext: utf8.encode(
          const MessageControl.reaction(targetEnvelopeId: 'old-msg', emoji: '🙏')
              .encode(),
        ),
      ));
      await pumpEventQueue();

      final stored = await db.getMessage('old-msg');
      expect(stored, isNotNull);
      expect(stored!.reactions, {_peerAccountId: '🙏'});
    });
  });

  group('pinned messages', () {
    Conversation pinConvo() => Conversation(
          id: 'pc',
          peerUsername: _peerUsername,
          peerAccountId: _peerAccountId,
          peerDeviceId: 'peer-dev',
          peerIdentityPubKey: const [9, 8, 7],
          peerX25519PubKey: const [1, 2, 3],
          cryptoMode: CryptoMode.mls,
          messages: [
            ChatMessage(
              envelopeId: 'p1',
              conversationId: 'pc',
              senderDeviceId: 'peer-dev',
              body: 'pin me',
              serverTs: DateTime.utc(2026, 5, 7, 12),
              mine: false,
            ),
          ],
          unreadCount: 0,
        );

    test('setConversationPin sets the pin, persists, fans a control out, clears',
        () async {
      final submitted = <SubmitMessagePayload>[];
      when(() => api.submitMessage(any())).thenAnswer((inv) async {
        submitted.add(inv.positionalArguments.first as SubmitMessagePayload);
        return SubmitMessageResult(
            envelopeId: 'srv', serverTs: DateTime.utc(2026));
      });
      await sessions.save(session);
      await notifier.connect();
      final convo = pinConvo();
      notifier.seed(convo);
      await db.upsertMessages('pc', convo.messages);

      await notifier.setConversationPin('pc', 'p1');
      await pumpEventQueue();
      expect(notifier.byId('pc')!.pinnedEnvelopeId, 'p1');
      // Persisted on the conversation row.
      expect(
        (await db.loadConversations())
            .firstWhere((c) => c.id == 'pc')
            .pinnedEnvelopeId,
        'p1',
      );
      // A pin control rode the encrypted path to the peer.
      final pin = submitted
          .where((p) => p.conversationId == 'pc')
          .map((p) => MessageControl.tryDecode(utf8.decode(p.ciphertext)))
          .firstWhere((c) => c != null && c.isPin, orElse: () => null);
      expect(pin, isNotNull);
      expect(pin!.targetEnvelopeId, 'p1');
      expect(pin.pinRemove, isFalse);

      await notifier.setConversationPin('pc', null);
      await pumpEventQueue();
      expect(notifier.byId('pc')!.pinnedEnvelopeId, isNull);
    });

    test('an inbound pin control from the peer sets, then a remove clears it',
        () async {
      await sessions.save(session);
      await notifier.connect();
      final convo = pinConvo();
      notifier.seed(convo);
      await db.upsertMessages('pc', convo.messages);

      ws.push(_envelope(
        envelopeId: 'pin-env',
        conversationId: 'pc',
        senderDeviceId: 'peer-dev',
        envelopeType: EnvelopeType.mlsApplication,
        ciphertext:
            utf8.encode(const MessageControl.pin(targetEnvelopeId: 'p1').encode()),
      ));
      await pumpEventQueue();
      expect(notifier.byId('pc')!.pinnedEnvelopeId, 'p1');
      // Control, not a bubble — message count unchanged.
      expect(notifier.byId('pc')!.messages.length, 1);

      ws.push(_envelope(
        envelopeId: 'pin-env-2',
        conversationId: 'pc',
        senderDeviceId: 'peer-dev',
        envelopeType: EnvelopeType.mlsApplication,
        ciphertext: utf8.encode(
          const MessageControl.pin(targetEnvelopeId: 'p1', remove: true).encode(),
        ),
      ));
      await pumpEventQueue();
      expect(notifier.byId('pc')!.pinnedEnvelopeId, isNull);
    });

    test('a stale unpin for a different id leaves the current pin intact',
        () async {
      await sessions.save(session);
      await notifier.connect();
      notifier.seed(pinConvo().copyWith(pinnedEnvelopeId: 'p1'));

      ws.push(_envelope(
        envelopeId: 'pin-stale',
        conversationId: 'pc',
        senderDeviceId: 'peer-dev',
        envelopeType: EnvelopeType.mlsApplication,
        ciphertext: utf8.encode(
          const MessageControl.pin(targetEnvelopeId: 'other', remove: true)
              .encode(),
        ),
      ));
      await pumpEventQueue();
      expect(notifier.byId('pc')!.pinnedEnvelopeId, 'p1');
    });
  });

  // User-reported 2026-10-21: "the first message I send to someone (before they
  // accept the invitation) sometimes gets lost and all they receive is the
  // invitation". The request row appeared EMPTY: resolving the unknown sender
  // only seeded the conversation and left decrypting the message to a detached
  // network refetch. Anything that moved the conversation to MLS first — the
  // recipient opening the request (warm-up migration) or the delivered receipt
  // migrating as the leader — turned that message into a text_legacy for an
  // MLS-mode 1:1, which was never decrypted and was eventually ack+dropped.
  group('first message of a new contact (before accept)', () {
    final requestId = Conversation.oneToOneId('me-acc', _peerAccountId);

    FetchKeyPackageResult keyPackage() => FetchKeyPackageResult(
          keyPackage: List<int>.filled(64, 0xBB),
          replenishNeeded: false,
          remainingForUser: 9,
        );

    String seedMlsOneToOne() {
      const convoId = 'mls-first-contact';
      notifier.seed(Conversation(
        id: convoId,
        peerUsername: _peerUsername,
        peerAccountId: _peerAccountId,
        peerDeviceId: 'peer-dev',
        peerIdentityPubKey: const [9, 8, 7],
        peerX25519PubKey: const [1, 2, 3],
        messages: const [],
        unreadCount: 0,
        cryptoMode: CryptoMode.mls,
      ));
      return convoId;
    }

    test('is decrypted in the same pass that creates the message request',
        () async {
      await sessions.save(session);
      await notifier.connect();
      when(() => api.lookupAccountByDevice('peer-dev'))
          .thenAnswer((_) async => _peerAccount());
      // The held-envelope refetch finds nothing (setUp default): the first
      // message must not depend on that extra round-trip.

      ws.push(_envelope(
        envelopeId: 'first',
        conversationId: requestId,
        envelopeType: EnvelopeType.textLegacy,
        ciphertext: utf8.encode('hello'),
      ));
      await pumpEventQueue();

      expect(notifier.byId(requestId)!.messages.map((m) => m.body),
          contains('hello'));
    });

    test('survives the request being opened before the refetch returns',
        () async {
      await sessions.save(session);
      await notifier.connect();
      when(() => api.lookupAccountByDevice('peer-dev'))
          .thenAnswer((_) async => _peerAccount());
      // We are the migration leader ('me-acc' < 'peer-acc') and the peer has
      // key packages, so opening the thread migrates the request to MLS.
      when(() => api.lookupKeyPackage(any()))
          .thenAnswer((_) async => keyPackage());
      final refetch = Completer<List<Envelope>>();
      when(() => api.catchupMessages(
          since: any(named: 'since'),
          limit: any(named: 'limit'))).thenAnswer((_) => refetch.future);
      final first = _envelope(
        envelopeId: 'first',
        conversationId: requestId,
        envelopeType: EnvelopeType.textLegacy,
        ciphertext: utf8.encode('hello'),
      );

      ws.push(first);
      await pumpEventQueue();
      await notifier.warmUpMlsMigration(requestId);
      await pumpEventQueue();
      // The slow refetch finally hands the held message back.
      refetch.complete([first]);
      await pumpEventQueue(times: 50);

      expect(notifier.byId(requestId)!.messages.map((m) => m.body),
          contains('hello'));
    });

    test('a ratchet message that lands on an MLS-mode 1:1 is still delivered',
        () async {
      await sessions.save(session);
      await notifier.connect();
      final convoId = seedMlsOneToOne();

      ws.push(_envelope(
        envelopeId: 'late-ratchet',
        conversationId: convoId,
        envelopeType: EnvelopeType.textLegacy,
        ciphertext: utf8.encode('sent before they saw our Welcome'),
      ));
      await pumpEventQueue(times: 50);

      expect(notifier.byId(convoId)!.messages.map((m) => m.body),
          contains('sent before they saw our Welcome'));
    });

    test('a continuing-chain ratchet message does not tear the MLS group down',
        () async {
      crypto = _ChainCounterCrypto();
      notifier = buildNotifier();
      await sessions.save(session);
      await notifier.connect();
      final convoId = seedMlsOneToOne();
      when(() => api.lookupKeyPackage(any()))
          .thenAnswer((_) async => keyPackage());
      final submittedTypes = <String>[];
      when(() => api.submitMessage(any())).thenAnswer((inv) async {
        submittedTypes.add(
            (inv.positionalArguments.first as SubmitMessagePayload).envelopeType);
        return SubmitMessageResult(
            envelopeId: 'srv', serverTs: DateTime.utc(2026));
      });

      // Counter 1: the peer is still on its ORIGINAL ratchet (it just hasn't
      // processed our Welcome yet) — not a peer that lost the group.
      ws.push(_envelope(
        envelopeId: 'second',
        conversationId: convoId,
        envelopeType: EnvelopeType.textLegacy,
        ciphertext: [1, ...utf8.encode('second')],
      ));
      await pumpEventQueue(times: 100);

      expect(submittedTypes, isNot(contains(EnvelopeType.mlsWelcome)));
    });

    test('a redelivered ratchet message is not appended twice', () async {
      await sessions.save(session);
      await notifier.connect();
      when(() => api.lookupAccount(_peerUsername))
          .thenAnswer((_) async => _peerAccount());
      final convoId = await notifier.startConversation(
        myDeviceId: _myDeviceId,
        username: _peerUsername,
      );
      final env = _envelope(
        envelopeId: 'dup',
        conversationId: convoId,
        envelopeType: EnvelopeType.textLegacy,
      );

      ws.push(env);
      await pumpEventQueue();
      ws.push(env);
      await pumpEventQueue();

      expect(
          notifier.byId(convoId)!.messages.where((m) => m.envelopeId == 'dup'),
          hasLength(1));
    });
  });
}
