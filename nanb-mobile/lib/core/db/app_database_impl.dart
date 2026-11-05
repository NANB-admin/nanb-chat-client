import 'dart:convert';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';

import '../../features/chat/models/chat_message.dart';
import '../../features/chat/models/link_preview.dart';
import '../../features/chat/models/conversation.dart';
import '../../features/chat/models/conversation_kind.dart';
import '../../features/chat/models/crypto_mode.dart';
import '../../features/chat/models/group_member.dart';
import '../../features/chat/models/message_kind.dart';
import '../crypto/conversation_crypto_state.dart';
import 'app_database.dart';
import 'sqlcipher_error_classifier.dart';

/// Production AppDatabase backed by SQLCipher via `sqflite_sqlcipher`.
/// Excluded from unit-test coverage (third-party I/O glue) per project policy
/// — `AppDatabaseInMemory` covers the contract.
class AppDatabaseImpl implements AppDatabase {
  Database? _db;

  @override
  bool get isOpen => _db != null;

  @override
  Future<void> open({
    required String masterKeyHex,
    bool recreateIfUnreadable = false,
  }) async {
    if (_db != null) return;
    final dir = await getApplicationDocumentsDirectory();
    final dbPath = p.join(dir.path, 'nanb.db');
    try {
      _db = await _openEncrypted(dbPath, masterKeyHex);
    } on DatabaseException catch (e) {
      // SQLCipher couldn't read the file: a wrong/lost key or a corrupt DB
      // surfaces as sqlite error 26 ("file is not a database"). Other failures
      // (locked, disk I/O) aren't decrypt failures — rethrow them untouched.
      if (!_looksUnreadable(e)) rethrow;
      if (!recreateIfUnreadable) {
        throw DatabaseUnreadableException(dbPath, e);
      }
      // The caller vouched the file is provably unrecoverable (e.g. the
      // SQLCipher key was just regenerated, so no key that could decrypt it
      // still exists). Drop the dead file and create a clean database.
      await deleteFile();
      _db = await _openEncrypted(dbPath, masterKeyHex);
    }
  }

  /// True when a sqflite failure is SQLCipher being unable to decrypt/parse the
  /// file (wrong or lost key, or corruption) rather than a transient open error.
  /// The message-matching logic lives in [isUnreadableSqlcipherError] so it can
  /// be unit-tested without a native sqflite/SQLCipher database.
  bool _looksUnreadable(DatabaseException e) =>
      isUnreadableSqlcipherError(e.toString());

