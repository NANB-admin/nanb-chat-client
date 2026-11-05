import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/app/theme.dart';
import 'package:nanb_chat/features/chat/widgets/attach_sheet.dart';

void main() {
  // Pumps a button that opens the sheet and records what show() returns.
  Future<AttachAction?> openAndTap(WidgetTester tester, String label) async {
    AttachAction? result;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async => result = await AttachSheet.show(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('shows camera capture, gallery, and file options', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => AttachSheet.show(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Take photo'), findsOneWidget);
    expect(find.text('Record video'), findsOneWidget);
    expect(find.text('Photo'), findsOneWidget);
    expect(find.text('Video'), findsOneWidget);
    expect(find.text('File'), findsOneWidget);
  });

  testWidgets('Take photo returns takePhoto (camera capture)', (tester) async {
    expect(await openAndTap(tester, 'Take photo'), AttachAction.takePhoto);
  });

  testWidgets('Record video returns recordVideo (camera capture)',
      (tester) async {
    expect(await openAndTap(tester, 'Record video'), AttachAction.recordVideo);
  });

  testWidgets('gallery Photo returns photo', (tester) async {
    expect(await openAndTap(tester, 'Photo'), AttachAction.photo);
  });

  testWidgets('gallery Video returns video', (tester) async {
    expect(await openAndTap(tester, 'Video'), AttachAction.video);
  });
}
