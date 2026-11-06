import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../core/platform/web_deploy_version.dart';

/// On the WEB build, tells the user when a newer build has been deployed than
/// the one they loaded, with a Reload button. An open tab otherwise keeps
/// running old code until it is reloaded by hand.
///
/// The build the page loaded with is the first `version.json` it reads (the
/// deploy that served this code); later polls that differ mean a new deploy.
/// On mobile it returns [child] untouched. [enabled], [fetchLatest], [onReload]
/// and [interval] are injectable for tests.
class WebUpdateBanner extends StatefulWidget {
  const WebUpdateBanner({
    super.key,
    required this.child,
    bool? enabled,
    Future<String?> Function()? fetchLatest,
    VoidCallback? onReload,
    this.interval = const Duration(minutes: 10),
  })  : _enabled = enabled,
        _fetchLatest = fetchLatest,
        _onReload = onReload;

  final Widget child;
  final Duration interval;
  final bool? _enabled;
  final Future<String?> Function()? _fetchLatest;
  final VoidCallback? _onReload;

  @override
  State<WebUpdateBanner> createState() => _WebUpdateBannerState();
}

class _WebUpdateBannerState extends State<WebUpdateBanner> {
  Timer? _timer;
  String? _loadedBuild;
  bool _updateAvailable = false;

  bool get _enabled => widget._enabled ?? kIsWeb;
  Future<String?> Function() get _fetch =>
      widget._fetchLatest ?? fetchDeployedBuild;

  @override
  void initState() {
    super.initState();
    if (!_enabled) return;
    unawaited(_check());
    _timer = Timer.periodic(widget.interval, (_) => unawaited(_check()));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _check() async {
    final latest = await _fetch();
    if (!mounted || latest == null) return;
    final loaded = _loadedBuild;
    if (loaded == null) {
      _loadedBuild = latest;
      return;
    }
    if (latest != loaded && !_updateAvailable) {
      setState(() => _updateAvailable = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_enabled || !_updateAvailable) return widget.child;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Material(
          color: scheme.primaryContainer,
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'A new version is available.',
                      style: TextStyle(color: scheme.onPrimaryContainer),
                    ),
                  ),
                  TextButton(
                    onPressed: widget._onReload ?? reloadPage,
                    child: const Text('Reload'),
                  ),
                ],
              ),
            ),
          ),
        ),
        Expanded(child: widget.child),
      ],
    );
  }
}
