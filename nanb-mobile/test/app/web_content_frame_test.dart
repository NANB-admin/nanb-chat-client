import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/app/web_content_frame.dart';

const _probeKey = ValueKey('probe');

Widget _app({required bool enabled, double maxWidth = 400}) {
  return MaterialApp(
    home: Scaffold(
      body: WebContentFrame(
        enabled: enabled,
        maxWidth: maxWidth,
        child: const SizedBox.expand(key: _probeKey),
      ),
    ),
  );
}

Future<void> _useWindow(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets('disabled: the child fills the whole window (mobile unchanged)',
      (tester) async {
    await _useWindow(tester, const Size(1200, 800));
    await tester.pumpWidget(_app(enabled: false));

    expect(tester.getSize(find.byKey(_probeKey)).width, 1200);
  });

  testWidgets('enabled: the child is capped at maxWidth on a wide window',
      (tester) async {
    await _useWindow(tester, const Size(1200, 800));
    await tester.pumpWidget(_app(enabled: true));

    expect(tester.getSize(find.byKey(_probeKey)).width, 400);
  });

  testWidgets('enabled: the capped child is horizontally centred',
      (tester) async {
    await _useWindow(tester, const Size(1200, 800));
    await tester.pumpWidget(_app(enabled: true));

    expect(tester.getCenter(find.byKey(_probeKey)).dx, 600);
  });

  testWidgets('enabled: a window narrower than maxWidth is still filled',
      (tester) async {
    await _useWindow(tester, const Size(320, 800));
    await tester.pumpWidget(_app(enabled: true));

    expect(tester.getSize(find.byKey(_probeKey)).width, 320);
  });

  testWidgets('enabled: height is not constrained', (tester) async {
    await _useWindow(tester, const Size(1200, 800));
    await tester.pumpWidget(_app(enabled: true));

    expect(tester.getSize(find.byKey(_probeKey)).height, 800);
  });

  testWidgets('enabled: honours a custom maxWidth', (tester) async {
    await _useWindow(tester, const Size(1200, 800));
    await tester.pumpWidget(_app(enabled: true, maxWidth: 520));

    expect(tester.getSize(find.byKey(_probeKey)).width, 520);
  });

  testWidgets('in the test VM (not a browser) it defaults to disabled',
      (tester) async {
    await _useWindow(tester, const Size(1200, 800));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: const WebContentFrame(child: SizedBox.expand(key: _probeKey)),
      ),
    ));

    expect(tester.getSize(find.byKey(_probeKey)).width, 1200);
  });
}
