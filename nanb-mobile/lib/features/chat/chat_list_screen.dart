import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/design_tokens.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import '../../app/theme.dart';
import '../../core/network/connection_state.dart' as conn;
import 'conversations_notifier.dart';
import 'push_optin_prompt.dart';
import 'models/conversation.dart';
import 'models/conversation_kind.dart';
import 'models/message_kind.dart';
import 'models/system_event.dart';
import 'services/sticker_marker.dart';
import 'widgets/view_once_bubble.dart';
import 'widgets/connection_banner.dart';
import 'media_pipeline.dart';
import 'widgets/avatar_image.dart';
import 'widgets/message_status_ticks.dart';
import 'widgets/new_chat_or_group_sheet.dart';

/// Translated from `ChatListScreen` in the design source. Now backed by
/// `ConversationsNotifier` (real conversations + WS-driven updates).
class ChatListScreen extends ConsumerStatefulWidget {
  const ChatListScreen({super.key});

  @override
  ConsumerState<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends ConsumerState<ChatListScreen> {
  ConversationsNotifier? _connectedNotifier;
  bool _searching = false;
  final _searchCtrl = TextEditingController();

  /// When true the list shows ONLY archived conversations (the "Archived"
  /// folder); otherwise it shows the non-archived list.
  bool _showArchived = false;

  @override
  void initState() {
    super.initState();
    // One-time push opt-in prompt — push (Google FCM) is OFF by default for
    // privacy; this is where the user chooses. Shown after the first frame so a
    // dialog has a Navigator; self-gates on the pref so it only appears once.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      maybeShowPushOptIn(context, ref);
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _toggleSearch() {
    setState(() {
      _searching = !_searching;
      if (!_searching) _searchCtrl.clear();
    });
  }

  /// Case-insensitive name filter; a leading '@' in either the query or the
  /// stored username is ignored so '@bob', 'bob' and 'BOB' all match.
  List<Conversation> _filtered(List<Conversation> convos) {
    final q =
        _searchCtrl.text.trim().toLowerCase().replaceFirst(RegExp('^@'), '');
    if (q.isEmpty) return convos;
    return convos.where((c) {
      final name = c.kind == ConversationKind.group
          ? (c.groupName ?? '')
          : c.peerUsername;
      return name.toLowerCase().replaceFirst(RegExp('^@'), '').contains(q);
    }).toList(growable: false);
  }

  /// Connects (idempotently) on the current notifier, and re-connects if the
  /// provider is rebuilt with a *new* instance. That rebuild happens when the
  /// saved server URL finishes loading and changes `apiBaseUrlProvider` —
  /// which is the normal case for a custom server (e.g. a physical device on a
  /// LAN). A one-shot connect in `initState` would bind to the pre-load
  /// notifier, which then gets disposed by the rebuild, leaving the live
  /// instance never connected (stuck "Connecting…"). Watching for the instance
  /// swap in `build` fixes that.
  void _ensureConnected(ConversationsNotifier notifier) {
    if (identical(notifier, _connectedNotifier)) return;
    _connectedNotifier = notifier;
    Future.microtask(() async {
      try {
        await notifier.connect();
        // Disappearing-messages sweep — drops messages older than the user's
        // TTL preference. Cheap when nothing qualifies.
        final ttl =
            ref.read(appPreferencesProvider).value.disappearingDefault.ttl;
        await notifier.runDisappearingSweep(ttl);
        // Once we're signed in and on the chat list, surface the one-time
        // "display over other apps" rationale so incoming calls can ring
        // full-screen while the device is unlocked + backgrounded.
        if (mounted) await _maybePromptCallOverlay();
      } catch (_) {
        // A provider rebuild can dispose this notifier mid-connect; the
        // replacement instance re-triggers _ensureConnected on the next build.
      }
    });
  }

  /// Shows the call-overlay permission rationale at most once per device. The
  /// "display over other apps" permission has no in-place runtime dialog, so we
  /// explain why first and only send the user to settings if they opt in.
  /// Gated so it never reappears once shown (the gate also short-circuits when
  /// the permission is already granted).
  Future<void> _maybePromptCallOverlay() async {
    final gate = ref.read(overlayPermissionGateProvider);
    if (!await gate.needsPrompt()) return;
    await gate.markPrompted();
    if (!mounted) return;
    final allow = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Ring for calls'),
        content: const Text(
          'To show the full-screen call screen when someone calls you while '
          "you're using another app, allow Chat to display over other apps. "
          'Without it, incoming calls only appear as a notification.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('NOT NOW'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('ALLOW'),
          ),
        ],
      ),
    );
    if (allow == true) await gate.openSettings();
  }

  String _convoName(Conversation c) => c.kind == ConversationKind.group
      ? (c.groupName ?? '(unnamed group)')
      : c.peerUsername;

  /// Applies the current view (archived vs not) + search filter, then orders:
  /// pinned conversations first, then most-recent-message first.
  List<Conversation> _orderedVisible(List<Conversation> convos) {
    final searched = _filtered(convos);
    // Blocked conversations live only under Settings → Blocked — never in the
    // main or archived list.
    final inView = searched
        .where((c) => !c.blocked && c.archived == _showArchived)
        .toList();
    inView.sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      final at = a.lastMessage?.serverTs;
      final bt = b.lastMessage?.serverTs;
      if (at == null && bt == null) return 0;
      if (at == null) return 1;
      if (bt == null) return -1;
      return bt.compareTo(at); // newest first
    });
    return inView;
  }

  /// Long-press menu on a chat-list row: pin / mute / archive / delete.
  void _showConversationActions(Conversation c) {
    final notifier = ref.read(conversationsProvider);
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(
                  c.pinned ? Icons.push_pin : Icons.push_pin_outlined),
              title: Text(c.pinned ? 'Unpin' : 'Pin to top'),
              onTap: () {
                Navigator.pop(sheetCtx);
                notifier.setPinned(c.id, !c.pinned);
              },
            ),
            ListTile(
              leading: Icon(
                  c.muted ? Icons.notifications_off : Icons.notifications_outlined),
              title: Text(c.muted ? 'Unmute' : 'Mute notifications'),
              onTap: () {
                Navigator.pop(sheetCtx);
                notifier.setMuted(c.id, !c.muted);
              },
            ),
            ListTile(
              leading: Icon(
                  c.archived ? Icons.unarchive_outlined : Icons.archive_outlined),
              title: Text(c.archived ? 'Unarchive' : 'Archive'),
              onTap: () {
                Navigator.pop(sheetCtx);
                notifier.setArchived(c.id, !c.archived);
              },
            ),
            const Divider(height: 8),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete'),
              onTap: () {
                Navigator.pop(sheetCtx);
                _confirmDelete(c);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// Confirm, then delete the conversation locally. Deletion is device-local
  /// only — the peer keeps their copy and a new inbound message re-creates
  /// the conversation (see `ConversationsNotifier.deleteConversation`).
  Future<void> _confirmDelete(Conversation c) async {
    final isGroup = c.kind == ConversationKind.group;
    final name = _convoName(c);
    // An admin deleting a group disbands it for EVERY member; anyone else just
    // leaves (the unchanged behaviour and wording below).
    final disband = isGroup && c.isSelfGroupAdmin;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(disband ? 'Delete $name for everyone?' : 'Delete $name?'),
        content: Text(
          disband
              ? 'This deletes the group and all its messages for every member, '
                  'on all of their devices. This cannot be undone.'
              : isGroup
              ? "You'll leave the group and its messages will be deleted "
                  'from your devices.'
              : 'Deletes the messages from this device only. $name is not '
                  'notified and can still message you, which starts a new '
                  'conversation.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(disband ? 'Delete for everyone' : 'Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final notifier = ref.read(conversationsProvider);
    if (disband && await notifier.disbandGroup(c.id)) return;
    await notifier.deleteConversationEverywhere(c.id);
  }

  /// Confirm, then wipe the unreadable on-disk DB and restore persistence.
  /// Offered from the degraded-mode banner — the saved history is already
  /// inaccessible, so this only clears what can't be read; account + keys stay.
  Future<void> _confirmResetLocalDb() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Reset local data?'),
        content: const Text(
          "This device's saved message history is unreadable and can't be "
          'recovered. Resetting clears it so messages can save again. Your '
          'account and recovery phrase are unaffected, and messages still on '
          'the server re-sync.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await ref.read(conversationsProvider).recoverDegradedDatabase();
  }

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    final notifier = ref.watch(conversationsProvider);
    _ensureConnected(notifier);
    // Unsorted: [_orderedVisible] re-sorts (pinned-first) from scratch anyway,
    // so paying for the getter's own sort here would be wasted work.
    final convos = notifier.conversationsUnsorted;
    final visible = _orderedVisible(convos);
    final archivedCount =
        convos.where((c) => c.archived && !c.blocked).length;
    // The "Archived" entry shows at the top of the main list when archived
    // conversations exist and the user isn't mid-search.
    final showArchivedEntry =
        !_showArchived && !_searching && archivedCount > 0;
    return Scaffold(
      backgroundColor: t.bg,
      body: SafeArea(
        child: Column(
          children: [
            _TopBar(
              t: t,
              searching: _searching,
              searchController: _searchCtrl,
              onToggleSearch: _toggleSearch,
              onQueryChanged: (_) => setState(() {}),
              archivedTitle: _showArchived ? 'Archived' : null,
              onBackFromArchived:
                  _showArchived ? () => setState(() => _showArchived = false) : null,
            ),
            const ConnectionBanner(),
            _StatusStrip(
              t: t,
              state: notifier.connectionState,
              // True only when traffic is genuinely flowing over the embedded
              // Tor onion path: the flag is on, the user enabled it, AND the
              // engine has bootstrapped (fail-closed sentinel until then). The
              // strip rebuilds when the Tor controller flips to connected.
              onion: kBuiltInTorEnabled &&
                  ref.watch(appPreferencesProvider).value.builtInTorEnabled &&
                  ref.watch(torControllerProvider).isConnected,
              // Tor is the chosen transport (independent of bootstrap state) →
              // the connecting/reconnecting label reads "VIA TOR".
              torSelected: kBuiltInTorEnabled &&
                  ref.watch(appPreferencesProvider).value.builtInTorEnabled,
            ),
            if (notifier.databaseDegradedToMemory)
              _DegradedDbBanner(t: t, onReset: _confirmResetLocalDb),
            if (showArchivedEntry)
              _ArchivedEntry(
                t: t,
                count: archivedCount,
                onTap: () => setState(() => _showArchived = true),
              ),
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: convos.isEmpty
                        ? (notifier.hydrated
                            ? _EmptyState(t: t)
                            : _ListLoading(t: t))
                        : visible.isEmpty
                            ? (_searching
                                ? _NoMatches(t: t, query: _searchCtrl.text)
                                : _ShelfEmpty(
                                    t: t,
                                    archived: _showArchived,
                                  ))
                            : _ChatRows(
                                t: t,
                                conversations: visible,
                                onLongPress: _showConversationActions,
                                nameFor: notifier.displayNameFor,
                                avatarFor: notifier.peerAvatarDescriptor,
                              ),
                  ),
                  // Connecting finishes BEFORE the backlog drains, so a cold
                  // start opened on a stale list that silently rearranged a few
                  // seconds later — the new message's conversation appearing
                  // with no explanation. This covers exactly that window.
                  // Only over the list: the top bar and the connection banner
                  // stay legible, and the empty/loading states already have
                  // their own affordance.
                  //
                  // Gated on [catchupBacklog], NOT on `!catchupSettled` alone.
                  // The settled flag is re-armed at the top of connect(), before
                  // anything knows whether there IS a backlog, so keying on it
                  // veiled the list on every cold start — including the ordinary
                  // one that fetches nothing and settles in ~270ms, where the
                  // veil was the only reason opening the app looked like it had
                  // a second phase at all. It also raced the "Connecting…"
                  // banner, showing two contradictory progress messages at once.
                  // A count > 0 means a page really came back with envelopes to
                  // drain, which is precisely when the list is about to move.
                  if (!notifier.catchupSettled &&
                      notifier.catchupBacklog > 0 &&
                      convos.isNotEmpty)
                    Positioned.fill(child: _SyncingOverlay(t: t)),
                ],
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: t.accent,
        foregroundColor: t.accentOn,
        elevation: 6,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        onPressed: () => showModalBottomSheet<void>(
          context: context,
          backgroundColor: Colors.transparent,
          builder: (_) => const NewChatOrGroupSheet(),
        ),
        child: const Icon(Icons.edit_outlined, size: 22),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.t,
    required this.searching,
    required this.searchController,
    required this.onToggleSearch,
    required this.onQueryChanged,
    this.archivedTitle,
    this.onBackFromArchived,
  });
  final DesignTokens t;
  final bool searching;
  final TextEditingController searchController;
  final VoidCallback onToggleSearch;
  final ValueChanged<String> onQueryChanged;

  /// Non-null when viewing the Archived folder — renders a back arrow + this
  /// title instead of the app name + search.
  final String? archivedTitle;
  final VoidCallback? onBackFromArchived;

  @override
  Widget build(BuildContext context) {
    if (archivedTitle != null) {
      return Container(
        padding: const EdgeInsets.fromLTRB(8, 14, 16, 10),
        decoration: BoxDecoration(
          color: t.surface,
          border: Border(bottom: BorderSide(color: t.border)),
        ),
        child: Row(
          children: [
            IconButton(
              icon: Icon(Icons.arrow_back, color: t.text),
              iconSize: 20,
              onPressed: onBackFromArchived,
            ),
            Text(
              archivedTitle!,
              style: monoStyle(
                fontSize: 13,
                color: t.text,
                letterSpacing: 2,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
      decoration: BoxDecoration(
        color: t.surface,
        border: Border(bottom: BorderSide(color: t.border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: searching
                ? TextField(
                    controller: searchController,
                    autofocus: true,
                    onChanged: onQueryChanged,
                    style: monoStyle(fontSize: 13, color: t.text),
                    decoration: InputDecoration(
                      hintText: 'Search conversations…',
                      hintStyle: monoStyle(fontSize: 13, color: t.textFaint),
                      isDense: true,
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.zero,
                    ),
                  )
                : Text(
                    'Chat',
                    style: monoStyle(
                      fontSize: 13,
                      color: t.text,
                      letterSpacing: 3,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
          ),
          IconButton(
            icon: Icon(searching ? Icons.close : Icons.search,
                color: t.textMuted),
            iconSize: 20,
            padding: const EdgeInsets.all(4),
            constraints: const BoxConstraints(),
            onPressed: onToggleSearch,
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: Icon(Icons.more_vert, color: t.textMuted),
            iconSize: 20,
            padding: const EdgeInsets.all(4),
            constraints: const BoxConstraints(),
            onPressed: () => context.push(Routes.settings),
          ),
        ],
      ),
    );
  }
}

/// Shown when a search query matches no conversation names.
class _NoMatches extends StatelessWidget {
  const _NoMatches({required this.t, required this.query});
  final DesignTokens t;
  final String query;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          'No conversations match "$query"',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: t.textMuted),
        ),
      ),
    );
  }
}

/// Tappable "Archived" row pinned above the main list.
class _ArchivedEntry extends StatelessWidget {
  const _ArchivedEntry({
    required this.t,
    required this.count,
    required this.onTap,
  });
  final DesignTokens t;
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: t.border)),
        ),
        child: Row(
          children: [
            Icon(Icons.archive_outlined, size: 20, color: t.textMuted),
            const SizedBox(width: 12),
            Text(
              'Archived',
              style: TextStyle(fontSize: 14, color: t.text),
            ),
            const Spacer(),
            Text(
              '$count',
              style: monoStyle(fontSize: 12, color: t.textMuted),
            ),
            const SizedBox(width: 4),
            Icon(Icons.chevron_right, size: 18, color: t.textFaint),
          ],
        ),
      ),
    );
  }
}

