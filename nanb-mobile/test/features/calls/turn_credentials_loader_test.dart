import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/models/turn_credentials.dart';
import 'package:nanb_chat/features/calls/turn_credentials_loader.dart';

void main() {
  TurnCredentials creds() => const TurnCredentials(
        urls: ['turn:relay.nanb:3478?transport=udp'],
        username: 'u',
        credential: 'p',
        ttlSeconds: 600,
      );

  group('loadCallIceConfig', () {
    test('returns a relay-only ICE config on the first success', () async {
      var calls = 0;
      final cfg = await loadCallIceConfig(() async {
        calls++;
        return creds();
      }, backoff: (_) => Duration.zero);

      expect(calls, 1);
      expect(cfg.relayOnly, isTrue);
      expect(cfg.iceServers.single['urls'], creds().urls);
      expect(cfg.iceServers.single['username'], 'u');
      expect(cfg.iceServers.single['credential'], 'p');
    });

    test('retries a transient fetch failure, then succeeds', () async {
      var calls = 0;
      final cfg = await loadCallIceConfig(() async {
        calls++;
        if (calls < 3) throw StateError('turn 503');
        return creds();
      }, backoff: (_) => Duration.zero);

      expect(calls, 3, reason: 'kept retrying until the fetch succeeded');
      expect(cfg.iceServers, isNotEmpty);
    });

    test('throws after exhausting every attempt (so the call fails fast '
        'instead of hanging relay-only with no servers)', () async {
      var calls = 0;
      await expectLater(
        loadCallIceConfig(
          () async {
            calls++;
            throw StateError('turn down');
          },
          attempts: 3,
          backoff: (_) => Duration.zero,
        ),
        throwsA(isA<StateError>()),
      );
      expect(calls, 3, reason: 'tried exactly `attempts` times');
    });
  });
}
