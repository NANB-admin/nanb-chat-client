import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../../app/design_tokens.dart';
import '../../../app/providers.dart';
import '../models/sticker.dart';
import '../models/sticker_import_file.dart';
import '../models/sticker_pack.dart';
import '../services/sticker_catalog.dart';
import '../services/sticker_collector.dart';
import '../services/user_sticker_store.dart';
import '../sticker_providers.dart';
import 'sticker_editor_screen.dart';
import 'sticker_thumbnail.dart';

/// The picker's "Stickers" tab: a strip of pack tabs (the user's own stickers
/// first, then the bundled packs) over a grid. Tapping a sticker calls
/// [onSelected] — it does NOT send anything itself; the host loads the bytes and
/// routes them through the encrypted media pipeline, like the GIF tab.
///
/// "My stickers" starts with a "+" tile that adds an image from the gallery, and
/// long-pressing one of your stickers offers to remove it. Stickers are also
/// added from a chat via the message long-press "Add to stickers" action.
class StickerBrowser extends ConsumerStatefulWidget {
  const StickerBrowser({
    super.key,
    required this.onSelected,
    this.catalog,
    this.store,
    this.collector,
  });

  final ValueChanged<Sticker> onSelected;

  /// Injectable for tests; when null the app providers are used.
  final StickerCatalog? catalog;
  final UserStickerStore? store;
  final StickerCollector? collector;

  @override
  ConsumerState<StickerBrowser> createState() => _StickerBrowserState();
}

class _StickerBrowserState extends ConsumerState<StickerBrowser> {
  List<StickerPack> _packs = const [];
  List<Sticker> _mine = const [];
  bool _loaded = false;

  /// 0 = "My stickers"; 1.. = the bundled packs in order.
  int _selected = 0;

