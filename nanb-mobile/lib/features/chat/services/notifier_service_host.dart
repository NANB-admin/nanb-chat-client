import '../../../core/db/app_database.dart';
import '../../../core/network/api_client.dart';
import '../models/conversation.dart';

/// The narrow capability surface a `ConversationsNotifier` exposes to its
/// collaborator services (reactions, pins, …). Services depend only on this
/// interface — not on the notifier's internals — so each concern can live in
/// its own file while still sharing the live conversation map, the
/// per-conversation FIFO lock, persistence, listener notification, and the
/// encrypted control-message fan-out.
///
/// Implemented by `ConversationsNotifier` via thin delegators to its private
/// members.
abstract interface class NotifierServiceHost {
  /// The live in-memory conversation for [id], or null if not loaded.
  Conversation? conversation(String id);

  /// All live in-memory conversations (for the muted/blocked SecureStorage
  /// mirrors). Iteration-only — do not mutate.
  Iterable<Conversation> allConversations();

  /// Replace the live in-memory conversation for [id].
  void setConversation(String id, Conversation conversation);

  /// Run [body] under [id]'s FIFO lock. NEVER call from inside an already-held
  /// lock for the same [id] — it self-deadlocks (see ConversationsNotifier).
  Future<T> runLocked<T>(String id, Future<T> Function() body);

  /// Notify listeners (delegates to ChangeNotifier.notifyListeners).
  void notifyHost();

  /// The local-data layer.
  AppDatabase get db;

  /// Encrypt + submit a control [body] to the peer's device(s) through the
  /// normal E2EE send path (no on-screen bubble). [toDeviceId] / [allPeerDevices]
  /// pick the target device(s) on an MLS 1:1 — see [ControlSender.sendControl].
  Future<void> sendControl(String conversationId, String body,
      {String? pushKind, String? toDeviceId, bool allPeerDevices = false});

  /// Encrypt + submit a control [body] to our OWN other devices (self-sync).
  Future<void> sendSelfControl(String conversationId, String body);

  /// Like [sendControl] (to the peer / every group member device), but invokes
  /// [onSealed] once the control has been ENCRYPTED — i.e. once it no longer
  /// needs the live MLS group — while the network submit is still in flight.
  /// Lets a caller that is about to wipe the group (group disband) wait for the
  /// cheap local step only, never the submit.
  Future<void> sendControlNotifyingSealed(String conversationId, String body,
      {required void Function() onSealed});

  /// Delete a group locally because an admin disbanded it: drop its messages,
  /// media, MLS state, conversation and member rows and tombstone the id — but
  /// emit NO leave commits (unlike [deleteConversation] on a group).
  Future<void> disbandGroupLocally(String conversationId);

  /// Submit one envelope over the preferred transport (warm WebSocket, HTTP
  /// fallback) with sealed-sender applied — the universal send chokepoint.
  Future<SubmitMessageResult> submit(SubmitMessagePayload payload);

  /// Acknowledge (consume) delivered envelopes on the server so they stop
  /// redelivering. The universal receive-side ack.
  Future<void> ack(List<String> envelopeIds);

  /// Opportunistically trim the in-memory message window for [conversationId]
  /// after enough inserts (keeps memory bounded; older messages stay on disk).
  Future<void> maybeTrim(String conversationId);

  /// Send a best-effort ephemeral frame over the WebSocket (not persisted, not
  /// encrypted) — e.g. typing signals. No-op when the socket is down.
  void sendEphemeral(Map<String, dynamic> frame);

  /// Whether the user has read receipts enabled (Privacy setting). Gates
  /// sending "read" receipts.
  bool get readReceiptsEnabled;

  /// The local user's account id (cached after connect; falls back to the
  /// stored session). Null if there is no session.
  Future<String?> currentAccountId();

  /// True iff [deviceId] is one of OUR OWN account's devices (warm own-device
  /// cache). [myDeviceId] is this device's id. Used to attribute / gate
  /// self-synced controls vs. peer controls.
  Future<bool> isMyDeviceWarm(String deviceId, String myDeviceId);

  /// The user's current conversation-privacy flags (block screenshots /
  /// forwarding), or null if no provider is wired.
  ({bool screenshots, bool forwarding})? privacyFlags();

  /// This device's id.
  Future<String> selfDeviceId();

  /// Remove the conversation locally (cascades to its messages + membership).
  Future<void> deleteConversation(String conversationId);

  /// Block/unblock a contact: sets [Conversation.blocked] AND mirrors the
  /// blocked set into SecureStorage (so the FCM background isolate suppresses
  /// wake notifications). Used by a rejected 1:1 request (reject = block).
  Future<void> setBlocked(String conversationId, bool blocked);

  /// Remove [targetDeviceId] from the MLS group of [conversationId] (fans a
  /// removal Commit to the other members). Used to leave a group on
  /// invite-reject.
  Future<void> removeMemberFromGroup({
    required String conversationId,
    required String targetDeviceId,
  });
}
