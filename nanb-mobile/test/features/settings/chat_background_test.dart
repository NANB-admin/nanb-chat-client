import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/secure_storage/secure_storage.dart';
import 'package:nanb_chat/features/chat/widgets/chat_background_view.dart';
import 'package:nanb_chat/features/chat/widgets/chat_pattern_painter.dart';
import 'package:nanb_chat/features/settings/app_preferences_notifier.dart';
import 'package:nanb_chat/features/settings/app_preferences_repository.dart';
import 'package:nanb_chat/features/settings/models/chat_background.dart';
import 'package:nanb_chat/features/settings/widgets/chat_background_picker.dart';

class _MemoryStorage implements SecureStorage {
  final Map<String, String> data = {};
  @override
  Future<String?> getString(String key) async => data[key];
  @override
  Future<void> putString(String key, String value) async => data[key] = value;
  @override
  Future<void> delete(String key) async => data.remove(key);
  @override
  Future<void> clear() async => data.clear();
}

void main() {
  group('ChatBackground', () {
    test('fromName parses a known name', () {
      expect(ChatBackground.fromName('ocean'), ChatBackground.ocean);
    });

    test('fromName falls back to the NANb default for an unknown name', () {
      expect(ChatBackground.fromName('nope'), ChatBackground.nanb);
    });

    test('fromName still parses the plain option', () {
      expect(ChatBackground.fromName('none'), ChatBackground.none);
    });

    test('every patterned background maps to a pattern', () {
      const patterned = [
        ChatBackground.nanb,
        ChatBackground.doodles,
        ChatBackground.confetti,
        ChatBackground.waves,
        ChatBackground.stars,
      ];
      for (final b in patterned) {
        expect(b.pattern, isNotNull, reason: b.name);
      }
    });

    test('plain and gradient presets have no pattern', () {
      expect(ChatBackground.none.pattern, isNull);
      expect(ChatBackground.fern.pattern, isNull);
    });

    test('every preset has a light and a dark gradient', () {
      const presets = [
        ChatBackground.fern,
        ChatBackground.ocean,
        ChatBackground.dusk,
        ChatBackground.sunset,
        ChatBackground.graphite,
      ];
      for (final b in presets) {
        expect(b.colors(dark: false), isNotNull, reason: b.name);
        expect(b.colors(dark: true), isNotNull, reason: b.name);
      }
    });

    test('none and custom have no preset gradient', () {
      expect(ChatBackground.none.colors(dark: false), isNull);
      expect(ChatBackground.custom.colors(dark: false), isNull);
    });
  });

  group('chat background preference', () {
    late _MemoryStorage storage;
    late AppPreferencesNotifier notifier;

    setUp(() {
      storage = _MemoryStorage();
      notifier = AppPreferencesNotifier(AppPreferencesRepository(storage));
    });

    test('defaults to the NANb pattern', () async {
      await notifier.load();

      expect(notifier.value.chatBackground, ChatBackground.nanb);
    });

    test('a chosen preset survives a reload', () async {
      await notifier.setChatBackground(ChatBackground.dusk);

      final reloaded = AppPreferencesNotifier(AppPreferencesRepository(storage));
      await reloaded.load();

      expect(reloaded.value.chatBackground, ChatBackground.dusk);
    });

    test('a custom photo path survives a reload', () async {
      await notifier.setCustomChatBackground('/data/bg.jpg');

      final reloaded = AppPreferencesNotifier(AppPreferencesRepository(storage));
      await reloaded.load();

      expect(reloaded.value.chatBackground, ChatBackground.custom);
      expect(reloaded.value.chatBackgroundPath, '/data/bg.jpg');
    });

    test('choosing a preset clears the stored photo path', () async {
      await notifier.setCustomChatBackground('/data/bg.jpg');

      await notifier.setChatBackground(ChatBackground.fern);

      expect(notifier.value.chatBackgroundPath, isEmpty);
    });
  });

  group('ChatBackgroundView', () {
    testWidgets('paints a gradient for a preset', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: ChatBackgroundView(
            background: ChatBackground.ocean,
            customPath: '',
            child: Text('hi'),
          ),
        ),
      );

      final gradients = tester
          .widgetList<DecoratedBox>(find.byType(DecoratedBox))
          .where((d) => (d.decoration as BoxDecoration).gradient != null);
      expect(gradients, isNotEmpty);
    });

    testWidgets('still shows the child over the backdrop', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: ChatBackgroundView(
            background: ChatBackground.ocean,
            customPath: '',
            child: Text('hi'),
          ),
        ),
      );

      expect(find.text('hi'), findsOneWidget);
    });

    testWidgets('paints the NANb pattern for the default background',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: ChatBackgroundView(
            background: ChatBackground.nanb,
            customPath: '',
            child: Text('hi'),
          ),
        ),
      );

      final painters = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((c) => c.painter)
          .whereType<ChatPatternPainter>();
      expect(painters, isNotEmpty);
    });

    testWidgets('paints no pattern for the plain background', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: ChatBackgroundView(
            background: ChatBackground.none,
            customPath: '',
            child: Text('hi'),
          ),
        ),
      );

      final painters = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((c) => c.painter)
          .whereType<ChatPatternPainter>();
      expect(painters, isEmpty);
    });

    testWidgets('a patterned preset keeps its gradient under the pattern',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: ChatBackgroundView(
            background: ChatBackground.waves,
            customPath: '',
            child: Text('hi'),
          ),
        ),
      );

      final gradients = tester
          .widgetList<DecoratedBox>(find.byType(DecoratedBox))
          .where((d) =>
              d.decoration is BoxDecoration &&
              (d.decoration as BoxDecoration).gradient != null);
      expect(gradients, isNotEmpty);
    });

    testWidgets('paints no gradient for the default', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: ChatBackgroundView(
            background: ChatBackground.none,
            customPath: '',
            child: Text('hi'),
          ),
        ),
      );

      final gradients = tester
          .widgetList<DecoratedBox>(find.byType(DecoratedBox))
          .where((d) =>
              d.decoration is BoxDecoration &&
              (d.decoration as BoxDecoration).gradient != null);
      expect(gradients, isEmpty);
    });
  });

  group('ChatBackgroundPicker', () {
    Widget host({
      ValueChanged<ChatBackground>? onSelect,
      VoidCallback? onPickPhoto,
    }) =>
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ChatBackgroundPicker(
                selected: ChatBackground.none,
                customPath: '',
                onSelect: onSelect ?? (_) {},
                onPickPhoto: onPickPhoto ?? () {},
              ),
            ),
          ),
        );

    testWidgets('tapping a preset selects it', (tester) async {
      ChatBackground? picked;
      await tester.pumpWidget(host(onSelect: (b) => picked = b));

      await tester.tap(find.text('Ocean'));

      expect(picked, ChatBackground.ocean);
    });

    testWidgets('tapping Photo asks to pick a photo', (tester) async {
      var asked = 0;
      await tester.pumpWidget(host(onPickPhoto: () => asked++));

      await tester.tap(find.text('Photo'));

      expect(asked, 1);
    });
  });
}
