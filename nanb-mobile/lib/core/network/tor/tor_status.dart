import 'package:flutter/foundation.dart';

/// Lifecycle phase of the embedded Tor engine. See `docs/embedded-tor-design.md`
/// §6 (Lifecycle & bootstrap UX).
enum TorPhase {
  /// Not running — direct connection.
  off,

  /// `start()` issued; the native engine/service is coming up.
  starting,

  /// Engine up, building circuits. Network is held (fail-closed — don't fall
  /// back to clearnet while Tor is the selected mode).
  bootstrapping,

  /// SOCKS port ready; traffic can flow through Tor.
  connected,

  /// Start/bootstrap failed or the engine stalled. Surfaced with [message].
  error,
}

/// Immutable snapshot of the embedded Tor engine's state, mirrored from the
/// native binding's status stream.
@immutable
class TorStatus {
  const TorStatus({
    required this.phase,
    this.bootstrapPercent = 0,
    this.socksPort,
    this.message,
  });

  const TorStatus.off() : this(phase: TorPhase.off);
  const TorStatus.starting() : this(phase: TorPhase.starting);

  final TorPhase phase;

  /// 0..100 while [TorPhase.bootstrapping]. Coarse — the C-tor service status
  /// broadcast is STARTING/ON, so without control-port bootstrap events this
  /// may jump 0 → 100. Best-effort; treat [phase] as authoritative.
  final int bootstrapPercent;

  /// The local SOCKS5 port the engine listens on, set once [TorPhase.connected].
  /// The networking layer routes through `127.0.0.1:<socksPort>`.
  final int? socksPort;

  /// Human-readable detail, primarily for [TorPhase.error].
  final String? message;

  /// True only when Tor is up AND a SOCKS port is known — the gate the routing
  /// layer should require before sending traffic through Tor.
  bool get isConnected => phase == TorPhase.connected && socksPort != null;

  TorStatus copyWith({
    TorPhase? phase,
    int? bootstrapPercent,
    int? socksPort,
    String? message,
  }) =>
      TorStatus(
        phase: phase ?? this.phase,
        bootstrapPercent: bootstrapPercent ?? this.bootstrapPercent,
        socksPort: socksPort ?? this.socksPort,
        message: message ?? this.message,
      );

  @override
  bool operator ==(Object other) =>
      other is TorStatus &&
      other.phase == phase &&
      other.bootstrapPercent == bootstrapPercent &&
      other.socksPort == socksPort &&
      other.message == message;

  @override
  int get hashCode => Object.hash(phase, bootstrapPercent, socksPort, message);

  @override
  String toString() =>
      'TorStatus(${phase.name}, $bootstrapPercent%, socks=$socksPort'
      '${message != null ? ', "$message"' : ''})';
}