  /// The raw `openDatabase` call — schema create + the full version-by-version
  /// upgrade ladder — shared by [open]'s first attempt and its post-wipe
  /// recreate so the migration logic lives in exactly one place.
  Future<Database> _openEncrypted(String dbPath, String masterKeyHex) {
    return openDatabase(
      dbPath,
      password: masterKeyHex,
      version: 33,
      // WAL + synchronous=NORMAL. The catchup drain is the write-heaviest thing
      // this app does — one transaction per inbound message, each of which
      // under the default rollback journal costs a journal write plus a full
      // fsync. WAL appends instead, and NORMAL lets the OS batch the flushes,
      // which is what turns a long "Catching up…" into a short one.
      //
      // Durability trade: with NORMAL, a power cut (not a crash — WAL still
      // survives that) can lose the last few committed transactions. That is
      // already the weaker half of this path: envelopes are acked
      // fire-and-forget, so anything lost that way is simply redelivered by the
      // server, which retains unacked envelopes. Both settings persist in the
      // database file, so this applies once and sticks.
      onConfigure: (db) async {
        try {
          await db.rawQuery('PRAGMA journal_mode=WAL');
          await db.execute('PRAGMA synchronous=NORMAL');
        } catch (_) {
          // Best-effort: a device that refuses WAL keeps the default journal
          // and is merely slower, never broken.
        }
      },
      onCreate: (db, version) async => _createSchema(db),
      onUpgrade: (db, oldVersion, newVersion) async {
        await _createSchema(db);
        if (oldVersion < 3) {
          try {
            await db.execute(
              "ALTER TABLE conversations ADD COLUMN peer_x25519_pub_key BLOB NOT NULL DEFAULT (X'')",
            );
          } catch (_) {/* already exists */}
        }
        if (oldVersion < 4) {
          try {
            await _createCryptoStateTable(db);
          } catch (_) {/* already exists */}
        }
        if (oldVersion < 5) {
          try {
            await db.execute(
              'ALTER TABLE conversations ADD COLUMN verified INTEGER NOT NULL DEFAULT 0',
            );
          } catch (_) {/* already exists */}
        }
        if (oldVersion < 6) {
          for (final stmt in const [
            "ALTER TABLE messages ADD COLUMN kind TEXT NOT NULL DEFAULT 'text'",
            'ALTER TABLE messages ADD COLUMN media_id TEXT',
            'ALTER TABLE messages ADD COLUMN media_key BLOB',
            'ALTER TABLE messages ADD COLUMN media_sha256 BLOB',
            'ALTER TABLE messages ADD COLUMN media_size INTEGER',
            'ALTER TABLE messages ADD COLUMN media_mime TEXT',
          ]) {
            try {
              await db.execute(stmt);
            } catch (_) {/* already exists */}
          }
        }
        if (oldVersion < 7) {
          // v7 added the persistent `failed` flag — replaces the old habit of
          // mutating the message body with a "(failed to send)" suffix.
          try {
            await db.execute(
              'ALTER TABLE messages ADD COLUMN failed INTEGER NOT NULL DEFAULT 0',
            );
          } catch (_) {/* already exists */}
        }
        if (oldVersion < 8) {
          // v8 adds the crypto_mode column so existing rows keep 'ratchet'
          // by default — Plan B's MlsMigrator flips the column to 'mls' on
          // the first successful outbound MLS send.
          try {
            await db.execute(
              "ALTER TABLE conversations ADD COLUMN crypto_mode TEXT NOT NULL DEFAULT 'ratchet'",
            );
          } catch (_) {/* already exists */}
        }
        if (oldVersion < 9) {
          try {
            await db.execute(
              "ALTER TABLE conversations ADD COLUMN kind TEXT NOT NULL DEFAULT 'oneToOne'",
            );
          } catch (_) {/* already exists */}
          try {
            await db.execute('ALTER TABLE conversations ADD COLUMN group_name TEXT');
          } catch (_) {/* already exists */}
          try {
            await db.execute('ALTER TABLE conversations ADD COLUMN mls_epoch INTEGER');
          } catch (_) {/* already exists */}
          try {
            await db.execute('''
              CREATE TABLE IF NOT EXISTS group_members (
                conversation_id TEXT NOT NULL,
                account_id TEXT NOT NULL,
                username TEXT NOT NULL,
                device_id TEXT NOT NULL,
                identity_pub_key BLOB NOT NULL,
                x25519_pub_key BLOB NOT NULL,
                is_admin INTEGER NOT NULL DEFAULT 0,
                is_self INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (conversation_id, device_id),
                FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE
              )
            ''');
          } catch (_) {/* already exists */}
          try {
            await db.execute(
              'CREATE INDEX IF NOT EXISTS idx_group_members_convo ON group_members(conversation_id)',
            );
          } catch (_) {/* already exists */}
        }
        if (oldVersion < 10) {
          try {
            await db.execute('ALTER TABLE messages ADD COLUMN media_filename TEXT');
          } catch (_) {/* already exists */}
        }
        if (oldVersion < 11) {
          try {
            await db.execute('ALTER TABLE messages ADD COLUMN voice_waveform BLOB');
          } catch (_) {/* already exists */}
        }
        if (oldVersion < 12) {
          // v12 adds the in-flight upload flag. Optimistic outbound media rows
          // ship the bytes via the in-memory cache only; if the app dies
          // mid-upload, boot recovery flips uploading=true → failed=true.
          try {
            await db.execute(
              'ALTER TABLE messages ADD COLUMN uploading INTEGER NOT NULL DEFAULT 0',
            );
          } catch (_) {/* already exists */}
        }
        if (oldVersion < 13) {
          // v13 adds the per-pending-upload AES-256-GCM key. Plaintext bytes
          // for in-flight uploads now live (encrypted) under
          // {appDocs}/pending-uploads/{outboxId}.bin; the key here unlocks
          // them on boot recovery so the upload can resume across restarts.
          try {
            await db.execute(
              'ALTER TABLE messages ADD COLUMN pending_upload_key BLOB',
            );
          } catch (_) {/* already exists */}
        }
        if (oldVersion < 14) {
          // v14 adds the message-request flag. Existing conversations load
          // as not-pending (default 0) — only new inbound-created ones are
          // ever marked pending.
          try {
            await db.execute(
              'ALTER TABLE conversations ADD COLUMN pending INTEGER NOT NULL DEFAULT 0',
            );
          } catch (_) {/* already exists */}
        }
        if (oldVersion < 15) {
          // v15 adds the voice-note duration so bubbles can label notes
          // before the audio is downloaded. Legacy rows stay null (label
          // falls back to 0:00 until first play).
          try {
            await db.execute(
              'ALTER TABLE messages ADD COLUMN media_duration_ms INTEGER',
            );
          } catch (_) {/* already exists */}
        }
        if (oldVersion < 16) {
          // v16 adds local conversation-organization flags. All default 0
          // (off) so existing rows are unpinned, unmuted, unarchived.
          for (final col in const ['pinned', 'muted', 'archived']) {
            try {
              await db.execute(
                'ALTER TABLE conversations ADD COLUMN $col INTEGER NOT NULL DEFAULT 0',
              );
            } catch (_) {/* already exists */}
          }
        }
        if (oldVersion < 17) {
          // v17 adds reply/quote denormalized fields on messages. Null for
          // non-reply messages and all legacy rows.
          for (final col in const [
            'reply_to_envelope_id TEXT',
            'reply_to_sender TEXT',
            'reply_to_preview TEXT',
          ]) {
            try {
              await db.execute('ALTER TABLE messages ADD COLUMN $col');
            } catch (_) {/* already exists */}
          }
        }
        if (oldVersion < 18) {
          // v18: per-device-pair ratchet state. The crypto-state PK gains
          // peer_device_id so a multi-device peer gets one ratchet per device.
          // SQLite can't alter a PK, so rebuild the table; existing rows become
          // the primary-device pair (peer_device_id '') — unchanged behaviour.
          try {
            await db.execute('''
              CREATE TABLE conversation_crypto_states_v18 (
                conversation_id TEXT NOT NULL,
                peer_device_id TEXT NOT NULL DEFAULT '',
                send_counter INTEGER NOT NULL,
                send_chain_key BLOB NOT NULL,
                recv_counter INTEGER NOT NULL,
                recv_chain_key BLOB NOT NULL,
                PRIMARY KEY (conversation_id, peer_device_id)
              )
            ''');
            await db.execute('''
              INSERT INTO conversation_crypto_states_v18
                (conversation_id, peer_device_id, send_counter, send_chain_key, recv_counter, recv_chain_key)
              SELECT conversation_id, '', send_counter, send_chain_key, recv_counter, recv_chain_key
              FROM conversation_crypto_states
            ''');
            await db.execute('DROP TABLE conversation_crypto_states');
            await db.execute(
                'ALTER TABLE conversation_crypto_states_v18 RENAME TO conversation_crypto_states');
          } catch (_) {/* fresh table already at v18 shape */}
        }
        if (oldVersion < 19) {
          // v19 adds per-message delivery status (sent/delivered/read), driven
          // by receipts the peer sends back. Default 0 (sent) for legacy rows.
          try {
            await db.execute(
              'ALTER TABLE messages ADD COLUMN delivery_status INTEGER NOT NULL DEFAULT 0',
            );
          } catch (_) {/* already exists */}
        }
        if (oldVersion < 20) {
          // v20: forwarded-message tag + the peer's conversation-privacy
          // flags (block screenshots / block forwarding).
          for (final stmt in const [
            'ALTER TABLE messages ADD COLUMN forwarded INTEGER NOT NULL DEFAULT 0',
            'ALTER TABLE conversations ADD COLUMN peer_blocks_screenshots INTEGER NOT NULL DEFAULT 0',
            'ALTER TABLE conversations ADD COLUMN peer_blocks_forwarding INTEGER NOT NULL DEFAULT 0',
          ]) {
            try {
              await db.execute(stmt);
            } catch (_) {/* already exists */}
          }
        }
        if (oldVersion < 21) {
          // v21 adds the local block flag. Default 0 so existing conversations
          // load unblocked.
          try {
            await db.execute(
              'ALTER TABLE conversations ADD COLUMN blocked INTEGER NOT NULL DEFAULT 0',
            );
          } catch (_) {/* already exists */}
        }
        if (oldVersion < 22) {
          // v22: per-message disappearing expiry (UTC ms). Carried from the
          // sender so both sides expire on the sender's timer. Null for legacy
          // rows — they fall back to the global sweep.
          try {
            await db.execute(
              'ALTER TABLE messages ADD COLUMN expires_at INTEGER',
            );
          } catch (_) {/* already exists */}
        }
        if (oldVersion < 23) {
          // v23 adds the per-conversation disappearing-messages override.
          // -1 (the default) means "use the global default"; any value > 0 is
          // an explicit retention the sender attaches to its messages here.
          try {
            await db.execute(
              'ALTER TABLE conversations ADD COLUMN disappearing_ttl INTEGER NOT NULL DEFAULT -1',
            );
          } catch (_) {/* already exists */}
        }
        if (oldVersion < 24) {
          // v24: emoji reactions, stored as a JSON object (reactor account id →
          // emoji). Null for messages with no reactions. Mutated in place as
          // reaction control messages arrive.
          try {
            await db.execute(
              'ALTER TABLE messages ADD COLUMN reactions TEXT',
            );
          } catch (_) {/* already exists */}
        }
        if (oldVersion < 25) {
          // v25: per-message pin flag (the original local-only pin model,
          // superseded by the conversation-level pin in v26 — column now unused
          // but left in place to avoid a table rebuild). Default 0 (unpinned).
          try {
            await db.execute(
              'ALTER TABLE messages ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0',
            );
          } catch (_) {/* already exists */}
        }
        if (oldVersion < 26) {
          // v26: single pinned message per conversation, shared across the chat
          // (synced via MessageControl.pin). Holds the pinned message's
          // envelope_id, or NULL when nothing is pinned.
          try {
            await db.execute(
              'ALTER TABLE conversations ADD COLUMN pinned_message_id TEXT',
            );
          } catch (_) {/* already exists */}
        }
        if (oldVersion < 27) {
          // v27 adds a PARTIAL index on messages(expires_at) so the
          // disappearing-message retention sweep (every 60s + on resume) stops
          // full-scanning. Partial (WHERE expires_at IS NOT NULL) so it only
          // covers sender-stamped disappearing messages — an app with the
          // feature off carries an empty index.
          try {
            await db.execute(
              'CREATE INDEX IF NOT EXISTS idx_messages_expires_at ON messages(expires_at) WHERE expires_at IS NOT NULL',
            );
          } catch (_) {/* already exists */}
        }
        if (oldVersion < 28) {
          // v28: stable client message id (the sender's outboxId, carried in the
          // E2EE `_cid` header) for resend dedup. Null on legacy rows. A partial
          // index backs the (senderDeviceId, client_msg_id) dedup lookup.
          try {
            await db.execute(
              'ALTER TABLE messages ADD COLUMN client_msg_id TEXT',
            );
          } catch (_) {/* already exists */}
          try {
            await db.execute(
              'CREATE INDEX IF NOT EXISTS idx_messages_client_msg_id ON messages(client_msg_id) WHERE client_msg_id IS NOT NULL',
            );
          } catch (_) {/* already exists */}
        }
        if (oldVersion < 29) {
          // v29: tombstones for deleted groups, so residual server-side
          // envelopes can't resurrect a group the user deleted. A plain new
          // table — _createSchema above already created it on this same run,
          // so this is only here to keep the ladder explicit + self-healing.
          await _createDeletedGroupsTable(db);
        }
        if (oldVersion < 30) {
          // v30: the link-preview card (title/description/thumbnail JSON) attached
          // to a message that contains a link. Null for every existing row. NOT
          // referenced by _createSchema's indexes: that runs BEFORE this ALTER on an
          // upgrade, so indexing it there would fail the open.
          try {
            await db.execute('ALTER TABLE messages ADD COLUMN link_preview TEXT');
          } catch (_) {/* already exists */}
        }
        if (oldVersion < 31) {
          // v31: set once the author has edited a text message. Like link_preview,
          // never referenced by _createSchema's indexes (it runs before this ALTER).
          try {
            await db.execute(
                'ALTER TABLE messages ADD COLUMN edited INTEGER NOT NULL DEFAULT 0');
          } catch (_) {/* already exists */}
        }
        if (oldVersion < 32) {
          // v32: when delivery / read receipts arrived (UTC ms). Never indexed.
          for (final col in const ['delivered_at', 'read_at']) {
            try {
              await db.execute('ALTER TABLE messages ADD COLUMN $col INTEGER');
            } catch (_) {/* already exists */}
          }
        }
        if (oldVersion < 33) {
          // v33: the group's photo (media-descriptor JSON). Null for every
          // existing row. NOT referenced by _createSchema's indexes: that runs
          // BEFORE this ALTER on an upgrade.
          try {
            await db.execute(
                'ALTER TABLE conversations ADD COLUMN group_avatar TEXT');
          } catch (_) {/* already exists */}
        }
      },
    );
  }

