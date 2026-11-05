import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/chat/widgets/message_bubble_file.dart';

Widget _host(String caption) => MaterialApp(
      home: Scaffold(
        body: MessageBubbleFile(
          filename: 'spec.pdf',
          size: '1 MB',
          time: '12:00',
          mine: true,
          caption: caption,
        ),
      ),
    );

void main() {
  testWidgets('shows the caption under the file', (tester) async {
    await tester.pumpWidget(_host('read this'));

    expect(find.text('read this'), findsOneWidget);
  });

  testWidgets('shows the filename alongside the caption', (tester) async {
    await tester.pumpWidget(_host('read this'));

    expect(find.text('spec.pdf'), findsOneWidget);
  });

  testWidgets('shows no caption text when there is none', (tester) async {
    await tester.pumpWidget(_host(''));

    expect(find.text('read this'), findsNothing);
  });
}
