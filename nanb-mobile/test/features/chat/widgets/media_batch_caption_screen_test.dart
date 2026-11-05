import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/chat/widgets/media_batch_caption_screen.dart';

Future<void> _open(
  WidgetTester tester,
  void Function(List<String>?) onResult, {
  required int items,
  String first = '',
}) async {
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => TextButton(
        onPressed: () async {
          onResult(await Navigator.of(context).push<List<String>>(
            MaterialPageRoute(
              builder: (_) => MediaBatchCaptionScreen(
                initialFirstCaption: first,
                previews: [
                  for (var i = 0; i < items; i++) Text('preview-$i'),
                ],
              ),
            ),
          ));
        },
        child: const Text('open'),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets("the composer text pre-fills only the first item's caption",
      (tester) async {
    List<String>? result;
    await _open(tester, (r) => result = r, items: 3, first: 'hello');

    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();

    expect(result, ['hello', '', '']);
  });

  testWidgets('each item keeps its own caption when swiping between them',
      (tester) async {
    List<String>? result;
    await _open(tester, (r) => result = r, items: 2);

    await tester.enterText(find.byType(TextField), 'one');
    await tester.drag(find.text('preview-0'), const Offset(-600, 0));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'two');
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();

    expect(result, ['one', 'two']);
  });

  testWidgets('the title shows the position among several items',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: MediaBatchCaptionScreen(
        previews: [Text('a'), Text('b')],
        title: 'Send photos',
      ),
    ));

    expect(find.text('Send photos (1/2)'), findsOneWidget);
  });

  testWidgets('a single item shows the plain title', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: MediaBatchCaptionScreen(
        previews: [Text('a')],
        title: 'Send file',
      ),
    ));

    expect(find.text('Send file'), findsOneWidget);
  });

  testWidgets('cancelling returns nothing', (tester) async {
    List<String>? result = ['sentinel'];
    await _open(tester, (r) => result = r, items: 1);

    await tester.tap(find.byTooltip('Cancel'));
    await tester.pumpAndSettle();

    expect(result, isNull);
  });
}