/// Warns that the on-disk SQLCipher database couldn't be opened and the session
/// is running in-memory (nothing persists). Offers a Reset that wipes the
/// unreadable file and restores persistence. Shown only while
/// [ConversationsNotifier.databaseDegradedToMemory].
class _DegradedDbBanner extends StatelessWidget {
  const _DegradedDbBanner({required this.t, required this.onReset});
  final DesignTokens t;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      decoration: BoxDecoration(
        color: t.warn.withValues(alpha: 0.12),
        border: Border(bottom: BorderSide(color: t.border)),
      ),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, size: 18, color: t.warn),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              "Local history unavailable on this device — messages aren't being "
              'saved. Tap Reset to fix.',
              style: TextStyle(fontSize: 12, color: t.text, height: 1.3),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: onReset,
            style: TextButton.styleFrom(
              foregroundColor: t.warn,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              minimumSize: const Size(0, 32),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(
              'RESET',
              style: monoStyle(
                fontSize: 11,
                color: t.warn,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.6,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Empty state for a shelf (main list with everything archived, or an empty
/// Archived folder).
class _ShelfEmpty extends StatelessWidget {
  const _ShelfEmpty({required this.t, required this.archived});
  final DesignTokens t;
  final bool archived;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          archived ? 'No archived conversations' : 'No conversations',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: t.textMuted),
        ),
      ),
    );
  }
}

