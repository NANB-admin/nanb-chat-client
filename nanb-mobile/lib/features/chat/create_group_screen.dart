import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/design_tokens.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import 'conversations_notifier.dart';
import 'models/conversation.dart';
import 'models/conversation_kind.dart';
import 'models/group_member_unavailable_exception.dart';
import 'models/member_seed.dart';
import 'services/group_photo_picker.dart';
import 'widgets/nanb_avatar.dart';

/// Plan C §10.2 — two-step create-group flow.
///
/// Step 1: multi-select existing 1:1 contacts (2..31 inclusive).
/// Step 2: enter group name (max 40 chars, trim+non-empty).
/// On Create: dispatch to `ConversationsNotifier.createGroup` and
/// navigate to the new conversation's thread on success.
class CreateGroupScreen extends ConsumerStatefulWidget {
  const CreateGroupScreen({super.key, required this.selfUsername});

  /// The current user's @username — passed to `createGroup` so the
  /// notifier can look up own account info via the API.
  final String selfUsername;

  @override
  ConsumerState<CreateGroupScreen> createState() => _CreateGroupScreenState();
}

class _CreateGroupScreenState extends ConsumerState<CreateGroupScreen> {
  int _step = 0;
  final Set<String> _selectedConvoIds = {};
  // People added by username who aren't existing 1:1 contacts.
  final List<MemberSeed> _addedSeeds = [];
  final TextEditingController _nameCtl = TextEditingController();
  final TextEditingController _usernameCtl = TextEditingController();
  bool _submitting = false;
  PickedGroupPhoto? _photo;
  bool _addingUser = false;

  @override
  void dispose() {
    _nameCtl.dispose();
    _usernameCtl.dispose();
    super.dispose();
  }

  int get _memberCount => _selectedConvoIds.length + _addedSeeds.length;

