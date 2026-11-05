import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:nanb_chat/app/providers.dart';
import 'package:nanb_chat/app/router.dart';
import 'package:nanb_chat/app/theme.dart';
import 'package:nanb_chat/core/models/api_error.dart';
import 'package:nanb_chat/core/network/api_client.dart';
import 'package:nanb_chat/features/onboarding/username_screen.dart';

class _MockApi extends Mock implements ApiClient {}

void main() {
  late _MockApi api;

  Widget buildHarness() {
    final router = GoRouter(
      routes: [
        GoRoute(
          path: Routes.username,
          builder: (context, state) => const UsernameScreen(),
        ),
        GoRoute(
          path: Routes.recoverySetup,
          builder: (context, state) => Scaffold(
            body: Text('RecoverySetup:${state.extra as String? ?? ''}'),
          ),
        ),
      ],
      initialLocation: Routes.username,
    );
    return ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
      ],
      child: MaterialApp.router(
        theme: buildLightTheme(),
        routerConfig: router,
      ),
    );
  }

  setUp(() {
    api = _MockApi();
  });

  testWidgets('available username navigates to recovery setup', (tester) async {
    when(() => api.checkUsername('nass'))
        .thenAnswer((_) async => const UsernameAvailability(available: true));

    await tester.pumpWidget(buildHarness());
    await tester.enterText(find.byType(TextField), 'nass');
    await tester.pump();
    await tester.tap(find.text('CONTINUE'));
    await tester.pumpAndSettle();

    verify(() => api.checkUsername('nass')).called(1);
    expect(find.text('RecoverySetup:nass'), findsOneWidget);
  });

  testWidgets('mixed-case username is checked and saved lowercase',
      (tester) async {
    when(() => api.checkUsername('nassj'))
        .thenAnswer((_) async => const UsernameAvailability(available: true));

    await tester.pumpWidget(buildHarness());
    await tester.enterText(find.byType(TextField), 'NassJ');
    await tester.pump();
    await tester.tap(find.text('CONTINUE'));
    await tester.pumpAndSettle();

    verify(() => api.checkUsername('nassj')).called(1);
    expect(find.text('RecoverySetup:nassj'), findsOneWidget);
  });

  testWidgets('taken username shows inline error and stays put', (tester) async {
    when(() => api.checkUsername('nass')).thenAnswer(
        (_) async => const UsernameAvailability(available: false, reason: 'taken'));

    await tester.pumpWidget(buildHarness());
    await tester.enterText(find.byType(TextField), 'nass');
    await tester.pump();
    await tester.tap(find.text('CONTINUE'));
    await tester.pumpAndSettle();

    expect(find.text('@nass is already taken'), findsOneWidget);
    expect(find.textContaining('RecoverySetup:'), findsNothing);
  });

  testWidgets('held username shows the 30-day hold error', (tester) async {
    when(() => api.checkUsername('nass')).thenAnswer((_) async =>
        const UsernameAvailability(available: false, reason: 'on_hold'));

    await tester.pumpWidget(buildHarness());
    await tester.enterText(find.byType(TextField), 'nass');
    await tester.pump();
    await tester.tap(find.text('CONTINUE'));
    await tester.pumpAndSettle();

    expect(
      find.text('@nass was recently deleted and is on a 30-day hold'),
      findsOneWidget,
    );
    expect(find.textContaining('RecoverySetup:'), findsNothing);
  });

  testWidgets('network failure blocks with a reachability error', (tester) async {
    when(() => api.checkUsername('nass')).thenThrow(
        const ApiError(code: 'network', message: 'connection refused'));

    await tester.pumpWidget(buildHarness());
    await tester.enterText(find.byType(TextField), 'nass');
    await tester.pump();
    await tester.tap(find.text('CONTINUE'));
    await tester.pumpAndSettle();

    expect(
      find.text("can't reach the server — check your connection"),
      findsOneWidget,
    );
    expect(find.textContaining('RecoverySetup:'), findsNothing);
  });

  testWidgets('typing clears a previous error', (tester) async {
    when(() => api.checkUsername('nass')).thenAnswer(
        (_) async => const UsernameAvailability(available: false, reason: 'taken'));

    await tester.pumpWidget(buildHarness());
    await tester.enterText(find.byType(TextField), 'nass');
    await tester.pump();
    await tester.tap(find.text('CONTINUE'));
    await tester.pumpAndSettle();
    expect(find.text('@nass is already taken'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'nass2');
    await tester.pump();
    expect(find.text('@nass is already taken'), findsNothing);
  });
}
