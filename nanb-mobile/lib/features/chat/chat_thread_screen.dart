import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart' as ph;

import '../../app/design_tokens.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/gif/gif_client.dart';
import '../../core/gif/gif_result.dart';
import '../../core/network/connection_state.dart' as conn;
import '../../core/network/tor/tor_status.dart';
import '../../core/platform/secure_screen.dart';
import '../calls/models/call_signal.dart';
import 'conversations_notifier.dart';
import 'models/chat_message.dart';
import 'models/conversation.dart';
import 'models/conversation_kind.dart';
import 'models/message_kind.dart';
import 'models/sticker.dart';
import 'send_error_text.dart';
import 'services/sticker_bytes_loader.dart';
import 'services/sticker_marker.dart';
import 'sticker_providers.dart';
import 'widgets/sticker_editor_screen.dart';
import 'voice/voice_recorder_sheet.dart';
import 'widgets/attach_sheet.dart';
import 'models/effective_chat_background.dart';
import 'widgets/chat_background_view.dart';
import 'widgets/chat_composer.dart';
import 'widgets/chat_top_bar.dart';
import 'widgets/connection_banner.dart';
import 'widgets/conversation_loading_view.dart';
import 'widgets/emoji_picker_sheet.dart';
import 'widgets/attachment_preview_card.dart';
import 'widgets/media_batch_caption_screen.dart';
import 'widgets/report_sheet.dart';
import 'widgets/media_caption_screen.dart';
import 'widgets/scroll_to_latest_button.dart';
import 'widgets/thread_bars.dart';
import 'widgets/thread_messages_list.dart';

/// Wired version of the design's `ChatThreadScreen` (1:1). Reads the
/// conversation from `ConversationsNotifier`; send button calls
/// `submitMessage` against the live server. Tap on the title opens the
/// contact-profile route.
class ChatThreadScreen extends ConsumerStatefulWidget {
  const ChatThreadScreen({super.key, required this.conversationId});
  final String conversationId;

  @override
  ConsumerState<ChatThreadScreen> createState() => _ChatThreadScreenState();
}

class _ChatThreadScreenState extends ConsumerState<ChatThreadScreen> {
  final _composer = TextEditingController();
  final _composerFocus = FocusNode();
  final _picker = ImagePicker();
  final _scroll = ScrollController();
  bool _attachBusy = false;
  bool _loadingOlder = false;

  /// Escape hatch for the `conv == null` loader. A deep-linked, not-yet-synced
  /// conversation normally resolves once catchup delivers it — but if catchup is
  /// wedged (its one attempt failed and the socket then stayed up), the loader
  /// would spin forever. After [_loadTimeout] we surface a recoverable state
  /// (Retry + back to the list) instead of an endless spinner. Reset by Retry,
  /// cleared once the conversation resolves.
  bool _loadTimedOut = false;
  Timer? _loadTimeoutTimer;
  static const Duration _loadTimeout = Duration(seconds: 10);

  /// Whether the inline emoji panel is open (rendered below the composer in
  /// place of the keyboard, so the text field stays visible). Mutually
  /// exclusive with the soft keyboard — see [_toggleEmojiPanel] and the
  /// [_composerFocus] listener.
  bool _showEmojiPanel = false;

  /// The message currently being replied to (drives the composer reply
  /// banner). Null when not replying.
  ChatMessage? _replyTo;

  /// The own message being edited; the composer holds its text until sent.
  ChatMessage? _editing;

  /// Whether this thread currently holds a [SecureScreen.pushProtected]
  /// (the PEER blocks screenshots). Tracked so push/pop stay balanced as
  /// the flag flips live and on dispose.
  bool _screenSecured = false;

  /// Listens for OS screenshot notifications (iOS) while this thread is open so
  /// we can tell the peer when they asked to keep this chat screenshot-protected
  /// — the real protection on iOS, which can't block the capture itself.
  /// Cancelled in dispose.
  StreamSubscription<void>? _screenshotSub;

  /// Pixel threshold from the top of the scrollable that triggers a
  /// "load older" prefetch. ~600px ≈ 4–5 message bubbles, which gives the
  /// next page time to land before the user scrolls into a blank zone.
  static const double _loadOlderTriggerPx = 600;

  Timer? _typingStopTimer;
  bool _typingSent = false;

  /// Whether the list is scrolled far enough from the newest message to offer
  /// the jump-to-latest button. A notifier so scrolling doesn't rebuild the screen.
  final _showJumpToLatest = ValueNotifier<bool>(false);
  static const double _jumpToLatestThresholdPx = 300;

  /// In-chat search. When [_searching] the thread shows only the messages
  /// matching the query ([_searchResults], DB-backed over the full local
  /// history), hides the composer, and pauses older-message pagination.
  bool _searching = false;
  final _searchCtrl = TextEditingController();
  List<ChatMessage> _searchResults = const [];
  Timer? _searchDebounce;

  /// Stable per-message keys for the full thread, so a search-result tap can
  /// `Scrollable.ensureVisible` the target. Created lazily; persists for the
  /// session (a few stale entries are harmless).
  final Map<String, GlobalKey> _messageKeys = {};

  /// The message to briefly flash-highlight after a jump-to (from a search
  /// result), cleared by [_flashTimer].
  String? _flashEnvelopeId;
  Timer? _flashTimer;

  /// The conversation's single pinned message, resolved for the banner.
  /// Preferred from the loaded window (always current); when the pin has
  /// scrolled out of memory, falls back to a one-shot DB fetch cached here.
  /// [_pinResolvedFor] is the envelope id [_pinMessage] was resolved for (so we
  /// only re-fetch when the pin changes); [_pinFetchInFlight] guards the fetch.
  ChatMessage? _pinMessage;
  String? _pinResolvedFor;
  String? _pinFetchInFlight;

  /// Cached in initState so dispose() can clear the open-conversation flag —
  /// `ref.read()` throws once the element is being disposed.
  late final ConversationsNotifier _notifier;

  /// The notifier instance we last drove [ConversationsNotifier.connect] on, so
  /// [_ensureConnected] connects each fresh instance exactly once. See its doc.
  ConversationsNotifier? _connectedNotifier;

  @override
  void initState() {
    super.initState();
    _notifier = ref.read(conversationsProvider);
    // Mark this thread as the one on screen so its inbound messages don't also
    // raise a notification while the user is actively reading them.
    _notifier.setOpenConversation(widget.conversationId);
    Future.microtask(() async {
      _notifier.markRead(widget.conversationId);
      // Keep the peer's display name + device list current while the thread is
      // open (the device list also gates the warm-up below).
      await _notifier.refreshPeerProfile(widget.conversationId);
      // Eagerly migrate a still-ratchet 1:1 to MLS now (group + Welcome) so the
      // FIRST message send is a fast MLS app message, not a migration. No-op if
      // already MLS / not eligible; best-effort (failure → lazy migration).
      unawaited(_notifier.warmUpMlsMigration(widget.conversationId));
    });
    _scroll.addListener(_maybeLoadOlder);
    _scroll.addListener(_updateJumpToLatest);
    _composer.addListener(_onComposerChanged);
    // Summoning the keyboard (tapping the text field) closes the emoji panel —
    // the two share the same bottom slot, so only one shows at a time.
    _composerFocus.addListener(_onComposerFocusChanged);
    // If the user screenshots a chat the peer asked to keep screenshot-
    // protected, notify the peer. The notifier gates on the peer's flag and
    // throttles, so an unrelated capture (e.g. only the user's own block is on)
    // is a no-op here.
    _screenshotSub = SecureScreen.screenshots.listen((_) {
      if (mounted) {
        unawaited(_notifier.notifyPeerOfScreenshot(widget.conversationId));
      }
    });
    // Arm the loader escape hatch in case this thread opens on a not-yet-synced
    // conversation that never resolves (see [_loadTimedOut]).
    _startLoadTimeout();
  }

