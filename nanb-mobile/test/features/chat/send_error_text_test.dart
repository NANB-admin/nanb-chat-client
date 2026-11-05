import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/crypto/mls_exceptions.dart';
import 'package:nanb_chat/core/models/api_error.dart';
import 'package:nanb_chat/core/network/ws_client.dart';
import 'package:nanb_chat/features/chat/send_error_text.dart';

void main() {
  const rawCoreCrypto = 'Mls(mlsError: WireCoreCryptoUniffi.MlsError.Other('
      'msg: "Couldn\'t find conversation"))';

  test('never shows the raw CoreCrypto message', () {
    final text =
        sendErrorText(const MlsUnknownGroupException(rawCoreCrypto));
    expect(text, isNot(contains('Mls')));
  });

  test('a lost 1:1 group tells the user to retry', () {
    final text = sendErrorText(const MlsUnknownGroupException(rawCoreCrypto));
    expect(text, contains('retry'));
  });

  test('a lost group membership asks to be re-added', () {
    final text = sendErrorText(
        const MlsUnknownGroupException(rawCoreCrypto),
        isGroup: true);
    expect(text, contains('re-add'));
  });

  test('another MLS failure is described as an encryption failure', () {
    expect(sendErrorText(const MlsIoException('io')), contains('encrypt'));
  });

  test('a gone peer device over the socket is named as such', () {
    expect(
      sendErrorText(const WsSendException('account_not_found', 'gone')),
      contains('no longer available'),
    );
  });

  test('a gone peer device over HTTP is named as such', () {
    expect(
      sendErrorText(const ApiError(
          code: 'account_not_found', message: 'gone', statusCode: 404)),
      contains('no longer available'),
    );
  });

  test('a rate limit asks the user to wait', () {
    expect(
      sendErrorText(const ApiError(
          code: 'rate_limited', message: 'slow', statusCode: 429)),
      contains('wait'),
    );
  });

  test('anything else falls back to a connection hint', () {
    expect(sendErrorText(StateError('boom')), contains('connection'));
  });
}
