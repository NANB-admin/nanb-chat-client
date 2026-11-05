import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/app/providers.dart';
import 'package:nanb_chat/core/secure_storage/secure_storage.dart';
import 'package:nanb_chat/features/onboarding/recovery_phrase_storage.dart';
import 'package:nanb_chat/features/settings/recovery_phrase_reveal_settings_screen.dart';

const _phrase =
    'boy wink flock dizzy inject enforce mercy offer wasp oil settle peasant';

Future<void> _pump(WidgetTester tester, SecureStorage storage) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [secureStorageProvider.overrideWithValue(storage)],
      child: const MaterialApp(home: RecoveryPhraseRevealSettingsScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('reveal is gated behind the passcode when one is set',
      (tester) async {
    final storage = SecureStorageInMemory();
    await RecoveryPhraseStorage(storage).save(_phrase);
    // Mark a passcode as set WITHOUT running setPasscode's PBKDF2 (100k
    // iterations are pathologically slow pure-Dart under `flutter test`).
    // PasscodeService.isSet() only checks the hash key exists; the gate never
    // verifies a PIN in this test, so a placeholder is enough.
    await storage.putString('passcode.hash.b64', 'placeholder');

    await _pump(tester, storage);

    // Hidden initially — no phrase word on screen.
    expect(find.text('boy'), findsNothing);

    await tester.tap(find.text('REVEAL'));
    // _toggleReveal runs an async isSet() check, then pushes the verify screen.
    // Don't pumpAndSettle — the pushed passcode route awaits input and never
    // "settles". Advance a few fixed frames instead.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 400));

    // The passcode prompt is shown; the phrase is NOT revealed.
    expect(find.text('Enter passcode to reveal'), findsOneWidget);
    expect(find.text('boy'), findsNothing);
  });

  testWidgets('reveal shows the phrase directly when no passcode is set',
      (tester) async {
    final storage = SecureStorageInMemory();
    await RecoveryPhraseStorage(storage).save(_phrase);
    // No passcode set.

    await _pump(tester, storage);

    expect(find.text('boy'), findsNothing);

    await tester.tap(find.text('REVEAL'));
    await tester.pumpAndSettle();

    // No gate → the first word is now visible.
    expect(find.text('boy'), findsOneWidget);
  });
}
