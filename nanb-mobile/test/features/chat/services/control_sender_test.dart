import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/crypto/crypto_bridge.dart';
import 'package:nanb_chat/core/models/account.dart';
import 'package:nanb_chat/core/models/jwt_session.dart';
import 'package:nanb_chat/core/network/api_client.dart';
import 'package:nanb_chat/core/push/push_kind.dart';
import 'package:nanb_chat/features/chat/models/control_migration_outcome.dart';
import 'package:nanb_chat/features/chat/models/conversation.dart';
import 'package:nanb_chat/features/chat/models/conversation_kind.dart';
import 'package:nanb_chat/features/chat/models/crypto_mode.dart';
import 'package:nanb_chat/features/chat/models/group_member.dart';
import 'package:nanb_chat/features/chat/services/control_sender.dart';
import 'package:nanb_chat/features/chat/services/device_cache.dart';
import 'package:nanb_chat/features/chat/services/notifier_service_host.dart';
import 'package:nanb_chat/features/chat/services/ratchet_core.dart';
import 'package:nanb_chat/features/onboarding/session_repository.dart';

const _convoId = '1to1:acc-me:acc-bob';
const _groupId = 'group:g1';

class _FakeCrypto implements CryptoBridge {
  _FakeCrypto(this.order);

  final List<String> order;

