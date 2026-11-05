import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/chat/models/chat_background_override.dart';
import 'package:nanb_chat/features/chat/models/conversation_state_field.dart';
import 'package:nanb_chat/features/chat/models/conversation_state_update.dart';
import 'package:nanb_chat/features/chat/models/field_version.dart';
import 'package:nanb_chat/features/chat/models/message_control.dart';
import 'package:nanb_chat/features/chat/models/state_field_change.dart';
import 'package:nanb_chat/features/settings/models/chat_background.dart';

MessageControl _state(Map<ConversationStateField, StateFieldChange> c) =>
    MessageControl.conversationState(ConversationStateUpdate(c));

void main() {
  group('FieldVersion', () {
    test('a later timestamp wins', () {
      expect(const FieldVersion(2, 'a').isNewerThan(const FieldVersion(1, 'z')),
          isTrue);
    });

    test('an earlier timestamp loses', () {
      expect(const FieldVersion(1, 'z').isNewerThan(const FieldVersion(2, 'a')),
          isFalse);
    });

    test('equal timestamps tie-break on the larger device id', () {
      expect(const FieldVersion(5, 'b').isNewerThan(const FieldVersion(5, 'a')),
          isTrue);
    });

    test('an identical version is not newer', () {
      expect(const FieldVersion(5, 'a').isNewerThan(const FieldVersion(5, 'a')),
          isFalse);
    });

    test('anything beats a missing version', () {
      expect(const FieldVersion(0, '').isNewerThan(null), isTrue);
    });
  });

  group('conversation_state wire format', () {
    test('encodes the exact documented JSON', () {
      final body = _state({
        ConversationStateField.muted:
            const StateFieldChange.flag(true, FieldVersion(10, 'dev-a')),
      }).encode();

      expect(jsonDecode(body), {
        '_control': 'conversation_state',
        'fields': {
          'muted': {'v': true, 't': 10, 'd': 'dev-a'},
        },
      });
    });

    test('round-trips a flag field', () {
      final back = MessageControl.tryDecode(_state({
        ConversationStateField.pinned:
            const StateFieldChange.flag(true, FieldVersion(1, 'a')),
      }).encode())!;

      expect(back.stateUpdate!.changes[ConversationStateField.pinned]!.flag,
          isTrue);
    });

    test('round-trips a number field', () {
      final back = MessageControl.tryDecode(_state({
        ConversationStateField.readUpToMs:
            const StateFieldChange.number(999, FieldVersion(1, 'a')),
      }).encode())!;

      expect(
          back.stateUpdate!.changes[ConversationStateField.readUpToMs]!.number,
          999);
    });

    test('round-trips a text field', () {
      final back = MessageControl.tryDecode(_state({
        ConversationStateField.background:
            const StateFieldChange.text('ocean', FieldVersion(1, 'a')),
      }).encode())!;

      expect(
          back.stateUpdate!.changes[ConversationStateField.background]!.text,
          'ocean');
    });

    test('round-trips the version', () {
      final back = MessageControl.tryDecode(_state({
        ConversationStateField.muted:
            const StateFieldChange.flag(false, FieldVersion(77, 'dev-z')),
      }).encode())!;

      expect(back.stateUpdate!.changes[ConversationStateField.muted]!.version,
          const FieldVersion(77, 'dev-z'));
    });

    test('an unknown field is dropped but known ones survive', () {
      final back = MessageControl.tryDecode(jsonEncode({
        '_control': 'conversation_state',
        'fields': {
          'futureField': {'v': true, 't': 1, 'd': 'a'},
          'muted': {'v': true, 't': 1, 'd': 'a'},
        },
      }))!;

      expect(back.stateUpdate!.changes.keys, [ConversationStateField.muted]);
    });

    test('a wrongly typed value is dropped', () {
      final back = MessageControl.tryDecode(jsonEncode({
        '_control': 'conversation_state',
        'fields': {
          'muted': {'v': 'yes', 't': 1, 'd': 'a'},
          'pinned': {'v': true, 't': 1, 'd': 'a'},
        },
      }))!;

      expect(back.stateUpdate!.changes.keys, [ConversationStateField.pinned]);
    });

    test('a control with only unknown fields does not decode', () {
      expect(
          MessageControl.tryDecode(jsonEncode({
            '_control': 'conversation_state',
            'fields': {
              'nope': {'v': true, 't': 1, 'd': 'a'},
            },
          })),
          isNull);
    });

    test('a missing fields map does not decode', () {
      expect(MessageControl.tryDecode('{"_control":"conversation_state"}'),
          isNull);
    });

    test('is flagged as a conversation-state control', () {
      expect(
          _state({
            ConversationStateField.muted:
                const StateFieldChange.flag(true, FieldVersion(1, 'a')),
          }).isConversationState,
          isTrue);
    });
  });

  group('conversation_deleted wire format', () {
    test('encodes the exact documented JSON', () {
      expect(const MessageControl.conversationDeleted().encode(),
          '{"_control":"conversation_deleted"}');
    });

    test('decodes to a conversation-deleted control', () {
      expect(
          MessageControl.tryDecode('{"_control":"conversation_deleted"}')!
              .isConversationDeleted,
          isTrue);
    });

    test('is not mistaken for delete-for-me', () {
      expect(const MessageControl.conversationDeleted().isDeleteForMe, isFalse);
    });
  });

  group('ChatBackgroundOverride', () {
    test('default syncs as "default"', () {
      expect(const ChatBackgroundOverride.useDefault().syncWire, 'default');
    });

    test('a preset syncs as its name', () {
      expect(const ChatBackgroundOverride.preset(ChatBackground.ocean).syncWire,
          'ocean');
    });

    test('a photo has no sync value', () {
      expect(const ChatBackgroundOverride.photo('/x.jpg').syncWire, isNull);
    });

    test('a synced "custom" is rejected', () {
      expect(ChatBackgroundOverride.fromSyncWire('custom'), isNull);
    });

    test('an unknown synced name is rejected', () {
      expect(ChatBackgroundOverride.fromSyncWire('neon'), isNull);
    });

    test('a photo survives the storage round-trip', () {
      final back = ChatBackgroundOverride.fromStorage(
          const ChatBackgroundOverride.photo('/x.jpg').toStorage());

      expect(back, const ChatBackgroundOverride.photo('/x.jpg'));
    });

    test('a preset survives the storage round-trip', () {
      final back = ChatBackgroundOverride.fromStorage(
          const ChatBackgroundOverride.preset(ChatBackground.dusk).toStorage());

      expect(back, const ChatBackgroundOverride.preset(ChatBackground.dusk));
    });
  });
}
