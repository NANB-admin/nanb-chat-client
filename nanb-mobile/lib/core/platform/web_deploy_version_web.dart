import 'dart:convert';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// The `build_number` in the host's `/version.json` (served `no-cache`), or
/// null when it can't be read (offline, blocked, malformed). Never throws.
Future<String?> fetchDeployedBuild() async {
  try {
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final res = await web.window
        .fetch('version.json?t=$stamp'.toJS, web.RequestInit(cache: 'no-store'))
        .toDart;
    if (!res.ok) return null;
    final text = (await res.text().toDart).toDart;
    final json = jsonDecode(text) as Map<String, Object?>;
    return json['build_number']?.toString();
  } catch (_) {
    return null;
  }
}

/// Reloads the page so the browser picks up the newly deployed build.
void reloadPage() => web.window.location.reload();