  @override
  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  @override
  Future<List<Conversation>> loadConversations({
    int messagesPerConversation = 50,
  }) async {
    final db = _db;
    if (db == null) return const [];
    final convoRows = await db.query('conversations');
    // Load every group's members in a single query and bucket by conversation,
    // instead of a per-conversation round trip. Most 1:1s have no members row
    // yet still paid a platform-channel hop each on cold start.
    final membersByConvo = await _allGroupMembers(db);
    // Pull the most recent N+1 messages for EVERY conversation in ONE batched
    // pass instead of a query per chat — the old cold-start N+1, where each
    // per-conversation query was its own awaited platform-channel hop. The +1
    // probe per conversation still decides hasMoreOlderMessages without a COUNT.
    final probe = messagesPerConversation + 1;
    final convoIds = [for (final row in convoRows) row['id'] as String];
    final messagesByConvo =
        await _recentMessagesPerConversation(db, convoIds, probe);
    final out = <Conversation>[];
    for (final row in convoRows) {
      final id = row['id'] as String;
      // Bucket is ascending by server_ts, holding this conversation's newest
      // `probe` rows. If it reached `probe`, an older message exists (hasMore)
      // and the extra is the oldest of the N+1 — drop it to keep the newest N.
      final bucket = messagesByConvo[id] ?? const <Map<String, Object?>>[];
      final hasMore = bucket.length == probe;
      final pageRowsAsc = hasMore ? bucket.sublist(1) : bucket;
      final messages =
          pageRowsAsc.map(_messageFromRow).toList(growable: false);
      final members = membersByConvo[id] ?? const <GroupMember>[];
      out.add(Conversation(
        id: id,
        peerUsername: row['peer_username'] as String,
        peerAccountId: row['peer_account_id'] as String,
        peerDeviceId: row['peer_device_id'] as String,
        peerIdentityPubKey: _intList(row['peer_identity_pub_key']),
        peerX25519PubKey: _intList(row['peer_x25519_pub_key']),
        messages: messages,
        unreadCount: (row['unread_count'] as int?) ?? 0,
        verified: ((row['verified'] as int?) ?? 0) == 1,
        hasMoreOlderMessages: hasMore,
        cryptoMode: CryptoMode.fromName(
          (row['crypto_mode'] as String?) ?? 'ratchet',
        ),
        kind: ConversationKind.fromName(
          (row['kind'] as String?) ?? 'oneToOne',
        ),
        groupName: row['group_name'] as String?,
        groupAvatar: row['group_avatar'] as String?,
        mlsEpoch: row['mls_epoch'] as int?,
        members: members,
        pending: ((row['pending'] as int?) ?? 0) == 1,
        pinned: ((row['pinned'] as int?) ?? 0) == 1,
        pinnedEnvelopeId: row['pinned_message_id'] as String?,
        muted: ((row['muted'] as int?) ?? 0) == 1,
        archived: ((row['archived'] as int?) ?? 0) == 1,
        blocked: ((row['blocked'] as int?) ?? 0) == 1,
        peerBlocksScreenshots:
            ((row['peer_blocks_screenshots'] as int?) ?? 0) == 1,
        peerBlocksForwarding:
            ((row['peer_blocks_forwarding'] as int?) ?? 0) == 1,
        disappearingTtl: (row['disappearing_ttl'] as int?) ?? -1,
      ));
    }
    return out;
  }

