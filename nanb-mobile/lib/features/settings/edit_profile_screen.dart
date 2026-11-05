import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../app/design_tokens.dart';
import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/models/api_error.dart';
import '../chat/models/message_kind.dart';
import '../chat/widgets/avatar_image.dart';
import 'widgets/settings_scaffold.dart';

/// Lets the user set their own display name (shown to peers in the chat list +
/// thread). Persists to the server via PATCH /accounts/me and caches it locally
/// so the settings identity card renders without a network hit.
class EditProfileScreen extends ConsumerStatefulWidget {
  const EditProfileScreen({super.key});

  /// Mirrors the server cap (`identity.MaxDisplayNameLen`).
  static const int maxLength = 64;

  @override
  ConsumerState<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends ConsumerState<EditProfileScreen> {
  final _controller = TextEditingController();
  final _picker = ImagePicker();
  bool _loading = true;
  bool _saving = false;
  bool _avatarBusy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    // Prefer the locally-cached name; fall back to the server's value so the
    // field is accurate even right after a fresh install / restore.
    final storage = ref.read(secureStorageProvider);
    var name = await storage.getString(myDisplayNameKey);
    if (name == null || name.isEmpty) {
      final session = await ref.read(sessionRepositoryProvider).current();
      if (session != null) {
        try {
          final acc = await ref.read(apiClientProvider).lookupAccount(session.username);
          name = acc.displayName;
        } catch (_) {/* offline — leave empty */}
      }
    }
    if (!mounted) return;
    _controller.text = name ?? '';
    setState(() => _loading = false);
  }

  /// Picks an image, encrypts + uploads it via the media pipeline, and stores
  /// the descriptor JSON as the account avatar. The descriptor (incl. the AES
  /// key) lives in the account record so contacts can decrypt it — avatars are
  /// not secret from your contacts; the encryption keeps the S3 blob private
  /// at rest behind presigned access.
  Future<void> _pickAvatar() async {
    if (_avatarBusy) return;
    // Opening the gallery backgrounds the app; suppress the app-lock re-prompt
    // so returning with a pick doesn't ask for the passcode again.
    ref.read(appLockControllerProvider).suppressNextBackgroundLock();
    final picked = await _picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 512,
      maxHeight: 512,
      imageQuality: 85,
    );
    if (picked == null || !mounted) return;
    setState(() => _avatarBusy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final bytes = await picked.readAsBytes();
      final mime = picked.mimeType ?? 'image/jpeg';
      final descriptor = await ref.read(mediaPipelineProvider).upload(
            kind: MessageKind.image,
            plaintext: bytes,
            mimeType: mime,
          );
      final json = descriptor.toJson();
      await ref.read(apiClientProvider).updateProfile(avatarUrl: json);
      await ref.read(secureStorageProvider).putString(myAvatarKey, json);
      ref.invalidate(myAvatarProvider);
      if (!mounted) return;
      messenger.showSnackBar(const SnackBar(content: Text('Avatar updated')));
    } on ApiError catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('Could not update avatar: ${e.message}')));
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('Could not update avatar: $e')));
    } finally {
      if (mounted) setState(() => _avatarBusy = false);
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    final name = _controller.text.trim();
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    final nav = Navigator.of(context);
    try {
      await ref.read(apiClientProvider).updateProfile(displayName: name);
      await ref.read(secureStorageProvider).putString(myDisplayNameKey, name);
      ref.invalidate(myDisplayNameProvider);
      if (!mounted) return;
      messenger.showSnackBar(const SnackBar(content: Text('Profile updated')));
      nav.pop();
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      messenger.showSnackBar(SnackBar(content: Text('Could not save: ${e.message}')));
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      messenger.showSnackBar(SnackBar(content: Text('Could not save: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    return SettingsScaffold(
      title: 'Edit profile',
      child: _loading
          ? const Center(child: Padding(
              padding: EdgeInsets.only(top: 64),
              child: CircularProgressIndicator(),
            ))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: GestureDetector(
                      onTap: _avatarBusy ? null : _pickAvatar,
                      child: Stack(
                        alignment: Alignment.bottomRight,
                        children: [
                          AvatarImage(
                            name: _controller.text.isEmpty ? 'me' : _controller.text,
                            descriptor: ref.watch(myAvatarProvider).valueOrNull,
                            size: 96,
                          ),
                          Container(
                            decoration: BoxDecoration(
                              color: t.accent,
                              shape: BoxShape.circle,
                              border: Border.all(color: t.bg, width: 2),
                            ),
                            padding: const EdgeInsets.all(6),
                            child: _avatarBusy
                                ? const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2, color: Colors.white),
                                  )
                                : const Icon(Icons.camera_alt,
                                    size: 14, color: Colors.white),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                const SettingsSectionHeader(label: 'Display name'),
                SettingsCard(
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      child: TextField(
                        controller: _controller,
                        maxLength: EditProfileScreen.maxLength,
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _save(),
                        inputFormatters: [
                          LengthLimitingTextInputFormatter(EditProfileScreen.maxLength),
                        ],
                        style: TextStyle(color: t.text, fontSize: 15),
                        decoration: InputDecoration(
                          hintText: 'Your name (optional)',
                          border: InputBorder.none,
                          counterStyle: monoStyle(fontSize: 10, color: t.textFaint),
                        ),
                      ),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 8, 14, 20),
                  child: Text(
                    'Shown to people you chat with instead of your @username. '
                    'Leave blank to show your @username.',
                    style: TextStyle(fontSize: 12, color: t.textMuted, height: 1.5),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: FilledButton(
                    onPressed: _saving ? null : _save,
                    style: FilledButton.styleFrom(
                      backgroundColor: t.accent,
                      minimumSize: const Size.fromHeight(48),
                    ),
                    child: Text(_saving ? 'Saving…' : 'Save'),
                  ),
                ),
              ],
            ),
    );
  }
}
