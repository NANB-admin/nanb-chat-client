import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/app/design_tokens.dart';
import 'package:nanb_chat/features/chat/widgets/thread_bars.dart';

Future<List<String>> _pumpAndTap(WidgetTester tester, String button) async {
  final taps = <String>[];
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: RequestBar(
        t: DesignTokens.light,
        peerUsername: '@bob',
        onAccept: () => taps.add('accept'),
        onReject: () => taps.add('reject'),
        onReport: () => taps.add('report'),
      ),
    ),
  ));
  await tester.tap(find.text(button));
  await tester.pump();
  return taps;
}

void main() {
  testWidgets('buttons are ordered Accept, Reject, Report left to right',
      (tester) async {
    await _pumpAndTap(tester, 'Accept');

    final xs = [
      for (final b in ['Accept', 'Reject', 'Report'])
        tester.getCenter(find.text(b)).dx,
    ];

    expect(xs, orderedEquals([...xs]..sort()));
  });

  testWidgets('Accept only accepts', (tester) async {
    expect(await _pumpAndTap(tester, 'Accept'), ['accept']);
  });

  testWidgets('Reject only rejects', (tester) async {
    expect(await _pumpAndTap(tester, 'Reject'), ['reject']);
  });

  testWidgets('Report only reports', (tester) async {
    expect(await _pumpAndTap(tester, 'Report'), ['report']);
  });
}
