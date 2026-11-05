import '../../../crypto/conversation_crypto_state.dart';
import '../models/web_row.dart';
import 'row_values.dart';

/// ConversationCryptoState <-> `conversation_crypto_states` row.
abstract final class CryptoStateRowCodec {
  static WebRow encode(ConversationCryptoState s) => {
        'conversation_id': s.conversationId,
        'peer_device_id': s.peerDeviceId,
        'send_counter': s.sendCounter,
        'send_chain_key': List<int>.from(s.sendChainKey),
        'recv_counter': s.recvCounter,
        'recv_chain_key': List<int>.from(s.recvChainKey),
      };

  static ConversationCryptoState decode(WebRow row) => ConversationCryptoState(
        conversationId: row['conversation_id'] as String,
        peerDeviceId: (row['peer_device_id'] as String?) ?? '',
        sendCounter: row['send_counter'] as int,
        sendChainKey: RowValues.intList(row['send_chain_key']),
        recvCounter: row['recv_counter'] as int,
        recvChainKey: RowValues.intList(row['recv_chain_key']),
      );
}
