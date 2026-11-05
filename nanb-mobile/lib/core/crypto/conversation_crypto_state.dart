import 'package:flutter/foundation.dart';

/// Per-conversation forward-secret ratchet state. One pair of chains per
/// conversation: this device's outgoing (`send`) chain and the peer's
/// outgoing chain (`recv`, from this side's perspective). Each message
/// advances exactly one chain — sender's send chain on encrypt, receiver's
/// recv chain on decrypt. Old chain keys are discarded as the chain
/// advances, so compromise at message N never exposes messages 0..N-1.
@immutable
class ConversationCryptoState {
  const ConversationCryptoState({
    required this.conversationId,
    required this.sendCounter,
    required this.sendChainKey,
    required this.recvCounter,
    required this.recvChainKey,
    this.peerDeviceId = '',
  });

  final String conversationId;

  /// Which of the peer's devices this ratchet talks to. Multi-device: each
  /// linked peer device gets its own ratchet (distinct X25519 → distinct
  /// chains), keyed by (conversationId, peerDeviceId). The empty string is the
  /// conversation's *primary* peer device (`Conversation.peerDeviceId`) — the
  /// single-device baseline, so legacy rows and 1:1 chats keep working
  /// unchanged. NOT used in any key derivation (the ECDH shared secret already
  /// differs per device); purely a storage-routing tag.
  final String peerDeviceId;

  /// Number of messages we have encrypted on this chain so far. Goes into
  /// the next ciphertext as the wire counter.
  final int sendCounter;

  /// 32-byte HKDF chain key for our outgoing direction. Advanced on every
  /// `encryptMessage`.
  final List<int> sendChainKey;

  /// Highest wire counter we have already accepted from the peer. Used to
  /// detect replays + drive the fast-forward when an in-window out-of-order
  /// message arrives.
  final int recvCounter;

  /// 32-byte HKDF chain key for incoming-from-peer messages.
  final List<int> recvChainKey;

  ConversationCryptoState copyWith({
    int? sendCounter,
    List<int>? sendChainKey,
    int? recvCounter,
    List<int>? recvChainKey,
    String? peerDeviceId,
  }) {
    return ConversationCryptoState(
      conversationId: conversationId,
      sendCounter: sendCounter ?? this.sendCounter,
      sendChainKey: sendChainKey ?? this.sendChainKey,
      recvCounter: recvCounter ?? this.recvCounter,
      recvChainKey: recvChainKey ?? this.recvChainKey,
      peerDeviceId: peerDeviceId ?? this.peerDeviceId,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ConversationCryptoState &&
          conversationId == other.conversationId &&
          peerDeviceId == other.peerDeviceId &&
          sendCounter == other.sendCounter &&
          listEquals(sendChainKey, other.sendChainKey) &&
          recvCounter == other.recvCounter &&
          listEquals(recvChainKey, other.recvChainKey);

  @override
  int get hashCode => Object.hash(
        conversationId,
        peerDeviceId,
        sendCounter,
        Object.hashAll(sendChainKey),
        recvCounter,
        Object.hashAll(recvChainKey),
      );
}

/// Result of a successful encrypt — the wire ciphertext + the advanced state
/// to persist.
@immutable
class EncryptResult {
  const EncryptResult({required this.ciphertext, required this.newState});
  final List<int> ciphertext;
  final ConversationCryptoState newState;
}

/// Result of a successful decrypt — the recovered plaintext + the advanced
/// state to persist.
@immutable
class DecryptResult {
  const DecryptResult({required this.plaintext, required this.newState});
  final List<int> plaintext;
  final ConversationCryptoState newState;
}
