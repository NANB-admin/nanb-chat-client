import Flutter
import UIKit

/// iOS counterpart to Android's `nanb.app/call_window` handler in
/// `MainActivity.kt`. Keeps the screen awake for the live span of a call so an
/// active video call doesn't Auto-Lock — the iPhone idle timer would otherwise
/// blank the screen after the user's *Settings → Display & Brightness →
/// Auto-Lock* interval and, since the app has no `voip` background mode, suspend
/// the app and drop the call.
///
/// Android additionally shows the call over the keyguard (`FLAG_SHOW_WHEN_LOCKED`
/// / `FLAG_TURN_SCREEN_ON`); iOS gives an app no control over the OS lock screen,
/// so here `engage`/`release` own only the idle (Auto-Lock) timer. Keeping an
/// *audio* call alive once the user manually locks is a separate concern handled
/// by the `audio` `UIBackgroundModes` entry, not this channel.
///
/// Channel contract (matches the Dart `CallWindow` + Android):
///   - Dart → native: `engage` (disable Auto-Lock), `release` (restore it).
final class CallWindowChannel: NSObject {
  static let channelName = "nanb.app/call_window"

  private var channel: FlutterMethodChannel?

  static func register(with messenger: FlutterBinaryMessenger) {
    let instance = CallWindowChannel()
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    instance.channel = channel
    channel.setMethodCallHandler { call, result in instance.onCall(call, result: result) }
  }

  private func onCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "engage":
      // `isIdleTimerDisabled` must be set on the main thread (UIApplication).
      DispatchQueue.main.async { UIApplication.shared.isIdleTimerDisabled = true }
      result(nil)
    case "release":
      DispatchQueue.main.async { UIApplication.shared.isIdleTimerDisabled = false }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