  /// The newest [probe] messages for each of [conversationIds], bucketed by
  /// conversation id and sorted ascending by `server_ts`. Replaces
  /// [loadConversations]'s old per-conversation query (the cold-start N+1) with
  /// a single batched round trip per chunk of conversations.
  ///
  /// Portable by design: a `UNION ALL` of one bounded subquery per conversation
  /// (`… WHERE conversation_id = ? ORDER BY server_ts DESC LIMIT ?`), which the
  /// existing `idx_messages_convo_ts` index serves directly. It leans only on
  /// subquery-in-FROM + `UNION ALL` — NO window functions (ROW_NUMBER et al.),
  /// so it runs on the older SQLite bundled with e.g. Android 10 devices. Each
  /// subquery stays bounded to `probe` rows, so a conversation near the 5000-row
  /// cap isn't fully materialised just to keep the newest page. Chunked to stay
  /// well under SQLITE_MAX_COMPOUND_SELECT and the bound-variable cap on those
  /// same devices.
  Future<Map<String, List<Map<String, Object?>>>>
      _recentMessagesPerConversation(
    Database db,
    List<String> conversationIds,
    int probe,
  ) async {
    final byConvo = <String, List<Map<String, Object?>>>{};
    if (conversationIds.isEmpty) return byConvo;
    const chunkSize = 100;
    for (var start = 0; start < conversationIds.length; start += chunkSize) {
      final end = start + chunkSize < conversationIds.length
          ? start + chunkSize
          : conversationIds.length;
      final chunk = conversationIds.sublist(start, end);
      // One bounded subquery per conversation, UNION ALL'd into a single query.
      // The subquery-in-FROM wrapper is required: SQLite forbids LIMIT directly
      // on a bare compound-select operand.
      const subSelect = 'SELECT * FROM (SELECT * FROM messages '
          'WHERE conversation_id = ? ORDER BY server_ts DESC LIMIT ?)';
      final sql = List.filled(chunk.length, subSelect).join('\nUNION ALL\n');
      final args = <Object?>[];
      for (final id in chunk) {
        args
          ..add(id)
          ..add(probe);
      }
      final rows = await db.rawQuery(sql, args);
      for (final row in rows) {
        final convoId = row['conversation_id'] as String;
        (byConvo[convoId] ??= <Map<String, Object?>>[]).add(row);
      }
    }
    // `UNION ALL` doesn't preserve each subquery's ORDER BY, so re-sort every
    // bucket ascending — matching the old per-conversation `ORDER BY server_ts
    // DESC` followed by `.reversed`.
    for (final bucket in byConvo.values) {
      bucket.sort(
        (a, b) => (a['server_ts'] as int).compareTo(b['server_ts'] as int),
      );
    }
    return byConvo;
  }

  @override
  Future<List<ChatMessage>> loadMessages(
    String conversationId, {
    required int limit,
    int? beforeServerTsMs,
  }) async {
    final db = _db;
    if (db == null || limit <= 0) return const [];
    final where = beforeServerTsMs == null
        ? 'conversation_id = ?'
        : 'conversation_id = ? AND server_ts < ?';
    final whereArgs = beforeServerTsMs == null
        ? <Object>[conversationId]
        : <Object>[conversationId, beforeServerTsMs];
    // DESC + LIMIT efficiently selects the newest N matching rows; reverse
    // to ascending to match the in-memory list ordering.
    final rows = await db.query(
      'messages',
      where: where,
      whereArgs: whereArgs,
      orderBy: 'server_ts DESC',
      limit: limit,
    );
    return rows.reversed.map(_messageFromRow).toList(growable: false);
  }

