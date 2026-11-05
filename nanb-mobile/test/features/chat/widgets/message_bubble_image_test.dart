import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/chat/widgets/message_bubble_image.dart';

// A valid 1x1 transparent PNG — real bytes so `Image.memory` can resolve
// without logging a decode error during the pump.
final Uint8List _onePxPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNk+M9Q'
  'DwADhgGAWjR9awAAAABJRU5ErkJggg==',
);

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(body: Center(child: child)),
    );

void main() {
  group('MessageBubbleImage tap', () {
    testWidgets('tapping the picture reports the tap', (tester) async {
      // The 1x1 fixture scales to a square as wide as the bubble, so give the
      // test a tall screen to keep the whole picture on it.
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var taps = 0;
      await tester.pumpWidget(
        _host(
          MessageBubbleImage(
            time: '10:14',
            mine: false,
            bytes: _onePxPng,
            onTap: () => taps++,
          ),
        ),
      );
      // Let the image decode, otherwise it has no height to tap.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump();

      await tester.tapAt(
        tester.getTopLeft(find.byType(Image)) + const Offset(10, 10),
      );

      expect(taps, 1);
    });
  });

  group('MessageBubbleImage decode cap (FIX #5)', () {
    testWidgets(
        'inline image caps the decode width (cacheWidth) instead of decoding '
        'at native resolution', (tester) async {
      await tester.pumpWidget(
        _host(
          MessageBubbleImage(time: '10:14', mine: false, bytes: _onePxPng),
        ),
      );
      await tester.pump();

      final image = tester.widget<Image>(find.byType(Image));
      // cacheWidth/cacheHeight are surfaced by wrapping the provider in a
      // ResizeImage, so the presence of that wrapper (with a bounded width) is
      // the observable proof the inline preview no longer decodes full-res.
      expect(image.image, isA<ResizeImage>());
      final resize = image.image as ResizeImage;
      expect(resize.width, isNotNull);
      expect(resize.width, greaterThan(0));
    });

    testWidgets('caps width only, leaving height to follow (keeps aspect ratio)',
        (tester) async {
      await tester.pumpWidget(
        _host(
          MessageBubbleImage(time: '10:14', mine: true, bytes: _onePxPng),
        ),
      );
      await tester.pump();

      final resize = tester.widget<Image>(find.byType(Image)).image
          as ResizeImage;
      // fitWidth scales height proportionally, so only the width is pinned —
      // constraining both would risk distorting a non-4:3 image.
      expect(resize.width, isNotNull);
      expect(resize.height, isNull);
    });

    testWidgets('scales the cap by devicePixelRatio', (tester) async {
      // A higher DPR must ask the decoder for more source pixels (a crisp
      // preview on a dense screen), so the cap is not a fixed logical size.
      // Hold the LOGICAL size constant (physicalSize scales with dpr) — that's
      // the real cross-device shape: same layout, more physical pixels.
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(400, 800);
      await tester.pumpWidget(
        _host(
          MessageBubbleImage(time: '10:14', mine: false, bytes: _onePxPng),
        ),
      );
      await tester.pump();
      final lowDprWidth =
          (tester.widget<Image>(find.byType(Image)).image as ResizeImage).width!;

      tester.view.devicePixelRatio = 3.0;
      tester.view.physicalSize = const Size(1200, 2400);
      await tester.pumpWidget(
        _host(
          MessageBubbleImage(time: '10:14', mine: false, bytes: _onePxPng),
        ),
      );
      await tester.pump();
      final highDprWidth =
          (tester.widget<Image>(find.byType(Image)).image as ResizeImage).width!;

      expect(highDprWidth, greaterThan(lowDprWidth));
    });

    testWidgets('still renders the stripe placeholder (no Image) while encrypted',
        (tester) async {
      await tester.pumpWidget(
        _host(
          const MessageBubbleImage(time: '10:14', mine: false, bytes: null),
        ),
      );
      await tester.pump();

      expect(find.byType(Image), findsNothing);
      expect(find.text('image · encrypted'), findsOneWidget);
    });
  });
}
