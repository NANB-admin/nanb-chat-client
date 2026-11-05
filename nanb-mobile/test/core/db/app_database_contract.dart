import 'package:nanb_chat/core/db/app_database.dart';

import 'contract/conversation_contract.dart';
import 'contract/group_and_crypto_contract.dart';
import 'contract/message_contract.dart';
import 'contract/retention_contract.dart';

/// Behavioural contract every [AppDatabase] implementation must satisfy.
/// [create] must return a FRESH, empty, not-yet-opened database each call.
/// Derived from `app_database_impl.dart` (the production SQL semantics); the
/// one place the SQL implementation disagrees with its own doc is flagged in
/// `contract/message_contract.dart` (search limit).
void runAppDatabaseContract(AppDatabase Function() create) {
  runConversationContract(create);
  runMessageContract(create);
  runRetentionContract(create);
  runGroupAndCryptoContract(create);
}