  Future<void> _pickPhoto() async {
    try {
      ref.read(appLockControllerProvider).suppressNextBackgroundLock();
      final photo =
          await GroupPhotoPicker(ref.read(mediaPipelineProvider)).pick();
      if (photo != null && mounted) setState(() => _photo = photo);
    } catch (e) {
      _toast('Couldn’t pick that photo: $e');
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  /// Looks up a typed username and adds them as a group member even if there's
  /// no existing 1:1 with them.
  Future<void> _addByUsername() async {
    if (_addingUser) return;
    final raw = _usernameCtl.text.trim();
    final cleaned = raw.startsWith('@') ? raw.substring(1) : raw;
    if (cleaned.isEmpty) return;
    final selfClean = widget.selfUsername.startsWith('@')
        ? widget.selfUsername.substring(1)
        : widget.selfUsername;
    if (cleaned.toLowerCase() == selfClean.toLowerCase()) {
      _toast("You're already in the group.");
      return;
    }
    setState(() => _addingUser = true);
    try {
      final notifier = ref.read(conversationsProvider);
      final seed = await notifier.resolveGroupMemberByUsername(cleaned);
      final dupe = _addedSeeds.any((s) => s.accountId == seed.accountId) ||
          _selectedConvoIds.any(
              (id) => notifier.byId(id)?.peerAccountId == seed.accountId);
      setState(() {
        if (!dupe) _addedSeeds.add(seed);
        _usernameCtl.clear();
      });
      if (dupe) _toast('@${seed.username} is already added.');
    } catch (_) {
      _toast('No user "@$cleaned" found.');
    } finally {
      if (mounted) setState(() => _addingUser = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final notifier = ref.watch(conversationsProvider);
    final candidates = notifier.conversations
        .where((c) => c.kind == ConversationKind.oneToOne)
        .toList();
    final t = DesignTokens.of(context);
    return Scaffold(
      backgroundColor: t.bg,
      body: SafeArea(
        child: _step == 0
            ? _buildStep1(candidates, t)
            : _buildStep2(notifier, t),
      ),
    );
  }

  Widget _buildStep1(List<Conversation> candidates, DesignTokens t) {
    final canAdvance = _memberCount >= 2 && _memberCount <= 31;
    return Column(
      children: [
        _TopBar(
          t: t,
          title: 'New group · select members',
          onBack: () => Navigator.of(context).maybePop(),
        ),
        // Add anyone by username — even if you've never had a 1:1 with them.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _usernameCtl,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _addByUsername(),
                  decoration: const InputDecoration(
                    labelText: 'Add by username',
                    hintText: '@username',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _addingUser ? null : _addByUsername,
                child: _addingUser
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Add'),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            children: [
              // People added by username (removable).
              for (final s in _addedSeeds)
                ListTile(
                  key: ValueKey('added-${s.accountId}'),
                  leading: NanbAvatar(name: s.username, size: 36),
                  title: Text('@${s.username}'),
                  trailing: IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => setState(() => _addedSeeds.remove(s)),
                  ),
                ),
              // Existing 1:1 contacts (multi-select).
              for (final c in candidates)
                CheckboxListTile(
                  key: ValueKey('contact-${c.id}'),
                  value: _selectedConvoIds.contains(c.id),
                  onChanged: (v) => setState(() {
                    if (v == true) {
                      _selectedConvoIds.add(c.id);
                    } else {
                      _selectedConvoIds.remove(c.id);
                    }
                  }),
                  title: Text(c.peerUsername),
                  secondary: NanbAvatar(name: c.peerUsername, size: 36),
                ),
              if (candidates.isEmpty && _addedSeeds.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'No contacts yet — add people by username above.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: t.textMuted),
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: canAdvance ? () => setState(() => _step = 1) : null,
              child: Text('Next ($_memberCount)'),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildStep2(ConversationsNotifier notifier, DesignTokens t) {
    final trimmed = _nameCtl.text.trim();
    final canCreate = trimmed.isNotEmpty && trimmed.length <= 40 && !_submitting;
    return Column(
      children: [
        _TopBar(
          t: t,
          title: 'Name the group',
          onBack: () => setState(() => _step = 0),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 20),
          child: GestureDetector(
            key: const ValueKey('group-photo-picker'),
            onTap: _submitting ? null : _pickPhoto,
            child: Column(
              children: [
                CircleAvatar(
                  radius: 44,
                  backgroundColor: t.surfaceAlt,
                  backgroundImage: _photo == null
                      ? null
                      : MemoryImage(Uint8List.fromList(_photo!.bytes)),
                  child: _photo == null
                      ? Icon(Icons.add_a_photo_outlined,
                          size: 28, color: t.textMuted)
                      : null,
                ),
                const SizedBox(height: 6),
                Text(
                  _photo == null ? 'Add group photo (optional)' : 'Change photo',
                  style: TextStyle(fontSize: 12, color: t.textMuted),
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: TextField(
            controller: _nameCtl,
            maxLength: 40,
            decoration: const InputDecoration(
              labelText: 'Group name',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: canCreate ? () => _create(notifier, trimmed) : null,
              child: _submitting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Create'),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _create(ConversationsNotifier notifier, String name) async {
    setState(() => _submitting = true);
    try {
      // Members come from two sources: people added by username (_addedSeeds)
      // and selected existing 1:1 contacts.
      final seeds = <MemberSeed>[..._addedSeeds];
      for (final id in _selectedConvoIds) {
        final c = notifier.byId(id);
        if (c == null) {
          throw StateError('selected conversation $id no longer exists');
        }
        seeds.add(MemberSeed(
          accountId: c.peerAccountId,
          username: c.peerUsername,
          deviceId: c.peerDeviceId,
          identityPubKey: c.peerIdentityPubKey,
          x25519PubKey: c.peerX25519PubKey,
        ));
      }
      final newId = await notifier.createGroup(
        groupName: name,
        selfUsername: widget.selfUsername,
        initialMembers: seeds,
      );
      // The photo is best-effort: the group already exists, so a failed upload
      // must not report the whole creation as failed. Admins can retry from
      // group info.
      final photo = _photo;
      if (photo != null) {
        try {
          final json =
              await GroupPhotoPicker(ref.read(mediaPipelineProvider))
                  .upload(photo);
          await notifier.setGroupAvatar(newId, json);
        } catch (_) {
          _toast('Group created, but the photo couldn’t be uploaded.');
        }
      }
      if (mounted) {
        context.go(Routes.chat.replaceFirst(':conversationId', newId));
      }
    } catch (e) {
      if (mounted) {
        final msg = e is GroupMemberUnavailableException
            ? e.toString()
            : 'Couldn’t create the group: $e';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg)),
        );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.t,
    required this.title,
    required this.onBack,
  });
  final DesignTokens t;
  final String title;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: t.surface,
        border: Border(bottom: BorderSide(color: t.border)),
      ),
      child: Row(
        children: [
          IconButton(
            icon: Icon(Icons.arrow_back, color: t.text),
            onPressed: onBack,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              style: TextStyle(fontSize: 14, color: t.text),
            ),
          ),
        ],
      ),
    );
  }
}
