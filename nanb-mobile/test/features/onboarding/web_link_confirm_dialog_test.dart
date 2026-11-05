import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/onboarding/widgets/web_link_confirm_dialog.dart';

void main() {
  late bool? result;

  Future<void> open(WidgetTester tester) async {
    result = null;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => result = await confirmWebLink(context),
          child: const Text('go'),
        ),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
  }

  testWidgets('warns that a web browser will read messages for 30 days',
      (tester) async {
    await open(tester);
    expect(find.textContaining('expires in 30 days'), findsOneWidget);
  });

  testWidgets('Cancel resolves false', (tester) async {
    await open(tester);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(result, isFalse);
  });

  testWidgets('Link resolves true', (tester) async {
    await open(tester);
    await tester.tap(find.text('Link'));
    await tester.pumpAndSettle();
    expect(result, isTrue);
  });
}
