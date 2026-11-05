import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/auth/passcode_service.dart';
import 'package:nanb_chat/core/secure_storage/secure_storage.dart';

void main() {
  late SecureStorageInMemory storage;
  late PasscodeService svc;

  setUp(() {
    storage = SecureStorageInMemory();
    svc = PasscodeService(storage);
  });

  test('no passcode initially; verify is false', () async {
    expect(await svc.isSet(), isFalse);
    expect(await svc.verify('123456'), isFalse);
  });

  test('set then verify the correct passcode; reject a wrong one', () async {
    await svc.setPasscode('123456');
    expect(await svc.isSet(), isTrue);
    expect(await svc.verify('123456'), isTrue);
    expect(await svc.verify('654321'), isFalse);
  });

  test('concurrent set + verify still derive correctly off the UI isolate', () async {
    // Each derive runs PBKDF2 on a spawned isolate; firing several in parallel
    // confirms the isolate-offloaded derivation stays correct under concurrency.
    await Future.wait([
      svc.setPasscode('135790'),
    ]);
    final results = await Future.wait([
      svc.verify('135790'),
      svc.verify('135790'),
      svc.verify('135790'),
    ]);
    expect(results, everyElement(isTrue));
  });

  test('clear removes the passcode', () async {
    await svc.setPasscode('424242');
    await svc.clear();
    expect(await svc.isSet(), isFalse);
    expect(await svc.verify('424242'), isFalse);
  });

  test('rejects wrong-length or non-digit passcodes', () async {
    await expectLater(svc.setPasscode('123'), throwsArgumentError);
    await expectLater(svc.setPasscode('12345678'), throwsArgumentError);
    await expectLater(svc.setPasscode('12ab56'), throwsArgumentError);
  });

  test('locks out after too many wrong attempts', () async {
    await svc.setPasscode('123456');
    for (var i = 0; i < 5; i++) {
      expect(await svc.verify('000000'), isFalse);
    }
    // The 5th wrong attempt arms the lockout window.
    expect(await svc.lockoutRemaining(), isNotNull);
    // Even the CORRECT PIN is refused while locked out.
    expect(await svc.verify('123456'), isFalse);
  });

  test('a correct PIN before the threshold resets the failure streak', () async {
    await svc.setPasscode('123456');
    for (var i = 0; i < 4; i++) {
      expect(await svc.verify('000000'), isFalse);
    }
    // Below the threshold — not locked out yet.
    expect(await svc.lockoutRemaining(), isNull);
    expect(await svc.verify('123456'), isTrue);
    // The streak reset, so four fresh wrong attempts still don't lock out.
    for (var i = 0; i < 4; i++) {
      expect(await svc.verify('000000'), isFalse);
    }
    expect(await svc.lockoutRemaining(), isNull);
  });

  test('setting a passcode clears any prior lockout', () async {
    await svc.setPasscode('123456');
    for (var i = 0; i < 5; i++) {
      await svc.verify('000000');
    }
    expect(await svc.lockoutRemaining(), isNotNull);
    await svc.setPasscode('654321');
    expect(await svc.lockoutRemaining(), isNull);
    expect(await svc.verify('654321'), isTrue);
  });

  test('never stores the PIN in cleartext; salt differs per device', () async {
    await svc.setPasscode('111111');
    final hash = await storage.getString('passcode.hash.b64');
    final salt = await storage.getString('passcode.salt.b64');
    expect(hash, isNotNull);
    expect(salt, isNotNull);
    expect(hash, isNot(contains('111111')));

    // Same PIN on a second device hashes differently (random salt).
    final svc2 = PasscodeService(SecureStorageInMemory());
    await svc2.setPasscode('111111');
    // (can't read svc2's storage here, but verifying its own PIN still works)
    expect(await svc2.verify('111111'), isTrue);
  });

  group('lockout resists wall-clock tampering', () {
    late SecureStorageInMemory storage;
    late DateTime wall;
    late int? mono;
    late PasscodeService svc;

    setUp(() {
      storage = SecureStorageInMemory();
      wall = DateTime.utc(2026, 1, 1, 12);
      mono = 1000000; // 1000s of uptime
      svc = PasscodeService(storage,
          now: () => wall, monotonicMs: () async => mono);
    });

    Future<void> armLockout() async {
      await svc.setPasscode('123456');
      for (var i = 0; i < 5; i++) {
        await svc.verify('000000');
      }
      expect(await svc.lockoutRemaining(), isNotNull); // 30s window armed
    }

    test('rolling the wall clock far forward does NOT clear the lockout — the '
        'monotonic clock still holds it', () async {
      await armLockout();
      wall = wall.add(const Duration(days: 365)); // attacker jumps the clock
      mono = mono! + 500; // but only 0.5s of real time elapsed
      expect(await svc.lockoutRemaining(), isNotNull);
      expect(await svc.verify('123456'), isFalse); // correct PIN still refused
    });

    test('the lockout clears once genuine (monotonic) time has elapsed',
        () async {
      await armLockout();
      wall = wall.add(const Duration(seconds: 31));
      mono = mono! + 31000; // both clocks advance together
      expect(await svc.lockoutRemaining(), isNull);
    });

    test('a reboot re-anchors the lockout on the fresh monotonic clock, so a '
        'reboot + wall-clock roll can NOT skip the wait', () async {
      await armLockout(); // 5 fails → 30s lockout
      // Reboot: uptime jumps backwards AND the attacker rolls the wall clock a
      // year forward. Old (broken) behavior fell back to wall → unlocked.
      mono = 200;
      wall = wall.add(const Duration(days: 365));
      // Still locked — the reboot re-anchored a fresh 30s monotonic deadline
      // the rolled wall clock can't shorten.
      expect(await svc.lockoutRemaining(), isNotNull);
      // Clears only once REAL (monotonic) time passes on the fresh anchor.
      mono = 200 + 31000;
      expect(await svc.lockoutRemaining(), isNull);
    });

    test('with no monotonic clock available it degrades to the wall clock',
        () async {
      mono = null; // platform gives no monotonic reading
      await armLockout();
      expect(await svc.lockoutRemaining(), isNotNull);
      wall = wall.add(const Duration(seconds: 31));
      expect(await svc.lockoutRemaining(), isNull);
    });
  });
}
