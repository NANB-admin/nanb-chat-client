import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/models/api_error.dart';

void main() {
  group('ApiError.fromJson', () {
    test('parses a top-level {code, message}', () {
      final e = ApiError.fromJson(
        {'code': 'bad_request', 'message': 'nope'},
        statusCode: 400,
      );
      expect(e.code, 'bad_request');
      expect(e.message, 'nope');
      expect(e.statusCode, 400);
    });

    test('unwraps a nested {"error": {code, message}} envelope', () {
      // The keypackages handler historically wrapped errors this way, which
      // crashed the old top-level-only parser on a null `code`.
      final e = ApiError.fromJson(
        {
          'error': {
            'code': 'key_package_exhausted',
            'message': 'no key packages available',
          },
        },
        statusCode: 410,
      );
      expect(e.code, 'key_package_exhausted');
      expect(e.message, 'no key packages available');
      expect(e.statusCode, 410);
    });

    test('defaults code to "unknown" instead of crashing on a missing code',
        () {
      final e = ApiError.fromJson({'message': 'something went wrong'});
      expect(e.code, 'unknown');
      expect(e.message, 'something went wrong');
    });
  });
}
