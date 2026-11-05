import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'services/sticker_catalog.dart';
import 'services/sticker_collector.dart';
import 'services/sticker_importer.dart';
import 'services/sticker_normalizer.dart';
import 'services/user_sticker_store.dart';

/// Bundled sticker packs (read from the asset manifest).
final stickerCatalogProvider = Provider<StickerCatalog>(
  (_) => StickerCatalog.fromBundle(),
);

/// The user's own stickers on disk.
final userStickerStoreProvider = Provider<UserStickerStore>(
  (_) => UserStickerStore(),
);

/// Normalize-and-save, shared by the message action and the picker's "+".
final stickerCollectorProvider = Provider<StickerCollector>(
  (ref) => StickerCollector(
    normalizer: const StickerNormalizer(),
    store: ref.watch(userStickerStoreProvider),
  ),
);

/// Imports stickers from files and sticker bundles made by other apps.
final stickerImporterProvider = Provider<StickerImporter>(
  (ref) => StickerImporter(ref.watch(stickerCollectorProvider)),
);
