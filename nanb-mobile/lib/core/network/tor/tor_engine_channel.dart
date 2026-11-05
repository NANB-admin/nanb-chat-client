import 'package:flutter/services.dart';

import 'tor_engine.dart';
import 'tor_status.dart';

/// [TorEngine] backed by the `nanb_crypto` plugin's native Tor binding
/// (Guardian Project C-tor). A [MethodChannel] drives start/stop; an
/// [EventChannel] streams status updates.
///
/// **Channel contract** (the native side must conform):
/// - MethodChannel `nanb.app/tor`: methods `start` and `stop` (no args).
/// - EventChannel `nanb.app/tor_status`: emits a Map per update:
///     - `phase`: one of `off|starting|bootstrapping|connected|error`
///     - `percent`: int 0..100 (optional; bootstrap progress)
///     - `socksPort`: int (present once `connected`)
///     - `message`: String (optional; error/detail)
///
/// Off Android (tests / iOS shim) the channels simply never deliver, so the
/// stream stays idle and start()/stop() throw [MissingPluginException] which the
/// controller turns into an error status.
class TorEngineChannel implements TorEngine {
  TorEngineChannel({MethodChannel? method, EventChannel? events})
      : _method = method ?? const MethodChannel('nanb.app/tor'),
        _events = events ?? const EventChannel('nanb.app/tor_status');

  final MethodChannel _method;
  final EventChannel _events;

  @override
  Stream<TorStatus> get status => _events
      .receiveBroadcastStream()
      .map(_decode)
      .where((s) => s != null)
      .cast<TorStatus>();

  @override
  Future<void> start() => _method.invokeMethod<void>('start');

  @override
  Future<void> stop() => _method.invokeMethod<void>('stop');

  @override
  Future<void> reconnect() => _method.invokeMethod<void>('reconnect');

  @override
  Future<void> prepareForBackground() =>
      _method.invokeMethod<void>('prepareForBackground');

  @override
  Future<void> wake() => _method.invokeMethod<void>('wake');

  static TorStatus? _decode(dynamic event) {
    if (event is! Map) return null;
    final phaseName = event['phase'] as String?;
    if (phaseName == null) return null;
    final phase = TorPhase.values.firstWhere(
      (p) => p.name == phaseName,
      orElse: () => TorPhase.error,
    );
    return TorStatus(
      phase: phase,
      bootstrapPercent: (event['percent'] as num?)?.toInt() ?? 0,
      socksPort: (event['socksPort'] as num?)?.toInt(),
      message: event['message'] as String?,
    );
  }
}
