import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/db/app_database.dart';
import 'package:nanb_chat/features/chat/models/conversation.dart';
import 'package:nanb_chat/features/chat/models/crypto_mode.dart';

Conversation _convo({
  String id = 'c1',
  CryptoMode cryptoMode = CryptoMode.ratchet,
}) {
  return Conversation(
    id: id,
    peerUsername: '@bob',
    peerAccountId: 'acct-b',
    peerDeviceId: 'dev-b',
    peerIdentityPubKey: const [1, 2],
    messages: const [],
    unreadCount: 0,
    cryptoMode: cryptoMode,
  );
}

void main() {
  test('new conversation defaults to ratchet', () async {
    final db = AppDatabaseInMemory();
    await db.open(masterKeyHex: 'k');
    await db.upsertConversation(_convo());
    final loaded = (await db.loadConversations()).first;
    expect(loaded.cryptoMode, CryptoMode.ratchet);
  });

  test('mls cryptoMode round-trips through save+load', () async {
    final db = AppDatabaseInMemory();
    await db.open(masterKeyHex: 'k');
    await db.upsertConversation(_convo(cryptoMode: CryptoMode.mls));
    final loaded = (await db.loadConversations()).first;
    expect(loaded.cryptoMode, CryptoMode.mls);
  });

  test('CryptoMode.fromName throws on unknown', () {
    expect(
      () => CryptoMode.fromName('totally-not-a-mode'),
      throwsA(isA<ArgumentError>()),
    );
  });
}
