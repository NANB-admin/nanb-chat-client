import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/chat/models/chat_background_override.dart';
import 'package:nanb_chat/features/chat/models/effective_chat_background.dart';
import 'package:nanb_chat/features/settings/models/chat_background.dart';

void main() {
  test('no override follows the global background', () {
    final e = EffectiveChatBackground.resolve(
        const ChatBackgroundOverride.useDefault(),
        ChatBackground.fern,
        '');

    expect(e.background, ChatBackground.fern);
  });

  test('no override follows the global custom photo path', () {
    final e = EffectiveChatBackground.resolve(
        const ChatBackgroundOverride.useDefault(),
        ChatBackground.custom,
        '/global.jpg');

    expect(e.customPath, '/global.jpg');
  });

  test('a preset override wins over the global background', () {
    final e = EffectiveChatBackground.resolve(
        const ChatBackgroundOverride.preset(ChatBackground.ocean),
        ChatBackground.fern,
        '');

    expect(e.background, ChatBackground.ocean);
  });

  test('a photo override uses its own path, not the global one', () {
    final e = EffectiveChatBackground.resolve(
        const ChatBackgroundOverride.photo('/chat.jpg'),
        ChatBackground.custom,
        '/global.jpg');

    expect(e.customPath, '/chat.jpg');
  });
}
