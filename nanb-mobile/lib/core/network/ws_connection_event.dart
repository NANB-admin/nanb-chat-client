import 'package:flutter/foundation.dart';

/// Events emitted by `WsReconnectSupervisor` for consumers (notably
/// `ConversationsNotifier`) to react to. Payload-free markers — the
/// supervisor does not track envelope-level state.
@immutable
sealed class WsConnectionEvent {
  const WsConnectionEvent();
}

/// Emitted exactly once per successful `WsClient.connect()` call.
/// `ConversationsNotifier` listens for this and triggers
/// `/messages/catchup` to backfill anything missed during the drop.
@immutable
class Reconnected extends WsConnectionEvent {
  const Reconnected();
}

/// Emitted exactly once when `refreshSession()` fails permanently. After
/// emitting `SignedOut` the supervisor transitions to terminal — no
/// further events are emitted and `start()`/`onAppResumed()` are no-ops
/// until `stop()` then `start()`.
@immutable
class SignedOut extends WsConnectionEvent {
  const SignedOut();
}
