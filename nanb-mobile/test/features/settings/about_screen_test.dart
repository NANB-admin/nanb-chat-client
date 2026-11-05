import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/app/theme.dart';
import 'package:nanb_chat/features/settings/about_screen.dart';
import 'package:package_info_plus/package_info_plus.dart';

Future<void> _pumpAbout(WidgetTester tester) async {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  PackageInfo.setMockInitialValues(
    appName: 'NANb Chat',
    packageName: 'us.nanb.chat',
    version: '1.0.0',
    buildNumber: '48',
    buildSignature: '',
  );
  await tester.pumpWidget(
    MaterialApp(theme: buildLightTheme(), home: const AboutScreen()),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('AboutScreen build info', () {
    testWidgets('shows the installed version and build number', (tester) async {
      await _pumpAbout(tester);

      expect(find.text('v1.0.0 (48)'), findsOneWidget);
    });
  });

  group('AboutScreen open-source section', () {
    testWidgets('names the licence', (tester) async {
      await _pumpAbout(tester);

      expect(find.text('GPL-3.0'), findsOneWidget);
    });

    testWidgets('offers a link to the source code', (tester) async {
      await _pumpAbout(tester);

      expect(find.text('Source code'), findsOneWidget);
    });

    testWidgets('offers the open-source licenses page', (tester) async {
      await _pumpAbout(tester);

      expect(find.text('Open-source licenses'), findsOneWidget);
    });

    testWidgets('tapping licenses opens the licence page', (tester) async {
      await _pumpAbout(tester);

      await tester.tap(find.text('Open-source licenses'));
      await tester.pumpAndSettle();

      expect(find.byType(LicensePage), findsOneWidget);
    });

    testWidgets('the licence page lists Wire CoreCrypto', (tester) async {
      await _pumpAbout(tester);

      await tester.tap(find.text('Open-source licenses'));
      await tester.pumpAndSettle();

      expect(find.text('Wire CoreCrypto'), findsOneWidget);
    });
  });
}
