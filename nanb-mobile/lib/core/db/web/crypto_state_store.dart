import '../../crypto/conversation_crypto_state.dart';
import 'codecs/crypto_state_row_codec.dart';
import 'web_table.dart';

/// `conversation_crypto_states` table logic, keyed by
/// (conversation_id, peer_device_id).
class CryptoStateStore {
  CryptoStateStore(this._table);

  final WebTable _table;

  static String _key(String conversationId, String peerDeviceId) =>
      '$conversationId\u0000$peerDeviceId';

  ConversationCryptoState? load(String conversationId, String peerDeviceId) {
    final row = _table.get(_key(conversationId, peerDeviceId));
    return row == null ? null : CryptoStateRowCodec.decode(row);
  }

  void save(ConversationCryptoState state) => _table.put(
      _key(state.conversationId, state.peerDeviceId),
      CryptoStateRowCodec.encode(state));

  /// Removes every peer-device pair of [conversationId].
  void deleteForConversation(String conversationId) {
    final keys = [
      for (final e in _table.entries)
        if (e.value['conversation_id'] == conversationId) e.key,
    ];
    keys.forEach(_table.remove);
  }
}
