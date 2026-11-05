import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/secure_storage/secure_storage.dart';
import 'package:nanb_chat/features/onboarding/recovery_phrase_storage.dart';

void main() {
  late SecureStorageInMemory storage;
  late RecoveryPhraseStorage repo;

  setUp(() {
    storage = SecureStorageInMemory();
    repo = RecoveryPhraseStorage(storage);
  });

  test('read returns null when nothing saved', () async {
    expect(await repo.read(), isNull);
  });

  test('save then read round-trips the phrase', () async {
    await repo.save('orbit pelican marble crisp');
    expect(await repo.read(), equals('orbit pelican marble crisp'));
  });

  test('save overwrites the previous value', () async {
    await repo.save('first');
    await repo.save('second');
    expect(await repo.read(), equals('second'));
  });

  test('clear removes the persisted phrase', () async {
    await repo.save('keep');
    await repo.clear();
    expect(await repo.read(), isNull);
  });
}
