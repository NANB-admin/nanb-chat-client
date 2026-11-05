import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/design_tokens.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import '../../app/theme.dart';
import '../../core/models/device.dart';
import '../../core/models/device_kind.dart';
import '../onboarding/widgets/nanb_button.dart';
import 'widgets/settings_scaffold.dart';

/// Max devices an account may have linked at once (mirrors the client cap; the
/// server allows a little more headroom). Linking is disabled at this count
/// until the user removes a device.
const int _maxDevices = 3;

/// Settings → Account → Linked devices. Lists every active device the server
/// knows about for this account, lets the user link a new one (until the cap),
/// and revoke any other device.
class LinkedDevicesScreen extends ConsumerStatefulWidget {
  const LinkedDevicesScreen({super.key});

  @override
  ConsumerState<LinkedDevicesScreen> createState() => _LinkedDevicesScreenState();
}

class _LinkedDevicesScreenState extends ConsumerState<LinkedDevicesScreen> {
  Future<List<Device>>? _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  bool _busy = false;

  Future<List<Device>> _load({bool connect = true}) async {
    // The notifier sets the bearer token on connect(); ensure that's done on
    // the FIRST load only. A reload (after a revoke) must NOT re-enter connect():
    // conversationsProvider can rebuild — disposing its notifier — while an
    // async connect() is mid-flight, and the late notifyListeners() then throws
    // "used after disposed". The session is already connected by then anyway.
    if (connect) {
      await ref.read(conversationsProvider).connect();
    }
    return ref.read(apiClientProvider).listDevices();
  }

  void _reload() {
    if (!mounted) return;
    // Block body (not `=> _future = …`): an arrow closure RETURNS the assigned
    // Future, and setState rejects a callback that returns a Future.
    setState(() {
      _future = _load(connect: false);
    });
  }

  Future<void> _revoke(Device device) async {
    if (_busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove this device?'),
        content: Text(
          'It will be signed out and stop receiving messages. You can link it '
          'again later. (${device.displayName ?? 'Device'})',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(apiClientProvider).revokeDevice(device.deviceId);
      // Best-effort: evict the revoked device's MLS leaf from every group it's
      // in so no dead leaf lingers (the conversationsProvider outlives this
      // screen, so it finishes even if we navigate away).
      unawaited(ref
          .read(conversationsProvider)
          .removeRevokedDeviceFromGroups(device.deviceId));
      if (!mounted) return;
      messenger.showSnackBar(const SnackBar(content: Text('Device removed.')));
      _reload();
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('Could not remove device: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    return SettingsScaffold(
      title: 'Linked devices',
      child: FutureBuilder<List<Device>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return _ErrorBody(t: t, error: snap.error!);
          }
          final devices = snap.data ?? const [];
          final atCap = devices.length >= _maxDevices;
          return ListView(
            children: [
              SettingsSectionHeader(
                  label: '${devices.length} of $_maxDevices devices'),
              SettingsCard(
                children: [
                  for (var i = 0; i < devices.length; i++)
                    _DeviceRow(
                      t: t,
                      device: devices[i],
                      last: i == devices.length - 1,
                      // Only OTHER devices can be removed from here — you can't
                      // revoke the device you're signed in on (delete the
                      // account instead).
                      onRemove: devices[i].isThisDevice || _busy
                          ? null
                          : () => _revoke(devices[i]),
                    ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.all(14),
                child: SizedBox(
                  width: double.infinity,
                  child: NanbButton(
                    label: 'Link a new device',
                    kind: NanbButtonKind.primary,
                    icon: Icons.qr_code_scanner,
                    onPressed: atCap
                        ? null
                        : () async {
                            // Refresh the list when we return — the just-linked
                            // device should appear without leaving + reopening.
                            await context.push(Routes.linkPrimaryDevice);
                            _reload();
                          },
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 0),
                child: Text(
                  atCap
                      ? 'Device limit reached ($_maxDevices). Remove a device '
                          'above to link a new one.'
                      : 'Each device gets its own keypair — compromise of one '
                          'does not affect the others. Every linked device '
                          'receives your messages.',
                  style: TextStyle(
                    fontSize: 12,
                    color: atCap ? t.warn : t.textMuted,
                    height: 1.5,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({
    required this.t,
    required this.device,
    required this.last,
    this.onRemove,
  });
  final DesignTokens t;
  final Device device;
  final bool last;

  /// Null for this device (you can't revoke the one you're signed in on) or
  /// while a revoke is in flight.
  final VoidCallback? onRemove;

  String get _fingerprint {
    final hex = device.devicePubKey
        .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join();
    final pairs = <String>[];
    for (var i = 0; i < hex.length && i < 12; i += 4) {
      pairs.add(hex.substring(i, i + 4));
    }
    return pairs.isEmpty ? '— — —' : pairs.join(' ');
  }

  String get _linkedAtLabel {
    final at = device.linkedAt;
    if (at == null) return '';
    final months = const [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return 'Linked ${months[at.month - 1]} ${at.day}, ${at.year}';
  }

  String get _expiresLabel {
    final at = device.expiresAt?.toLocal();
    if (at == null) return '';
    final months = const [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return 'Expires ${months[at.month - 1]} ${at.day}, ${at.year}';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        border: last ? null : Border(bottom: BorderSide(color: t.border)),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: t.surfaceAlt,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: t.border),
            ),
            child: Icon(
              device.isThisDevice ? Icons.smartphone : Icons.devices_other,
              size: 18,
              color: t.text,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Text(
                      device.displayName ?? 'Device',
                      style: TextStyle(fontSize: 14, color: t.text),
                    ),
                    if (device.kind == DeviceKind.web) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: t.surfaceAlt,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: t.border),
                        ),
                        child: Text(
                          'WEB',
                          style: monoStyle(
                            fontSize: 9,
                            color: t.textMuted,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                    ],
                    if (device.isThisDevice) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: t.accent.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: t.accent),
                        ),
                        child: Text(
                          'THIS DEVICE',
                          style: monoStyle(
                            fontSize: 9,
                            color: t.accent,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  _fingerprint,
                  style: monoStyle(
                    fontSize: 11,
                    color: t.textMuted,
                    letterSpacing: 0.4,
                  ),
                ),
                if (_linkedAtLabel.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    _linkedAtLabel,
                    style: monoStyle(
                      fontSize: 10,
                      color: t.textFaint,
                      letterSpacing: 0.3,
                    ),
                  ),
                ],
                if (_expiresLabel.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    _expiresLabel,
                    style: monoStyle(
                      fontSize: 10,
                      color: t.textFaint,
                      letterSpacing: 0.3,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (onRemove != null)
            IconButton(
              onPressed: onRemove,
              icon: Icon(Icons.delete_outline, size: 20, color: t.warn),
              tooltip: 'Remove device',
              visualDensity: VisualDensity.compact,
            ),
        ],
      ),
    );
  }
}

class _ErrorBody extends StatelessWidget {
  const _ErrorBody({required this.t, required this.error});
  final DesignTokens t;
  final Object error;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 36, color: t.warn),
            const SizedBox(height: 12),
            Text(
              "Couldn't load devices",
              style: TextStyle(fontSize: 14, color: t.text),
            ),
            const SizedBox(height: 8),
            Text(
              error.toString(),
              textAlign: TextAlign.center,
              style: monoStyle(fontSize: 11, color: t.textMuted, letterSpacing: 0.3),
            ),
          ],
        ),
      ),
    );
  }
}
