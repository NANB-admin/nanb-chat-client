import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/secure_storage/secure_storage.dart';
import 'package:nanb_chat/features/calls/caller_name_resolver.dart';
import 'package:nanb_chat/features/chat/conversations_notifier.dart';

void main() {
  late SecureStorageInMemory storage;

  setUp(() => storage = SecureStorageInMemory());

  Future<void> mirror(Map<String, String> names) => storage.putString(
      ConversationsNotifier.callPeerNamesKey, jsonEncode(names));

  test('prefers the live conversation name', () async {
    await mirror({'1to1:a': 'mirrored'});
    final r = CallerNameResolver(liveName: (_) => 'live', storage: storage);

    expect(await r.resolve('1to1:a'), 'live');
  });

  test('falls back to the mirror before the store is hydrated', () async {
    await mirror({'1to1:a': 'qa-s21'});
    final r = CallerNameResolver(liveName: (_) => null, storage: storage);

    expect(await r.resolve('1to1:a'), 'qa-s21');
  });

  test('returns empty when neither source knows the caller', () async {
    final r = CallerNameResolver(liveName: (_) => null, storage: storage);

    expect(await r.resolve('1to1:a'), '');
  });

  test('an unreadable mirror yields empty instead of throwing', () async {
    await storage.putString(ConversationsNotifier.callPeerNamesKey, 'not json');
    final r = CallerNameResolver(liveName: (_) => '', storage: storage);

    expect(await r.resolve('1to1:a'), '');
  });
}