  /// (Re)arms the [_loadTimeout] timer that flips [_loadTimedOut] true if the
  /// conversation is still unresolved by then. Safe to call from initState (it
  /// doesn't setState).
  void _startLoadTimeout() {
    _loadTimeoutTimer?.cancel();
    _loadTimeoutTimer = Timer(_loadTimeout, () {
      if (mounted) setState(() => _loadTimedOut = true);
    });
  }

  /// Manual recovery from the stalled loader: re-arm the timeout, drop back to
  /// the spinner, and nudge the notifier to reconnect + re-run catchup so a
  /// wedged gate converges. Reads the CURRENT notifier (not the initState-cached
  /// `_notifier`): a transport change (e.g. a built-in-Tor restart) can have
  /// swapped the instance, and the cached one is then a dead, disconnected
  /// object. connect() is idempotent, so it's a no-op when already connected.
  void _retryLoad() {
    setState(() => _loadTimedOut = false);
    _startLoadTimeout();
    final notifier = ref.read(conversationsProvider);
    unawaited(notifier.connect());
    notifier.catchUpIfNeeded();
  }

  /// Recoverable replacement for the endless spinner once [_loadTimeout] passes
  /// with the conversation still unresolved: explains the likely cause and
  /// offers a Retry (reconnect + re-run catchup) and a way back to the list.
  Widget _buildStalledLoader(DesignTokens t) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_off_outlined, color: t.textMuted),
          const SizedBox(height: 12),
          Text(
            'Still loading this conversation',
            textAlign: TextAlign.center,
            style: TextStyle(color: t.text, fontSize: 14),
          ),
          const SizedBox(height: 6),
          Text(
            'This can happen if the app lost the connection while in the '
            'background. Check your connection and try again.',
            textAlign: TextAlign.center,
            style: TextStyle(color: t.textMuted, fontSize: 12),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            alignment: WrapAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: _retryLoad,
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('Retry'),
              ),
              TextButton(
                onPressed: () => context.go(Routes.chatList),
                child: const Text('Go to chat list'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// The pre-resolution loading state (before the 10s stalled-loader escape
  /// hatch). Branded view with a message that reflects what we're actually
  /// waiting on: a (re)connect — named as "over Tor" when that's the transport,
  /// since a Tor restart after waking is the slow part — vs. catching up once
  /// the socket is back.
  Widget _buildLoadingView(ConversationsNotifier notifier) {
    final connecting =
        notifier.connectionState != conn.ConnectionState.connected;
    // Tor is the active transport whenever its controller isn't `off` (it's
    // starting/bootstrapping/connected/error). Watching it keeps the copy in
    // sync with a live Tor restart, e.g. the one triggered on resume.
    final usingTor = ref.watch(
        torControllerProvider.select((c) => c.phase != TorPhase.off));
    final String message;
    String? detail;
    if (connecting) {
      message = usingTor ? 'Reconnecting over Tor…' : 'Reconnecting…';
      detail = 'This can take a few seconds after the app wakes up.';
    } else {
      message = 'Loading conversation…';
    }
    return ConversationLoadingView(message: message, detail: detail);
  }

  @override
  void dispose() {
    // Leaving this thread — its messages should raise notifications again.
    // Use the cached notifier: ref.read() is illegal during dispose.
    _notifier.setOpenConversation(null);
    _composer.removeListener(_onComposerChanged);
    _composerFocus.removeListener(_onComposerFocusChanged);
    _composerFocus.dispose();
    _typingStopTimer?.cancel();
    // Best-effort: tell the peer we stopped typing as we leave.
    if (_typingSent) {
      _notifier.sendTyping(widget.conversationId, false);
    }
    _scroll.removeListener(_maybeLoadOlder);
    _scroll.removeListener(_updateJumpToLatest);
    _showJumpToLatest.dispose();
    _scroll.dispose();
    _loadTimeoutTimer?.cancel();
    _searchDebounce?.cancel();
    _flashTimer?.cancel();
    _screenshotSub?.cancel();
    _searchCtrl.dispose();
    _composer.dispose();
    if (_screenSecured) {
      _screenSecured = false;
      unawaited(SecureScreen.popProtected());
    }
    super.dispose();
  }

  /// Keyboard ↔ panel are mutually exclusive: when the text field gains focus
  /// (keyboard appears), drop the emoji panel so they don't stack.
  void _onComposerFocusChanged() {
    if (_composerFocus.hasFocus && _showEmojiPanel) {
      setState(() => _showEmojiPanel = false);
    }
  }

  /// Emoji button: open the inline panel (hiding the keyboard first) or, if
  /// it's already open, close it and return to the keyboard.
  void _toggleEmojiPanel() {
    if (_showEmojiPanel) {
      setState(() => _showEmojiPanel = false);
      _composerFocus.requestFocus();
    } else {
      // Drop the keyboard, then show the panel in the freed space.
      _composerFocus.unfocus();
      setState(() => _showEmojiPanel = true);
    }
  }

  /// Drives the outgoing typing signal: emit `typing` on the first keystroke,
  /// then `stopped` after a 3s idle gap or when the field is cleared.
  void _onComposerChanged() {
    if (_composer.text.trim().isEmpty) {
      _stopTyping();
      return;
    }
    if (!_typingSent) {
      _typingSent = true;
      ref.read(conversationsProvider).sendTyping(widget.conversationId, true);
    }
    _typingStopTimer?.cancel();
    _typingStopTimer = Timer(const Duration(seconds: 3), _stopTyping);
  }

  void _stopTyping() {
    _typingStopTimer?.cancel();
    _typingStopTimer = null;
    if (_typingSent) {
      _typingSent = false;
      ref.read(conversationsProvider).sendTyping(widget.conversationId, false);
    }
  }

  // ── In-chat search ──────────────────────────────────────────────────────

  void _openSearch() {
    setState(() {
      _searching = true;
      _showEmojiPanel = false;
      _searchResults = const [];
      _searchCtrl.clear();
    });
  }

  void _closeSearch() {
    _searchDebounce?.cancel();
    setState(() {
      _searching = false;
      _searchResults = const [];
      _searchCtrl.clear();
    });
  }

  /// Debounced search: query the local DB ~220ms after the user stops typing.
  void _onSearchChanged(String q) {
    _searchDebounce?.cancel();
    if (q.trim().isEmpty) {
      setState(() => _searchResults = const []);
      return;
    }
    _searchDebounce = Timer(const Duration(milliseconds: 220), () async {
      final results = await ref
          .read(conversationsProvider)
          .searchMessages(widget.conversationId, q);
      if (mounted && _searching) setState(() => _searchResults = results);
    });
  }

  /// Resolve [conv]'s single pinned message for the banner. Prefers the loaded
  /// window (reflects edits/reactions live); when the pin has scrolled out of
  /// memory, falls back to a cached one-shot DB fetch. Returns null while a
  /// fetch is pending (the fetch `setState`s when it lands) or when nothing is
  /// pinned. Safe to call from `build` — the fetch is guarded against repeats.
  ChatMessage? _resolvePinned(Conversation conv) {
    final id = conv.pinnedEnvelopeId;
    if (id == null || id.isEmpty) {
      _pinMessage = null;
      _pinResolvedFor = null;
      return null;
    }
    final loaded = conv.messages
        .where((m) => m.envelopeId == id)
        .cast<ChatMessage?>()
        .firstWhere((_) => true, orElse: () => null);
    if (loaded != null) {
      _pinMessage = loaded;
      _pinResolvedFor = id;
      return loaded;
    }
    if (_pinResolvedFor == id) return _pinMessage; // cached fetch for this pin
    if (_pinFetchInFlight != id) {
      _pinFetchInFlight = id;
      unawaited(() async {
        final m = await ref.read(conversationsProvider).getMessage(id);
        if (!mounted) return;
        setState(() {
          _pinFetchInFlight = null;
          // Adopt only if the pin hasn't changed underneath the fetch.
          final cur =
              ref.read(conversationsProvider).byId(widget.conversationId);
          if (cur?.pinnedEnvelopeId == id) {
            _pinMessage = m;
            _pinResolvedFor = id;
          }
        });
      }());
    }
    return null;
  }

  /// Jump to [m] in the full thread: leave search if active, page older until
  /// the target is loaded (bounded), scroll it to the CENTRE of the viewport,
  /// and flash it briefly. Used by both search-result taps and the pinned
  /// banner. Works whether the target is on-screen or scrolled far out of the
  /// lazy `ListView`'s build range — a `GlobalKey` only has a context once its
  /// row is laid out, so we nudge the scroll toward the target until it is.
  Future<void> _jumpToMessage(ChatMessage m) => _jumpToEnvelope(m.envelopeId);

  /// [_jumpToMessage] by envelope id — also used by a reply's quoted preview,
  /// whose original may be gone (deleted / expired), in which case we say so.
  Future<void> _jumpToEnvelope(String id) async {
    if (id.isEmpty) return;
    if (_searching) {
      setState(() {
        _searching = false;
        _searchResults = const [];
        _searchCtrl.clear();
      });
    }
    final notifier = ref.read(conversationsProvider);
    // 1. Ensure the target is in the loaded window (page older, bounded).
    var guard = 0;
    while (guard++ < 60) {
      final convo = notifier.byId(widget.conversationId);
      if (convo == null) return;
      if (convo.messages.any((x) => x.envelopeId == id)) break;
      if (!convo.hasMoreOlderMessages) {
        // Not on disk (e.g. the original expired or was deleted).
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Original message not found')),
          );
        }
        return;
      }
      await notifier.loadOlderMessages(widget.conversationId);
    }
    if (!mounted) return;
    setState(() {}); // make sure the loaded message + its key are in the tree

    // 2. Bring the target into the lazy list's build range, then centre it.
    for (var attempt = 0; attempt < 40; attempt++) {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || !_scroll.hasClients) return;
      final ctx = _messageKeys[id]?.currentContext;
      if (ctx != null && ctx.mounted) {
        await Scrollable.ensureVisible(
          ctx,
          alignment: 0.5, // centre, clear of the top bar
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeInOut,
        );
        break;
      }
      // Not laid out yet — determine the direction to the target and nudge.
      final convo = notifier.byId(widget.conversationId);
      if (convo == null) return;
      final targetIdx = convo.messages.indexWhere((x) => x.envelopeId == id);
      if (targetIdx < 0) return;
      // Highest message index currently laid out (newest on screen). The target
      // is newer than the viewport iff its index is greater.
      int? maxLaid;
      for (var i = 0; i < convo.messages.length; i++) {
        if (_messageKeys[convo.messages[i].envelopeId]?.currentContext !=
            null) {
          maxLaid = (maxLaid == null || i > maxLaid) ? i : maxLaid;
        }
      }
      final pos = _scroll.position;
      final step = pos.viewportDimension * 0.85;
      // reverse:true → older messages sit toward maxScrollExtent.
      double next;
      if (maxLaid != null && targetIdx > maxLaid) {
        next = pos.pixels - step; // target is NEWER → scroll down (toward 0)
      } else {
        next = pos.pixels + step; // older / unknown → scroll up (toward max)
      }
      next = next.clamp(0.0, pos.maxScrollExtent);
      if ((next - pos.pixels).abs() < 1) break; // can't move further — give up
      await _scroll.animateTo(
        next,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
      );
    }

    // 3. Flash the target.
    if (!mounted) return;
    setState(() => _flashEnvelopeId = id);
    _flashTimer?.cancel();
    _flashTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _flashEnvelopeId = null);
    });
  }

  /// The list is reversed, so offset 0 is the newest message; scrolling up into
  /// history raises the offset.
  void _updateJumpToLatest() {
    if (!_scroll.hasClients) return;
    _showJumpToLatest.value = _scroll.position.pixels > _jumpToLatestThresholdPx;
  }

  void _jumpToLatest() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      0,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  void _maybeLoadOlder() {
    if (_searching) return; // pagination is paused while searching
    if (_loadingOlder) return;
    if (!_scroll.hasClients) return;
    // The list is reversed (newest at bottom, oldest at top), so "scrolling
    // up" toward older history means moving toward maxScrollExtent. Fire
    // the prefetch when the user is within `_loadOlderTriggerPx` of it.
    final remaining =
        _scroll.position.maxScrollExtent - _scroll.position.pixels;
    if (remaining > _loadOlderTriggerPx) return;
    final convo = ref.read(conversationsProvider).byId(widget.conversationId);
    if (convo == null || !convo.hasMoreOlderMessages) return;
    _loadingOlder = true;
    ref
        .read(conversationsProvider)
        .loadOlderMessages(widget.conversationId)
        .whenComplete(() {
          if (mounted) _loadingOlder = false;
        });
  }

  /// Group sender display name for a message (deviceId → member username).
  String _groupSenderName(Conversation conv, ChatMessage m) {
    for (final mem in conv.members) {
      if (mem.deviceId == m.senderDeviceId) return mem.username;
    }
    return conv.peerUsername.isNotEmpty ? conv.peerUsername : 'Unknown';
  }

  /// One-line preview of a message for the reply banner.
  String _replyPreviewText(ChatMessage m) {
    switch (m.kind) {
      case MessageKind.image:
        return StickerMarker.isSticker(m) ? '🏷️ Sticker' : '📷 Photo';
      case MessageKind.video:
        return '🎬 Video';
      case MessageKind.voice:
        return '🎤 Voice message';
      case MessageKind.file:
        return '📎 ${m.mediaFilename ?? 'File'}';
      case MessageKind.system:
      case MessageKind.text:
        final t = m.body.replaceAll('\n', ' ').trim();
        return t.length > 80 ? '${t.substring(0, 80)}…' : t;
    }
  }

  void _startEdit(ChatMessage m) {
    setState(() {
      _editing = m;
      _replyTo = null;
    });
    _composer.text = m.body;
    _composer.selection = TextSelection.collapsed(offset: m.body.length);
    _composerFocus.requestFocus();
  }

  void _cancelEdit() {
    setState(() => _editing = null);
    _composer.clear();
  }

  Future<void> _commitEdit(ChatMessage target) async {
    final text = _composer.text.trim();
    if (text.isEmpty) return;
    _composer.clear();
    setState(() => _editing = null);
    final ok = await ref.read(conversationsProvider).editMessage(
          conversationId: widget.conversationId,
          target: target,
          newText: text,
        );
    if (!ok && mounted && text != target.body) {
      _showError('Couldn’t edit — messages can be edited for 15 minutes.');
    }
  }

  Future<void> _send() async {
    final editing = _editing;
    if (editing != null) return _commitEdit(editing);
    final text = _composer.text.trim();
    if (text.isEmpty) return;
    final replyTo = _replyTo;
    // Clear the composer IMMEDIATELY — the optimistic bubble (and its
    // failed-state Retry affordance) owns the text from here on. Awaiting
    // the full encrypt + network round-trip before clearing (the old
    // behavior) held the typed text hostage for seconds on slow sends /
    // first-send MLS migrations. Clearing synchronously also makes a
    // double-tap harmless: the second tap sees an empty field.
    _composer.clear();
    setState(() => _replyTo = null);
    final session = await ref.read(sessionRepositoryProvider).current();
    if (session == null) {
      // Broken local state — put the text back so it isn't lost.
      _composer.text = text;
      _showError('No active session.');
      return;
    }
    // Fire-and-forget: the bubble appears optimistically right away and
    // flips to failed+Retry if the submit ultimately errors; the snackbar
    // is just a heads-up.
    unawaited(
      ref
          .read(conversationsProvider)
          .sendMessage(
            conversationId: widget.conversationId,
            myDeviceId: session.deviceId,
            text: text,
            replyTo: replyTo,
          )
          .catchError((Object e) {
            if (mounted) _showSendError(e);
          }),
    );
  }

  /// Requests CAMERA before launching a capture. Because the app declares
  /// the CAMERA permission in its manifest (for the QR scanner), image_picker
  /// requires it to be granted before the camera intent will return a result;
  /// without this gate the capture silently no-ops. Returns false (with a
  /// snackbar) when denied. Gallery picks skip this.
  Future<bool> _ensureCameraPermission() async {
    final status = await ph.Permission.camera.request();
    if (status.isGranted) return true;
    _showError('Camera permission is needed to take photos or videos.');
    return false;
  }

  /// Places a video call after securing camera + microphone — `getUserMedia`
  /// needs both granted up front, or the call would negotiate with no media
  /// tracks. Audio calls don't gate here (the mic flow is handled natively).
  Future<void> _placeVideoCall({
    required String conversationId,
    required String peerAccountId,
    required String peerUsername,
  }) async {
    final cam = await ph.Permission.camera.request();
    final mic = await ph.Permission.microphone.request();
    if (!cam.isGranted || !mic.isGranted) {
      _showError('Camera and microphone are needed for a video call.');
      return;
    }
    await ref.read(callControllerProvider).placeCall(
          conversationId: conversationId,
          peerAccountId: peerAccountId,
          peerUsername: peerUsername,
          kind: CallMediaKind.video,
        );
  }

  Future<void> _attachImage({ImageSource source = ImageSource.gallery}) async {
    if (_attachBusy) return;
    if (source == ImageSource.camera && !await _ensureCameraPermission()) {
      return;
    }
    setState(() => _attachBusy = true);
    try {
      // The camera/gallery is a separate activity — backgrounding here must not
      // re-trip the app lock when the user returns with their pick.
      ref.read(appLockControllerProvider).suppressNextBackgroundLock();
      final picked = await _picker.pickImage(
        source: source,
        // Down-rezzed to keep encrypt + upload bounded; 2K long-edge is plenty
        // for chat sharing and keeps blobs comfortably under a few MB.
        maxWidth: 2048,
        maxHeight: 2048,
        imageQuality: 85,
      );
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      final mime = picked.mimeType ?? _guessMimeFromName(picked.name);
      await _confirmAndSendImage(bytes, mime);
    } catch (e) {
      _showSendError(e);
    } finally {
      if (mounted) setState(() => _attachBusy = false);
    }
  }

  /// Message-request "Report": sends the sender's recent messages to NANb for
  /// review, then rejects the request (which blocks them). The report goes
  /// first so it can't be lost; if it fails the request stays pending and the
  /// user can retry or choose Reject/Accept.
  Future<void> _reportAndReject(String peerUsername) async {
    final notifier = ref.read(conversationsProvider);
    final messenger = ScaffoldMessenger.of(context);
    final draft = await showReportSheet(
      context,
      peerUsername: peerUsername,
      showBlockOption: false,
      submitLabel: 'Report & reject',
    );
    if (draft == null || !mounted) return;
    try {
      await notifier.reportUser(
        widget.conversationId,
        reason: draft.reason,
        note: draft.note,
        alsoBlock: false,
      );
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text("Couldn't submit report. Try again.")),
      );
      return;
    }
    await notifier.rejectMessageRequest(widget.conversationId);
    messenger.showSnackBar(
      const SnackBar(content: Text('Reported and rejected')),
    );
    if (mounted) context.go(Routes.chatList);
  }

  /// Gallery picker: several photos at once, each with its own caption (the
  /// composer text pre-fills the first). Sent one after another, in order.
  Future<void> _attachGalleryImages() async {
    if (_attachBusy) return;
    setState(() => _attachBusy = true);
    try {
      // The gallery is a separate activity — don't re-trip the app lock on return.
      ref.read(appLockControllerProvider).suppressNextBackgroundLock();
      final picked = await _picker.pickMultiImage(
        maxWidth: 2048,
        maxHeight: 2048,
        imageQuality: 85,
        limit: 10,
      );
      if (picked.isEmpty || !mounted) return;
      final images = <({Uint8List bytes, String mime})>[];
      for (final f in picked) {
        images.add((
          bytes: await f.readAsBytes(),
          mime: f.mimeType ?? _guessMimeFromName(f.name),
        ));
      }
      if (!mounted) return;
      final captions = await Navigator.of(context).push<List<String>>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => MediaBatchCaptionScreen(
            title: images.length > 1 ? 'Send photos' : 'Send image',
            initialFirstCaption: _composer.text,
            previews: [
              for (final i in images)
                Image.memory(
                  i.bytes,
                  fit: BoxFit.contain,
                  errorBuilder: (context, error, stackTrace) =>
                      const Text('Preview unavailable'),
                ),
            ],
          ),
        ),
      );
      if (captions == null || !mounted) return;
      _composer.clear();
      final session = await ref.read(sessionRepositoryProvider).current();
      if (!mounted) return;
      if (session == null) {
        if (_composer.text.isEmpty) _composer.text = captions.first;
        _showError('No active session.');
        return;
      }
      for (var n = 0; n < images.length; n++) {
        await ref.read(conversationsProvider).sendImage(
              conversationId: widget.conversationId,
              myDeviceId: session.deviceId,
              imageBytes: images[n].bytes,
              mimeType: images[n].mime,
              caption: captions[n],
            );
      }
    } catch (e) {
      _showSendError(e);
    } finally {
      if (mounted) setState(() => _attachBusy = false);
    }
  }

  Future<void> _confirmAndSendImage(Uint8List bytes, String mimeType) async {
    if (!mounted) return;
    final caption = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => MediaCaptionScreen(
          bytes: bytes,
          initialCaption: _composer.text,
        ),
      ),
    );
    if (caption == null || !mounted) return;
    _composer.clear();
    try {
      final session = await ref.read(sessionRepositoryProvider).current();
      if (!mounted) return;
      if (session == null) {
        if (_composer.text.isEmpty) _composer.text = caption;
        _showError('No active session.');
        return;
      }
      await ref.read(conversationsProvider).sendImage(
        conversationId: widget.conversationId,
        myDeviceId: session.deviceId,
        imageBytes: bytes,
        mimeType: mimeType,
        caption: caption,
      );
    } catch (_) {
      // Restore the caption after failure without overwriting a newer draft.
      if (mounted && _composer.text.isEmpty) _composer.text = caption;
      rethrow;
    }
  }

  String _guessMimeFromName(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.webp')) return 'image/webp';
    return 'image/jpeg';
  }

  Future<void> _handleAttach() async {
    final action = await AttachSheet.show(context);
    if (action == null) return;
    switch (action) {
      case AttachAction.takePhoto:
        await _attachImage(source: ImageSource.camera);
        break;
      case AttachAction.recordVideo:
        await _pickAndSendVideo(source: ImageSource.camera);
        break;
      case AttachAction.photo:
        await _attachGalleryImages();
        break;
      case AttachAction.video:
        await _pickAndSendVideo();
        break;
      case AttachAction.file:
        await _pickAndSendFile();
        break;
    }
  }

  /// Downloads the chosen GIF's bytes and sends them through the normal
  /// encrypted image path (`mimeType: image/gif`). Invoked from the emoji
  /// panel's GIF tab. GIPHY's `downsized` rendition keeps the blob small; the
  /// bytes are E2EE-uploaded like any other image, so the server never sees the
  /// GIF in the clear.
  Future<void> _sendGif(GifResult gif) async {
    if (_attachBusy) return;
    setState(() => _attachBusy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final session = await ref.read(sessionRepositoryProvider).current();
      if (session == null) {
        _showError('No active session.');
        return;
      }
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Loading GIF…'),
          duration: Duration(seconds: 30),
        ),
      );
      // Download the chosen GIF's bytes through the server's media proxy
      // (/gifs/media) so the fetch leaves the server's IP, not the user's —
      // GIPHY never sees the user. The server validates it's a GIPHY host.
      final gifClient = GifClient(
        baseUrl: ref.read(apiBaseUrlProvider),
        bearerToken: session.jwt,
        socksProxy: ref.read(socksProxyProvider),
      );
      final List<int> bytes;
      try {
        bytes = await gifClient.downloadBytes(gif.sendUrl);
      } finally {
        gifClient.close();
      }
      messenger.hideCurrentSnackBar();
      if (bytes.isEmpty) {
        _showError('Could not download GIF.');
        return;
      }
      await _confirmAndSendImage(Uint8List.fromList(bytes), 'image/gif');
    } catch (e) {
      _showSendError(e);
    } finally {
      messenger.hideCurrentSnackBar();
      if (mounted) setState(() => _attachBusy = false);
    }
  }

  /// Sends the tapped sticker through the normal encrypted image path, tagged
  /// with the `sticker.<ext>` filename so the recipient renders it frameless.
  /// Unlike a GIF it never takes the composer's text as a caption.
  Future<void> _sendSticker(Sticker sticker) async {
    if (_attachBusy) return;
    setState(() => _attachBusy = true);
    try {
      final session = await ref.read(sessionRepositoryProvider).current();
      if (session == null) {
        _showError('No active session.');
        return;
      }
      final bytes = await loadStickerBytes(sticker);
      await ref.read(conversationsProvider).sendImage(
            conversationId: widget.conversationId,
            myDeviceId: session.deviceId,
            imageBytes: bytes,
            mimeType: sticker.mimeType,
            filename: StickerMarker.filenameFor(sticker.mimeType),
          );
    } catch (e) {
      _showSendError(e);
    } finally {
      if (mounted) setState(() => _attachBusy = false);
    }
  }

  /// "Add to stickers" from a message's long-press menu: saves that image into
  /// the user's own sticker collection.
  Future<void> _addToStickers(ChatMessage m) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final bytes = await ref.read(conversationsProvider).mediaBytesFor(m);
      if (bytes == null || !mounted) {
        messenger.showSnackBar(
          const SnackBar(content: Text("Couldn't add that image.")),
        );
        return;
      }
      // Let the user crop / rotate before it becomes a sticker.
      final edited =
          await editSticker(context, bytes, m.mediaMime ?? 'image/jpeg');
      if (edited == null) return;
      final saved = await ref
          .read(stickerCollectorProvider)
          .addFromBytes(edited.bytes, edited.mimeType);
      messenger.showSnackBar(SnackBar(
        content: Text(saved == null
            ? "Couldn't add that image."
            : 'Added to your stickers'),
      ));
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text("Couldn't add that image.")),
      );
    }
  }

  /// Shows the caption screen for media with no inline picture (a file or a
  /// video). Returns the typed caption, or null if the user backed out.
  Future<String?> _askCaption({
    required String title,
    required IconData icon,
    required String name,
    required int sizeBytes,
  }) {
    final sizeLabel = _sizeLabel(sizeBytes);
    return Navigator.of(context).push<String>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => MediaCaptionScreen(
          title: title,
          initialCaption: _composer.text,
          preview: AttachmentPreviewCard(
            icon: icon,
            name: name,
            sizeLabel: sizeLabel,
          ),
        ),
      ),
    );
  }

  Future<void> _pickAndSendFile() async {
    if (_attachBusy) return;
    setState(() => _attachBusy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      // withData:false → the picker returns PATHS, not the bytes. Loading the
      // bytes natively and marshalling them across the platform channel
      // (withData:true) froze the UI thread for large files on low-end devices
      // ("App isn't responding"). We read each path off the UI thread below.
      // The system file picker is a separate activity — don't re-trip the app
      // lock when the user returns with their selection.
      ref.read(appLockControllerProvider).suppressNextBackgroundLock();
      final res = await FilePicker.platform.pickFiles(
        type: FileType.any,
        withData: false,
        allowMultiple: true,
      );
      if (res == null || res.files.isEmpty) return;
      final files = res.files;
      // Reject oversize BEFORE reading any bytes (server caps encrypted media
      // at NANB_MEDIA_MAX_SIZE_MB=100 MB). size is known from metadata, so we
      // never load a too-big file into memory.
      for (final f in files) {
        if (f.size > 100 * 1024 * 1024) {
          _showError('${f.name} is too large (100 MB max).');
          return;
        }
        if (f.path == null) {
          _showError('Could not read ${f.name}.');
          return;
        }
      }
      if (!mounted) return;
      // Preview + optional caption per file, like an image. Backing out sends
      // nothing.
      final captions = await Navigator.of(context).push<List<String>>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => MediaBatchCaptionScreen(
            title: files.length > 1 ? 'Send files' : 'Send file',
            initialFirstCaption: _composer.text,
            previews: [
              for (final f in files)
                AttachmentPreviewCard(
                  icon: Icons.insert_drive_file_outlined,
                  name: f.name,
                  sizeLabel: _sizeLabel(f.size),
                ),
            ],
          ),
        ),
      );
      if (captions == null) return;
      final session = await ref.read(sessionRepositoryProvider).current();
      if (session == null) {
        _showError('No active session.');
        return;
      }
      _composer.clear();
      for (var n = 0; n < files.length; n++) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(files.length > 1
                ? 'Loading file ${n + 1} of ${files.length}…'
                : 'Loading file…'),
            duration: const Duration(seconds: 30),
          ),
        );
        // File.readAsBytes is async and runs on dart:io's worker pool, so the UI
        // thread stays responsive while a large file loads.
        final bytes = await File(files[n].path!).readAsBytes();
        messenger.hideCurrentSnackBar();
        await ref.read(conversationsProvider).sendFile(
              conversationId: widget.conversationId,
              myDeviceId: session.deviceId,
              fileBytes: bytes,
              mimeType: _mimeFromExt(files[n].name),
              filename: files[n].name,
              caption: captions[n],
            );
      }
    } catch (e) {
      _showSendError(e);
    } finally {
      messenger.hideCurrentSnackBar();
      if (mounted) setState(() => _attachBusy = false);
    }
  }

  String _sizeLabel(int sizeBytes) {
    final mb = sizeBytes / (1024 * 1024);
    return mb >= 1
        ? '${mb.toStringAsFixed(1)} MB'
        : '${(sizeBytes / 1024).ceil()} KB';
  }

  Future<void> _pickAndSendVideo({
    ImageSource source = ImageSource.gallery,
  }) async {
    if (_attachBusy) return;
    final messenger = ScaffoldMessenger.of(context);
    if (source == ImageSource.camera && !await _ensureCameraPermission()) {
      return;
    }
    setState(() => _attachBusy = true);
    try {
      // External camera/gallery activity — don't re-prompt the app lock on return.
      ref.read(appLockControllerProvider).suppressNextBackgroundLock();
      final picked = await _picker.pickVideo(
        source: source,
        maxDuration: const Duration(minutes: 5),
      );
      if (picked == null) return;
      // Check the size from metadata before loading the bytes, so a too-big
      // clip never gets read into memory (and can't jank the UI).
      if (await picked.length() > 100 * 1024 * 1024) {
        _showError('Video too large (100 MB max). Try a shorter clip.');
        return;
      }
      if (!mounted) return;
      final caption = await _askCaption(
        title: 'Send video',
        icon: Icons.videocam_outlined,
        name: picked.name,
        sizeBytes: await picked.length(),
      );
      if (caption == null) return;
      final session = await ref.read(sessionRepositoryProvider).current();
      if (session == null) {
        _showError('No active session.');
        return;
      }
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Loading video…'),
          duration: Duration(seconds: 30),
        ),
      );
      final bytes = await picked.readAsBytes();
      messenger.hideCurrentSnackBar();
      await ref
          .read(conversationsProvider)
          .sendVideo(
            conversationId: widget.conversationId,
            myDeviceId: session.deviceId,
            videoBytes: bytes,
            mimeType: picked.mimeType ?? 'video/mp4',
            caption: caption,
          );
      _composer.clear();
    } catch (e) {
      _showSendError(e);
    } finally {
      messenger.hideCurrentSnackBar();
      if (mounted) setState(() => _attachBusy = false);
    }
  }

  Future<void> _recordAndSendVoice() async {
    if (_attachBusy) return;
    setState(() => _attachBusy = true);
    try {
      final recording = await VoiceRecorderSheet.show(context);
      if (recording == null) return;
      final file = File(recording.path);
      if (!await file.exists()) return;
      final bytes = await file.readAsBytes();
      final session = await ref.read(sessionRepositoryProvider).current();
      if (session == null) {
        _showError('No active session.');
        return;
      }
      await ref
          .read(conversationsProvider)
          .sendVoice(
            conversationId: widget.conversationId,
            myDeviceId: session.deviceId,
            voiceBytes: bytes,
            waveform: recording.waveform.isEmpty ? null : recording.waveform,
            durationMs: recording.duration == Duration.zero
                ? null
                : recording.duration.inMilliseconds,
          );
      try {
        await file.delete();
      } catch (_) {
        /* best-effort temp cleanup */
      }
    } catch (e) {
      _showSendError(e);
    } finally {
      if (mounted) setState(() => _attachBusy = false);
    }
  }

  String _mimeFromExt(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.pdf')) return 'application/pdf';
    if (lower.endsWith('.txt')) return 'text/plain';
    if (lower.endsWith('.zip')) return 'application/zip';
    if (lower.endsWith('.doc')) return 'application/msword';
    if (lower.endsWith('.docx')) {
      return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
    }
    return 'application/octet-stream';
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// A failed send's snackbar — never the raw exception text (see
  /// [sendErrorText]).
  void _showSendError(Object e) {
    final convo = ref.read(conversationsProvider).byId(widget.conversationId);
    _showError(sendErrorText(
      e,
      isGroup: convo?.kind == ConversationKind.group,
    ));
  }

  /// Drives [ConversationsNotifier.connect] (idempotent) for THIS screen, and
  /// re-drives it whenever the provider is rebuilt with a *new* instance.
  ///
  /// The chat list normally owns connecting (see `ChatListScreen._ensureConnected`),
  /// but a thread reached by tapping a notification is a top-level route with the
  /// chat list NOT mounted — so nothing else connects the notifier. And the
  /// instance is swapped out from under us whenever the transport changes: a
  /// built-in-Tor restart on resume (the OS suspended the app, Arti relaunches on
  /// a fresh SOCKS port) rebuilds `conversationsProvider`, leaving a brand-new,
  /// un-hydrated notifier (`hydrated == false`) that no one would otherwise
  /// `connect()`. That is the "deep-linked thread stuck on the Conversation
  /// spinner after waking from background" bug. Connecting here closes that gap;
  /// `connect()` no-ops on the warm path where the chat list already connected.
  void _ensureConnected(ConversationsNotifier notifier) {
    if (identical(notifier, _connectedNotifier)) return;
    _connectedNotifier = notifier;
    Future.microtask(() async {
      try {
        await notifier.connect();
      } catch (_) {
        // A provider rebuild can dispose this notifier mid-connect; the
        // replacement instance re-triggers _ensureConnected on the next build.
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    final notifier = ref.watch(conversationsProvider);
    // Make sure this notifier is actually connecting/hydrating even when we were
    // deep-linked straight here (chat list never mounted) or the provider was
    // just rebuilt by a transport change. Without this the loader below can spin
    // forever on a fresh, un-hydrated notifier.
    _ensureConnected(notifier);
    final conv = notifier.byId(widget.conversationId);

    if (conv == null) {
      // A null conversation is almost always transient when we land here from a
      // notification tap: the thread can be deep-linked before the notifier has
      // hydrated from disk (the chat list, which drives connect(), may not have
      // mounted yet), and a brand-new conversation's row only materialises once
      // the first foreground WS catchup decrypts the pushed message. So we only
      // trust a null as "genuinely absent" once we're hydrated, online, AND
      // that first catchup has settled; until then, show a neutral loader.
      final stillLoading =
          !(notifier.hydrated &&
              notifier.connectionState == conn.ConnectionState.connected &&
              notifier.catchupSettled);
      return Scaffold(
        backgroundColor: t.bg,
        appBar: AppBar(title: const Text('Conversation')),
        body: Center(
          child: stillLoading
              ? (_loadTimedOut
                  ? _buildStalledLoader(t)
                  : _buildLoadingView(notifier))
              : Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    'This conversation has not started yet.\n\nTap the pencil on the chat list to start one.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: t.textMuted),
                  ),
                ),
        ),
      );
    }

    // The conversation resolved — the load-timeout escape hatch is moot now.
    _loadTimeoutTimer?.cancel();
    _loadTimeoutTimer = null;

    // A message that lands while this thread is already open should be marked
    // read right away — initState's markRead only fires on the first open, so
    // without this a message received mid-conversation never gets a read
    // receipt. markRead no-ops when there's nothing unread, so this stays cheap
    // across the rebuilds an inbound message triggers. Deferred off the build
    // frame because markRead calls notifyListeners().
    if (conv.unreadCount > 0) {
      Future.microtask(() {
        if (mounted) {
          ref.read(conversationsProvider).markRead(widget.conversationId);
        }
      });
    }

    // The peer blocks screenshots → hold a window-level FLAG_SECURE for as
    // long as this thread is in the stack (covers media viewer / profile
    // pushed on top too). Idempotent state-sync, balanced in dispose; safe
    // as a build side effect (no setState, fire-and-forget channel call).
    final wantSecure = conv.peerBlocksScreenshots;
    if (wantSecure != _screenSecured) {
      _screenSecured = wantSecure;
      unawaited(
        wantSecure ? SecureScreen.pushProtected() : SecureScreen.popProtected(),
      );
    }

    final prefs = ref.watch(appPreferencesProvider).value;
    // Per-chat override wins; 'default' / none follows the global setting.
    final effectiveBackground = EffectiveChatBackground.resolve(
      notifier.backgroundOverrideOf(widget.conversationId),
      prefs.chatBackground,
      prefs.chatBackgroundPath,
    );
    final isGroup = conv.kind == ConversationKind.group;
    // Prefer the peer's display name (group name for groups), falling back to
    // the @username when none is set.
    final topBarName = ref.read(conversationsProvider).displayNameFor(conv);
    // 1:1: show "typing…" while the peer is composing; groups: member count.
    final topBarSub = isGroup
        ? '${conv.distinctMembers.length} members'
        : (ref.read(conversationsProvider).isPeerTyping(widget.conversationId)
              ? 'typing…'
              : null);
    final onTitleTap = isGroup
        ? () => context.push(
            Routes.groupInfo.replaceFirst(
              ':conversationId',
              widget.conversationId,
            ),
          )
        : () => context.push(
            Routes.contactProfile.replaceFirst(
              ':conversationId',
              widget.conversationId,
            ),
          );

    final selfMembershipPresent = !isGroup || conv.members.any((m) => m.isSelf);
    // 1:1 conversations from a sender that couldn't be identified (deleted
    // account, failed lookup) have no peerAccountId — a reply would have
    // nowhere to go (the old behavior mis-addressed it back to ourselves).
    final peerAddressable = isGroup || conv.peerAccountId.isNotEmpty;
    final composerBlockedReason = !selfMembershipPresent
        ? 'You were removed from this group'
        : !peerAddressable
        ? "Can't reply — this sender couldn't be identified"
        : null;

    return PopScope(
      // When the emoji panel is open, the system Back gesture collapses it
      // first (matching how Back dismisses the keyboard) instead of leaving
      // the thread.
      canPop: !_showEmojiPanel,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _showEmojiPanel) {
          setState(() => _showEmojiPanel = false);
        }
      },
      child: Scaffold(
        backgroundColor: t.bg,
        // The app runs edge-to-edge, so wrap in SafeArea to keep the top bar
        // below the status bar and the composer above the nav bar (otherwise the
        // input row sits under the system nav buttons and can't be tapped). The
        // top bar lives in the body (not the appBar slot) so it picks up the
        // SafeArea inset — same pattern as the chat list.
        body: SafeArea(
          child: Column(
            children: [
              ChatTopBar(
                name: topBarName,
                sub: topBarSub,
                avatar: ref
                    .read(conversationsProvider)
                    .peerAvatarDescriptor(conv),
                isGroup: isGroup,
                // 1:1 only — set by QR-verified adds and the contact
                // profile's mark-verified action. Groups have no single
                // peer key to verify.
                verified: !isGroup && conv.verified,
                // The thread is sometimes entered via context.go() (QR
                // scan-to-add, notification taps), which REPLACES the stack —
                // Navigator.maybePop() then has nothing to pop and the arrow
                // goes dead. Fall back to the chat list explicitly.
                onBack: () {
                  if (context.canPop()) {
                    context.pop();
                  } else {
                    context.go(Routes.chatList);
                  }
                },
                onTitleTap: onTitleTap,
                // Voice call: shown only for a callable 1:1 (accepted,
                // non-blocked). Places the call; the CallOverlay shows the UI.
                onCall: (!isGroup &&
                        ref.read(conversationsProvider).isCallable(conv.id))
                    ? () => ref.read(callControllerProvider).placeCall(
                          conversationId: conv.id,
                          peerAccountId: conv.peerAccountId,
                          peerUsername: conv.peerUsername,
                        )
                    : null,
                // Video call: same gating as voice; secures camera + mic first.
                onVideoCall: (!isGroup &&
                        ref.read(conversationsProvider).isCallable(conv.id))
                    ? () => _placeVideoCall(
                          conversationId: conv.id,
                          peerAccountId: conv.peerAccountId,
                          peerUsername: conv.peerUsername,
                        )
                    : null,
                menuActions: {
                  'Search messages': _openSearch,
                  isGroup ? 'Group info' : 'View contact': onTitleTap,
                  'Go to chat list': () => context.go(Routes.chatList),
                },
              ),
              const ConnectionBanner(),
              if (_searching)
                ThreadSearchBar(
                  t: t,
                  controller: _searchCtrl,
                  onChanged: _onSearchChanged,
                  onClose: _closeSearch,
                  resultCount: _searchResults.length,
                  hasQuery: _searchCtrl.text.trim().isNotEmpty,
                ),
              // Pinned banner: the conversation's single shared pinned message
              // (synced across the chat). Tapping it jumps to the message; the
              // × clears the pin for everyone. Resolves reactively from the
              // conversation's pinnedEnvelopeId.
              if (!_searching)
                Builder(builder: (_) {
                  final pinned = _resolvePinned(conv);
                  if (pinned == null) return const SizedBox.shrink();
                  return PinnedBanner(
                    t: t,
                    preview: _replyPreviewText(pinned),
                    onTap: () => _jumpToMessage(pinned),
                    onClear: () => ref
                        .read(conversationsProvider)
                        .setConversationPin(widget.conversationId, null),
                  );
                }),
              Expanded(
                // Tap anywhere in the message area (empty space included) to
                // dismiss the keyboard. Complements the list's drag-to-dismiss
                // — covers a brand-new thread that has no scrollable to drag
                // yet. Translucent so taps on bubbles (long-press, swipe-reply,
                // search-jump) still reach them; only unclaimed taps unfocus.
                child: ChatBackgroundView(
                  background: effectiveBackground.background,
                  customPath: effectiveBackground.customPath,
                  child: Stack(
                  children: [
                  Positioned.fill(
                  child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: () => FocusScope.of(context).unfocus(),
                  child: MessagesList(
                    messages: _searching ? _searchResults : conv.messages,
                    hasMoreOlderMessages:
                        _searching ? false : conv.hasMoreOlderMessages,
                    scrollController: _scroll,
                    t: t,
                    notifier: ref.read(conversationsProvider),
                    isGroup: isGroup,
                    members: conv.members,
                    onReply: (m) => setState(() => _replyTo = m),
                    onEdit: _searching ? null : _startEdit,
                    onAddToStickers: _addToStickers,
                    // Search mode: highlight the term + tap a result to jump.
                    highlightQuery:
                        _searching ? _searchCtrl.text.trim() : null,
                    onTapMessage: _searching ? _jumpToMessage : null,
                    // Full thread: stable keys (for jump-to) + post-jump flash.
                    messageKeys: _messageKeys,
                    flashEnvelopeId: _searching ? null : _flashEnvelopeId,
                    onJumpToMessageId: _searching ? null : _jumpToEnvelope,
                    peerTyping: !isGroup &&
                        ref
                            .read(conversationsProvider)
                            .isPeerTyping(widget.conversationId),
                  ),
                ),
                  ),
                  Positioned(
                    right: 12,
                    bottom: 12,
                    child: ValueListenableBuilder<bool>(
                      valueListenable: _showJumpToLatest,
                      builder: (_, show, _) => ScrollToLatestButton(
                        visible: show && !_searching,
                        onPressed: _jumpToLatest,
                      ),
                    ),
                  ),
                  ],
                  ),
                ),
              ),
              // Message request: the decision bar replaces the composer (and
              // wins over composerBlockedReason — the user must decide first;
              // an accepted-but-unaddressable peer then falls back to the
              // blocked-reason strip). While searching, the composer is hidden
              // (the search bar takes its place at the top).
              _searching
                  ? const SizedBox.shrink()
                  : conv.pending
                  ? (conv.kind == ConversationKind.group
                      ? GroupInviteBar(
                          t: t,
                          groupName: conv.groupName,
                          onAccept: () => ref
                              .read(conversationsProvider)
                              .acceptGroupInvite(widget.conversationId),
                          onReject: () async {
                            await ref
                                .read(conversationsProvider)
                                .rejectGroupInvite(widget.conversationId);
                            if (context.mounted) context.go(Routes.chatList);
                          },
                        )
                      : RequestBar(
                          t: t,
                          peerUsername: conv.peerUsername,
                          onAccept: () => ref
                              .read(conversationsProvider)
                              .acceptMessageRequest(widget.conversationId),
                          onReject: () async {
                            await ref
                                .read(conversationsProvider)
                                .rejectMessageRequest(widget.conversationId);
                            if (context.mounted) context.go(Routes.chatList);
                          },
                          onReport: () => _reportAndReject(conv.peerUsername),
                        ))
                  : conv.blocked
                  ? BlockedBar(
                      t: t,
                      onUnblock: () => ref
                          .read(conversationsProvider)
                          .setBlocked(widget.conversationId, false),
                    )
                  : composerBlockedReason == null
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_editing != null)
                          ReplyComposerBanner(
                            t: t,
                            sender: 'Editing message',
                            preview: _replyPreviewText(_editing!),
                            onCancel: _cancelEdit,
                          )
                        else if (_replyTo != null)
                          ReplyComposerBanner(
                            t: t,
                            sender: _replyTo!.mine
                                ? 'You'
                                : (conv.kind == ConversationKind.group
                                      ? _groupSenderName(conv, _replyTo!)
                                      : conv.peerUsername),
                            preview: _replyPreviewText(_replyTo!),
                            onCancel: () => setState(() => _replyTo = null),
                          ),
                        ChatComposer(
                          controller: _composer,
                          focusNode: _composerFocus,
                          onSend: _send,
                          onAttach: _attachBusy ? null : _handleAttach,
                          onMic: _attachBusy ? null : _recordAndSendVoice,
                          onEmoji: _toggleEmojiPanel,
                          emojiOpen: _showEmojiPanel,
                        ),
                        // Inline emoji panel: sits below the composer (in
                        // place of the keyboard) so the text field stays
                        // visible while the user picks and sends.
                        if (_showEmojiPanel)
                          EmojiPickerPanel(
                            controller: _composer,
                            onClose: () =>
                                setState(() => _showEmojiPanel = false),
                            onGifSelected: (gif) {
                              setState(() => _showEmojiPanel = false);
                              _sendGif(gif);
                            },
                            onStickerSelected: (sticker) {
                              setState(() => _showEmojiPanel = false);
                              _sendSticker(sticker);
                            },
                          ),
                      ],
                    )
                  : Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: t.surface,
                        border: Border(top: BorderSide(color: t.border)),
                      ),
                      child: Center(
                        child: Text(
                          composerBlockedReason,
                          style: TextStyle(color: t.textMuted, fontSize: 13),
                        ),
                      ),
                    ),
            ],
          ),
        ),
      ),
    );
  }
}

