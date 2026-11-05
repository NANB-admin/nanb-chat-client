import 'dart:async';

import '../../../core/models/account.dart';
import '../../../core/models/device.dart';
import '../../../core/network/api_client.dart';
import '../models/conversation.dart';

/// In-memory caches of the peer/own device directory: per-account peer device
/// lists (each device's X25519 + sealed-receive capability) and THIS account's
/// own device list. Backs multi-device fan-out (RatchetCore), sealed-sender
/// device gating (SealedSender), self-sync "mine" detection (isMyDevice*), and
/// group-member resolution. Cross-cutting — the notifier keeps thin delegators
/// so existing callers + host methods are unchanged. Extracted from
/// `ConversationsNotifier`.
class DeviceCache {
  DeviceCache({required ApiClient api}) : _api = api;

  final ApiClient _api;

  final Map<String, List<AccountDevice>> _peerDevices = {};
  List<Device>? _myDevicesCache;
  DateTime? _myDevicesFetchedAt;

  /// The cached peer device list for [accountId] (empty if unknown).
  List<AccountDevice> peerDevices(String accountId) =>
      _peerDevices[accountId] ?? const <AccountDevice>[];

  final Map<String, DateTime> _peerFetchedAt = {};

  /// Record [accountId]'s device list (learned from an account lookup).
  void setPeerDevices(String accountId, List<AccountDevice> devices,
      {DateTime? now}) {
    _peerDevices[accountId] = devices;
    _peerFetchedAt[accountId] = now ?? DateTime.now();
  }

  /// True when [accountId]'s cached device list is missing or older than
  /// [maxAge]. A peer can link a new device at any time; a list cached before
  /// that silently omits it, so every send fans out without it until the app
  /// restarts.
  bool peerDevicesStale(String accountId,
      {Duration maxAge = const Duration(minutes: 2), DateTime? now}) {
    final at = _peerFetchedAt[accountId];
    if (at == null) return true;
    return (now ?? DateTime.now()).difference(at) > maxAge;
  }

  /// True when the own-device list was never fetched or is older than
  /// [maxAge]. You can link a device at any time; a list cached before that
  /// silently omits it, so this device's own sends (the self-sync copy to your
  /// other devices) never reached the new one until an app restart. Bounded
  /// like the peer list.
  bool myDevicesStale(
      {Duration maxAge = const Duration(minutes: 2), DateTime? now}) {
    final at = _myDevicesFetchedAt;
    if (_myDevicesCache == null || at == null) return true;
    return (now ?? DateTime.now()).difference(at) > maxAge;
  }

  /// This account's own devices. Cached, but re-fetched once it is older than
  /// two minutes so a newly linked device is picked up for self-sync. If the
  /// refresh fails the previous list is kept (empty only when nothing was ever
  /// fetched), so a flaky network never makes a send drop its self-sync copies.
  Future<List<Device>> myDevices({DateTime? now}) async {
    final cached = _myDevicesCache;
    if (cached != null && !myDevicesStale(now: now)) return cached;
    try {
      final devs = await _api.listDevices();
      _myDevicesCache = devs;
      _myDevicesFetchedAt = now ?? DateTime.now();
      return devs;
    } catch (_) {
      return cached ?? const [];
    }
  }

  /// Synchronous peek at the own-device cache (empty if not yet loaded).
  List<Device> myDevicesSync() => _myDevicesCache ?? const <Device>[];

  /// Drop + reload the own-device cache (after a device-link change / cold miss).
  Future<void> refreshMyDevices() async {
    _myDevicesCache = null;
    await myDevices();
  }

  /// Invalidate the own-device cache without reloading.
  void clearMyDevices() {
    _myDevicesCache = null;
    _myDevicesFetchedAt = null;
  }

  /// The X25519 key for [deviceId], from the peer-device or own-device cache.
  /// Empty when unknown.
  List<int> x25519ForSender(Conversation convo, String deviceId) {
    for (final d
        in (_peerDevices[convo.peerAccountId] ?? const <AccountDevice>[])) {
      if (d.deviceId == deviceId) return d.x25519PubKey;
    }
    for (final d in (_myDevicesCache ?? const <Device>[])) {
      if (d.deviceId == deviceId) return d.x25519PubKey;
    }
    return const [];
  }

  /// True when [deviceId] belongs to THIS account (this device or a linked one)
  /// — drives `mine` for self-synced copies of our own sends.
  bool isMyDevice(String deviceId, String myDeviceId) {
    if (deviceId == myDeviceId) return true;
    final mine = _myDevicesCache;
    return mine != null && mine.any((d) => d.deviceId == deviceId);
  }

  /// Like [isMyDevice] but warms the own-device cache once if it's never been
  /// loaded — a RECEIVE-ONLY linked device never populates it on a send path, so
  /// a self-synced copy of our own message would otherwise render as incoming.
  Future<bool> isMyDeviceWarm(String deviceId, String myDeviceId) async {
    if (isMyDevice(deviceId, myDeviceId)) return true;
    if (_myDevicesCache == null) {
      await myDevices();
      return isMyDevice(deviceId, myDeviceId);
    }
    return false;
  }

  /// Drop all cached device data (sign-out / account switch).
  void clear() {
    _peerDevices.clear();
    _peerFetchedAt.clear();
    _myDevicesCache = null;
    _myDevicesFetchedAt = null;
  }
}
