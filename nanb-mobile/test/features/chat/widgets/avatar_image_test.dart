import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/app/providers.dart';
import 'package:nanb_chat/features/chat/avatar_loader.dart';
import 'package:nanb_chat/features/chat/media_pipeline.dart';
import 'package:nanb_chat/features/chat/models/message_kind.dart';
import 'package:nanb_chat/features/chat/widgets/avatar_image.dart';
import 'package:nanb_chat/features/chat/widgets/avatar_viewer_screen.dart';

// 4x2 (landscape) and 2x4 (portrait) solid-red PNGs.
final Uint8List _landscape = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAQAAAACCAIAAADwyuo0AAAAEklEQVR4nGP4z8AARwjWfwYGAG+qB/lC/d2tAAAAAElFTkSuQmCC',
);
final Uint8List _portrait = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAIAAAAECAIAAAArjXluAAAAEUlEQVR4nGP4z8DwnwGMMSgAd6QH+WEDI4sAAAAASUVORK5CYII=',
);

const _descriptor = MediaDescriptor(
  kind: MessageKind.image,
  mediaId: 'avatar-1',
  key: [1],
  sha256: [2],
  sizeBytes: 10,
  mimeType: 'image/png',
);

class _FakePipeline implements MediaPipeline {
  _FakePipeline(this.bytes);
  final Uint8List bytes;

  @override
  Future<List<int>> download(MediaDescriptor descriptor) async => bytes;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<ResizeImage> _pumpAvatar(
  WidgetTester tester,
  Uint8List bytes, {
  bool enlargeOnTap = false,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        avatarLoaderProvider
            .overrideWithValue(AvatarLoader(_FakePipeline(bytes))),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: AvatarImage(
            name: 'bob',
            descriptor: _descriptor,
            size: 80,
            enlargeOnTap: enlargeOnTap,
          ),
        ),
      ),
    ),
  );
  // Let the (real-async) download + header read finish.
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
  await tester.pump();
  return tester.widget<Image>(find.byType(Image)).image as ResizeImage;
}

void main() {
  testWidgets('a landscape photo is resized by height only, never squashed',
      (tester) async {
    final image = await _pumpAvatar(tester, _landscape);

    expect(image.width, isNull);
    expect(image.height, isNotNull);
  });

  testWidgets('a portrait photo is resized by width only, never squashed',
      (tester) async {
    final image = await _pumpAvatar(tester, _portrait);

    expect(image.height, isNull);
    expect(image.width, isNotNull);
  });

  testWidgets('tapping an enlargeable avatar opens the viewer', (tester) async {
    await _pumpAvatar(tester, _landscape, enlargeOnTap: true);

    await tester.tap(find.byType(AvatarImage));
    await tester.pumpAndSettle();

    expect(find.byType(AvatarViewerScreen), findsOneWidget);
  });

  testWidgets('tapping a plain avatar does not open the viewer',
      (tester) async {
    await _pumpAvatar(tester, _landscape);

    await tester.tap(find.byType(AvatarImage));
    await tester.pumpAndSettle();

    expect(find.byType(AvatarViewerScreen), findsNothing);
  });
}
