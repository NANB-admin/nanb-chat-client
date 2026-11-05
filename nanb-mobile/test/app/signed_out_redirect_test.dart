import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/app/router.dart';

/// The signed-out guard runs when the server has rejected this device
/// (revoked/deleted) or the user signed out non-destructively. It must still
/// let the user ONBOARD — otherwise a device whose account no longer exists is
/// bricked, which is what happened on iOS after an app reinstall resurrected a
/// stale keychain session.
void main() {
  test('lets the welcome screen through', () {
    expect(signedOutRedirect(Routes.welcome), isNull);
  });

  test('lets create-account through', () {
    expect(signedOutRedirect(Routes.username), isNull);
  });

  test('lets recovery-phrase setup through', () {
    expect(signedOutRedirect(Routes.recoverySetup), isNull);
  });

  test('lets restore-from-phrase through', () {
    expect(signedOutRedirect(Routes.restore), isNull);
  });

  test('lets link-new-device through', () {
    expect(signedOutRedirect(Routes.linkNewDevice), isNull);
  });

  test('lets the network settings screen through', () {
    expect(signedOutRedirect(Routes.settingsNetwork), isNull);
  });

  test('sends the chat list back to welcome', () {
    expect(signedOutRedirect(Routes.chatList), Routes.welcome);
  });

  test('sends an open conversation back to welcome', () {
    expect(signedOutRedirect('/chat/abc-123'), Routes.welcome);
  });

  test('sends other settings screens back to welcome', () {
    expect(signedOutRedirect(Routes.settingsPrivacy), Routes.welcome);
  });

  test('sends linked-devices back to welcome', () {
    expect(signedOutRedirect(Routes.settingsLinkedDevices), Routes.welcome);
  });

  test('sends the share-target screen back to welcome', () {
    expect(signedOutRedirect(Routes.shareTarget), Routes.welcome);
  });
}
