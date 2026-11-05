import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/chat/models/link_preview.dart';
import 'package:nanb_chat/features/chat/widgets/link_preview_card.dart';
import 'package:nanb_chat/features/chat/widgets/message_bubble.dart';

void main() {
  group('MessageBubble', () {
    testWidgets('renders senderLabel above bubble when provided and mine=false',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MessageBubble(
              text: 'hello',
              time: '12:34',
              mine: false,
              senderLabel: '@ada',
            ),
          ),
        ),
      );

      expect(find.text('@ada'), findsOneWidget);
      expect(find.text('hello'), findsOneWidget);
    });

    testWidgets('omits senderLabel when null', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MessageBubble(
              text: 'hello',
              time: '12:34',
              mine: false,
            ),
          ),
        ),
      );

      expect(find.text('@ada'), findsNothing);
      expect(find.text('hello'), findsOneWidget);
    });

    testWidgets(
        'omits senderLabel when mine=true (sender labels are for non-mine bubbles)',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MessageBubble(
              text: 'hello',
              time: '12:34',
              mine: true,
              senderLabel: '@me',
            ),
          ),
        ),
      );

      expect(find.text('@me'), findsNothing);
      expect(find.text('hello'), findsOneWidget);
    });

    testWidgets('highlights the matched term within the body',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: MessageBubble(
              text: 'hello world',
              time: '12:34',
              mine: false,
              highlight: 'world',
            ),
          ),
        ),
      );

      // The full text is preserved (rendered as rich spans).
      expect(find.text('hello world'), findsOneWidget);
      // The matched run is bolded (the highlight style).
      final rich = tester
          .widgetList<RichText>(find.byType(RichText))
          .firstWhere((r) => r.text.toPlainText() == 'hello world');
      final bolded = <String>[];
      void visit(InlineSpan s) {
        if (s is TextSpan) {
          if (s.text != null && s.style?.fontWeight == FontWeight.bold) {
            bolded.add(s.text!);
          }
          s.children?.forEach(visit);
        }
      }

      visit(rich.text);
      expect(bolded, contains('world'));
    });

    testWidgets('renders plain text when no highlight is given',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: MessageBubble(text: 'hello world', time: '12:34', mine: false),
          ),
        ),
      );
      expect(find.text('hello world'), findsOneWidget);
    });
  });

  group('MessageBubble links', () {
    const shared = 'look https://www.instagram.com/reel/Cabc123/?igsh=xyz ok';

    Future<void> pumpBubble(
      WidgetTester tester, {
      required ValueChanged<String> onOpenLink,
      String text = shared,
      String? highlight,
    }) {
      return tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MessageBubble(
              text: text,
              time: '12:34',
              mine: false,
              highlight: highlight,
              onOpenLink: onOpenLink,
            ),
          ),
        ),
      );
    }

    testWidgets('tapping a link opens that link', (tester) async {
      final opened = <String>[];
      await pumpBubble(tester, onOpenLink: opened.add);

      await tester.tapOnText(find.textRange.ofSubstring(
          'https://www.instagram.com/reel/Cabc123/?igsh=xyz'));

      expect(opened, ['https://www.instagram.com/reel/Cabc123/?igsh=xyz']);
    });

    testWidgets('tapping the plain text around a link opens nothing',
        (tester) async {
      final opened = <String>[];
      await pumpBubble(tester, onOpenLink: opened.add);

      await tester.tapOnText(find.textRange.ofSubstring('look'));

      expect(opened, isEmpty);
    });

    testWidgets('a bare www link opens over https', (tester) async {
      final opened = <String>[];
      await pumpBubble(tester,
          text: 'try www.example.com today', onOpenLink: opened.add);

      await tester.tapOnText(find.textRange.ofSubstring('www.example.com'));

      expect(opened, ['https://www.example.com']);
    });

    testWidgets('the link is underlined so it reads as tappable',
        (tester) async {
      await pumpBubble(tester, onOpenLink: (_) {});

      final rich = tester
          .widgetList<RichText>(find.byType(RichText))
          .firstWhere((r) => r.text.toPlainText() == shared);
      final underlined = <String>[];
      void visit(InlineSpan s) {
        if (s is TextSpan) {
          if (s.text != null &&
              s.style?.decoration == TextDecoration.underline) {
            underlined.add(s.text!);
          }
          s.children?.forEach(visit);
        }
      }

      visit(rich.text);
      expect(underlined,
          ['https://www.instagram.com/reel/Cabc123/?igsh=xyz']);
    });

    testWidgets('the whole message text is still shown around the link',
        (tester) async {
      await pumpBubble(tester, onOpenLink: (_) {});

      expect(find.text(shared), findsOneWidget);
    });

    testWidgets('a search highlight takes precedence over link tapping',
        (tester) async {
      final opened = <String>[];
      await pumpBubble(tester, onOpenLink: opened.add, highlight: 'look');

      await tester.tapOnText(find.textRange.ofSubstring(
          'https://www.instagram.com/reel/Cabc123/?igsh=xyz'));

      expect(opened, isEmpty);
    });
  });

  group('MessageBubble link preview card', () {
    const preview = LinkPreview(
      url: 'https://www.instagram.com/reel/Cabc123/',
      title: 'A reel about cats',
      description: 'Watch this now',
    );

    Future<void> pumpCard(
      WidgetTester tester, {
      LinkPreview? linkPreview = preview,
      ValueChanged<String>? onOpenLink,
    }) {
      return tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MessageBubble(
              text: 'look https://www.instagram.com/reel/Cabc123/',
              time: '12:34',
              mine: false,
              linkPreview: linkPreview,
              onOpenLink: onOpenLink ?? (_) {},
            ),
          ),
        ),
      );
    }

    testWidgets('shows the page title', (tester) async {
      await pumpCard(tester);

      expect(find.text('A reel about cats'), findsOneWidget);
    });

    testWidgets('shows the page description', (tester) async {
      await pumpCard(tester);

      expect(find.text('Watch this now'), findsOneWidget);
    });

    testWidgets('shows the site the link goes to', (tester) async {
      await pumpCard(tester);

      expect(find.text('www.instagram.com'), findsOneWidget);
    });

    testWidgets('still shows the message text', (tester) async {
      await pumpCard(tester);

      expect(find.textContaining('look '), findsOneWidget);
    });

    testWidgets('tapping the card opens the link', (tester) async {
      final opened = <String>[];
      await pumpCard(tester, onOpenLink: opened.add);

      await tester.tap(find.text('A reel about cats'));

      expect(opened, [preview.url]);
    });

    testWidgets('shows no card when there is no preview', (tester) async {
      await pumpCard(tester, linkPreview: null);

      expect(find.byType(LinkPreviewCard), findsNothing);
    });
  });

  group('MessageBubble reply preview', () {
    Future<void> pumpReply(
      WidgetTester tester, {
      VoidCallback? onTapReply,
    }) {
      return tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MessageBubble(
              text: 'my answer',
              time: '12:34',
              mine: true,
              replyWho: '@ada',
              replyText: 'the original question',
              onTapReply: onTapReply,
            ),
          ),
        ),
      );
    }

    testWidgets('tapping the reply preview reports the tap', (tester) async {
      var taps = 0;
      await pumpReply(tester, onTapReply: () => taps++);

      await tester.tap(find.text('the original question'));

      expect(taps, 1);
    });

    testWidgets('tapping the message body does not report a reply tap',
        (tester) async {
      var taps = 0;
      await pumpReply(tester, onTapReply: () => taps++);

      await tester.tap(find.text('my answer'));

      expect(taps, 0);
    });

    testWidgets('the reply preview is inert when no handler is given',
        (tester) async {
      await pumpReply(tester);

      await tester.tap(find.text('the original question'));

      expect(find.text('the original question'), findsOneWidget);
    });
  });
}
