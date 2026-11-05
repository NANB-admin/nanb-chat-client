import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/chat/widgets/emoji_picker_sheet.dart';

void main() {
  group('EmojiPickerSheet.insert', () {
    test('appends at the end when the caret is at the end', () {
      final c = TextEditingController(text: 'hi');
      c.selection = const TextSelection.collapsed(offset: 2);

      EmojiPickerSheet.insert(c, '😀');

      expect(c.text, 'hi😀');
      expect(c.selection.baseOffset, 'hi😀'.length);
    });

    test('inserts at the caret in the middle of the text', () {
      final c = TextEditingController(text: 'ab');
      c.selection = const TextSelection.collapsed(offset: 1);

      EmojiPickerSheet.insert(c, '🔥');

      expect(c.text, 'a🔥b');
      expect(c.selection.baseOffset, 'a🔥'.length);
    });

    test('replaces the current selection', () {
      final c = TextEditingController(text: 'abc');
      c.selection = const TextSelection(baseOffset: 1, extentOffset: 3);

      EmojiPickerSheet.insert(c, '👍');

      expect(c.text, 'a👍');
      expect(c.selection.baseOffset, 'a👍'.length);
    });

    test('appends when there is no valid selection', () {
      final c = TextEditingController(text: 'yo');
      // Default controller has an invalid (-1) selection until focused.

      EmojiPickerSheet.insert(c, '🎉');

      expect(c.text, 'yo🎉');
    });
  });

  group('EmojiPickerSheet.backspace', () {
    test('removes a multi-code-unit emoji in one press', () {
      final c = TextEditingController(text: 'hi😀');
      c.selection = const TextSelection.collapsed(offset: 'hi😀'.length);

      EmojiPickerSheet.backspace(c);

      expect(c.text, 'hi');
      expect(c.selection.baseOffset, 2);
    });

    test('removes the grapheme before the caret in the middle', () {
      final c = TextEditingController(text: 'a🔥b');
      c.selection = const TextSelection.collapsed(offset: 'a🔥'.length);

      EmojiPickerSheet.backspace(c);

      expect(c.text, 'ab');
      expect(c.selection.baseOffset, 1);
    });

    test('deletes the current selection when there is one', () {
      final c = TextEditingController(text: 'abc');
      c.selection = const TextSelection(baseOffset: 1, extentOffset: 3);

      EmojiPickerSheet.backspace(c);

      expect(c.text, 'a');
      expect(c.selection.baseOffset, 1);
    });

    test('falls back to deleting the last char when selection is invalid', () {
      final c = TextEditingController(text: 'yo👍');
      // Invalid (-1) selection — treat as caret at end.

      EmojiPickerSheet.backspace(c);

      expect(c.text, 'yo');
    });

    test('is a no-op on empty text', () {
      final c = TextEditingController(text: '');

      EmojiPickerSheet.backspace(c);

      expect(c.text, '');
    });

    test('is a no-op with the caret at the start', () {
      final c = TextEditingController(text: 'hey');
      c.selection = const TextSelection.collapsed(offset: 0);

      EmojiPickerSheet.backspace(c);

      expect(c.text, 'hey');
    });
  });
}
