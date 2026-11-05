import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/secure_storage/secure_storage.dart';
import 'package:nanb_chat/features/chat/models/chat_background_override.dart';
import 'package:nanb_chat/features/chat/models/conversation_state_field.dart';
import 'package:nanb_chat/features/chat/models/field_version.dart';
import 'package:nanb_chat/features/chat/services/conversation_state_store.dart';
import 'package:nanb_chat/features/settings/models/chat_background.dart';

const _id = '1to1:a:b';

void main() {
  late SecureStorageInMemory storage;

  setUp(() => storage = SecureStorageInMemory());

  Future<ConversationStateStore> fresh() async {
    final s = ConversationStateStore(storage);
    await s.load();
    return s;
  }

  test('an empty store has no version', () async {
    final s = await fresh();

    expect(s.versionOf(_id, ConversationStateField.muted), isNull);
  });

  test('a recorded version is persisted across a reload', () async {
    final s = await fresh();
    await s.recordVersion(
        _id, ConversationStateField.muted, const FieldVersion(5, 'dev'));

    final again = await fresh();

    expect(again.versionOf(_id, ConversationStateField.muted),
        const FieldVersion(5, 'dev'));
  });

  test('a watermark is persisted across a reload', () async {
    final s = await fresh();
    await s.recordVersion(
        _id, ConversationStateField.readUpToMs, const FieldVersion(5, 'dev'),
        watermark: 1234);

    final again = await fresh();

    expect(again.watermarkOf(_id, ConversationStateField.readUpToMs), 1234);
  });

  test('a background override is persisted across a reload', () async {
    final s = await fresh();
    await s.setBackground(
        _id, const ChatBackgroundOverride.preset(ChatBackground.dusk));

    final again = await fresh();

    expect(again.backgroundOf(_id),
        const ChatBackgroundOverride.preset(ChatBackground.dusk));
  });

  test('the background defaults to use-default', () async {
    final s = await fresh();

    expect(s.backgroundOf(_id).isDefault, isTrue);
  });

  test('setting the default override removes the stored entry', () async {
    final s = await fresh();
    await s.setBackground(
        _id, const ChatBackgroundOverride.preset(ChatBackground.dusk));
    await s.setBackground(_id, const ChatBackgroundOverride.useDefault());

    final again = await fresh();

    expect(again.backgroundOf(_id).isDefault, isTrue);
  });

  test('versions are kept per conversation', () async {
    final s = await fresh();
    await s.recordVersion(
        _id, ConversationStateField.muted, const FieldVersion(5, 'dev'));

    expect(s.versionOf('other', ConversationStateField.muted), isNull);
  });

  test('forget drops the conversation from storage', () async {
    final s = await fresh();
    await s.recordVersion(
        _id, ConversationStateField.muted, const FieldVersion(5, 'dev'));
    await s.forget(_id);

    final again = await fresh();

    expect(again.versionOf(_id, ConversationStateField.muted), isNull);
  });

  test('corrupt storage loads as empty instead of throwing', () async {
    await storage.putString(ConversationStateStore.storageKey, '{not json');

    final s = await fresh();

    expect(s.versionOf(_id, ConversationStateField.muted), isNull);
  });
}
