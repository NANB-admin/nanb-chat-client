import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/design_tokens.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import '../../app/theme.dart';
import '../../core/models/incoming_share.dart';
import '../../core/network/connection_state.dart' as conn;
import 'conversations_notifier.dart';
import 'models/conversation.dart';
import 'models/conversation_kind.dart';
import 'services/share_dispatcher.dart';
import 'widgets/conversation_multi_picker.dart';

/// "Share to…" — where content handed to us by the OS share sheet lands.
///
/// Opened by `NanbApp` when a pending share is collected (see
/// `IncomingShareChannel`). Picking a conversation sends the shared text/files
/// through the ordinary E2EE send paths and drops the user into that thread, so
/// the share behaves exactly like composing the same message in-app.
class ShareTargetScreen extends ConsumerStatefulWidget {
  const ShareTargetScreen({super.key, required this.share});

  final IncomingShare share;

  @override
  ConsumerState<ShareTargetScreen> createState() => _ShareTargetScreenState();
}

class _ShareTargetScreenState extends ConsumerState<ShareTargetScreen> {
  /// Guards against a double-tap sending the share into two conversations.
  bool _sending = false;

  /// Conversation ids ticked as recipients. Insertion-ordered so the share goes
  /// out in the order the user picked.
  final Set<String> _selected = <String>{};
  final TextEditingController _filter = TextEditingController();

  /// The notifier this screen has already driven a connect on.
  ConversationsNotifier? _connectedNotifier;

