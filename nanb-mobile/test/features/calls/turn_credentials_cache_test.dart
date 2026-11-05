import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/models/turn_credentials.dart';
import 'package:nanb_chat/core/secure_storage/secure_storage.dart';
import 'package:nanb_chat/features/calls/turn_credentials_cache.dart';

void main() {
  // Mirrors the live server: 12h TTL (NANB_TURN_TTL_SECONDS default 43200).
  TurnCredentials creds({String username = 'u'}) => TurnCredentials(
        urls: const ['turn:relay.nanb:3478?transport=udp'],
        username: username,
        credential: 'p',
        ttlSeconds: 43200,
      );

  final t0 = DateTime.utc(2026, 7, 14, 12);

  group('TurnCredentialsCache', () {
    test('fetches from the network when nothing is cached', () async {
      var fetches = 0;
      final cache = TurnCredentialsCache(
        storage: SecureStorageInMemory(),
        clock: () => t0,
      );

      final got = await cache.get(() async {
        fetches++;
        return creds();
      });

      expect(fetches, 1);
      expect(got.username, 'u');
    });

    test('serves a still-valid credential without refetching', () async {
      var fetches = 0;
      final storage = SecureStorageInMemory();
      Future<TurnCredentials> fetch() async {
        fetches++;
        return creds();
      }

      await TurnCredentialsCache(storage: storage, clock: () => t0).get(fetch);
      // A later call, well inside the 12h TTL — the whole point of the cache:
      // no Tor round-trip on the call-setup path.
      final got = await TurnCredentialsCache(
        storage: storage,
        clock: () => t0.add(const Duration(hours: 6)),
      ).get(fetch);

      expect(fetches, 1);
      expect(got.username, 'u');
    });

    test('refetches a credential too close to expiry to outlive a call',
        () async {
      var fetches = 0;
      final storage = SecureStorageInMemory();
      Future<TurnCredentials> fetch() async {
        fetches++;
        return creds(username: fetches == 1 ? 'stale' : 'fresh');
      }

      await TurnCredentialsCache(storage: storage, clock: () => t0).get(fetch);
      // 30min left of the 12h TTL — inside the 1h margin. Reusing it would risk
      // coturn rejecting a mid-call permission refresh and dropping the media.
      final got = await TurnCredentialsCache(
        storage: storage,
        clock: () => t0.add(const Duration(hours: 11, minutes: 30)),
      ).get(fetch);

      expect(fetches, 2);
      expect(got.username, 'fresh');
    });

    test('refetches after clear (account switch must not reuse a credential)',
        () async {
      var fetches = 0;
      final storage = SecureStorageInMemory();
      Future<TurnCredentials> fetch() async {
        fetches++;
        return creds();
      }

      final cache = TurnCredentialsCache(storage: storage, clock: () => t0);
      await cache.get(fetch);
      await cache.clear();
      await cache.get(fetch);

      expect(fetches, 2);
    });

    test('refetches when the stored entry is unreadable', () async {
      var fetches = 0;
      final storage = SecureStorageInMemory();
      await storage.putString(TurnCredentialsCache.storageKey, 'not-json');

      await TurnCredentialsCache(storage: storage, clock: () => t0).get(() async {
        fetches++;
        return creds();
      });

      expect(fetches, 1);
    });

    test('stores the fetched credential so a later call can reuse it', () async {
      final storage = SecureStorageInMemory();

      await TurnCredentialsCache(storage: storage, clock: () => t0)
          .get(() async => creds());

      expect(await storage.getString(TurnCredentialsCache.storageKey),
          isNotNull);
    });
  });
}
