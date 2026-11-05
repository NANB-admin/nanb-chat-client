import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/chat/models/system_event.dart';

void main() {
  group('SystemEvent', () {
    test('encodes member_joined into a JSON string with all required keys', () {
      final json = SystemEvent.memberJoined(
        accountId: 'acc-1',
        username: '@lin-w',
        epoch: 13,
      ).toJsonString();
      expect(json, contains('"_system":"member_joined"'));
      expect(json, contains('"account_id":"acc-1"'));
      expect(json, contains('"username":"@lin-w"'));
      expect(json, contains('"epoch":13'));
    });

    test('decode resolves member_removed and exposes typed fields', () {
      const raw = '{"_system":"member_removed","account_id":"a","username":"@k","epoch":14,"by":"@ada"}';
      final ev = SystemEvent.tryDecode(raw)!;
      expect(ev.kind, SystemEventKind.memberRemoved);
      expect(ev.username, '@k');
      expect(ev.by, '@ada');
      expect(ev.epoch, 14);
    });

    test('tryDecode returns null on non-JSON', () {
      expect(SystemEvent.tryDecode('hi there'), isNull);
    });

    test('tryDecode returns null on JSON without _system key', () {
      expect(SystemEvent.tryDecode('{"foo":"bar"}'), isNull);
    });

    test('tryDecode returns null on unknown _system value', () {
      const raw = '{"_system":"alien_event"}';
      expect(SystemEvent.tryDecode(raw), isNull);
    });

    test('displayText for member_joined renders human-readable line', () {
      final ev = SystemEvent.memberJoined(
        accountId: 'a',
        username: '@lin',
        epoch: 1,
      );
      expect(ev.displayText, '@lin joined the group');
    });

    test('displayText for group_renamed includes both names', () {
      final ev = SystemEvent.groupRenamed(
        from: 'Old',
        to: 'New',
        epoch: 1,
        by: '@ada',
      );
      expect(ev.displayText, '@ada renamed the group · "Old" → "New"');
    });

    test('displayText for member_removed names both actor and target', () {
      final ev = SystemEvent.memberRemoved(
        accountId: 'a',
        username: '@k',
        epoch: 5,
        by: '@ada',
      );
      expect(ev.displayText, '@ada removed @k');
    });

    test('displayText for identity_key_changed names the peer', () {
      final ev = SystemEvent.identityKeyChanged(
        username: '@bob',
        at: DateTime.utc(2026, 5, 16, 12, 34, 56),
      );
      expect(
        ev.displayText,
        '@bob has a new identity key — verify before continuing',
      );
    });

    test('displayText for you_were_removed names the actor', () {
      final ev = SystemEvent.youWereRemoved(by: '@ada');
      expect(ev.displayText, 'You were removed by @ada');
    });

    test('group_info round-trips name + roster (incl. base64 byte keys)', () {
      final original = SystemEvent.groupInfo(
        groupName: 'the crew',
        epoch: 3,
        members: const [
          GroupInfoMember(
            accountId: 'acc-cara',
            username: '@cara1',
            deviceId: 'dev-cara',
            identityPubKey: [1, 2, 3, 250],
            x25519PubKey: [9, 8, 7],
            isAdmin: true,
          ),
          GroupInfoMember(
            accountId: 'acc-ada',
            username: '@ada8',
            deviceId: 'dev-ada',
            identityPubKey: [4, 5, 6],
            x25519PubKey: [0, 255, 128],
            isAdmin: false,
          ),
        ],
      );

      final decoded = SystemEvent.tryDecode(original.toJsonString())!;
      expect(decoded.kind, SystemEventKind.groupInfo);
      expect(decoded.groupName, 'the crew');
      expect(decoded.epoch, 3);
      expect(decoded.members, hasLength(2));
      final cara = decoded.members!.first;
      expect(cara.username, '@cara1');
      expect(cara.deviceId, 'dev-cara');
      expect(cara.identityPubKey, [1, 2, 3, 250]);
      expect(cara.x25519PubKey, [9, 8, 7]);
      expect(cara.isAdmin, isTrue);
      expect(decoded.members![1].isAdmin, isFalse);
    });

    test('tryDecode returns null when typed field has wrong type', () {
      const raw =
          '{"_system":"member_joined","account_id":"a","username":"@k","epoch":"thirteen"}';
      expect(SystemEvent.tryDecode(raw), isNull);
    });

    test('call event round-trips and renders a duration', () {
      final ev = SystemEvent.call(
        outgoing: true,
        outcome: 'completed',
        durationSeconds: 272,
        at: DateTime.utc(2026, 6, 14, 12),
      );
      final decoded = SystemEvent.tryDecode(ev.toJsonString())!;
      expect(decoded.kind, SystemEventKind.call);
      expect(decoded.callOutgoing, isTrue);
      expect(decoded.callOutcome, 'completed');
      expect(decoded.callDurationSeconds, 272);
      expect(decoded.displayText, 'Outgoing call · 4:32');
    });

    test('call displayText covers each outcome', () {
      String text(bool outgoing, String outcome, [int? dur]) =>
          SystemEvent.call(
            outgoing: outgoing,
            outcome: outcome,
            durationSeconds: dur,
            at: DateTime.utc(2026),
          ).displayText;

      expect(text(false, 'completed', 5), 'Incoming call · 0:05');
      expect(text(false, 'missed'), 'Missed call');
      expect(text(true, 'declined'), 'Call declined');
      expect(text(true, 'failed'), 'Call failed');
      expect(text(true, 'cancelled'), 'Cancelled call');
      expect(text(false, 'cancelled'), 'Missed call');
    });

    test('video call event round-trips + labels as "video call"', () {
      final ev = SystemEvent.call(
        outgoing: true,
        outcome: 'completed',
        durationSeconds: 272,
        video: true,
        at: DateTime.utc(2026, 6, 14, 12),
      );
      final decoded = SystemEvent.tryDecode(ev.toJsonString())!;
      expect(decoded.callVideo, isTrue);
      expect(decoded.displayText, 'Outgoing video call · 4:32');
    });

    test('video call displayText covers each outcome', () {
      String text(bool outgoing, String outcome, [int? dur]) =>
          SystemEvent.call(
            outgoing: outgoing,
            outcome: outcome,
            durationSeconds: dur,
            video: true,
            at: DateTime.utc(2026),
          ).displayText;

      expect(text(false, 'completed', 5), 'Incoming video call · 0:05');
      expect(text(false, 'missed'), 'Missed video call');
      expect(text(true, 'declined'), 'Video call declined');
      expect(text(true, 'failed'), 'Video call failed');
      expect(text(true, 'cancelled'), 'Cancelled video call');
      expect(text(false, 'cancelled'), 'Missed video call');
    });

    test('screenshot_taken round-trips and names the screenshotter', () {
      final ev = SystemEvent.screenshotTaken(
        username: '@bob',
        at: DateTime.utc(2026, 6, 28, 9, 0, 0),
      );
      final decoded = SystemEvent.tryDecode(ev.toJsonString())!;
      expect(decoded.kind, SystemEventKind.screenshotTaken);
      expect(decoded.username, '@bob');
      expect(decoded.displayText, '@bob took a screenshot');
    });

    test('screenshot_taken byYou round-trips and renders "You took a screenshot"',
        () {
      final ev = SystemEvent.screenshotTaken(
        byYou: true,
        at: DateTime.utc(2026, 6, 28, 9, 0, 0),
      );
      final decoded = SystemEvent.tryDecode(ev.toJsonString())!;
      expect(decoded.kind, SystemEventKind.screenshotTaken);
      expect(decoded.byYou, isTrue);
      expect(decoded.displayText, 'You took a screenshot');
    });

    test('a legacy call log with no video flag reads as audio', () {
      // Pre-feature entries have no c_vid key → callVideo null → "call".
      final decoded = SystemEvent.tryDecode(
        '{"_system":"call","c_out":true,"c_res":"completed","c_dur":60}',
      )!;
      expect(decoded.callVideo, isNull);
      expect(decoded.displayText, 'Outgoing call · 1:00');
    });
  });
}
