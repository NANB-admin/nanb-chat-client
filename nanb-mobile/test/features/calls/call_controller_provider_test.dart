import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/app/providers.dart';
import 'package:nanb_chat/core/secure_storage/secure_storage.dart';
import 'package:nanb_chat/features/calls/models/call_signal.dart';
import 'package:nanb_chat/features/chat/conversations_notifier.dart';
import 'package:nanb_chat/features/onboarding/session_repository.dart';

/// Minimal notifier fake: a real settable [onCallSignal] field (the call layer
/// binds inbound signals to it), everything else routed through noSuchMethod.
class _FakeNotifier extends ChangeNotifier implements ConversationsNotifier {
  @override
  void Function(String, CallSignal, String)? onCallSignal;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  // Regression: a built-in-Tor restart on resume hands out a new SOCKS port,
  // which rebuilds conversationsProvider as a NEW instance. callControllerProvider
  // must NOT be torn down by that swap — otherwise the live CallController is
  // disposed and an in-progress call (e.g. one being answered under app-lock)
  // vanishes, dropping the user back to the chat list.
  test(
      'CallController survives a conversationsProvider rebuild and re-binds the '
      'signal handler onto the new notifier', () async {
    final container = ProviderContainer(overrides: [
      conversationsProvider.overrideWith((ref) => _FakeNotifier()),
      sessionRepositoryProvider
          .overrideWith((ref) => SessionRepository(SecureStorageInMemory())),
    ]);
    addTearDown(container.dispose);

    final controllerA = container.read(callControllerProvider);
    final notifierA = container.read(conversationsProvider.notifier);
    expect(notifierA.onCallSignal, isNotNull,
        reason: 'inbound signals are wired on the initial notifier');

    // Simulate the transport change (Tor restart → new SOCKS port) that rebuilds
    // conversationsProvider with a fresh notifier instance.
    container.refresh(conversationsProvider);
    await Future<void>.value(); // let the ref.listen re-bind fire

    final controllerB = container.read(callControllerProvider);
    final notifierB = container.read(conversationsProvider.notifier);

    expect(identical(controllerA, controllerB), isTrue,
        reason: 'the live CallController must not be disposed/recreated');
    expect(identical(notifierA, notifierB), isFalse,
        reason: 'the notifier really was swapped out');
    expect(notifierB.onCallSignal, isNotNull,
        reason: 'inbound signals re-bound onto the new notifier');
  });
}