  @override
  void initState() {
    super.initState();
    _filter.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  /// Conversations a share can go to: same rule as the in-thread "Forward to…"
  /// picker — no pending requests, no groups we've been removed from, no
  /// half-formed 1:1s.
  List<Conversation> _targets(List<Conversation> all) {
    final query = _filter.text.trim().toLowerCase();
    final notifier = ref.read(conversationsProvider);
    return all
        .where((c) =>
            !c.pending &&
            (c.kind == ConversationKind.group
                ? c.members.any((m) => m.isSelf)
                : c.peerAccountId.isNotEmpty))
        .where((c) =>
            query.isEmpty ||
            notifier.displayNameFor(c).toLowerCase().contains(query))
        .toList(growable: false);
  }

  void _toggle(Conversation c) {
    setState(() {
      if (!_selected.remove(c.id)) _selected.add(c.id);
    });
  }

  Future<void> _shareToSelected() async {
    if (_sending || _selected.isEmpty) return;
    setState(() => _sending = true);
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    final notifier = ref.read(conversationsProvider);
    final ids = _selected.toList(growable: false);
    final firstName = notifier.displayNameFor(
        notifier.conversations.firstWhere((c) => c.id == ids.first));
    try {
      final session = await ref.read(sessionRepositoryProvider).current();
      if (session == null) {
        messenger.showSnackBar(
          const SnackBar(content: Text('No active session.')),
        );
        return;
      }
      final perConversation = await ShareDispatcher(notifier).deliverToAll(
        share: widget.share,
        conversationIds: ids,
        myDeviceId: session.deviceId,
      );
      final expected = widget.share.messageCount;
      final reached =
          ids.where((id) => (perConversation[id] ?? 0) > 0).toList();
      if (reached.isEmpty) {
        messenger.showSnackBar(
          const SnackBar(content: Text("Couldn't share that content.")),
        );
        return;
      }
      final partial = reached.any((id) => perConversation[id]! < expected);
      // One recipient: land in that thread — the share sheet's implicit promise
      // is "this is now a message in that chat". Several: the chat list.
      if (ids.length == 1) {
        router.go('/chat/${ids.first}');
      } else {
        router.go(Routes.chatList);
      }
      _clearPendingShare();
      final where = ids.length == 1 ? firstName : '${reached.length} chats';
      messenger.showSnackBar(
        SnackBar(
          content: Text(reached.length < ids.length
              ? 'Shared to $where — ${ids.length - reached.length} failed.'
              : partial
                  ? 'Shared to $where — some files were too large or '
                      'unreadable.'
                  : 'Shared to $where'),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Share failed: $e')));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// True while the first hydrate is still in flight and there is genuinely
  /// nothing to show yet. Once anything has loaded — or the connection has
  /// settled, including offline — the real empty state is honest.
  bool _loading(ConversationsNotifier notifier) =>
      notifier.conversations.isEmpty &&
      notifier.connectionState == conn.ConnectionState.connecting &&
      _filter.text.trim().isEmpty;

  /// Loads the conversations (and brings the socket up), the same way
  /// `ChatListScreen` does.
  ///
  /// REQUIRED because a share can cold-start the app straight onto this
  /// screen, without the chat list ever being built — and `connect()` is what
  /// hydrates conversations from the local database. Without this the picker
  /// came up empty on a cold-start share (seen on device). `connect()` is
  /// idempotent and concurrent callers piggy-back, so reaching this screen from
  /// a warm app is a no-op. Re-run when the provider swaps the notifier
  /// instance (a server-URL change rebuilds it), same as the chat list.
  void _ensureConnected(ConversationsNotifier notifier) {
    if (identical(notifier, _connectedNotifier)) return;
    _connectedNotifier = notifier;
    Future.microtask(() async {
      try {
        await notifier.connect();
      } catch (_) {
        // A provider rebuild can dispose this notifier mid-connect; the
        // replacement re-triggers this on the next build.
      }
    });
  }

  /// Drops the collected payload once the share has been dealt with, so a
  /// later navigation to `/share` can't re-offer content already sent.
  void _clearPendingShare() {
    ref.read(pendingShareProvider.notifier).state = null;
  }

  /// Leaves the share flow for the chat list, discarding the payload.
  void _cancel() {
    context.go(Routes.chatList);
    _clearPendingShare();
  }

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    final notifier = ref.watch(conversationsProvider);
    _ensureConnected(notifier);
    final targets = _targets(notifier.conversations);
    // The screen is reached with `go` (see NanbApp — `push` doesn't survive the
    // router refreshes a cold start causes), so there is no route below it to
    // pop to. Intercept the system back gesture and route to the chat list
    // rather than letting it drop out of the app.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _cancel();
      },
      child: _buildScaffold(context, t, notifier, targets),
    );
  }

  Widget _buildScaffold(
    BuildContext context,
    DesignTokens t,
    ConversationsNotifier notifier,
    List<Conversation> targets,
  ) {
    return Scaffold(
      backgroundColor: t.bg,
      appBar: AppBar(
        backgroundColor: t.surface,
        title: const Text('Share to'),
        // A share is a one-shot flow: closing it discards the payload rather
        // than leaving it parked (it has already been consumed natively).
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Cancel',
          onPressed: _cancel,
        ),
      ),
      body: Column(
        children: [
          _SharePreview(share: widget.share, tokens: t),
          if (_sending) LinearProgressIndicator(color: t.accent),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: TextField(
              controller: _filter,
              style: monoStyle(fontSize: 13, color: t.text),
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: Icon(Icons.search, size: 18, color: t.textFaint),
                hintText: 'Search chats',
                hintStyle: monoStyle(fontSize: 13, color: t.textFaint),
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          Expanded(
            child: targets.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      // A cold-start share reaches this screen while the
                      // conversations are still hydrating, so "you have none"
                      // would be a lie for the first second — show the load
                      // instead, and only claim empty once it has settled.
                      child: _loading(notifier)
                          ? CircularProgressIndicator(color: t.accent)
                          : Text(
                              _filter.text.trim().isEmpty
                                  ? 'No conversations to share to yet.'
                                  : 'No chats match that search.',
                              style:
                                  monoStyle(fontSize: 13, color: t.textMuted),
                              textAlign: TextAlign.center,
                            ),
                    ),
                  )
                : ConversationMultiPicker(
                    notifier: notifier,
                    conversations: targets,
                    selectedIds: _selected,
                    onToggle: _toggle,
                    enabled: !_sending,
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  key: const ValueKey('share-send'),
                  onPressed:
                      _selected.isEmpty || _sending ? null : _shareToSelected,
                  icon: const Icon(Icons.send),
                  label: Text(_selected.isEmpty
                      ? 'Select chats'
                      : 'Send to ${_selected.length}'),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Summary of what's about to be shared, so the user can see they picked the
/// right thing before choosing a chat.
class _SharePreview extends StatelessWidget {
  const _SharePreview({required this.share, required this.tokens});

  final IncomingShare share;
  final DesignTokens tokens;

  @override
  Widget build(BuildContext context) {
    final parts = <String>[];
    if (share.attachments.isNotEmpty) {
      parts.add(share.attachments.length == 1
          ? share.attachments.first.filename
          : '${share.attachments.length} files');
    }
    if (share.text.isNotEmpty) parts.add(share.text);
    return Container(
      width: double.infinity,
      color: tokens.surfaceAlt,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'SHARING',
            style: monoStyle(
              fontSize: 10,
              color: tokens.textFaint,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            parts.join(' · '),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: monoStyle(fontSize: 12, color: tokens.textMuted),
          ),
        ],
      ),
    );
  }
}
