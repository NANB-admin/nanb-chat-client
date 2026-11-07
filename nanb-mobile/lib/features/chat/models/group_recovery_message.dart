import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// What a [GroupRecoveryMessage] asks the group's other devices to do.
enum GroupRecoveryKind {
  /// "I lost this group: remove my old leaf and add me back."
  rejoin,

  /// "I am back: re-send me your messages from after [GroupRecoveryMessage.sinceMs]."
  resync,
}

/// A request from a group member's device that lost its MLS state.
///
/// It cannot travel inside the group, because the sender no longer has it. So it
/// is sealed to each other member's device and Ed25519-signed by the requester,
/// who is checked against the group's roster. The signature binds the group, the
/// device and the kind, so it can't be replayed against another group or device.
class GroupRecoveryMessage {
  const GroupRecoveryMessage({
    required this.kind,
    required this.groupId,
    required this.deviceId,
    required this.sinceMs,
    required this.issuedAtMs,
    required this.signature,
  });

  final GroupRecoveryKind kind;
  final String groupId;
  final String deviceId;

  /// The newest message time the requester still holds in this group.
  final int sinceMs;
  final int issuedAtMs;

  /// Ed25519 over [signingBytes], by the requester's identity key.
  final List<int> signature;

  /// Domain-separated bytes signed by the requester and verified by the helper.
  static List<int> signingBytes({
    required GroupRecoveryKind kind,
    required String groupId,
    required String deviceId,
    required int sinceMs,
    required int issuedAtMs,
  }) =>
      utf8.encode(
          'nanb-group-recovery-v1|${kind.name}|$groupId|$deviceId|$sinceMs|$issuedAtMs');

  Uint8List encode() => Uint8List.fromList(utf8.encode(jsonEncode({
        'k': kind.name,
        'g': groupId,
        'd': deviceId,
        's': sinceMs,
        't': issuedAtMs,
        'sig': base64.encode(signature),
      })));

  /// Null when [bytes] isn't a well-formed message. Never throws.
  static GroupRecoveryMessage? tryDecode(List<int> bytes) {
    try {
      final raw = jsonDecode(utf8.decode(bytes));
      if (raw is! Map) return null;
      final kindName = raw['k'];
      final groupId = raw['g'];
      final deviceId = raw['d'];
      final sinceMs = raw['s'];
      final issuedAtMs = raw['t'];
      final sig = raw['sig'];
      if (groupId is! String ||
          deviceId is! String ||
          sinceMs is! int ||
          issuedAtMs is! int ||
          sig is! String) {
        return null;
      }
      final kind =
          GroupRecoveryKind.values.where((k) => k.name == kindName).firstOrNull;
      if (kind == null) return null;
      return GroupRecoveryMessage(
        kind: kind,
        groupId: groupId,
        deviceId: deviceId,
        sinceMs: sinceMs,
        issuedAtMs: issuedAtMs,
        signature: base64.decode(sig),
      );
    } catch (_) {
      return null;
    }
  }

  /// Whether [signature] is valid for [signerIdentityPubKey]. Never throws.
  Future<bool> verify(List<int> signerIdentityPubKey) async {
    if (signerIdentityPubKey.length != 32 || signature.length != 64) return false;
    try {
      return await Ed25519().verify(
        signingBytes(
          kind: kind,
          groupId: groupId,
          deviceId: deviceId,
          sinceMs: sinceMs,
          issuedAtMs: issuedAtMs,
        ),
        signature: Signature(
          signature,
          publicKey:
              SimplePublicKey(signerIdentityPubKey, type: KeyPairType.ed25519),
        ),
      );
    } catch (_) {
      return false;
    }
  }
}
