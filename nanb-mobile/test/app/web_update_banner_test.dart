import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/app/web_update_banner.dart';

const _interval = Duration(minutes: 10);

Future<void> _pump(
  WidgetTester tester, {
  required Future<String?> Function() fetch,
  VoidCallback? onReload,
  bool enabled = true,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: WebUpdateBanner(
        enabled: enabled,
        fetchLatest: fetch,
        onReload: onReload ?? () {},
        interval: _interval,
        child: const Scaffold(body: Text('content')),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('WebUpdateBanner', () {
    testWidgets('stays hidden while the deployed build is the loaded one',
        (tester) async {
      await _pump(tester, fetch: () async => '48');

      await tester.pump(_interval);

      expect(find.text('A new version is available.'), findsNothing);
    });

    testWidgets('appears when a newer build is deployed', (tester) async {
      final builds = ['48', '49'];
      await _pump(tester, fetch: () async => builds.removeAt(0));

      await tester.pump(_interval);
      await tester.pump();

      expect(find.text('A new version is available.'), findsOneWidget);
    });

    testWidgets('stays hidden when the version cannot be read', (tester) async {
      await _pump(tester, fetch: () async => null);

      await tester.pump(_interval);

      expect(find.text('A new version is available.'), findsNothing);
    });

    testWidgets('Reload calls the reload action', (tester) async {
      var reloads = 0;
      final builds = ['48', '49'];
      await _pump(
        tester,
        fetch: () async => builds.removeAt(0),
        onReload: () => reloads++,
      );
      await tester.pump(_interval);
      await tester.pump();

      await tester.tap(find.text('Reload'));

      expect(reloads, 1);
    });

    testWidgets('keeps showing the page content under the banner',
        (tester) async {
      final builds = ['48', '49'];
      await _pump(tester, fetch: () async => builds.removeAt(0));

      await tester.pump(_interval);
      await tester.pump();

      expect(find.text('content'), findsOneWidget);
    });

    testWidgets('does nothing when disabled (mobile)', (tester) async {
      var fetches = 0;
      await _pump(
        tester,
        enabled: false,
        fetch: () async {
          fetches++;
          return '48';
        },
      );

      await tester.pump(_interval);

      expect(fetches, 0);
    });
  });
}
