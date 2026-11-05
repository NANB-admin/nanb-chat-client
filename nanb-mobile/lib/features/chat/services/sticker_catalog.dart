import 'package:flutter/services.dart';

import '../models/sticker.dart';
import '../models/sticker_pack.dart';

/// Lists the sticker packs bundled under `assets/stickers/<pack>/<file>`.
///
/// Packs are discovered from the asset manifest, so adding a pack is just
/// dropping a folder of images in (and, optionally, naming it in [_titles] /
/// [_order] below) — no per-sticker list to maintain.
class StickerCatalog {
  StickerCatalog({required Future<List<String>> Function() listAssetPaths})
      : _listAssetPaths = listAssetPaths;

  /// The real catalog, backed by the app's asset bundle.
  factory StickerCatalog.fromBundle() => StickerCatalog(
        listAssetPaths: () async =>
            (await AssetManifest.loadFromAssetBundle(rootBundle)).listAssets(),
      );

  static const _root = 'assets/stickers/';

  /// Display order and titles for the shipped packs; a pack not named here sorts
  /// after them (alphabetically) under a title derived from its folder name.
  static const _order = ['faces', 'reactions', 'fun'];
  static const _titles = {
    'faces': 'Faces',
    'reactions': 'Reactions',
    'fun': 'Fun',
  };

  final Future<List<String>> Function() _listAssetPaths;

  Future<List<StickerPack>> bundledPacks() async {
    final byPack = <String, List<String>>{};
    for (final path in await _listAssetPaths()) {
      if (!path.startsWith(_root) || !_isImage(path)) continue;
      final rest = path.substring(_root.length);
      final slash = rest.indexOf('/');
      if (slash <= 0) continue; // a loose file, not inside a pack folder
      byPack.putIfAbsent(rest.substring(0, slash), () => []).add(path);
    }
    final ids = byPack.keys.toList()..sort(_compareIds);
    return [
      for (final id in ids)
        StickerPack(
          id: id,
          title: _titles[id] ?? _titleCase(id),
          stickers: [
            for (final path in (byPack[id]!..sort())) Sticker.asset(path),
          ],
        ),
    ];
  }

  static int _compareIds(String a, String b) {
    final ia = _order.indexOf(a);
    final ib = _order.indexOf(b);
    if (ia >= 0 && ib >= 0) return ia.compareTo(ib);
    if (ia >= 0) return -1;
    if (ib >= 0) return 1;
    return a.compareTo(b);
  }

  static bool _isImage(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.png') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.gif');
  }

  static String _titleCase(String id) => id.isEmpty
      ? id
      : id
          .split(RegExp(r'[_\- ]+'))
          .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
          .join(' ');
}
