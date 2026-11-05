import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/secure_storage/secure_storage.dart';
import 'package:nanb_chat/features/chat/models/conversation_state_field.dart';
import 'package:nanb_chat/features/chat/models/conversation_state_update.dart';
import 'package:nanb_chat/features/chat/models/field_version.dart';
import 'package:nanb_chat/features/chat/models/message_control.dart';
import 'package:nanb_chat/features/chat/models/state_field_change.dart';
import 'package:nanb_chat/features/chat/services/conversation_settings_service.dart';
import 'package:nanb_chat/features/chat/services/conversation_state_applier.dart';
import 'package:nanb_chat/features/chat/services/conversation_state_store.dart';

import 'state_sync_test_host.dart';

class _Harness {
  _Harness({StateFakeHost? host}) : host = host ?? StateFakeHost(stateConvo()) {
    settings = ConversationSettingsService(
      host: this.host,
      secureStorage: storage,
      mutedKey: 'muted',
      blockedKey: 'blocked',
    );
    store = ConversationStateStore(storage);
    applier = ConversationStateApplier(
      this.host,
      settings: settings,
      store: store,
      deleteMessageLocal: (id, m) async {
        deleted.add(m.envelopeId);
        final c = this.host.convo!;
        this.host.convo = c.copyWith(
            messages: [for (final x in c.messages) if (x != m) x]);
        this.host.db.rows.removeWhere((r) => r.envelopeId == m.envelopeId);
      },
    );
  }

  final StateFakeHost host;
  final storage = SecureStorageInMemory();
  final deleted = <String>[];
  late final ConversationSettingsService settings;
  late final ConversationStateStore store;
  late final ConversationStateApplier applier;

  Future<void> apply(
    Map<ConversationStateField, StateFieldChange> changes, {
    String sender = stateSiblingDevice,
    String conversationId = stateConvoId,
  }) =>
      applier.applyInbound(
        conversationId: conversationId,
        control: MessageControl.conversationState(
            ConversationStateUpdate(changes)),
        senderDeviceId: sender,
        myDeviceId: stateMyDevice,
      );
}

StateFieldChange _flag(bool v, [int ts = 100, String dev = stateSiblingDevice]) =>
    StateFieldChange.flag(v, FieldVersion(ts, dev));

StateFieldChange _num(int v, [int ts = 100, String dev = stateSiblingDevice]) =>
    StateFieldChange.number(v, FieldVersion(ts, dev));

