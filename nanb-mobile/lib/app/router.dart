import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/network/connection_state.dart' as conn;
import '../features/chat/chat_list_screen.dart';
import '../features/chat/conversations_notifier.dart';
import '../features/chat/chat_thread_screen.dart';
import '../features/chat/contact_profile_screen.dart';
import '../features/chat/create_group_screen.dart';
import '../features/chat/group_info_screen.dart';
import '../features/chat/new_chat_screen.dart';
import '../features/chat/scan_contact_screen.dart';
import '../features/chat/share_target_screen.dart';
import '../features/chat/shared_media_screen.dart';
import '../features/chat/video/video_player_screen.dart';
import '../features/onboarding/link_new_device_screen.dart';
import '../features/onboarding/link_primary_device_screen.dart';
import '../features/onboarding/recovery_phrase_setup_screen.dart';
import '../features/onboarding/restore_screen.dart';
import '../features/onboarding/resuming_screen.dart';
import '../features/onboarding/username_screen.dart';
import '../features/onboarding/welcome_screen.dart';
import '../features/settings/about_screen.dart';
import '../features/settings/appearance_screen.dart';
import '../features/settings/blocks_screen.dart';
import '../features/settings/linked_devices_screen.dart';
import '../features/settings/network_screen.dart';
import '../features/settings/notifications_screen.dart';
import '../features/settings/edit_profile_screen.dart';
import '../features/settings/privacy_screen.dart';
import '../features/settings/recovery_phrase_reveal_settings_screen.dart';
import '../features/settings/settings_hub_screen.dart';
import 'providers.dart';

class Routes {
  Routes._();
  static const String resuming = '/resuming';
  static const String welcome = '/welcome';
  static const String username = '/welcome/username';
  static const String recoverySetup = '/welcome/recovery';
  static const String restore = '/welcome/restore';
  static const String linkNewDevice = '/welcome/link-new';
  static const String linkPrimaryDevice = '/settings/link-primary';
  static const String chatList = '/chat-list';
  static const String newChat = '/chat-list/new';
  static const String scanContact = '/chat-list/new/scan';
  static const String newGroup = '/chat-list/new-group';
  static const String shareTarget = '/share';
  static const String chat = '/chat/:conversationId';
  static const String contactProfile = '/chat/:conversationId/profile';
  static const String groupInfo = '/chat/:conversationId/group-info';
  static const String sharedMedia = '/chat/:conversationId/shared';
  static const String videoPlayer = '/chat/:conversationId/video/:envelopeId';
  static const String settings = '/settings';
  static const String settingsEditProfile = '/settings/edit-profile';
  static const String settingsAppearance = '/settings/appearance';
  static const String settingsAbout = '/settings/about';
  static const String settingsNotifications = '/settings/notifications';
  static const String settingsPrivacy = '/settings/privacy';
  static const String settingsNetwork = '/settings/network';
  static const String settingsBlocks = '/settings/blocks';
  static const String settingsRecoveryPhrase = '/settings/recovery-phrase';
  static const String settingsLinkedDevices = '/settings/linked-devices';
}

/// Where a navigation must be sent while this device's session is unusable —
/// either the server rejected it (revoked/deleted device) or the user signed
/// out non-destructively. Null means "allow it".
///
/// EVERY onboarding route is allowed, not just `/welcome` itself:
/// create-account, recovery-phrase setup, restore and link-new-device all live
/// under `/welcome/…`. Matching only the exact path made onboarding
/// UNREACHABLE in exactly the state that needs it — tapping "Create account"
/// pushed `/welcome/username`, which this guard bounced straight back to
/// `/welcome`, so the button looked dead and the screen appeared to reload.
///
/// That is reachable in the wild, not just after a server-side wipe: iOS keeps
/// keychain items when an app is DELETED, so a reinstall resurrects the old
/// session, the server rejects the now-unknown device (401 →
/// `/sessions/challenge` 404 → signedOut), and the user could never onboard
/// again. Android hides it, because clearing app data drops the session too.
String? signedOutRedirect(String location) {
  if (location.startsWith(Routes.welcome)) return null;
  // Server config must stay reachable pre-login (e.g. pointing a fresh install
  // on a physical device at the PC's LAN IP before signing in).
  if (location == Routes.settingsNetwork) return null;
  return Routes.welcome;
}

