import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/models/account.dart';
import 'package:nanb_chat/core/models/api_error.dart';
import 'package:nanb_chat/core/models/device.dart';
import 'package:nanb_chat/core/models/envelope.dart';
import 'package:nanb_chat/core/models/jwt_session.dart';
import 'package:nanb_chat/features/chat/models/chat_message.dart';
import 'package:nanb_chat/features/chat/models/message_kind.dart';

void main() {
  group('Account', () {
    test('JSON round-trip preserves all fields', () {
      const a = Account(
        accountId: 'acc-1',
        username: 'nass',
        identityPubKey: [1, 2, 3, 4],
        x25519PubKey: [9, 8, 7, 6],
        displayName: 'Nass',
        avatarUrl: 'https://example.com/a.png',
      );
      final round = Account.fromJson(a.toJson());
      expect(round, equals(a));
    });

    test('omits x25519_pub_key from JSON when empty (legacy account)', () {
      const a = Account(
        accountId: 'acc-1',
        username: 'nass',
        identityPubKey: [1, 2, 3, 4],
      );
      final json = a.toJson();
      expect(json.containsKey('x25519_pub_key'), isFalse);
      // round-trip preserves the empty default.
      expect(Account.fromJson(json).x25519PubKey, isEmpty);
    });
  });

  group('ChatMessage media fields', () {
    ChatMessage build({MessageKind kind = MessageKind.text}) {
      return ChatMessage(
        envelopeId: 'env-1',
        conversationId: 'c',
        senderDeviceId: 'dev',
        body: 'hi',
        serverTs: DateTime.utc(2026, 5, 9),
        mine: true,
        outboxId: '',
        kind: kind,
        mediaId: kind == MessageKind.text ? null : 'mid',
        mediaKey: kind == MessageKind.text ? null : const [1, 2],
        mediaSha256: kind == MessageKind.text ? null : const [3, 4],
        mediaSize: kind == MessageKind.text ? null : 100,
        mediaMime: kind == MessageKind.text ? null : 'image/png',
      );
    }

    test('copyWith preserves media fields when not overridden', () {
      final original = build(kind: MessageKind.image);
      final copy = original.copyWith(body: 'updated');
      expect(copy.body, equals('updated'));
      expect(copy.kind, equals(MessageKind.image));
      expect(copy.mediaId, equals(original.mediaId));
      expect(copy.mediaSize, equals(original.mediaSize));
    });

    test('equality + hashCode include media fields', () {
      final a = build(kind: MessageKind.image);
      final b = build(kind: MessageKind.image);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));

      final differentKind = build();
      expect(a, isNot(equals(differentKind)));
    });

    test('text and image messages with same scalar fields are not equal', () {
      final txt = build();
      final img = build(kind: MessageKind.image);
      expect(txt, isNot(equals(img)));
    });

    test('hashCode is stable for null vs non-null media fields', () {
      final txt = build();
      final txt2 = build();
      expect(txt.hashCode, equals(txt2.hashCode));
    });
  });

  group('MessageKind.fromName', () {
    test('parses each variant', () {
      expect(MessageKind.fromName('text'), equals(MessageKind.text));
      expect(MessageKind.fromName('image'), equals(MessageKind.image));
      expect(MessageKind.fromName('voice'), equals(MessageKind.voice));
      expect(MessageKind.fromName('file'), equals(MessageKind.file));
    });

    test('MessageKind.fromName resolves system', () {
      expect(MessageKind.fromName('system'), equals(MessageKind.system));
    });

    test('falls back to text on null or unknown', () {
      expect(MessageKind.fromName(null), equals(MessageKind.text));
      expect(MessageKind.fromName('garbage'), equals(MessageKind.text));
    });

    test('omits optional fields when null', () {
      const a = Account(
        accountId: 'acc-1',
        username: 'nass',
        identityPubKey: [1, 2, 3, 4],
      );
      final json = a.toJson();
      expect(json.containsKey('display_name'), isFalse);
      expect(json.containsKey('avatar_url'), isFalse);
    });

    test('hashCode + == are consistent for equal instances', () {
      const a = Account(
        accountId: 'acc-1',
        username: 'nass',
        identityPubKey: [1, 2, 3, 4],
      );
      const b = Account(
        accountId: 'acc-1',
        username: 'nass',
        identityPubKey: [1, 2, 3, 4],
      );
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('different accountId means inequality', () {
      const a = Account(
        accountId: 'acc-1',
        username: 'nass',
        identityPubKey: [1, 2, 3, 4],
      );
      const b = Account(
        accountId: 'acc-2',
        username: 'nass',
        identityPubKey: [1, 2, 3, 4],
      );
      expect(a, isNot(equals(b)));
    });
  });

  group('Device', () {
    test('JSON round-trip', () {
      const d = Device(
        deviceId: 'dev-1',
        accountId: 'acc-1',
        devicePubKey: [9, 8, 7],
        displayName: 'iPhone',
      );
      expect(Device.fromJson(d.toJson()), equals(d));
    });

    test('equality + hash', () {
      const d1 = Device(deviceId: 'd', accountId: 'a', devicePubKey: [1]);
      const d2 = Device(deviceId: 'd', accountId: 'a', devicePubKey: [1]);
      expect(d1, equals(d2));
      expect(d1.hashCode, equals(d2.hashCode));
    });
  });

  group('Envelope', () {
    test('JSON round-trip preserves all fields', () {
      final e = Envelope(
        envelopeId: 'env-1',
        version: 'v1',
        domain: 'nanb.link',
        envelopeType: EnvelopeType.mlsApplication,
        conversationId: 'conv-1',
        senderDeviceId: 'sender-dev',
        recipientAccountId: 'recipient-acc',
        recipientDeviceId: 'recipient-dev',
        ciphertext: const [1, 2, 3],
        serverTs: DateTime.utc(2026, 5, 7, 12),
      );
      final round = Envelope.fromJson(e.toJson());
      expect(round, equals(e));
    });

    test('different envelopeId means inequality', () {
      final base = Envelope(
        envelopeId: 'env-1',
        version: 'v1',
        domain: 'd',
        envelopeType: 't',
        conversationId: 'c',
        senderDeviceId: 's',
        recipientAccountId: 'ra',
        recipientDeviceId: 'rd',
        ciphertext: const [1],
        serverTs: DateTime.utc(2026),
      );
      final other = Envelope(
        envelopeId: 'env-2',
        version: 'v1',
        domain: 'd',
        envelopeType: 't',
        conversationId: 'c',
        senderDeviceId: 's',
        recipientAccountId: 'ra',
        recipientDeviceId: 'rd',
        ciphertext: const [1],
        serverTs: DateTime.utc(2026),
      );
      expect(base, isNot(equals(other)));
    });
  });

  group('JwtSession', () {
    test('JSON round-trip', () {
      const s = JwtSession(
        accountId: 'acc-1',
        deviceId: 'dev-1',
        jwt: 'header.payload.sig',
        username: 'alice',
      );
      expect(JwtSession.fromJson(s.toJson()), equals(s));
    });

    test('fromJson and toJson include username', () {
      const s = JwtSession(
        accountId: 'acc-2',
        deviceId: 'dev-2',
        jwt: 'tok',
        username: 'bob',
      );
      final json = s.toJson();
      expect(json['username'], equals('bob'));
      expect(JwtSession.fromJson(json).username, equals('bob'));
    });

    test('equality and hashCode consider username', () {
      const a = JwtSession(
        accountId: 'acc-1',
        deviceId: 'dev-1',
        jwt: 'tok',
        username: 'alice',
      );
      const b = JwtSession(
        accountId: 'acc-1',
        deviceId: 'dev-1',
        jwt: 'tok',
        username: 'bob',
      );
      expect(a, isNot(equals(b)));
      expect(a.hashCode, isNot(equals(b.hashCode)));
    });
  });

  group('ApiError', () {
    test('fromJson with statusCode', () {
      final err = ApiError.fromJson(
        {'code': 'username_taken', 'message': 'taken'},
        statusCode: 409,
      );
      expect(err.code, equals('username_taken'));
      expect(err.message, equals('taken'));
      expect(err.statusCode, equals(409));
    });

    test('fromJson without message uses empty string', () {
      final err = ApiError.fromJson({'code': 'x'});
      expect(err.message, equals(''));
    });

    test('toString includes code, message, status', () {
      const err = ApiError(code: 'x', message: 'y', statusCode: 500);
      expect(err.toString(), contains('500'));
      expect(err.toString(), contains('x'));
      expect(err.toString(), contains('y'));
    });

    test('equality', () {
      const a = ApiError(code: 'x', message: 'y', statusCode: 500);
      const b = ApiError(code: 'x', message: 'y', statusCode: 500);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });
  });
}
