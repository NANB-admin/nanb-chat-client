import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/models/api_error.dart';
import 'package:nanb_chat/core/network/transient_retry.dart';

void main() {
  TransientRetry retry({int maxRetries = 10}) => TransientRetry(
        maxRetries: maxRetries,
        delay: (_) async {}, // don't sleep the suite
      );

  group('TransientRetry', () {
    test('returns the value when the operation succeeds first time', () async {
      var calls = 0;
      final got = await retry().run(() async {
        calls++;
        return 'ok';
      });

      expect(calls, 1);
      expect(got, 'ok');
    });

    test('retries a status-less failure until it succeeds', () async {
      // The Tor-bootstrap window: the fail-closed SOCKS sentinel refuses the
      // connection, so the request never reaches the server and carries no
      // HTTP status.
      var calls = 0;
      final got = await retry().run(() async {
        calls++;
        if (calls < 3) {
          throw const ApiError(code: 'network', message: 'connection refused');
        }
        return 'ok';
      });

      expect(calls, 3);
      expect(got, 'ok');
    });

    test('does NOT retry a failure that carries an HTTP status', () async {
      // A status code means the server answered and rejected it on its merits —
      // retrying would just repeat the rejection.
      var calls = 0;

      await expectLater(
        () => retry().run(() async {
          calls++;
          throw const ApiError(
              code: 'too_large', message: 'nope', statusCode: 413);
        }),
        throwsA(isA<ApiError>()),
      );
      expect(calls, 1);
    });

    test('gives up after the retry budget and rethrows the last error',
        () async {
      var calls = 0;

      await expectLater(
        () => retry(maxRetries: 2).run(() async {
          calls++;
          throw const ApiError(code: 'network', message: 'still down');
        }),
        throwsA(isA<ApiError>()),
      );
      expect(calls, 3); // the first attempt plus 2 retries
    });

    test('backs off between attempts', () async {
      final waits = <Duration>[];
      var calls = 0;
      await TransientRetry(delay: (d) async => waits.add(d)).run(() async {
        calls++;
        if (calls < 3) {
          throw const ApiError(code: 'network', message: 'refused');
        }
        return 'ok';
      });

      expect(waits, [
        const Duration(milliseconds: 250),
        const Duration(milliseconds: 500),
      ]);
    });
  });
}
