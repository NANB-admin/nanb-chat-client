import 'package:flutter_test/flutter_test.dart';

import 'package:nanb_chat/core/push/push_kind.dart';

void main() {
  test('a copy to our own account is silent', () {
    expect(
      pushKindForRecipient(recipientAccountId: 'me', selfAccountId: 'me'),
      PushKind.silent,
    );
  });

  test('a copy to another account keeps the normal wakeup', () {
    expect(
      pushKindForRecipient(recipientAccountId: 'peer', selfAccountId: 'me'),
      isNull,
    );
  });

  test('an unknown own account never silences anything', () {
    expect(
      pushKindForRecipient(recipientAccountId: '', selfAccountId: ''),
      isNull,
    );
    expect(
      pushKindForRecipient(recipientAccountId: 'me', selfAccountId: null),
      isNull,
    );
  });

  test('an explicitly requested kind always wins', () {
    expect(
      pushKindForRecipient(
          recipientAccountId: 'me',
          selfAccountId: 'me',
          requested: PushKind.call),
      PushKind.call,
    );
  });
}
