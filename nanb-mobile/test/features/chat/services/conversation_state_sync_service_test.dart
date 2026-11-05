import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/secure_storage/secure_storage.dart';
import 'package:nanb_chat/features/chat/models/chat_background_override.dart';
import 'package:nanb_chat/features/chat/models/conversation_state_field.dart';
import 'package:nanb_chat/features/chat/models/field_version.dart';
import 'package:nanb_chat/features/chat/models/message_control.dart';
import 'package:nanb_chat/features/chat/services/conversation_settings_service.dart';
import 'package:nanb_chat/features/chat/services/conversation_state_store.dart';
import 'package:nanb_chat/features/chat/services/conversation_state_sync_service.dart';
import 'package:nanb_chat/features/settings/models/chat_background.dart';

import 'state_sync_test_host.dart';

class _Harness {
  _Harness({StateFakeHost? host, int nowMs = 1000})
      : host = host ?? StateFakeHost(stateConvo()),
        _nowMs = nowMs {
    store = ConversationStateStore(storage);
    service = ConversationStateSyncService(
      this.host,
      settings: ConversationSettingsService(
        host: this.host,
        secureStorage: storage,
        mutedKey: 'muted',
        blockedKey: 'blocked',
      ),
      store: store,
      now: () => DateTime.fromMillisecondsSinceEpoch(_nowMs, isUtc: true),
      readDebounce: const Duration(milliseconds: 30),
    );
  }

  final StateFakeHost host;
  final storage = SecureStorageInMemory();
  late final ConversationStateStore store;
  late final ConversationStateSyncService service;
  int _nowMs;

  void setNow(int ms) => _nowMs = ms;

  /// The self-sync controls decoded.
  List<MessageControl> get sent => [
        for (final b in host.selfControls) MessageControl.tryDecode(b)!,
      ];

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 80));
}

