import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/design_tokens.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import '../../app/theme.dart';
import 'file_opener.dart';
import 'media_file_opener.dart';
import 'models/chat_message.dart';
import 'models/message_kind.dart';
import 'models/shared_content.dart';
import 'models/shared_link.dart';
import 'widgets/image_viewer_screen.dart';
import 'widgets/open_link_dialog.dart';
import 'widgets/shared_media_tile.dart';

/// "Media, links and files" for one conversation: everything still stored that
/// was sent in it, filterable by type. GIFs and stickers are not listed.
class SharedMediaScreen extends ConsumerStatefulWidget {
  const SharedMediaScreen({super.key, required this.conversationId});

  final String conversationId;

  @override
  ConsumerState<SharedMediaScreen> createState() => _SharedMediaScreenState();
}

class _SharedMediaScreenState extends ConsumerState<SharedMediaScreen> {
  SharedContent? _content;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final content = await ref
          .read(conversationsProvider)
          .sharedContentFor(widget.conversationId);
      if (mounted) setState(() => _content = content);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    final content = _content;
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        backgroundColor: t.bg,
        appBar: AppBar(
          backgroundColor: t.surface,
          title: const Text('Media, links and files'),
          bottom: TabBar(
            indicatorColor: t.accent,
            labelColor: t.text,
            unselectedLabelColor: t.textMuted,
            tabs: [
              Tab(text: 'Media${_count(content?.media.length)}'),
              Tab(text: 'Links${_count(content?.links.length)}'),
              Tab(text: 'Files${_count(content?.files.length)}'),
            ],
          ),
        ),
        body: _failed
            ? _Empty(t: t, text: "Couldn't load shared content.")
            : content == null
                ? Center(child: CircularProgressIndicator(color: t.accent))
                : TabBarView(
                    children: [
                      _mediaTab(t, content),
                      _linksTab(t, content),
                      _filesTab(t, content),
                    ],
                  ),
      ),
    );
  }

  static String _count(int? n) => n == null || n == 0 ? '' : ' ($n)';

  Widget _mediaTab(DesignTokens t, SharedContent content) {
    if (content.media.isEmpty) {
      return _Empty(t: t, text: 'No photos or videos yet.');
    }
    final notifier = ref.read(conversationsProvider);
    return GridView.builder(
      padding: const EdgeInsets.all(2),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 2,
        crossAxisSpacing: 2,
      ),
      itemCount: content.media.length,
      itemBuilder: (context, i) {
        final m = content.media[i];
        return SharedMediaTile(
          key: ValueKey('media-${m.envelopeId}'),
          message: m,
          notifier: notifier,
          onTap: (bytes) => _openMedia(m, bytes),
        );
      },
    );
  }

  void _openMedia(ChatMessage m, Uint8List? bytes) {
    if (m.kind == MessageKind.video) {
      context.push(Routes.videoPlayer
          .replaceFirst(':conversationId', m.conversationId)
          .replaceFirst(':envelopeId', m.envelopeId));
    } else if (bytes != null) {
      ImageViewerScreen.open(context, bytes);
    }
  }

  Widget _linksTab(DesignTokens t, SharedContent content) {
    if (content.links.isEmpty) return _Empty(t: t, text: 'No links yet.');
    return ListView.separated(
      itemCount: content.links.length,
      separatorBuilder: (_, _) => Divider(height: 1, color: t.border),
      itemBuilder: (context, i) => _linkTile(t, content.links[i]),
    );
  }

  Widget _linkTile(DesignTokens t, SharedLink link) {
    final preview = link.message.linkPreview;
    final showPreviewTitle = preview != null && preview.url == link.url;
    final host = Uri.tryParse(
            link.url.startsWith('www.') ? 'https://${link.url}' : link.url)
        ?.host;
    return ListTile(
      key: ValueKey('link-${link.message.envelopeId}-${link.url}'),
      leading: Icon(Icons.link, color: t.textMuted),
      title: Text(
        showPreviewTitle ? preview.title : (host ?? link.url),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        link.url,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: monoStyle(fontSize: 11, color: t.textMuted),
      ),
      trailing: Text(_date(link.message),
          style: monoStyle(fontSize: 10, color: t.textFaint)),
      onTap: () => confirmAndOpenLink(
        context,
        link.url.startsWith('www.') ? 'https://${link.url}' : link.url,
      ),
    );
  }

  Widget _filesTab(DesignTokens t, SharedContent content) {
    if (content.files.isEmpty) return _Empty(t: t, text: 'No files yet.');
    return ListView.separated(
      itemCount: content.files.length,
      separatorBuilder: (_, _) => Divider(height: 1, color: t.border),
      itemBuilder: (context, i) {
        final m = content.files[i];
        return ListTile(
          key: ValueKey('file-${m.envelopeId}'),
          leading: Icon(Icons.insert_drive_file_outlined, color: t.textMuted),
          title: Text(
            m.mediaFilename ?? 'attachment',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            '${_size(m.mediaSize ?? 0)} · ${_date(m)}',
            style: monoStyle(fontSize: 11, color: t.textMuted),
          ),
          onTap: () => _openFile(m),
        );
      },
    );
  }

  Future<void> _openFile(ChatMessage m) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final bytes = await ref.read(conversationsProvider).mediaBytesFor(m);
      if (bytes == null) {
        messenger.showSnackBar(
          const SnackBar(content: Text('Download failed.')),
        );
        return;
      }
      final result = await MediaFileOpener(opener: OpenFilexFileOpener())
          .writeAndOpen(
        envelopeId: m.envelopeId,
        filename: m.mediaFilename ?? 'attachment',
        bytes: bytes,
      );
      if (!result.success) {
        messenger.showSnackBar(
          SnackBar(content: Text(result.message ?? 'Could not open file.')),
        );
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Download failed: $e')));
    }
  }

  static String _size(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  static String _date(ChatMessage m) {
    final l = m.serverTs.toLocal();
    return '${l.year}-${l.month.toString().padLeft(2, '0')}-'
        '${l.day.toString().padLeft(2, '0')}';
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.t, required this.text});

  final DesignTokens t;
  final String text;

  @override
  Widget build(BuildContext context) => Center(
        child: Text(text, style: monoStyle(fontSize: 13, color: t.textMuted)),
      );
}