class _StatusStrip extends StatelessWidget {
  const _StatusStrip({
    required this.t,
    required this.state,
    this.onion = false,
    this.torSelected = false,
  });
  final DesignTokens t;
  final conn.ConnectionState state;

  /// Whether Tor is the selected transport (built-in Tor on), independent of
  /// whether it has finished bootstrapping. Drives a "VIA TOR" connection label
  /// so the user knows the connecting phase is the Tor path, not clearnet.
  final bool torSelected;

  /// Whether the connection is currently routing over the Tor onion service.
  /// Surfaces an `ONION` badge next to the connection label so the user can see
  /// at a glance that traffic is anonymised (and not silently on clearnet).
  final bool onion;

  @override
  Widget build(BuildContext context) {
    // Reflect the real supervisor state — a hardcoded "CONNECTED" here once
    // masked a supervisor that never noticed dead connections.
    final connected = state == conn.ConnectionState.connected;
    final label = switch (state) {
      conn.ConnectionState.connected => 'CONNECTED · E2EE',
      conn.ConnectionState.connecting =>
        torSelected ? 'CONNECTING VIA TOR…' : 'CONNECTING…',
      conn.ConnectionState.reconnecting =>
        torSelected ? 'RECONNECTING VIA TOR…' : 'RECONNECTING…',
      conn.ConnectionState.signedOut => 'SIGNED OUT',
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: t.surfaceAlt,
        border: Border(bottom: BorderSide(color: t.border)),
      ),
      child: Row(
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: connected ? t.accent : t.warn,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: monoStyle(
                fontSize: 10,
                color: t.textMuted,
                letterSpacing: 0.4,
              ),
            ),
          ),
          if (onion) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: t.accent.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                'ONION',
                style: monoStyle(
                  fontSize: 9,
                  color: t.accent,
                  letterSpacing: 0.6,
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
          Text(
            'v1 · nanb.link',
            style: monoStyle(
              fontSize: 10,
              color: t.textFaint,
            ),
          ),
        ],
      ),
    );
  }
}