GoRouter buildRouter({
  required ConversationsNotifier conversations,
  String initialLocation = Routes.welcome,
}) {
  return GoRouter(
    initialLocation: initialLocation,
    refreshListenable: conversations,
    redirect: (context, state) {
      // `signedOut` = the server rejected this device (revoked/deleted).
      // `manuallySignedOut` = the user signed out but kept their data on-device
      // (non-destructive); they resume from /welcome. Both gate to /welcome.
      if (conversations.connectionState == conn.ConnectionState.signedOut ||
          conversations.manuallySignedOut) {
        return signedOutRedirect(state.matchedLocation);
      }
      return null;
    },
    routes: [
      GoRoute(
        path: Routes.resuming,
        name: 'resuming',
        builder: (context, state) => const ResumingScreen(),
      ),
      GoRoute(
        path: Routes.welcome,
        name: 'welcome',
        builder: (context, state) => const WelcomeScreen(),
      ),
      GoRoute(
        path: Routes.username,
        name: 'username',
        builder: (context, state) => const UsernameScreen(),
      ),
      GoRoute(
        path: Routes.recoverySetup,
        name: 'recoverySetup',
        builder: (context, state) {
          final username = state.extra as String? ?? '';
          return RecoveryPhraseSetupScreen(username: username);
        },
      ),
      GoRoute(
        path: Routes.restore,
        name: 'restore',
        builder: (context, state) => const RestoreScreen(),
      ),
      GoRoute(
        path: Routes.linkNewDevice,
        name: 'linkNewDevice',
        builder: (context, state) => const LinkNewDeviceScreen(),
      ),
      GoRoute(
        path: Routes.linkPrimaryDevice,
        name: 'linkPrimaryDevice',
        builder: (context, state) => const LinkPrimaryDeviceScreen(),
      ),
      GoRoute(
        path: Routes.chatList,
        name: 'chatList',
        builder: (context, state) => const ChatListScreen(),
      ),
      GoRoute(
        path: Routes.newChat,
        name: 'newChat',
        builder: (context, state) => const NewChatScreen(),
      ),
      GoRoute(
        path: Routes.scanContact,
        name: 'scanContact',
        builder: (context, state) => const ScanContactScreen(),
      ),
      GoRoute(
        path: Routes.newGroup,
        name: 'newGroup',
        builder: (context, state) => const _NewGroupRoute(),
      ),
      // Landing route for content handed to us by the OS share sheet. The
      // payload comes from `pendingShareProvider`, NOT the URL or `extra`:
      // shared text is the user's private content and has no business in a
      // route string, and `extra` does not reliably survive the router
      // refreshes a cold start triggers. Rebuilding from state means a refresh
      // mid-share is harmless. No pending share (a stray navigation, or the
      // share already sent) falls back to the chat list.
      GoRoute(
        path: Routes.shareTarget,
        name: 'shareTarget',
        builder: (context, state) => const _ShareTargetRoute(),
      ),
      GoRoute(
        path: Routes.chat,
        name: 'chat',
        builder: (context, state) => ChatThreadScreen(
          conversationId: state.pathParameters['conversationId'] ?? '',
        ),
      ),
      GoRoute(
        path: Routes.contactProfile,
        name: 'contactProfile',
        builder: (context, state) => ContactProfileScreen(
          conversationId: state.pathParameters['conversationId'] ?? '',
        ),
      ),
      GoRoute(
        path: Routes.groupInfo,
        name: 'groupInfo',
        builder: (context, state) => GroupInfoScreen(
          conversationId: state.pathParameters['conversationId'],
        ),
      ),
      GoRoute(
        path: Routes.sharedMedia,
        name: 'sharedMedia',
        builder: (context, state) => SharedMediaScreen(
          conversationId: state.pathParameters['conversationId'] ?? '',
        ),
      ),
      GoRoute(
        path: Routes.videoPlayer,
        name: 'videoPlayer',
        builder: (context, state) => VideoPlayerScreen(
          conversationId: state.pathParameters['conversationId'] ?? '',
          envelopeId: state.pathParameters['envelopeId'] ?? '',
        ),
      ),
      GoRoute(
        path: Routes.settings,
        name: 'settings',
        builder: (context, state) => const SettingsHubScreen(),
      ),
      GoRoute(
        path: Routes.settingsAppearance,
        name: 'settingsAppearance',
        builder: (context, state) => const AppearanceScreen(),
      ),
      GoRoute(
        path: Routes.settingsAbout,
        name: 'settingsAbout',
        builder: (context, state) => const AboutScreen(),
      ),
      GoRoute(
        path: Routes.settingsNotifications,
        name: 'settingsNotifications',
        builder: (context, state) => const NotificationsScreen(),
      ),
      GoRoute(
        path: Routes.settingsEditProfile,
        name: 'settingsEditProfile',
        builder: (context, state) => const EditProfileScreen(),
      ),
      GoRoute(
        path: Routes.settingsPrivacy,
        name: 'settingsPrivacy',
        builder: (context, state) => const PrivacyScreen(),
      ),
      GoRoute(
        path: Routes.settingsNetwork,
        name: 'settingsNetwork',
        builder: (context, state) => const NetworkScreen(),
      ),
      GoRoute(
        path: Routes.settingsBlocks,
        name: 'settingsBlocks',
        builder: (context, state) => const BlocksScreen(),
      ),
      GoRoute(
        path: Routes.settingsRecoveryPhrase,
        name: 'settingsRecoveryPhrase',
        builder: (context, state) => const RecoveryPhraseRevealSettingsScreen(),
      ),
      GoRoute(
        path: Routes.settingsLinkedDevices,
        name: 'settingsLinkedDevices',
        builder: (context, state) => const LinkedDevicesScreen(),
      ),
    ],
  );
}

/// Renders the share-target picker from the pending-share state, falling back
/// to the chat list when there is nothing to share.
class _ShareTargetRoute extends ConsumerWidget {
  const _ShareTargetRoute();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final share = ref.watch(pendingShareProvider);
    if (share == null) return const ChatListScreen();
    return ShareTargetScreen(share: share);
  }
}

class _NewGroupRoute extends ConsumerWidget {
  const _NewGroupRoute();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FutureBuilder<String?>(
      future: ref.read(sessionRepositoryProvider).current().then((s) => s?.username),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        final username = snap.data;
        if (username == null) {
          // Should never happen — go_router redirect bounces unauthenticated
          // users to /welcome before this route is reached.
          return const Scaffold(body: Center(child: Text('Not signed in')));
        }
        return CreateGroupScreen(selfUsername: username);
      },
    );
  }
}
