import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../media_pipeline.dart';
import 'avatar_viewer_screen.dart';
import 'nanb_avatar.dart';

/// Circular avatar that renders an encrypted profile image when a [descriptor]
/// is present, falling back to [NanbAvatar]'s deterministic initials while
/// loading, on failure, or when no avatar is set.
class AvatarImage extends ConsumerStatefulWidget {
  const AvatarImage({
    super.key,
    required this.name,
    this.descriptor,
    this.size = 40,
    this.enlargeOnTap = false,
  });

  final String name;
  final MediaDescriptor? descriptor;
  final double size;

  /// When true, tapping the (loaded) photo opens a larger, view-only preview.
  final bool enlargeOnTap;

  @override
  ConsumerState<AvatarImage> createState() => _AvatarImageState();
}

class _AvatarImageState extends ConsumerState<AvatarImage> {
  Uint8List? _bytes;
  ui.Size? _sourceSize;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(AvatarImage old) {
    super.didUpdateWidget(old);
    if (widget.descriptor?.mediaId != old.descriptor?.mediaId) {
      _bytes = null;
      _sourceSize = null;
      _load();
    }
  }

  Future<void> _load() async {
    final d = widget.descriptor;
    if (d == null) return;
    final loader = ref.read(avatarLoaderProvider);
    final cached = loader.cached(d.mediaId);
    if (cached != null) {
      _bytes = cached;
      unawaited(_readSourceSize(cached));
      return;
    }
    final bytes = await loader.load(d);
    if (!mounted) return;
    setState(() => _bytes = bytes);
    if (bytes != null) unawaited(_readSourceSize(bytes));
  }

  /// Reads the source's pixel size from its header (no full decode) so the
  /// cache-resize below can keep the aspect ratio.
  Future<void> _readSourceSize(Uint8List bytes) async {
    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      final size = ui.Size(
        descriptor.width.toDouble(),
        descriptor.height.toDouble(),
      );
      descriptor.dispose();
      buffer.dispose();
      if (!mounted) return;
      setState(() => _sourceSize = size);
    } catch (_) {
      // Undecodable header: stay on the aspect-safe fallback in build().
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes == null) {
      return NanbAvatar(name: widget.name, size: widget.size);
    }
    // Decode at roughly on-screen pixel size rather than the source's native
    // resolution. Only ONE cache dimension may be set: giving both a square
    // value squashes a non-square photo to a square at decode time, and
    // BoxFit.cover then can't undo it (the distorted-avatar bug). We resize the
    // SHORTER side to the target so cover still fills the circle sharply.
    final target = (widget.size * MediaQuery.of(context).devicePixelRatio).round();
    final src = _sourceSize;
    int? cacheW;
    int? cacheH;
    if (target > 0 && src != null) {
      if (src.width <= src.height) {
        cacheW = target;
      } else {
        cacheH = target;
      }
    }
    final image = ClipOval(
      child: Image.memory(
        bytes,
        width: widget.size,
        height: widget.size,
        fit: BoxFit.cover,
        cacheWidth: cacheW,
        cacheHeight: cacheH,
        gaplessPlayback: true,
      ),
    );
    if (!widget.enlargeOnTap) return image;
    return GestureDetector(
      onTap: () => AvatarViewerScreen.open(context, bytes),
      child: image,
    );
  }
}