  StickerCatalog get _catalog =>
      widget.catalog ?? ref.read(stickerCatalogProvider);
  UserStickerStore get _store =>
      widget.store ?? ref.read(userStickerStoreProvider);
  StickerCollector get _collector =>
      widget.collector ?? ref.read(stickerCollectorProvider);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final packs = await _catalog.bundledPacks();
    final mine = await _store.list();
    if (!mounted) return;
    setState(() {
      _packs = packs;
      _mine = mine;
      _loaded = true;
      // Open on your own stickers once you have some; otherwise on the first
      // bundled pack so a new user lands on something to tap.
      _selected = mine.isEmpty && packs.isNotEmpty ? 1 : 0;
    });
  }

  Future<void> _reloadMine() async {
    final mine = await _store.list();
    if (mounted) setState(() => _mine = mine);
  }

  /// "+" tile: choose between a single edited photo and a bulk import.
  Future<void> _showAddOptions() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: const ValueKey('add-sticker-photo'),
              leading: const Icon(Icons.photo_outlined),
              title: const Text('Photo from gallery'),
              subtitle: const Text('Crop it first'),
              onTap: () => Navigator.pop(ctx, 'photo'),
            ),
            ListTile(
              key: const ValueKey('add-sticker-import'),
              leading: const Icon(Icons.file_download_outlined),
              title: const Text('Import from files'),
              subtitle: const Text(
                  'WebP / PNG / GIF images or a .wastickers / .zip pack'),
              onTap: () => Navigator.pop(ctx, 'import'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (choice == 'photo') await _addFromGallery();
    if (choice == 'import') await _importFromFiles();
  }

  /// Bulk-imports stickers saved from other apps (e.g. WhatsApp sticker images
  /// or a sticker-pack bundle) via the system file picker.
  Future<void> _importFromFiles() async {
    final messenger = ScaffoldMessenger.of(context);
    final importer = ref.read(stickerImporterProvider);
    ref.read(appLockControllerProvider).suppressNextBackgroundLock();
    final picked = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: true,
      type: FileType.any,
    );
    if (picked == null) return;
    final files = <StickerImportFile>[
      for (final f in picked.files)
        if (f.bytes != null)
          StickerImportFile(name: f.name, bytes: Uint8List.fromList(f.bytes!)),
    ];
    final result = await importer.import(files);
    await _reloadMine();
    messenger.showSnackBar(SnackBar(
      content: Text(result.added == 0
          ? "Couldn't find any stickers in that selection."
          : 'Imported ${result.added} sticker${result.added == 1 ? '' : 's'}'
              '${result.skipped > 0 ? ' (${result.skipped} skipped)' : ''}.'),
    ));
  }

  Future<void> _addFromGallery() async {
    final messenger = ScaffoldMessenger.of(context);
    // The gallery is a separate activity — don't re-trip the app lock on return.
    ref.read(appLockControllerProvider).suppressNextBackgroundLock();
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    final mime = picked.mimeType ?? Sticker.file(picked.path).mimeType;
    if (!mounted) return;
    // Crop / rotate first; backing out of the editor adds nothing.
    final edited = await editSticker(context, bytes, mime);
    if (edited == null) return;
    final saved = await _collector.addFromBytes(edited.bytes, edited.mimeType);
    if (saved == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text("Couldn't read that image.")),
      );
      return;
    }
    await _reloadMine();
  }

  Future<void> _confirmRemove(Sticker sticker) async {
    final remove = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove sticker?'),
        content: const Text('It will be deleted from My stickers.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (remove != true) return;
    await _store.remove(sticker);
    await _reloadMine();
  }

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    if (!_loaded) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    return Column(
      children: [
        _packStrip(t),
        Expanded(child: _selected == 0 ? _mineGrid(t) : _packGrid(t)),
      ],
    );
  }

  Widget _packStrip(DesignTokens t) {
    Widget tab(int index, Widget child, String label) {
      final selected = index == _selected;
      return Padding(
        padding: const EdgeInsets.only(right: 6),
        child: Tooltip(
          message: label,
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => setState(() => _selected = index),
            child: Container(
              width: 40,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: selected ? t.surfaceAlt : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
              ),
              child: child,
            ),
          ),
        ),
      );
    }

    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
        children: [
          tab(0, Icon(Icons.star_outline, color: t.textMuted), 'My stickers'),
          for (var i = 0; i < _packs.length; i++)
            tab(
              i + 1,
              StickerThumbnail(sticker: _packs[i].cover, size: 26),
              _packs[i].title,
            ),
        ],
      ),
    );
  }

  /// Lazy grid: a long "My stickers" list only builds (and reads from disk) the
  /// cells that are actually on screen.
  Widget _grid(int count, IndexedWidgetBuilder cell) {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        mainAxisSpacing: 6,
        crossAxisSpacing: 6,
      ),
      itemCount: count,
      itemBuilder: cell,
    );
  }

  Widget _packGrid(DesignTokens t) {
    final stickers = _packs[_selected - 1].stickers;
    return _grid(stickers.length, (context, i) {
      final s = stickers[i];
      return _cell(s, onTap: () => widget.onSelected(s));
    });
  }

  Widget _mineGrid(DesignTokens t) {
    return Column(
      children: [
        Expanded(
          // Cell 0 is the "+" tile; the user's stickers follow.
          child: _grid(_mine.length + 1, (context, i) {
            if (i == 0) {
              return InkWell(
                key: const ValueKey('add-sticker'),
                borderRadius: BorderRadius.circular(10),
                onTap: _showAddOptions,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: t.surfaceAlt,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(Icons.add, color: t.textMuted, size: 28),
                ),
              );
            }
            final s = _mine[i - 1];
            return _cell(
              s,
              onTap: () => widget.onSelected(s),
              onLongPress: () => _confirmRemove(s),
            );
          }),
        ),
        if (_mine.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              'Tap + to add an image, or long-press any photo in a chat and '
              'choose "Add to stickers".',
              textAlign: TextAlign.center,
              style: TextStyle(color: t.textFaint, fontSize: 12),
            ),
          ),
      ],
    );
  }

  Widget _cell(
    Sticker sticker, {
    required VoidCallback onTap,
    VoidCallback? onLongPress,
  }) {
    return InkWell(
      key: ValueKey(sticker.id),
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: StickerThumbnail(sticker: sticker),
      ),
    );
  }
}
