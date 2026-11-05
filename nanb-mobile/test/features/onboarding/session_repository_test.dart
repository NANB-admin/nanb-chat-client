import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/models/jwt_session.dart';
import 'package:nanb_chat/core/secure_storage/secure_storage.dart';
import 'package:nanb_chat/features/onboarding/session_repository.dart';

void main() {
  group('SessionRepository', () {
    late SecureStorageInMemory storage;
    late SessionRepository repo;

    setUp(() {
      storage = SecureStorageInMemory();
      repo = SessionRepository(storage);
    });

    test('current() returns null when nothing stored', () async {
      expect(await repo.current(), isNull);
    });

    test('save then current() round-trips the session', () async {
      const session = JwtSession(
        accountId: 'acc-1',
        deviceId: 'dev-1',
        jwt: 'header.payload.sig',
        username: 'alice',
      );
      await repo.save(session);
      expect(await repo.current(), equals(session));
    });

    test('save then current() round-trips username', () async {
      const session = JwtSession(
        accountId: 'acc-1',
        deviceId: 'dev-1',
        jwt: 'tok',
        username: 'bob',
      );
      await repo.save(session);
      expect((await repo.current())?.username, equals('bob'));
    });

    test('clear() removes a stored session', () async {
      const session = JwtSession(
        accountId: 'acc-1',
        deviceId: 'dev-1',
        jwt: 'jwt',
        username: 'alice',
      );
      await repo.save(session);
      await repo.clear();
      expect(await repo.current(), isNull);
    });

    test('current() returns null when only some keys present', () async {
      await storage.putString('session.account_id', 'acc-1');
      // Missing device_id + jwt + username.
      expect(await repo.current(), isNull);
    });

    test('current() returns null when username key is missing', () async {
      await storage.putString('session.account_id', 'acc-1');
      await storage.putString('session.device_id', 'dev-1');
      await storage.putString('session.jwt', 'tok');
      // Missing username — should return null.
      expect(await repo.current(), isNull);
    });

    test('save replaces an existing session', () async {
      const a = JwtSession(accountId: 'acc-1', deviceId: 'dev-1', jwt: 'old', username: 'alice');
      const b = JwtSession(accountId: 'acc-1', deviceId: 'dev-1', jwt: 'new', username: 'alice');
      await repo.save(a);
      await repo.save(b);
      expect(await repo.current(), equals(b));
    });

    group('signed-out gate', () {
      const session = JwtSession(
        accountId: 'acc-1',
        deviceId: 'dev-1',
        jwt: 'jwt',
        username: 'alice',
      );

      test('defaults to false', () async {
        expect(await repo.isSignedOut(), isFalse);
      });

      test('setSignedOut(true) raises the gate; (false) clears it', () async {
        await repo.setSignedOut(true);
        expect(await repo.isSignedOut(), isTrue);
        await repo.setSignedOut(false);
        expect(await repo.isSignedOut(), isFalse);
      });

      test('a non-destructive sign-out keeps the session but raises the gate',
          () async {
        await repo.save(session);
        await repo.setSignedOut(true);
        // The session itself survives — that is what lets chat history + the
        // device identity persist across a sign-out.
        expect(await repo.current(), equals(session));
        expect(await repo.exists(), isTrue);
        expect(await repo.isSignedOut(), isTrue);
      });

      test('save() (fresh login) clears a lingering gate', () async {
        await repo.setSignedOut(true);
        await repo.save(session);
        expect(await repo.isSignedOut(), isFalse);
      });

      test('clear() (erase / delete-account) clears the gate', () async {
        await repo.save(session);
        await repo.setSignedOut(true);
        await repo.clear();
        expect(await repo.current(), isNull);
        expect(await repo.isSignedOut(), isFalse);
      });
    });
  });
}
