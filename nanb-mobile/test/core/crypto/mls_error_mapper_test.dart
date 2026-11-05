import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/crypto/mls_error_mapper.dart';
import 'package:nanb_chat/core/crypto/mls_exceptions.dart';

void main() {
  test('mls_unknown_group maps to MlsUnknownGroupException', () {
    expect(MlsErrorMapper.fromCode('mls_unknown_group', 'x'),
        isA<MlsUnknownGroupException>());
  });

  test('mls_decrypt_failed maps to MlsDecryptException', () {
    expect(MlsErrorMapper.fromCode('mls_decrypt_failed', 'x'),
        isA<MlsDecryptException>());
  });

  test('mls_io maps to MlsIoException', () {
    expect(MlsErrorMapper.fromCode('mls_io', 'x'), isA<MlsIoException>());
  });

  test('mls_invalid_argument maps to MlsArgumentException', () {
    expect(MlsErrorMapper.fromCode('mls_invalid_argument', 'x'),
        isA<MlsArgumentException>());
  });

  test('mls_not_implemented maps to MlsNotImplementedException', () {
    expect(MlsErrorMapper.fromCode('mls_not_implemented', 'x'),
        isA<MlsNotImplementedException>());
  });

  test('an unrecognised code keeps its code in MlsUnknownException', () {
    final e = MlsErrorMapper.fromCode('mls_unknown', 'boom');
    expect(e, isA<MlsUnknownException>());
    expect((e as MlsUnknownException).code, 'mls_unknown');
  });

  test('fromErrorText extracts the code from a wrapped JS error string', () {
    final e = MlsErrorMapper.fromErrorText(
        'JavaScriptError: Error: nanb_mls_code=mls_unknown_group;Couldn\'t find conversation');
    expect(e, isA<MlsUnknownGroupException>());
  });

  test('fromErrorText keeps the message after the marker', () {
    final e = MlsErrorMapper.fromErrorText(
        'Error: nanb_mls_code=mls_decrypt_failed;We already decrypted this');
    expect(e.message, 'We already decrypted this');
  });

  test('fromErrorText without a marker falls back to MlsIoException', () {
    expect(MlsErrorMapper.fromErrorText('network exploded'),
        isA<MlsIoException>());
  });
}