void main() {
  test('muting changes the conversation', () async {
    final h = _Harness();

    await h.service.setMuted(stateConvoId, true);

    expect(h.host.convo!.muted, isTrue);
  });

  test('muting sends one sparse control with only the muted field', () async {
    final h = _Harness();

    await h.service.setMuted(stateConvoId, true);

    expect(h.sent.single.stateUpdate!.changes.keys,
        [ConversationStateField.muted]);
  });

  test('the control carries this device id and the current time', () async {
    final h = _Harness(nowMs: 4242);

    await h.service.setMuted(stateConvoId, true);

    expect(
        h.sent.single.stateUpdate!.changes[ConversationStateField.muted]!
            .version,
        const FieldVersion(4242, stateMyDevice));
  });

  test('a no-op change sends nothing', () async {
    final h = _Harness();

    await h.service.setMuted(stateConvoId, false);

    expect(h.host.selfControls, isEmpty);
  });

  test('a repeated identical change sends only once', () async {
    final h = _Harness();

    await h.service.setMuted(stateConvoId, true);
    await h.service.setMuted(stateConvoId, true);

    expect(h.host.selfControls.length, 1);
  });

  test('pin is sent', () async {
    final h = _Harness();

    await h.service.setPinned(stateConvoId, true);

    expect(h.sent.single.stateUpdate!.changes.keys,
        [ConversationStateField.pinned]);
  });

  test('archive is sent', () async {
    final h = _Harness();

    await h.service.setArchived(stateConvoId, true);

    expect(h.sent.single.stateUpdate!.changes.keys,
        [ConversationStateField.archived]);
  });

  test('block is sent', () async {
    final h = _Harness();

    await h.service.setBlocked(stateConvoId, true);

    expect(h.sent.single.stateUpdate!.changes.keys,
        [ConversationStateField.blocked]);
  });

  test('verified is sent', () async {
    final h = _Harness();

    await h.service.setVerified(stateConvoId, true);

    expect(h.sent.single.stateUpdate!.changes.keys,
        [ConversationStateField.verified]);
  });

  test('the disappearing timer is sent as seconds', () async {
    final h = _Harness();

    await h.service.setDisappearingTtl(stateConvoId, 3600);

    expect(
        h.sent.single.stateUpdate!
            .changes[ConversationStateField.disappearingTtl]!.number,
        3600);
  });

  test('resetting the timer to default is sent as -1', () async {
    final h = _Harness();
    await h.service.setDisappearingTtl(stateConvoId, 3600);

    await h.service.setDisappearingTtl(stateConvoId, -1);

    expect(
        h.sent.last.stateUpdate!
            .changes[ConversationStateField.disappearingTtl]!.number,
        -1);
  });

  test('a send failure does not undo the local change', () async {
    final h = _Harness();
    h.host.selfSendThrows = true;

    await h.service.setMuted(stateConvoId, true);
    await h.settle();

    expect(h.host.convo!.muted, isTrue);
  });

  test('a later local edit outranks a version applied from a sibling',
      () async {
    final h = _Harness(nowMs: 100);
    await h.store
        .recordVersion(stateConvoId, ConversationStateField.muted,
            const FieldVersion(5000, 'dev-zzz'));

    await h.service.setMuted(stateConvoId, true);

    expect(
        h.sent.single.stateUpdate!.changes[ConversationStateField.muted]!
            .version.timestampMs,
        5001);
  });

  group('background override', () {
    test('a preset is stored locally', () async {
      final h = _Harness();

      await h.service.setBackgroundOverride(stateConvoId,
          const ChatBackgroundOverride.preset(ChatBackground.ocean));

      expect(h.service.backgroundOverrideOf(stateConvoId).preset,
          ChatBackground.ocean);
    });

    test('a preset is synced as its name', () async {
      final h = _Harness();

      await h.service.setBackgroundOverride(stateConvoId,
          const ChatBackgroundOverride.preset(ChatBackground.ocean));

      expect(
          h.sent.single.stateUpdate!
              .changes[ConversationStateField.background]!.text,
          'ocean');
    });

    test('resetting to default is synced as "default"', () async {
      final h = _Harness();
      await h.service.setBackgroundOverride(stateConvoId,
          const ChatBackgroundOverride.preset(ChatBackground.ocean));

      await h.service.setBackgroundOverride(
          stateConvoId, const ChatBackgroundOverride.useDefault());

      expect(
          h.sent.last.stateUpdate!
              .changes[ConversationStateField.background]!.text,
          'default');
    });

    test('a custom photo is stored locally', () async {
      final h = _Harness();

      await h.service.setBackgroundOverride(
          stateConvoId, const ChatBackgroundOverride.photo('/p.jpg'));

      expect(h.service.backgroundOverrideOf(stateConvoId).photoPath, '/p.jpg');
    });

    test('a custom photo is never synced', () async {
      final h = _Harness();

      await h.service.setBackgroundOverride(
          stateConvoId, const ChatBackgroundOverride.photo('/p.jpg'));

      expect(h.host.selfControls, isEmpty);
    });

    test('re-selecting the same override sends nothing more', () async {
      final h = _Harness();
      const o = ChatBackgroundOverride.preset(ChatBackground.ocean);
      await h.service.setBackgroundOverride(stateConvoId, o);

      await h.service.setBackgroundOverride(stateConvoId, o);

      expect(h.host.selfControls.length, 1);
    });
  });

  group('read position', () {
    Future<_Harness> withMessages(List<int> ts) async {
      final h = _Harness(
          host: StateFakeHost(stateConvo(
              messages: [for (var i = 0; i < ts.length; i++) stateMsg('m$i', ts[i])])));
      return h;
    }

    test('advancing sends the newest incoming serverTs after the debounce',
        () async {
      final h = await withMessages([10, 20]);

      await h.service.noteRead(stateConvoId);
      await h.settle();

      expect(
          h.sent.single.stateUpdate!
              .changes[ConversationStateField.readUpToMs]!.number,
          20);
    });

    test('nothing is sent before the debounce elapses', () async {
      final h = await withMessages([10]);

      await h.service.noteRead(stateConvoId);

      expect(h.host.selfControls, isEmpty);
      await h.settle();
    });

    test('rapid advances coalesce into one send', () async {
      final h = await withMessages([10]);
      await h.service.noteRead(stateConvoId);
      h.host.convo = h.host.convo!.copyWith(
          messages: [...h.host.convo!.messages, stateMsg('x', 20)]);
      await h.service.noteRead(stateConvoId);
      await h.settle();

      expect(h.host.selfControls.length, 1);
    });

    test('the coalesced send carries the latest position', () async {
      final h = await withMessages([10]);
      await h.service.noteRead(stateConvoId);
      h.host.convo = h.host.convo!.copyWith(
          messages: [...h.host.convo!.messages, stateMsg('x', 20)]);
      await h.service.noteRead(stateConvoId);
      await h.settle();

      expect(
          h.sent.single.stateUpdate!
              .changes[ConversationStateField.readUpToMs]!.number,
          20);
    });

    test('an unchanged position sends nothing', () async {
      final h = await withMessages([10]);
      await h.service.noteRead(stateConvoId);
      await h.settle();

      await h.service.noteRead(stateConvoId);
      await h.settle();

      expect(h.host.selfControls.length, 1);
    });

    test('our own messages do not advance the position', () async {
      final h = _Harness(
          host: StateFakeHost(
              stateConvo(messages: [stateMsg('m', 99, mine: true)])));

      await h.service.noteRead(stateConvoId);
      await h.settle();

      expect(h.host.selfControls, isEmpty);
    });
  });

  group('clear history', () {
    test('sends the watermark immediately', () async {
      final h = _Harness();

      await h.service.noteCleared(stateConvoId, 555);

      expect(
          h.sent.single.stateUpdate!
              .changes[ConversationStateField.clearedAtMs]!.number,
          555);
    });

    test('a watermark that did not advance is not re-sent', () async {
      final h = _Harness();
      await h.service.noteCleared(stateConvoId, 555);

      await h.service.noteCleared(stateConvoId, 555);

      expect(h.host.selfControls.length, 1);
    });

    test('newestMessageMs is the newest serverTs', () {
      final h = _Harness();

      expect(
          h.service.newestMessageMs(
              stateConvo(messages: [stateMsg('a', 5), stateMsg('b', 9)])),
          9);
    });
  });

  group('full state (bootstrap)', () {
    test('a conversation at defaults sends nothing', () async {
      final h = _Harness();

      await h.service.sendFullState(stateConvoId);

      expect(h.host.selfControls, isEmpty);
    });

    test('only fields that differ from defaults are included', () async {
      final h = _Harness(
          host: StateFakeHost(
              stateConvo().copyWith(muted: true, disappearingTtl: 60)));

      await h.service.sendFullState(stateConvoId);

      expect(h.sent.single.stateUpdate!.changes.keys.toSet(), {
        ConversationStateField.muted,
        ConversationStateField.disappearingTtl,
      });
    });

    test('uses the stored version of a field', () async {
      final h = _Harness(
          host: StateFakeHost(stateConvo().copyWith(pinned: true)));
      await h.store.recordVersion(stateConvoId, ConversationStateField.pinned,
          const FieldVersion(77, 'dev-old'));

      await h.service.sendFullState(stateConvoId);

      expect(
          h.sent.single.stateUpdate!.changes[ConversationStateField.pinned]!
              .version,
          const FieldVersion(77, 'dev-old'));
    });

    test('includes the background preset and the watermarks', () async {
      final h = _Harness();
      await h.service.setBackgroundOverride(stateConvoId,
          const ChatBackgroundOverride.preset(ChatBackground.fern));
      await h.service.noteCleared(stateConvoId, 40);
      h.host.selfControls.clear();

      await h.service.sendFullState(stateConvoId);

      expect(h.sent.single.stateUpdate!.changes.keys.toSet(), {
        ConversationStateField.background,
        ConversationStateField.clearedAtMs,
      });
    });

    test('a device-local photo background is not included', () async {
      final h = _Harness();
      await h.service.setBackgroundOverride(
          stateConvoId, const ChatBackgroundOverride.photo('/p.jpg'));

      await h.service.sendFullState(stateConvoId);

      expect(h.host.selfControls, isEmpty);
    });

    test('a failing send surfaces to the caller', () async {
      final h = _Harness(
          host: StateFakeHost(stateConvo().copyWith(muted: true)));
      h.host.selfSendThrows = true;

      expect(h.service.sendFullState(stateConvoId), throwsStateError);
    });

    test('the wire body is valid conversation_state JSON', () async {
      final h = _Harness(
          host: StateFakeHost(stateConvo().copyWith(muted: true)));

      await h.service.sendFullState(stateConvoId);

      expect(jsonDecode(h.host.selfControls.single)['_control'],
          'conversation_state');
    });
  });
}