  /// Column map for a conversation row. Extracted so the single-write and
  /// transactional paths cannot drift apart.
  Map<String, Object?> _conversationRow(Conversation conversation) => {
        'id': conversation.id,
        'peer_username': conversation.peerUsername,
        'peer_account_id': conversation.peerAccountId,
        'peer_device_id': conversation.peerDeviceId,
        'peer_identity_pub_key':
            _intListToBlob(conversation.peerIdentityPubKey),
        'peer_x25519_pub_key':
            _intListToBlob(conversation.peerX25519PubKey),
        'unread_count': conversation.unreadCount,
        'verified': conversation.verified ? 1 : 0,
        'crypto_mode': conversation.cryptoMode.name,
        'kind': conversation.kind.name,
        'group_name': conversation.groupName,
        'mls_epoch': conversation.mlsEpoch,
        'pending': conversation.pending ? 1 : 0,
        'pinned': conversation.pinned ? 1 : 0,
        'pinned_message_id': conversation.pinnedEnvelopeId,
        'group_avatar': conversation.groupAvatar,
        'muted': conversation.muted ? 1 : 0,
        'archived': conversation.archived ? 1 : 0,
        'blocked': conversation.blocked ? 1 : 0,
        'peer_blocks_screenshots': conversation.peerBlocksScreenshots ? 1 : 0,
        'peer_blocks_forwarding': conversation.peerBlocksForwarding ? 1 : 0,
        'disappearing_ttl': conversation.disappearingTtl,
      };

  /// Column map for a message row. See [_conversationRow].
  Map<String, Object?> _messageRow(String conversationId, ChatMessage m) => {
        'envelope_id': m.envelopeId,
        'conversation_id': conversationId,
        'sender_device_id': m.senderDeviceId,
        'body': m.body,
        'server_ts': m.serverTs.toUtc().millisecondsSinceEpoch,
        'mine': m.mine ? 1 : 0,
        'outbox_id': m.outboxId,
        'client_msg_id': m.clientMsgId,
        'kind': m.kind.name,
        'media_id': m.mediaId,
        'media_key': m.mediaKey == null ? null : _intListToBlob(m.mediaKey!),
        'media_sha256':
            m.mediaSha256 == null ? null : _intListToBlob(m.mediaSha256!),
        'media_size': m.mediaSize,
        'media_mime': m.mediaMime,
        'media_filename': m.mediaFilename,
        'media_duration_ms': m.mediaDurationMs,
        'reply_to_envelope_id': m.replyToEnvelopeId,
        'reply_to_sender': m.replyToSender,
        'reply_to_preview': m.replyToPreview,
        'voice_waveform': m.voiceWaveform == null
            ? null
            : _intListToBlob(m.voiceWaveform!),
        'failed': m.failed ? 1 : 0,
        'uploading': m.uploading ? 1 : 0,
        'pending_upload_key': m.pendingUploadKey == null
            ? null
            : _intListToBlob(m.pendingUploadKey!),
        'delivery_status': m.deliveryStatus.index,
        'forwarded': m.forwarded ? 1 : 0,
        'expires_at': m.expiresAt?.toUtc().millisecondsSinceEpoch,
        'reactions': m.reactions.isEmpty ? null : jsonEncode(m.reactions),
        'link_preview': m.linkPreview?.encode(),
        'edited': m.edited ? 1 : 0,
        'delivered_at': m.deliveredAt?.toUtc().millisecondsSinceEpoch,
        'read_at': m.readAt?.toUtc().millisecondsSinceEpoch,
      };

