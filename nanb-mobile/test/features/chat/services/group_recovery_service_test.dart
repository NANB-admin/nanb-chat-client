import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/crypto/add_member_result.dart';
import 'package:nanb_chat/core/crypto/crypto_bridge.dart';
import 'package:nanb_chat/core/db/app_database.dart';
import 'package:nanb_chat/core/models/account.dart';
import 'package:nanb_chat/core/models/envelope.dart' as wire;
import 'package:nanb_chat/core/models/jwt_session.dart';
import 'package:nanb_chat/core/network/api_client.dart';
import 'package:nanb_chat/core/push/push_kind.dart';
import 'package:nanb_chat/core/secure_storage/secure_storage.dart';
import 'package:nanb_chat/features/chat/models/chat_message.dart';
import 'package:nanb_chat/features/chat/models/conversation.dart';
import 'package:nanb_chat/features/chat/models/conversation_kind.dart';
import 'package:nanb_chat/features/chat/models/crypto_mode.dart';
import 'package:nanb_chat/features/chat/models/group_member.dart';
import 'package:nanb_chat/features/chat/models/group_recovery_message.dart';
import 'package:nanb_chat/features/chat/models/message_kind.dart';
import 'package:nanb_chat/features/chat/models/system_event.dart';
import 'package:nanb_chat/features/chat/services/group_recovery_service.dart';
import 'package:nanb_chat/features/chat/services/notifier_service_host.dart';
import 'package:nanb_chat/features/onboarding/session_repository.dart';

const _groupId = 'group:g1';
final _now = DateTime.utc(2026, 11, 6, 12);