void main() {
  test('muted is applied to the conversation', () async {
    final h = _Harness();

    await h.apply({ConversationStateField.muted: _flag(true)});

    expect(h.host.convo!.muted, isTrue);
  });

  test('muted also refreshes the background-isolate mirror', () async {
    final h = _Harness();

    await h.apply({ConversationStateField.muted: _flag(true)});

    expect(jsonDecode((await h.storage.getString('muted'))!), [stateConvoId]);
  });

  test('blocked also refreshes the background-isolate mirror', () async {
    final h = _Harness();

    await h.apply({ConversationStateField.blocked: _flag(true)});

    expect(jsonDecode((await h.storage.getString('blocked'))!), [stateConvoId]);
  });

  test('pinned is applied', () async {
    final h = _Harness();

    await h.apply({ConversationStateField.pinned: _flag(true)});

    expect(h.host.convo!.pinned, isTrue);
  });

  test('archived is applied', () async {
    final h = _Harness();

    await h.apply({ConversationStateField.archived: _flag(true)});

    expect(h.host.convo!.archived, isTrue);
  });

  test('verified is applied', () async {
    final h = _Harness();

    await h.apply({ConversationStateField.verified: _flag(true)});

    expect(h.host.convo!.verified, isTrue);
  });

  test('disappearingTtl is applied', () async {
    final h = _Harness();

    await h.apply({ConversationStateField.disappearingTtl: _num(3600)});

    expect(h.host.convo!.disappearingTtl, 3600);
  });

  test('an invalid disappearingTtl is ignored', () async {
    final h = _Harness();

    await h.apply({ConversationStateField.disappearingTtl: _num(0)});

    expect(h.host.convo!.disappearingTtl, -1);
  });

  test('a preset background is stored as the override', () async {
    final h = _Harness();

    await h.apply({
      ConversationStateField.background: StateFieldChange.text(
          'ocean', const FieldVersion(100, stateSiblingDevice)),
    });

    expect(h.store.backgroundOf(stateConvoId).syncWire, 'ocean');
  });

  test('a "default" background clears the override', () async {
    final h = _Harness();
    await h.apply({
      ConversationStateField.background: StateFieldChange.text(
          'ocean', const FieldVersion(100, stateSiblingDevice)),
    });

    await h.apply({
      ConversationStateField.background: StateFieldChange.text(
          'default', const FieldVersion(200, stateSiblingDevice)),
    });

    expect(h.store.backgroundOf(stateConvoId).isDefault, isTrue);
  });

  test('a synced "custom" background is ignored', () async {
    final h = _Harness();

    await h.apply({
      ConversationStateField.background: StateFieldChange.text(
          'custom', const FieldVersion(100, stateSiblingDevice)),
    });

    expect(h.store.backgroundOf(stateConvoId).isDefault, isTrue);
  });

  test('a peer device cannot change our state', () async {
    final h = _Harness();

    await h.apply({ConversationStateField.muted: _flag(true)},
        sender: statePeerDevice);

    expect(h.host.convo!.muted, isFalse);
  });

  test('an unknown conversation is ignored', () async {
    final h = _Harness();

    await h.apply({ConversationStateField.muted: _flag(true)},
        conversationId: 'other');

    expect(h.host.convo!.muted, isFalse);
  });

  test('applying never sends anything', () async {
    final h = _Harness();

    await h.apply({
      ConversationStateField.muted: _flag(true),
      ConversationStateField.pinned: _flag(true),
    });

    expect(h.host.selfControls, isEmpty);
  });

  test('an older version does not overwrite a newer one', () async {
    final h = _Harness();
    await h.apply({ConversationStateField.muted: _flag(true, 200)});

    await h.apply({ConversationStateField.muted: _flag(false, 100)});

    expect(h.host.convo!.muted, isTrue);
  });

  test('a newer version overwrites an older one', () async {
    final h = _Harness();
    await h.apply({ConversationStateField.muted: _flag(true, 100)});

    await h.apply({ConversationStateField.muted: _flag(false, 200)});

    expect(h.host.convo!.muted, isFalse);
  });

  test('equal timestamps resolve by device id, the same on any arrival order',
      () async {
    final a = _Harness();
    await a.apply({ConversationStateField.muted: _flag(true, 100, 'dev-a')});
    await a.apply({ConversationStateField.muted: _flag(false, 100, 'dev-b')});
    final b = _Harness();
    await b.apply({ConversationStateField.muted: _flag(false, 100, 'dev-b')});
    await b.apply({ConversationStateField.muted: _flag(true, 100, 'dev-a')});

    expect(a.host.convo!.muted, b.host.convo!.muted);
  });

  test('versions are per field: a stale muted does not block a fresh pinned',
      () async {
    final h = _Harness();
    await h.apply({ConversationStateField.muted: _flag(true, 500)});

    await h.apply({
      ConversationStateField.muted: _flag(false, 100),
      ConversationStateField.pinned: _flag(true, 100),
    });

    expect(h.host.convo!.pinned, isTrue);
  });

  test('an applied version is persisted for later comparisons', () async {
    final h = _Harness();

    await h.apply({ConversationStateField.muted: _flag(true, 321)});

    expect(h.store.versionOf(stateConvoId, ConversationStateField.muted),
        const FieldVersion(321, stateSiblingDevice));
  });

  group('readUpToMs', () {
    test('clears unread when everything is at or before the position',
        () async {
      final h = _Harness(
          host: StateFakeHost(stateConvo(
              messages: [stateMsg('a', 10), stateMsg('b', 20)], unread: 2)));

      await h.apply({ConversationStateField.readUpToMs: _num(20)});

      expect(h.host.convo!.unreadCount, 0);
    });

    test('keeps unread for messages newer than the position', () async {
      final h = _Harness(
          host: StateFakeHost(stateConvo(messages: [
        stateMsg('a', 10),
        stateMsg('b', 20),
        stateMsg('c', 30),
      ], unread: 3)));

      await h.apply({ConversationStateField.readUpToMs: _num(20)});

      expect(h.host.convo!.unreadCount, 1);
    });

    test('never increases the unread count', () async {
      final h = _Harness(
          host: StateFakeHost(stateConvo(messages: [
        stateMsg('a', 10),
        stateMsg('b', 20),
        stateMsg('c', 30),
      ], unread: 1)));

      await h.apply({ConversationStateField.readUpToMs: _num(5)});

      expect(h.host.convo!.unreadCount, 1);
    });

    test('our own messages never count as unread', () async {
      final h = _Harness(
          host: StateFakeHost(stateConvo(
              messages: [stateMsg('a', 10), stateMsg('m', 30, mine: true)],
              unread: 1)));

      await h.apply({ConversationStateField.readUpToMs: _num(10)});

      expect(h.host.convo!.unreadCount, 0);
    });

    test('the stored position never moves backwards', () async {
      final h = _Harness();
      await h.apply({ConversationStateField.readUpToMs: _num(500, 100)});

      await h.apply({ConversationStateField.readUpToMs: _num(300, 200)});

      expect(h.store.watermarkOf(stateConvoId, ConversationStateField.readUpToMs),
          500);
    });
  });

  group('clearedAtMs', () {
    test('deletes in-memory messages at or before the watermark', () async {
      final h = _Harness(
          host: StateFakeHost(
              stateConvo(messages: [stateMsg('a', 10), stateMsg('b', 20)])));

      await h.apply({ConversationStateField.clearedAtMs: _num(10)});

      expect(h.deleted, ['a']);
    });

    test('keeps messages newer than the watermark', () async {
      final h = _Harness(
          host: StateFakeHost(
              stateConvo(messages: [stateMsg('a', 10), stateMsg('b', 20)])));

      await h.apply({ConversationStateField.clearedAtMs: _num(10)});

      expect(h.host.convo!.messages.map((m) => m.envelopeId), ['b']);
    });

    test('also deletes older rows that are only on disk', () async {
      final host = StateFakeHost(stateConvo(messages: [stateMsg('c', 30)]));
      host.db.rows.addAll([stateMsg('old1', 1), stateMsg('old2', 2)]);
      final h = _Harness(host: host);

      await h.apply({ConversationStateField.clearedAtMs: _num(10)});

      expect(h.deleted.toSet(), {'old1', 'old2'});
    });

    test('does not broadcast', () async {
      final h = _Harness(
          host: StateFakeHost(stateConvo(messages: [stateMsg('a', 10)])));

      await h.apply({ConversationStateField.clearedAtMs: _num(10)});

      expect(h.host.selfControls, isEmpty);
    });

    test('resets the unread count when everything unread was cleared',
        () async {
      final h = _Harness(
          host: StateFakeHost(
              stateConvo(messages: [stateMsg('a', 10)], unread: 1)));

      await h.apply({ConversationStateField.clearedAtMs: _num(10)});

      expect(h.host.convo!.unreadCount, 0);
    });
  });
}