/// Shown during the cold-start disk read, before hydration completes — a
/// quiet spinner instead of flashing the "no conversations yet" empty state
/// at a user who actually has chats.
/// Translucent "catching up" veil over the conversation list, shown from the
/// moment the socket is up until the first catchup drain settles.
///
/// That gap is real and user-visible: `connect()` returns once the socket and
/// the MLS reconcile are done, but the BACKLOG drains afterwards — so a cold
/// start opened on a stale list that rearranged itself a few seconds later,
/// with the new message's conversation appearing out of nowhere.
///
/// Deliberately `IgnorePointer`: the list underneath stays fully usable and
/// tappable, so this can only ever look like a hint, never trap the user —
/// which matters because a catchup that never settles would otherwise leave a
/// permanent modal veil.
class _SyncingOverlay extends StatelessWidget {
  const _SyncingOverlay({required this.t});
  final DesignTokens t;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        color: t.bg.withValues(alpha: 0.72),
        alignment: Alignment.center,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child:
                  CircularProgressIndicator(strokeWidth: 2, color: t.textFaint),
            ),
            const SizedBox(width: 10),
            Text(
              'Catching up…',
              style: TextStyle(color: t.textFaint, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

class _ListLoading extends StatelessWidget {
  const _ListLoading({required this.t});
  final DesignTokens t;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SizedBox(
        width: 26,
        height: 26,
        child: CircularProgressIndicator(strokeWidth: 2, color: t.textFaint),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.t});
  final DesignTokens t;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.chat_bubble_outline, size: 56, color: t.textFaint),
            const SizedBox(height: 16),
            Text(
              'No conversations yet',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: t.text),
            ),
            const SizedBox(height: 8),
            Text(
              "Tap the pencil to find someone by their @handle and start chatting.",
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: t.textMuted, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChatRows extends StatelessWidget {
  const _ChatRows({
    required this.t,
    required this.conversations,
    required this.onLongPress,
    required this.nameFor,
    required this.avatarFor,
  });
  final DesignTokens t;
  final List<Conversation> conversations;
  final void Function(Conversation) onLongPress;

  /// Resolves a conversation's display name (peer display name / @username /
  /// group name) — supplied by the parent from the conversations notifier.
  final String Function(Conversation) nameFor;

  /// Resolves a 1:1 peer's avatar descriptor (encrypted media), or null.
  final MediaDescriptor? Function(Conversation) avatarFor;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      itemCount: conversations.length,
      itemBuilder: (context, i) {
        final c = conversations[i];
        return InkWell(
          onTap: () =>
              context.push(Routes.chat.replaceFirst(':conversationId', c.id)),
          onLongPress: () => onLongPress(c),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: t.border)),
            ),
            child: Row(
              children: [
                c.kind == ConversationKind.group
                    ? _GroupAvatar(
                        t: t,
                        size: 44,
                        name: nameFor(c),
                        avatar: avatarFor(c),
                      )
                    : AvatarImage(
                        name: nameFor(c),
                        descriptor: avatarFor(c),
                        size: 44,
                      ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _NameRow(t: t, c: c, name: nameFor(c)),
                      const SizedBox(height: 2),
                      _LastRow(t: t, c: c),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _NameRow extends StatelessWidget {
  const _NameRow({required this.t, required this.c, required this.name});
  final DesignTokens t;
  final Conversation c;

  /// Resolved display name (peer's display name or @username; group name for
  /// groups) — computed by the parent from the conversations notifier.
  final String name;

  @override
  Widget build(BuildContext context) {
    final lastTs = c.lastMessage?.serverTs;
    return Row(
      children: [
        Expanded(
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: monoStyle(fontSize: 14, color: t.text, fontWeight: FontWeight.w500),
          ),
        ),
        if (c.muted) ...[
          Icon(Icons.notifications_off, size: 13, color: t.textFaint),
          const SizedBox(width: 4),
        ],
        if (c.pinned) ...[
          Icon(Icons.push_pin, size: 13, color: t.textMuted),
          const SizedBox(width: 4),
        ],
        if (c.pending) ...[
          _RequestBadge(t: t),
          const SizedBox(width: 6),
        ],
        if (lastTs != null)
          Text(
            _formatTime(lastTs),
            style: monoStyle(
              fontSize: 10,
              color: t.textFaint,
              letterSpacing: 0.3,
            ),
          ),
      ],
    );
  }
}

class _LastRow extends StatelessWidget {
  const _LastRow({required this.t, required this.c});
  final DesignTokens t;
  final Conversation c;

  @override
  Widget build(BuildContext context) {
    final last = c.lastMessage;
    // System messages (call logs, key-change notices, etc.) carry a JSON body —
    // render the human-readable line, not the raw JSON. No "You:" prefix on them.
    final isSystem = last?.kind == MessageKind.system;
    final body = last == null
        ? '(no messages)'
        : isSystem
            ? (SystemEvent.tryDecode(last.body)?.displayText ?? '')
            : last.viewOnce
                ? ViewOnceBubble.label(last)
                : StickerMarker.isSticker(last)
                    ? '🏷️ Sticker'
                    : last.body;
    // WhatsApp-style: an outgoing last message shows its delivery ticks in
    // place of the old "You:" label; incoming / system rows are unchanged.
    final isMine = last?.mine == true && !isSystem;
    return Row(
      children: [
        if (isMine) ...[
          MessageStatusTicks(message: last!, t: t),
          const SizedBox(width: 3),
        ],
        Expanded(
          child: Text(
            body,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 13, color: t.textMuted),
          ),
        ),
        if (c.unreadCount > 0) _UnreadBadge(count: c.unreadCount, t: t),
      ],
    );
  }
}

/// Marker for a pending message request (inbound conversation from a sender
/// the user never contacted) — accepted/rejected from the chat thread.
class _RequestBadge extends StatelessWidget {
  const _RequestBadge({required this.t});
  final DesignTokens t;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: t.warn),
      ),
      child: Text(
        'REQUEST',
        style: monoStyle(
          fontSize: 8.5,
          color: t.warn,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}

class _UnreadBadge extends StatelessWidget {
  const _UnreadBadge({required this.count, required this.t});
  final int count;
  final DesignTokens t;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 18),
      height: 18,
      padding: const EdgeInsets.symmetric(horizontal: 5),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: t.accent,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Text(
        '$count',
        style: monoStyle(
          fontSize: 10,
          color: t.accentOn,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}

class _GroupAvatar extends StatelessWidget {
  const _GroupAvatar({
    required this.t,
    required this.size,
    required this.name,
    this.avatar,
  });
  final DesignTokens t;
  final double size;
  final String name;
  final MediaDescriptor? avatar;

  @override
  Widget build(BuildContext context) {
    if (avatar != null) {
      return AvatarImage(name: name, descriptor: avatar, size: size);
    }
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: t.surfaceAlt,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: t.border),
      ),
      child: Icon(Icons.group_outlined, size: size * 0.45, color: t.textMuted),
    );
  }
}

String _formatTime(DateTime ts) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final tsLocal = ts.toLocal();
  final tsDay = DateTime(tsLocal.year, tsLocal.month, tsLocal.day);
  if (tsDay == today) {
    final hh = tsLocal.hour.toString().padLeft(2, '0');
    final mm = tsLocal.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }
  final yesterday = today.subtract(const Duration(days: 1));
  if (tsDay == yesterday) return 'Yesterday';
  return '${tsLocal.month}/${tsLocal.day}';
}