class _Sessions implements SessionRepository {
  @override
  Future<JwtSession?> current() async => const JwtSession(
      accountId: 'acc-me', deviceId: 'dev-m', jwt: 'j', username: 'me');

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Db implements AppDatabase {
  @override
  Future<void> updateConversationGroupFields(String id,
      {String? groupName, int? mlsEpoch, String? groupAvatar}) async {}

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Crypto implements CryptoBridge {
  @override
  Future<Set<String>> groupMemberDeviceIds(String groupId) async => const {};

  int epoch = 7;
  bool holdsGroup = true;
  bool removeThrows = false;
  final calls = <String>[];

  @override
  Future<IdentityHandle?> currentIdentity() async => const IdentityHandle(
      id: 'i', publicKey: [1], x25519PublicKey: [2]);

  @override
  Future<List<int>> signWithIdentity(
          IdentityHandle handle, List<int> payload) async =>
      List<int>.filled(64, 9);

  @override
  Future<int> currentEpoch(String groupId) async {
    if (!holdsGroup) throw StateError('no group');
    return epoch;
  }

  @override
  Future<List<int>> removeMember(
      {required String groupId, required String targetDeviceId}) async {
    if (removeThrows) throw StateError('no leaf');
    calls.add('remove:$targetDeviceId');
    return utf8.encode('remove-commit');
  }

  @override
  Future<AddMemberResult> addMember(
      {required String groupId, required List<int> peerKeyPackage}) async {
    calls.add('add');
    return AddMemberResult(
        commit: utf8.encode('add-commit'), welcome: utf8.encode('welcome'));
  }

  @override
  Future<List<int>> encrypt(
          {required String groupId, required List<int> plaintext}) async =>
      plaintext;

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Api implements ApiClient {
  final submitted = <SubmitMessagePayload>[];
  bool sameAccount = false;

  @override
  Future<List<DeviceKeyPackageResult>> lookupDeviceKeyPackages(
          String username) async =>
      const [
        DeviceKeyPackageResult(deviceId: 'dev-x', keyPackage: [1]),
        DeviceKeyPackageResult(deviceId: 'dev-x-2', keyPackage: [2]),
      ];

  @override
  Future<Account> lookupAccountByDevice(String deviceId) async => Account(
      accountId: sameAccount ? 'acc-x' : 'acc-stranger',
      username: 'x',
      identityPubKey: const [1]);

  @override
  Future<SubmitMessageResult> submitMessage(SubmitMessagePayload p) async {
    submitted.add(p);
    return SubmitMessageResult(envelopeId: 'e', serverTs: _now);
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Host implements NotifierServiceHost {
  _Host(this.convo);

  Conversation convo;
  final submitted = <SubmitMessagePayload>[];
  @override
  final AppDatabase db = _Db();

  @override
  Conversation? conversation(String id) => id == convo.id ? convo : null;

  @override
  void setConversation(String id, Conversation c) => convo = c;

  @override
  void notifyHost() {}

  @override
  Future<T> runLocked<T>(String id, Future<T> Function() body) => body();

  @override
  Future<String> selfDeviceId() async => 'dev-m';

  @override
  Future<SubmitMessageResult> submit(SubmitMessagePayload p) async {
    submitted.add(p);
    return SubmitMessageResult(envelopeId: 'e', serverTs: _now);
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

GroupMember _member(String device, String account, List<int> key) => GroupMember(
      accountId: account,
      username: account,
      deviceId: device,
      identityPubKey: key,
      x25519PubKey: const [3],
      isAdmin: false,
      isSelf: device == 'dev-m',
    );

ChatMessage _message(String id, DateTime at,
        {bool mine = true,
        String sender = 'dev-m',
        MessageKind kind = MessageKind.text,
        String? body}) =>
    ChatMessage(
      envelopeId: id,
      conversationId: _groupId,
      senderDeviceId: sender,
      clientMsgId: 'cid-$id',
      body: body ?? 'body-$id',
      serverTs: at,
      mine: mine,
      kind: kind,
    );

class _Rig {
  _Rig(this.memberKey, {List<ChatMessage> messages = const [], this.step = Duration.zero})
      : host = _Host(Conversation(
          id: _groupId,
          peerUsername: '',
          peerAccountId: '',
          peerDeviceId: '',
          peerIdentityPubKey: const [],
          messages: messages,
          unreadCount: 0,
          kind: ConversationKind.group,
          cryptoMode: CryptoMode.mls,
          members: [
            _member('dev-m', 'acc-me', const [4]),
            _member('dev-x', 'acc-x', memberKey),
          ],
        )) {
    service = _build();
  }

  final List<int> memberKey;
  final Duration step;
  final _Host host;
  final _Crypto crypto = _Crypto();
  final _Api api = _Api();
  final SecureStorage storage = SecureStorageInMemory();
  int rejoinedCalls = 0;
  late GroupRecoveryService service;

  GroupRecoveryService _build() => GroupRecoveryService(
        host: host,
        crypto: crypto,
        api: api,
        sessions: _Sessions(),
        storage: storage,
        onRejoined: () => rejoinedCalls++,
        helperStep: step,
        clock: () => _now,
      );
}

/// A real signing key, so authenticity is checked for real.
class _Signer {
  _Signer._(this.keyPair, this.publicKey);

  final SimpleKeyPair keyPair;
  final List<int> publicKey;

  static Future<_Signer> create() async {
    final kp = await Ed25519().newKeyPair();
    return _Signer._(kp, (await kp.extractPublicKey()).bytes);
  }

  Future<wire.Envelope> envelope({
    GroupRecoveryKind kind = GroupRecoveryKind.rejoin,
    String deviceId = 'dev-x',
    String groupId = _groupId,
    int? sinceMs,
    DateTime? issuedAt,
  }) async {
    final since = sinceMs ?? 0;
    final at = (issuedAt ?? _now).millisecondsSinceEpoch;
    final sig = await Ed25519().sign(
      GroupRecoveryMessage.signingBytes(
          kind: kind,
          groupId: groupId,
          deviceId: deviceId,
          sinceMs: since,
          issuedAtMs: at),
      keyPair: keyPair,
    );
    final body = GroupRecoveryMessage(
      kind: kind,
      groupId: groupId,
      deviceId: deviceId,
      sinceMs: since,
      issuedAtMs: at,
      signature: sig.bytes,
    ).encode();
    return wire.Envelope(
      envelopeId: 'env',
      version: 'v1',
      domain: 'd',
      envelopeType: wire.EnvelopeType.groupRecovery,
      conversationId: groupId,
      senderDeviceId: deviceId,
      recipientAccountId: 'acc-me',
      recipientDeviceId: 'dev-m',
      ciphertext: body,
      serverTs: _now,
    );
  }
}

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 5));

void main() {
  late _Signer signer;

  setUp(() async => signer = await _Signer.create());

  group('asking to come back', () {
    test('asks every other member device', () async {
      final rig = _Rig(const [5]);

      await rig.service.requestRejoin(_groupId);

      expect(rig.host.submitted.single.recipientDeviceId, 'dev-x');
    });

    test('sends a group recovery envelope', () async {
      final rig = _Rig(const [5]);

      await rig.service.requestRejoin(_groupId);

      expect(rig.host.submitted.single.envelopeType,
          wire.EnvelopeType.groupRecovery);
    });

    test('does not buzz anyone', () async {
      final rig = _Rig(const [5]);

      await rig.service.requestRejoin(_groupId);

      expect(rig.host.submitted.single.pushKind, PushKind.silent);
    });

    test('does not ask again within the cooldown', () async {
      // Reconcile runs on every reconnect.
      final rig = _Rig(const [5]);

      await rig.service.requestRejoin(_groupId);
      await rig.service.requestRejoin(_groupId);

      expect(rig.host.submitted, hasLength(1));
    });

    test('says when its newest message was', () async {
      final at = _now.subtract(const Duration(hours: 2));
      final rig = _Rig(const [5], messages: [_message('a', at)]);

      await rig.service.requestRejoin(_groupId);

      final sent =
          GroupRecoveryMessage.tryDecode(rig.host.submitted.single.ciphertext)!;
      expect(sent.sinceMs, at.millisecondsSinceEpoch);
    });
  });

  group('after a Welcome', () {
    test('asks for what it missed when it had asked to come back', () async {
      final rig = _Rig(const [5]);
      await rig.service.requestRejoin(_groupId);
      rig.host.submitted.clear();

      await rig.service.onJoinedFromWelcome(_groupId);

      expect(
          GroupRecoveryMessage.tryDecode(rig.host.submitted.single.ciphertext)!
              .kind,
          GroupRecoveryKind.resync);
    });

    test('a brand-new member asks for nothing', () async {
      // It must not be able to pull history from before it joined.
      final rig = _Rig(const [5]);

      await rig.service.onJoinedFromWelcome(_groupId);

      expect(rig.host.submitted, isEmpty);
    });

    test('remembers it asked across a restart', () async {
      final rig = _Rig(const [5]);
      await rig.service.requestRejoin(_groupId);
      rig.host.submitted.clear();
      final restarted = GroupRecoveryService(
        host: rig.host,
        crypto: rig.crypto,
        api: rig.api,
        sessions: _Sessions(),
        storage: rig.storage,
        onRejoined: () {},
        clock: () => _now,
      );

      await restarted.onJoinedFromWelcome(_groupId);

      expect(rig.host.submitted, hasLength(1));
    });

    test('asks only once', () async {
      final rig = _Rig(const [5]);
      await rig.service.requestRejoin(_groupId);
      rig.host.submitted.clear();

      await rig.service.onJoinedFromWelcome(_groupId);
      await rig.service.onJoinedFromWelcome(_groupId);

      expect(rig.host.submitted, hasLength(1));
    });

    test('retries failed sends', () async {
      final rig = _Rig(const [5]);
      await rig.service.requestRejoin(_groupId);

      await rig.service.onJoinedFromWelcome(_groupId);

      expect(rig.rejoinedCalls, 1);
    });
  });

  group('helping a device back in', () {
    test('removes the old leaf then adds the device back', () async {
      final rig = _Rig(signer.publicKey);

      await rig.service.onEnvelope(await signer.envelope());
      await _settle();

      expect(rig.crypto.calls, ['remove:dev-x', 'add']);
    });

    test('sends the Welcome to the requesting device', () async {
      final rig = _Rig(signer.publicKey);

      await rig.service.onEnvelope(await signer.envelope());
      await _settle();

      final welcome = rig.api.submitted
          .where((p) => p.envelopeType == wire.EnvelopeType.mlsWelcome)
          .single;
      expect(welcome.recipientDeviceId, 'dev-x');
    });

    test('still adds it back when no old leaf is left', () async {
      // A Welcome that failed to send last time leaves it removed but not added.
      final rig = _Rig(signer.publicKey);
      rig.crypto.removeThrows = true;

      await rig.service.onEnvelope(await signer.envelope());
      await _settle();

      expect(rig.crypto.calls, ['add']);
    });

    test('ignores a device not on the roster', () async {
      final rig = _Rig(signer.publicKey);

      await rig.service.onEnvelope(await signer.envelope(deviceId: 'stranger'));
      await _settle();

      expect(rig.crypto.calls, isEmpty);
    });

    test('ignores a bad signature from another account', () async {
      final rig = _Rig(const [5]);

      await rig.service.onEnvelope(await signer.envelope());
      await _settle();

      expect(rig.crypto.calls, isEmpty);
    });

    test('accepts a linked device the server places on that account', () async {
      // A linked device signs with its own key, which the roster doesn't hold.
      final rig = _Rig(const [5]);
      rig.api.sameAccount = true;

      await rig.service.onEnvelope(await signer.envelope());
      await _settle();

      expect(rig.crypto.calls, contains('add'));
    });

    test('ignores a stale request', () async {
      final rig = _Rig(signer.publicKey);

      await rig.service.onEnvelope(await signer.envelope(
          issuedAt: _now.subtract(const Duration(days: 8))));
      await _settle();

      expect(rig.crypto.calls, isEmpty);
    });

    test('ignores a group this device does not have', () async {
      final rig = _Rig(signer.publicKey);

      await rig.service.onEnvelope(await signer.envelope(groupId: 'group:other'));
      await _settle();

      expect(rig.crypto.calls, isEmpty);
    });

    test('cannot help when it lost the group too', () async {
      final rig = _Rig(signer.publicKey);
      rig.crypto.holdsGroup = false;

      await rig.service.onEnvelope(await signer.envelope());
      await _settle();

      expect(rig.crypto.calls, isEmpty);
    });

    test('stands down if the group moved while it waited its turn', () async {
      // A device ranked ahead already re-added it; a second commit would fork.
      final rig = _Rig(signer.publicKey, step: const Duration(milliseconds: 20));
      rig.host.convo = rig.host.convo.copyWith(members: [
        _member('dev-a', 'acc-a', const [6]),
        ...rig.host.convo.members,
      ]);

      await rig.service.onEnvelope(await signer.envelope());
      rig.crypto.epoch = 8;
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(rig.crypto.calls, isEmpty);
    });

    test('helps only once per cooldown', () async {
      final rig = _Rig(signer.publicKey);

      await rig.service.onEnvelope(await signer.envelope());
      await _settle();
      rig.crypto.calls.clear();
      await rig.service.onEnvelope(await signer.envelope());
      await _settle();

      expect(rig.crypto.calls, isEmpty);
    });

    test('dispose cancels help it was waiting to give', () async {
      final rig = _Rig(signer.publicKey, step: const Duration(milliseconds: 20));
      rig.host.convo = rig.host.convo.copyWith(members: [
        _member('dev-a', 'acc-a', const [6]),
        ...rig.host.convo.members,
      ]);

      await rig.service.onEnvelope(await signer.envelope());
      rig.service.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(rig.crypto.calls, isEmpty);
    });
  });

  group('re-sending what it missed', () {
    final since = _now.subtract(const Duration(hours: 3));

    Future<List<String>> resync(_Rig rig, {int? sinceMs}) async {
      await rig.service.onEnvelope(await signer.envelope(
        kind: GroupRecoveryKind.resync,
        sinceMs: sinceMs ?? since.millisecondsSinceEpoch,
      ));
      return [
        for (final p in rig.host.submitted) utf8.decode(p.ciphertext),
      ];
    }

    test('re-sends this device\'s messages from after that time', () async {
      final rig = _Rig(signer.publicKey,
          messages: [_message('new', _now.subtract(const Duration(hours: 1)))]);

      expect((await resync(rig)).single, contains('body-new'));
    });

    test('keeps the client id so the receiver can dedup', () async {
      final rig = _Rig(signer.publicKey,
          messages: [_message('new', _now.subtract(const Duration(hours: 1)))]);

      expect((await resync(rig)).single, startsWith('{"_cid":"cid-new"}'));
    });

    test('sends to the requesting device only', () async {
      final rig = _Rig(signer.publicKey,
          messages: [_message('new', _now.subtract(const Duration(hours: 1)))]);

      await resync(rig);

      expect(rig.host.submitted.single.recipientDeviceId, 'dev-x');
    });

    test('skips what the device already has', () async {
      final rig = _Rig(signer.publicKey,
          messages: [_message('old', _now.subtract(const Duration(hours: 4)))]);

      expect(await resync(rig), isEmpty);
    });

    test('skips other people\'s messages', () async {
      final rig = _Rig(signer.publicKey, messages: [
        _message('theirs', _now.subtract(const Duration(hours: 1)),
            mine: false, sender: 'dev-a'),
      ]);

      expect(await resync(rig), isEmpty);
    });

    test('never reveals anything from before the member joined', () async {
      // Asking with an early time must not pull earlier history.
      final joinedAt = _now.subtract(const Duration(hours: 2));
      final rig = _Rig(signer.publicKey, messages: [
        _message('before', _now.subtract(const Duration(hours: 5))),
        _message(
          'joined',
          joinedAt,
          kind: MessageKind.system,
          body: SystemEvent.memberJoined(
                  accountId: 'acc-x', username: 'x', epoch: 1)
              .toJsonString(),
        ),
        _message('after', _now.subtract(const Duration(hours: 1))),
      ]);

      final sent = await resync(rig, sinceMs: 1);

      expect(sent.single, contains('body-after'));
    });

    test('answers once per cooldown', () async {
      final rig = _Rig(signer.publicKey,
          messages: [_message('new', _now.subtract(const Duration(hours: 1)))]);

      await resync(rig);
      final twice = await resync(rig);

      expect(twice, hasLength(1));
    });
  });
}
