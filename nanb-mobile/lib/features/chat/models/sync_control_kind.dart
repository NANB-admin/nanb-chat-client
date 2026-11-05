/// Which "sync" control a [MessageControl] carries, for the two controls that
/// have no payload field of their own to discriminate them.
///
/// - [deleteForMe]: this account removed a message with "Delete for me" and
///   tells ITS OWN other devices to drop it too. Honored only from own devices.
/// - [groupDeleted]: a group admin disbanded the group; every member device
///   deletes it locally. Honored only from a roster admin (or their own device).
/// - [conversationDeleted]: the user deleted a 1:1 on one device; their other
///   devices delete it too (own devices only, nothing goes to the peer).
enum SyncControlKind { deleteForMe, groupDeleted, conversationDeleted }