  @override
  Future<List<int>> encrypt(
      {required String groupId, required List<int> plaintext}) async {
    order.add('encrypt');
    return const [1, 2, 3];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _FakeApi implements ApiClient {
  _FakeApi(this.order);

  final List<String> order;
  int lookups = 0;
  Account? lookupResult;
  bool lookupThrows = false;

  @override
  Future<Account> lookupAccount(String username) async {
    lookups++;
    if (lookupThrows) throw StateError('offline');
    return lookupResult!;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _FakeSessions implements SessionRepository {
  @override
  Future<JwtSession?> current() async => const JwtSession(
        accountId: 'acc-me',
        deviceId: 'dev-me',
        jwt: 'jwt',
        username: '@me',
      );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _FakeRatchet implements RatchetCore {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _FakeHost implements NotifierServiceHost {
  _FakeHost(this.convo, this.order);

  final Conversation convo;
  final List<String> order;
  final submitted = <SubmitMessagePayload>[];

  @override
  Conversation? conversation(String id) => convo;

  @override
  Future<T> runLocked<T>(String id, Future<T> Function() body) => body();

  @override
  Future<SubmitMessageResult> submit(SubmitMessagePayload payload) async {
    order.add('submit');
    submitted.add(payload);
    return SubmitMessageResult(envelopeId: 'e', serverTs: DateTime.utc(2026));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

Account _bob(List<String> devices) => Account(
      accountId: 'acc-bob',
      username: '@bob',
      identityPubKey: const [1],
      devices: [for (final d in devices) AccountDevice(deviceId: d)],
    );

Conversation _oneToOne() => const Conversation(
      id: _convoId,
      peerUsername: '@bob',
      peerAccountId: 'acc-bob',
      peerDeviceId: 'bob-1',
      peerIdentityPubKey: [1],
      messages: [],
      unreadCount: 0,
      cryptoMode: CryptoMode.mls,
    );

GroupMember _member(String account, String device) => GroupMember(
      accountId: account,
      username: device,
      deviceId: device,
      identityPubKey: const [1],
      x25519PubKey: const [2],
      isAdmin: false,
      isSelf: account == 'acc-me',
    );

Conversation _group(List<GroupMember> members) => Conversation(
      id: _groupId,
      peerUsername: '',
      peerAccountId: '',
      peerDeviceId: '',
      peerIdentityPubKey: const [],
      messages: const [],
      unreadCount: 0,
      kind: ConversationKind.group,
      cryptoMode: CryptoMode.mls,
      members: members,
    );

class _Rig {
  _Rig(Conversation convo, {ControlMigrationOutcome? migrationOutcome}) {
    api = _FakeApi(order);
    host = _FakeHost(convo, order);
    cache = DeviceCache(api: api);
    sender = ControlSender(
      host: host,
      crypto: crypto,
      api: api,
      sessions: _FakeSessions(),
      ratchetCore: _FakeRatchet(),
      deviceCache: cache,
      contentTtlSeconds: () => null,
      migrateMultiDevice: migrationOutcome == null
          ? null
          : (convo, body, {required force, required pushKind}) async {
              migrationCalls.add((force: force, pushKind: pushKind));
              return migrationOutcome;
            },
    );
  }

  final migrationCalls = <({bool force, String pushKind})>[];

  final order = <String>[];
  late final _FakeApi api;
  late final _FakeHost host;
  late final DeviceCache cache;
  late final ControlSender sender;
  late final _FakeCrypto crypto = _FakeCrypto(order);

  List<String> get submittedDevices =>
      [for (final p in host.submitted) p.recipientDeviceId];
}

Conversation _ratchetOneToOne() => const Conversation(
      id: _convoId,
      peerUsername: '@bob',
      peerAccountId: 'acc-bob',
      peerDeviceId: 'bob-1',
      peerIdentityPubKey: [1],
      peerX25519PubKey: [1, 2, 3],
      messages: [],
      unreadCount: 0,
    );

void main() {
  group('multi-device migration of a ratchet 1:1', () {
    test('a migrated control is not sent again through the single-peer path',
        () async {
      final rig = _Rig(_ratchetOneToOne(),
          migrationOutcome: ControlMigrationOutcome.migrated);
      rig.api.lookupResult = _bob(['bob-1', 'bob-2']);

      await rig.sender.sendControl(_convoId, '{}');

      expect(rig.host.submitted, isEmpty);
    });

    test('the migration is asked for with the re-establish force flag',
        () async {
      final rig = _Rig(_ratchetOneToOne(),
          migrationOutcome: ControlMigrationOutcome.migrated);
      rig.api.lookupResult = _bob(['bob-1', 'bob-2']);

      await rig.sender.sendControl(_convoId, '{}', forceMigration: true);

      expect(rig.migrationCalls.single.force, isTrue);
    });

    test('a migrated control goes out silent so it raises no banner', () async {
      final rig = _Rig(_ratchetOneToOne(),
          migrationOutcome: ControlMigrationOutcome.migrated);
      rig.api.lookupResult = _bob(['bob-1', 'bob-2']);

      await rig.sender.sendControl(_convoId, '{}');

      expect(rig.migrationCalls.single.pushKind, PushKind.silent);
    });

    test('the peer directory is loaded before migrating', () async {
      final rig = _Rig(_ratchetOneToOne(),
          migrationOutcome: ControlMigrationOutcome.migrated);
      rig.api.lookupResult = _bob(['bob-1', 'bob-2']);

      await rig.sender.sendControl(_convoId, '{}');

      expect(rig.api.lookups, 1);
    });
  });

  group('1:1 peer directory', () {
    test('a STALE peer device list is refreshed so a new device is addressed',
        () async {
      final rig = _Rig(_oneToOne());
      rig.cache.setPeerDevices(
        'acc-bob',
        const [AccountDevice(deviceId: 'bob-1')],
        now: DateTime.now().subtract(const Duration(minutes: 10)),
      );
      rig.api.lookupResult = _bob(['bob-1', 'bob-2']);

      await rig.sender.sendControl(_convoId, '{}', allPeerDevices: true);

      expect(rig.submittedDevices, ['bob-1', 'bob-2']);
    });

    test('a FRESH peer device list is not looked up again', () async {
      final rig = _Rig(_oneToOne());
      rig.cache.setPeerDevices(
          'acc-bob', const [AccountDevice(deviceId: 'bob-1')]);

      await rig.sender.sendControl(_convoId, '{}', allPeerDevices: true);

      expect(rig.api.lookups, 0);
    });

    test('a failed refresh keeps addressing the cached devices', () async {
      final rig = _Rig(_oneToOne());
      rig.cache.setPeerDevices(
        'acc-bob',
        const [AccountDevice(deviceId: 'bob-1'), AccountDevice(deviceId: 'bob-2')],
        now: DateTime.now().subtract(const Duration(minutes: 10)),
      );
      rig.api.lookupThrows = true;

      await rig.sender.sendControl(_convoId, '{}', allPeerDevices: true);

      expect(rig.submittedDevices, ['bob-1', 'bob-2']);
    });

    test('a cold directory is looked up', () async {
      final rig = _Rig(_oneToOne());
      rig.api.lookupResult = _bob(['bob-1', 'bob-2']);

      await rig.sender.sendControl(_convoId, '{}', allPeerDevices: true);

      expect(rig.submittedDevices, ['bob-1', 'bob-2']);
    });

    test('without allPeerDevices only the row device is addressed', () async {
      final rig = _Rig(_oneToOne());
      rig.cache.setPeerDevices(
        'acc-bob',
        const [AccountDevice(deviceId: 'bob-1'), AccountDevice(deviceId: 'bob-2')],
      );

      await rig.sender.sendControl(_convoId, '{}');

      expect(rig.submittedDevices, ['bob-1']);
    });
  });

  group('group send', () {
    final members = [
      _member('acc-me', 'dev-me'),
      _member('acc-me', 'dev-me-2'),
      _member('acc-b', 'dev-b'),
      _member('acc-c', 'dev-c'),
    ];

    test('goes to every member device except this one', () async {
      final rig = _Rig(_group(members));

      await rig.sender.sendControl(_groupId, '{}');

      expect(rig.submittedDevices, ['dev-me-2', 'dev-b', 'dev-c']);
    });

    test("includes the sender's own other devices", () async {
      final rig = _Rig(_group(members));

      await rig.sender.sendControl(_groupId, '{}');

      expect(rig.submittedDevices, contains('dev-me-2'));
    });

    test('addresses each device under its own account id', () async {
      final rig = _Rig(_group(members));

      await rig.sender.sendControl(_groupId, '{}');

      expect(
          [for (final p in rig.host.submitted) p.recipientAccountId],
          ['acc-me', 'acc-b', 'acc-c']);
    });

    test('encrypts once for the whole group', () async {
      final rig = _Rig(_group(members));

      await rig.sender.sendControl(_groupId, '{}');

      expect(rig.order.where((e) => e == 'encrypt'), hasLength(1));
    });

    test('a group with no other device sends nothing and does not throw',
        () async {
      final rig = _Rig(_group([_member('acc-me', 'dev-me')]));

      await rig.sender.sendControl(_groupId, '{}');

      expect(rig.host.submitted, isEmpty);
    });
  });

  group('onSealed', () {
    test('fires after encryption and before any submit', () async {
      final rig = _Rig(_group([
        _member('acc-me', 'dev-me'),
        _member('acc-b', 'dev-b'),
      ]));
      final order = rig.order;

      await rig.sender
          .sendControl(_groupId, '{}', onSealed: () => order.add('sealed'));

      expect(order, ['encrypt', 'sealed', 'submit']);
    });
  });
}
