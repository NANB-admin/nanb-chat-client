import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/chat/models/sticker.dart';
import 'package:nanb_chat/features/chat/models/sticker_image.dart';
import 'package:nanb_chat/features/chat/services/sticker_catalog.dart';
import 'package:nanb_chat/features/chat/services/user_sticker_store.dart';
import 'package:nanb_chat/features/chat/widgets/sticker_browser.dart';

/// 1x1 transparent PNG — valid bytes so a user sticker decodes cleanly.
const _tinyPng = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x62, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
];

/// The browser chains several real loads (asset manifest, then disk), each of
/// which resumes in the fake-async zone only on a pump — so alternate real time
/// with pumps until the chain has run its course.
Future<void> settle(WidgetTester tester) async {
  // A file read is itself several chained steps (open, length, read, close), so
  // leave enough rounds that no handle is still open when the test ends.
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump();
  }
}

void main() {
  late Directory root;
  late UserStickerStore store;
  late List<Sticker> selected;
  final catalog = StickerCatalog.fromBundle();

  setUp(() async {
    root = Directory.systemTemp.createTempSync('sticker_browser_test');
    store = UserStickerStore(directory: () async => root);
    selected = [];
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// Mounts the browser and waits for its real (non-fake-async) asset + disk
  /// loads to finish.
  Future<void> pumpBrowser(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: StickerBrowser(
              onSelected: selected.add,
              catalog: catalog,
              store: store,
            ),
          ),
        ),
      ),
    );
    await settle(tester);
  }

  Future<List<Sticker>> packStickers(WidgetTester tester, int pack) async {
    final packs = await tester.runAsync(catalog.bundledPacks);
    return packs![pack].stickers;
  }

  testWidgets('opens on the first bundled pack when the user has no stickers',
      (tester) async {
    final first = (await packStickers(tester, 0)).first;

    await pumpBrowser(tester);

    expect(find.byKey(ValueKey(first.id)), findsOneWidget);
  });

  testWidgets('tapping a bundled sticker reports that sticker',
      (tester) async {
    final first = (await packStickers(tester, 0)).first;
    await pumpBrowser(tester);

    await tester.tap(find.byKey(ValueKey(first.id)));

    expect(selected, [first]);
  });

  testWidgets('switching to another pack shows that pack\'s stickers',
      (tester) async {
    final reactionsFirst = (await packStickers(tester, 1)).first;
    await pumpBrowser(tester);

    await tester.tap(find.byTooltip('Reactions'));
    await tester.pump();

    expect(find.byKey(ValueKey(reactionsFirst.id)), findsOneWidget);
  });

  testWidgets('opens on My stickers when the user already has some',
      (tester) async {
    final mine = (await tester.runAsync(
      () => store.add(const StickerImage(bytes: _tinyPng, mimeType: 'image/png')),
    ))!;

    await pumpBrowser(tester);

    expect(find.byKey(ValueKey(mine.id)), findsOneWidget);
  });

  testWidgets('My stickers offers an add tile', (tester) async {
    await tester.runAsync(
      () => store.add(const StickerImage(bytes: _tinyPng, mimeType: 'image/png')),
    );

    await pumpBrowser(tester);

    expect(find.byKey(const ValueKey('add-sticker')), findsOneWidget);
  });

  testWidgets('tapping one of my stickers reports it', (tester) async {
    final mine = (await tester.runAsync(
      () => store.add(const StickerImage(bytes: _tinyPng, mimeType: 'image/png')),
    ))!;
    await pumpBrowser(tester);

    await tester.tap(find.byKey(ValueKey(mine.id)));

    expect(selected, [mine]);
  });

  testWidgets('long-press then confirm removes one of my stickers',
      (tester) async {
    final mine = (await tester.runAsync(
      () => store.add(const StickerImage(bytes: _tinyPng, mimeType: 'image/png')),
    ))!;
    await pumpBrowser(tester);

    await tester.longPress(find.byKey(ValueKey(mine.id)));
    await tester.pump();
    await tester.tap(find.text('Remove'));
    await settle(tester);

    expect(find.byKey(ValueKey(mine.id)), findsNothing);
  });

  testWidgets('long-press then cancel keeps the sticker', (tester) async {
    final mine = (await tester.runAsync(
      () => store.add(const StickerImage(bytes: _tinyPng, mimeType: 'image/png')),
    ))!;
    await pumpBrowser(tester);

    await tester.longPress(find.byKey(ValueKey(mine.id)));
    await tester.pump();
    await tester.tap(find.text('Cancel'));
    await tester.pump();

    expect(find.byKey(ValueKey(mine.id)), findsOneWidget);
  });
}