  @override
  Future<void> upsertConversationWithMessages(
      Conversation conversation, List<ChatMessage> messages) async {
    final db = _db;
    if (db == null) return;
    // ONE transaction, not two. The receive path used to call
    // upsertConversation + upsertMessages back to back for EVERY envelope, so
    // each message cost two separate SQLCipher commits — and every commit on an
    // encrypted store pays its own crypto + fsync. Measured on-device
    // 2026-08-22, a 32-message catchup spent 3.7s locally at ~114ms/message;
    // halving the commit count is the cheapest part of that to give back, and
    // it also makes the pair atomic (a crash between them previously left a
    // conversation summary advertising a message that was never stored).
    await db.transaction((txn) async {
      await txn.insert(
        'conversations',
        _conversationRow(conversation),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      if (messages.isEmpty) return;
      final batch = txn.batch();
      for (final m in messages) {
        batch.insert(
          'messages',
          _messageRow(conversation.id, m),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  @override
  Future<void> upsertConversation(Conversation conversation) async {
    final db = _db;
    if (db == null) return;
    await db.insert(
      'conversations',
      _conversationRow(conversation),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<void> deleteConversation(String conversationId) async {
    final db = _db;
    if (db == null) return;
    await db.delete('group_members',
        where: 'conversation_id = ?', whereArgs: [conversationId]);
    await db.delete('messages', where: 'conversation_id = ?', whereArgs: [conversationId]);
    await db.delete('conversations', where: 'id = ?', whereArgs: [conversationId]);
  }

  @override
  Future<void> clearMessagesForConversation(String conversationId) async {
    final db = _db;
    if (db == null) return;
    await db.delete('messages',
        where: 'conversation_id = ?', whereArgs: [conversationId]);
  }

  @override
  Future<List<ChatMessage>> searchMessages(
    String conversationId,
    String query, {
    int limit = 200,
  }) async {
    final db = _db;
    if (db == null) return const [];
    final q = query.trim();
    if (q.isEmpty) return const [];
    // SQLite LIKE is ASCII-case-insensitive by default. Escape the user's
    // wildcards so a literal % / _ in the query isn't treated as a pattern.
    final like = '%${q.replaceAll('\\', '\\\\').replaceAll('%', '\\%').replaceAll('_', '\\_')}%';
    final rows = await db.query(
      'messages',
      where: "conversation_id = ? AND kind = 'text' AND body LIKE ? ESCAPE '\\'",
      whereArgs: [conversationId, like],
      orderBy: 'server_ts DESC',
      limit: limit,
    );
    return rows.map(_messageFromRow).toList(growable: false);
  }

  @override
  Future<ChatMessage?> getMessage(String envelopeId) async {
    final db = _db;
    if (db == null) return null;
    final rows = await db.query(
      'messages',
      where: 'envelope_id = ?',
      whereArgs: [envelopeId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _messageFromRow(rows.first);
  }

  @override
  Future<bool> hasMessageWithClientId(
    String conversationId,
    String senderDeviceId,
    String clientMsgId,
  ) async {
    final db = _db;
    if (db == null) return false;
    final rows = await db.query(
      'messages',
      columns: const ['envelope_id'],
      where:
          'conversation_id = ? AND sender_device_id = ? AND client_msg_id = ?',
      whereArgs: [conversationId, senderDeviceId, clientMsgId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  @override
  Future<void> upsertMessages(String conversationId, List<ChatMessage> messages) async {
    final db = _db;
    if (db == null) return;
    final batch = db.batch();
    for (final m in messages) {
      batch.insert(
        'messages',
        _messageRow(conversationId, m),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  @override
  Future<void> deleteMessage(String envelopeId) async {
    final db = _db;
    if (db == null) return;
    await db.delete('messages', where: 'envelope_id = ?', whereArgs: [envelopeId]);
  }

  @override
  Future<void> trimMessages(String conversationId, {required int keep}) async {
    final db = _db;
    if (db == null) return;
    await db.execute(
      '''
      DELETE FROM messages
      WHERE conversation_id = ?
        AND envelope_id NOT IN (
          SELECT envelope_id FROM messages
          WHERE conversation_id = ?
          ORDER BY server_ts DESC
          LIMIT ?
        )
      ''',
      [conversationId, conversationId, keep],
    );
  }

  @override
  Future<void> clearAll() async {
    final db = _db;
    if (db == null) return;
    await db.delete('group_members');
    await db.delete('messages');
    await db.delete('conversation_crypto_states');
    await db.delete('conversations');
    await db.delete('deleted_groups');
  }

  @override
  Future<void> deleteFile() async {
    await _db?.close();
    _db = null;
    final dir = await getApplicationDocumentsDirectory();
    final dbPath = p.join(dir.path, 'nanb.db');
    await deleteDatabase(dbPath);
  }

  Future<void> _createSchema(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS conversations (
        id TEXT PRIMARY KEY,
        peer_username TEXT NOT NULL,
        peer_account_id TEXT NOT NULL,
        peer_device_id TEXT NOT NULL,
        peer_identity_pub_key BLOB NOT NULL,
        peer_x25519_pub_key BLOB NOT NULL DEFAULT (X''),
        unread_count INTEGER NOT NULL DEFAULT 0,
        verified INTEGER NOT NULL DEFAULT 0,
        crypto_mode TEXT NOT NULL DEFAULT 'ratchet',
        kind TEXT NOT NULL DEFAULT 'oneToOne',
        group_name TEXT,
        mls_epoch INTEGER,
        pending INTEGER NOT NULL DEFAULT 0,
        pinned INTEGER NOT NULL DEFAULT 0,
        muted INTEGER NOT NULL DEFAULT 0,
        archived INTEGER NOT NULL DEFAULT 0,
        blocked INTEGER NOT NULL DEFAULT 0,
        peer_blocks_screenshots INTEGER NOT NULL DEFAULT 0,
        peer_blocks_forwarding INTEGER NOT NULL DEFAULT 0,
        disappearing_ttl INTEGER NOT NULL DEFAULT -1,
        pinned_message_id TEXT,
        group_avatar TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS messages (
        envelope_id TEXT PRIMARY KEY,
        conversation_id TEXT NOT NULL,
        sender_device_id TEXT NOT NULL,
        body TEXT NOT NULL,
        server_ts INTEGER NOT NULL,
        mine INTEGER NOT NULL,
        outbox_id TEXT,
        kind TEXT NOT NULL DEFAULT 'text',
        media_id TEXT,
        media_key BLOB,
        media_sha256 BLOB,
        media_size INTEGER,
        media_mime TEXT,
        media_filename TEXT,
        media_duration_ms INTEGER,
        reply_to_envelope_id TEXT,
        reply_to_sender TEXT,
        reply_to_preview TEXT,
        voice_waveform BLOB,
        failed INTEGER NOT NULL DEFAULT 0,
        uploading INTEGER NOT NULL DEFAULT 0,
        pending_upload_key BLOB,
        delivery_status INTEGER NOT NULL DEFAULT 0,
        forwarded INTEGER NOT NULL DEFAULT 0,
        expires_at INTEGER,
        reactions TEXT,
        pinned INTEGER NOT NULL DEFAULT 0,
        client_msg_id TEXT,
        link_preview TEXT,
        edited INTEGER NOT NULL DEFAULT 0,
        delivered_at INTEGER,
        read_at INTEGER
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_messages_convo_ts ON messages(conversation_id, server_ts)',
    );
    // Partial index backing the resend-dedup lookup (hasMessageWithClientId):
    // only rows carrying a sender-stamped client_msg_id are indexed. See v28.
    //
    // GUARDED: _createSchema also runs at the TOP of onUpgrade, BEFORE the v28
    // block's `ALTER TABLE messages ADD COLUMN client_msg_id`. On a v27->v28
    // upgrade the column doesn't exist yet here, so this throws "no such column"
    // and would fail the whole DB open (infinite-spinner regression). Swallow it
    // — the v28 upgrade block re-creates this index AFTER the ALTER. On a fresh
    // install the column is already in the CREATE TABLE above, so it succeeds.
    try {
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_messages_client_msg_id ON messages(client_msg_id) WHERE client_msg_id IS NOT NULL',
      );
    } catch (_) {/* column is added later in the v28 upgrade block */}
    // Partial index for the disappearing-message retention sweep: only rows
    // carrying a sender-stamped expiry are indexed, so the periodic + on-resume
    // sweep (deleteExpiredMessages) never full-scans, and an app with
    // disappearing messages off carries an empty index. See schema v27.
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_messages_expires_at ON messages(expires_at) WHERE expires_at IS NOT NULL',
    );
    await db.execute('''
      CREATE TABLE IF NOT EXISTS group_members (
        conversation_id TEXT NOT NULL,
        account_id TEXT NOT NULL,
        username TEXT NOT NULL,
        device_id TEXT NOT NULL,
        identity_pub_key BLOB NOT NULL,
        x25519_pub_key BLOB NOT NULL,
        is_admin INTEGER NOT NULL DEFAULT 0,
        is_self INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (conversation_id, device_id),
        FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_group_members_convo ON group_members(conversation_id)',
    );
    await _createDeletedGroupsTable(db);
    await _createCryptoStateTable(db);
  }

  /// Tombstones for groups the user deleted (schema v29). Deliberately NOT
  /// foreign-keyed to `conversations` — the whole point is that the row
  /// outlives the conversation it names.
  static Future<void> _createDeletedGroupsTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS deleted_groups (
        conversation_id TEXT PRIMARY KEY,
        deleted_at INTEGER NOT NULL
      )
    ''');
  }

  static Future<void> _createCryptoStateTable(Database db) async {
    // Keyed by (conversation_id, peer_device_id). peer_device_id '' is the
    // conversation's primary peer device — the single-device baseline; each
    // additional linked peer device gets its own ratchet row.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS conversation_crypto_states (
        conversation_id TEXT NOT NULL,
        peer_device_id TEXT NOT NULL DEFAULT '',
        send_counter INTEGER NOT NULL,
        send_chain_key BLOB NOT NULL,
        recv_counter INTEGER NOT NULL,
        recv_chain_key BLOB NOT NULL,
        PRIMARY KEY (conversation_id, peer_device_id)
      )
    ''');
  }

  @override
  Future<int> deleteMessagesPastLocalRetention(
      DateTime now, int? globalTtlSeconds) async {
    final db = _db;
    if (db == null) return 0;
    // Cheap-exit when no local retention is in force at all: with no global
    // default (the `? IS NOT NULL` branch dead) the only rows that could expire
    // are those in a conversation with an explicit override. If none exists, the
    // delete below is a guaranteed no-op — skip its full scan so an app with
    // disappearing messages off doesn't scan every 60s tick / resume.
    if (globalTtlSeconds == null) {
      final anyOverride = await db.rawQuery(
        'SELECT EXISTS(SELECT 1 FROM conversations WHERE disappearing_ttl > 0) AS present',
      );
      if ((anyOverride.first['present'] as int) == 0) return 0;
    }
    final nowMs = now.toUtc().millisecondsSinceEpoch;
    // Delete any message whose (server_ts + this device's effective retention)
    // is at/before now. Effective TTL = the per-conversation override
    // (disappearing_ttl seconds, when > 0) else the global default; a message in
    // a conversation with neither (no override, null global) has no local
    // retention and is left to its sender-stamped expiry only. Applied to the
    // CURRENT setting retroactively, regardless of any stamped expiry.
    return db.rawDelete('''
      DELETE FROM messages
      WHERE envelope_id IN (
        SELECT m.envelope_id FROM messages m
        LEFT JOIN conversations c ON c.id = m.conversation_id
        WHERE
          (COALESCE(c.disappearing_ttl, 0) > 0
            AND ? >= m.server_ts + c.disappearing_ttl * 1000)
          OR
          (COALESCE(c.disappearing_ttl, 0) <= 0
            AND ? IS NOT NULL
            AND ? >= m.server_ts + ? * 1000)
      )
    ''', [nowMs, globalTtlSeconds, nowMs, globalTtlSeconds]);
  }

  @override
  Future<int> deleteExpiredMessages(DateTime now) async {
    final db = _db;
    if (db == null) return 0;
    // Skip the delete entirely when no message carries a sender-stamped expiry —
    // the common case with disappearing messages off. Backed by the partial
    // idx_messages_expires_at index this EXISTS probe is O(1)-ish (an empty
    // index), so the sweep costs nothing each tick until a TTL'd message lands.
    final anyExpiring = await db.rawQuery(
      'SELECT EXISTS(SELECT 1 FROM messages WHERE expires_at IS NOT NULL) AS present',
    );
    if ((anyExpiring.first['present'] as int) == 0) return 0;
    return db.delete(
      'messages',
      where: 'expires_at IS NOT NULL AND expires_at <= ?',
      whereArgs: [now.toUtc().millisecondsSinceEpoch],
    );
  }

  @override
  Future<ConversationCryptoState?> loadConversationCryptoState(
    String conversationId, {
    String peerDeviceId = '',
  }) async {
    final db = _db;
    if (db == null) return null;
    final rows = await db.query(
      'conversation_crypto_states',
      where: 'conversation_id = ? AND peer_device_id = ?',
      whereArgs: [conversationId, peerDeviceId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return ConversationCryptoState(
      conversationId: row['conversation_id'] as String,
      peerDeviceId: (row['peer_device_id'] as String?) ?? '',
      sendCounter: row['send_counter'] as int,
      sendChainKey: _intList(row['send_chain_key']),
      recvCounter: row['recv_counter'] as int,
      recvChainKey: _intList(row['recv_chain_key']),
    );
  }

  @override
  Future<void> saveConversationCryptoState(ConversationCryptoState state) async {
    final db = _db;
    if (db == null) return;
    await db.insert(
      'conversation_crypto_states',
      {
        'conversation_id': state.conversationId,
        'peer_device_id': state.peerDeviceId,
        'send_counter': state.sendCounter,
        'send_chain_key': _intListToBlob(state.sendChainKey),
        'recv_counter': state.recvCounter,
        'recv_chain_key': _intListToBlob(state.recvChainKey),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<void> deleteConversationCryptoState(String conversationId) async {
    final db = _db;
    if (db == null) return;
    await db.delete(
      'conversation_crypto_states',
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
    );
  }

  @override
  Future<void> upsertGroupMembers(
    String conversationId,
    List<GroupMember> members,
  ) async {
    final db = _db;
    if (db == null) return;
    await db.transaction((txn) async {
      await txn.delete('group_members',
          where: 'conversation_id = ?', whereArgs: [conversationId]);
      for (final m in members) {
        await txn.insert('group_members', {
          'conversation_id': conversationId,
          'account_id': m.accountId,
          'username': m.username,
          'device_id': m.deviceId,
          'identity_pub_key': _intListToBlob(m.identityPubKey),
          'x25519_pub_key': _intListToBlob(m.x25519PubKey),
          'is_admin': m.isAdmin ? 1 : 0,
          'is_self': m.isSelf ? 1 : 0,
        });
      }
    });
  }

  @override
  Future<List<GroupMember>> getGroupMembers(String conversationId) async {
    final db = _db;
    if (db == null) return const [];
    return _groupMembersFor(db, conversationId);
  }

  @override
  Future<void> deleteGroupMember(String conversationId, String deviceId) async {
    final db = _db;
    if (db == null) return;
    await db.delete(
      'group_members',
      where: 'conversation_id = ? AND device_id = ?',
      whereArgs: [conversationId, deviceId],
    );
  }

  @override
  Future<void> deleteGroupMembersForConversation(String conversationId) async {
    final db = _db;
    if (db == null) return;
    await db.delete(
      'group_members',
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
    );
  }

  @override
  Future<void> updateConversationGroupFields(
    String conversationId, {
    String? groupName,
    int? mlsEpoch,
  }) async {
    final db = _db;
    if (db == null) return;
    final updates = <String, Object?>{};
    if (groupName != null) updates['group_name'] = groupName;
    if (mlsEpoch != null) updates['mls_epoch'] = mlsEpoch;
    if (updates.isEmpty) return;
    await db.update(
      'conversations',
      updates,
      where: 'id = ?',
      whereArgs: [conversationId],
    );
  }

  @override
  Future<void> markGroupDeleted(String conversationId) async {
    final db = _db;
    if (db == null) return;
    await db.insert(
      'deleted_groups',
      {
        'conversation_id': conversationId,
        'deleted_at': DateTime.now().toUtc().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<void> clearGroupDeleted(String conversationId) async {
    final db = _db;
    if (db == null) return;
    await db.delete(
      'deleted_groups',
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
    );
  }

  @override
  Future<Set<String>> loadDeletedGroupIds() async {
    final db = _db;
    if (db == null) return <String>{};
    final rows = await db.query('deleted_groups', columns: ['conversation_id']);
    return {for (final row in rows) row['conversation_id'] as String};
  }

  Future<List<GroupMember>> _groupMembersFor(
    Database db,
    String conversationId,
  ) async {
    final rows = await db.query(
      'group_members',
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
    );
    return rows.map(_groupMemberFromRow).toList(growable: false);
  }

  /// Every conversation's members in one query, bucketed by conversation id —
  /// the bulk form used by [loadConversations] to avoid a query per chat.
  Future<Map<String, List<GroupMember>>> _allGroupMembers(Database db) async {
    final rows = await db.query('group_members');
    final byConvo = <String, List<GroupMember>>{};
    for (final row in rows) {
      final convoId = row['conversation_id'] as String;
      (byConvo[convoId] ??= <GroupMember>[]).add(_groupMemberFromRow(row));
    }
    return byConvo;
  }

  GroupMember _groupMemberFromRow(Map<String, Object?> row) => GroupMember(
        accountId: row['account_id'] as String,
        username: row['username'] as String,
        deviceId: row['device_id'] as String,
        identityPubKey: _intList(row['identity_pub_key']),
        x25519PubKey: _intList(row['x25519_pub_key']),
        isAdmin: (row['is_admin'] as int) == 1,
        isSelf: (row['is_self'] as int) == 1,
      );

  ChatMessage _messageFromRow(Map<String, Object?> row) {
    final mediaKey = row['media_key'];
    final mediaSha = row['media_sha256'];
    final waveform = row['voice_waveform'];
    final pendingKey = row['pending_upload_key'];
    return ChatMessage(
      envelopeId: row['envelope_id'] as String,
      conversationId: row['conversation_id'] as String,
      senderDeviceId: row['sender_device_id'] as String,
      body: row['body'] as String,
      serverTs: DateTime.fromMillisecondsSinceEpoch(
        row['server_ts'] as int,
        isUtc: true,
      ),
      mine: (row['mine'] as int) == 1,
      outboxId: row['outbox_id'] as String?,
      clientMsgId: row['client_msg_id'] as String?,
      kind: MessageKind.fromName(row['kind'] as String?),
      mediaId: row['media_id'] as String?,
      mediaKey: mediaKey == null ? null : _intList(mediaKey),
      mediaSha256: mediaSha == null ? null : _intList(mediaSha),
      mediaSize: row['media_size'] as int?,
      mediaMime: row['media_mime'] as String?,
      mediaFilename: row['media_filename'] as String?,
      mediaDurationMs: row['media_duration_ms'] as int?,
      replyToEnvelopeId: row['reply_to_envelope_id'] as String?,
      replyToSender: row['reply_to_sender'] as String?,
      replyToPreview: row['reply_to_preview'] as String?,
      voiceWaveform: waveform == null ? null : _intList(waveform),
      failed: ((row['failed'] as int?) ?? 0) == 1,
      uploading: ((row['uploading'] as int?) ?? 0) == 1,
      pendingUploadKey: pendingKey == null ? null : _intList(pendingKey),
      deliveryStatus: MessageDeliveryStatus
          .values[(row['delivery_status'] as int?) ?? 0],
      forwarded: ((row['forwarded'] as int?) ?? 0) == 1,
      expiresAt: row['expires_at'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              row['expires_at'] as int,
              isUtc: true,
            ),
      reactions: _reactionsFromJson(row['reactions'] as String?),
      linkPreview: LinkPreview.tryDecode(row['link_preview'] as String?),
      edited: ((row['edited'] as int?) ?? 0) == 1,
      deliveredAt: _msToUtc(row['delivered_at'] as int?),
      readAt: _msToUtc(row['read_at'] as int?),
    );
  }

  static DateTime? _msToUtc(int? ms) =>
      ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);

  /// Decode the stored reactions JSON (reactor account id → emoji) back to a
  /// map; tolerates null/garbage by returning an empty map.
  Map<String, String> _reactionsFromJson(String? json) {
    if (json == null || json.isEmpty) return const {};
    try {
      final decoded = jsonDecode(json);
      if (decoded is! Map) return const {};
      return decoded.map((k, v) => MapEntry('$k', '$v'));
    } catch (_) {
      return const {};
    }
  }

  List<int> _intList(Object? blob) {
    if (blob == null) return const [];
    if (blob is List<int>) return List<int>.from(blob);
    if (blob is List) return blob.cast<int>();
    return const [];
  }

  /// sqflite only binds `Uint8List` (not `List<int>`) to BLOB columns —
  /// passing a plain `List<int>` logs a deprecation warning and is slated to
  /// throw in a future sqflite. Every byte column write goes through here.
  Uint8List _intListToBlob(List<int> bytes) => Uint8List.fromList(bytes);
}
