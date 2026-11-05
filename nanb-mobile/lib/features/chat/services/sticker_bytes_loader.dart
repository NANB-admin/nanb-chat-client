import 'dart:io';

import 'package:flutter/services.dart';

import '../models/sticker.dart';

/// Reads a sticker's encoded image bytes, from the asset bundle (bundled
/// stickers) or from disk (user-made ones).
Future<List<int>> loadStickerBytes(Sticker sticker) async {
  final asset = sticker.assetPath;
  if (asset != null) {
    final data = await rootBundle.load(asset);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }
  return File(sticker.filePath!).readAsBytes();
}
