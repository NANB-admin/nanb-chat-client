import Flutter
import UIKit

/// iOS counterpart to Android's `FLAG_SECURE` handling in `MainActivity.kt`.
/// Drives the `nanb.app/secure_screen` method channel the Dart `SecureScreen`
/// expects, so the user's "block screenshots" preference and a peer's
/// `peerBlocksScreenshots` request do something on iPhone.
///
/// iOS has NO true `FLAG_SECURE` and **cannot block a still screenshot at all**,
/// so this does what iOS actually allows, in two layout-SAFE ways:
///
///   - **Block** (recording / mirroring only): while secure, cover the window
///     with an opaque overlay whenever the screen is being *captured*
///     (`UIScreen.isCaptured` — screen recording or AirPlay mirroring). This is
///     just a top-most subview, added/removed as capture starts/stops, so it can
///     never shift or clip the real UI. (The previous secure-`UITextField`
///     CALayer trick re-parented the whole window layer and broke the app layout
///     on iOS 26 — pinning the UI into a corner — so it was removed.) iOS still
///     does NOT let us blank a still screenshot; that's what Detect is for.
///
///   - **Detect** (`onScreenshot`): while secure, forward
///     `userDidTakeScreenshotNotification` to Dart so the app can warn the user
///     and notify the peer — the real protection for still screenshots, which
///     nothing on iOS can prevent.
///
/// Channel contract (matches Android + the Dart `SecureScreen`):
///   - Dart → native: `setSecure` `{ "secure": Bool }`
///   - native → Dart: `onScreenshot` (no args), fired only while secure is on.
final class SecureScreenChannel: NSObject {
  static let channelName = "nanb.app/secure_screen"

  private var channel: FlutterMethodChannel?
  private var secure = false
  /// The opaque cover shown while secure AND the screen is being captured. Nil
  /// when not covering. A plain subview — never the window's own layer.
  private var overlay: UIView?

  static func register(with messenger: FlutterBinaryMessenger) {
    let instance = SecureScreenChannel()
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    instance.channel = channel
    channel.setMethodCallHandler { call, result in instance.onCall(call, result: result) }
    instance.startObservers()
  }

  private func onCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "setSecure":
      let args = call.arguments as? [String: Any]
      let enabled = (args?["secure"] as? Bool)
        ?? (args?["secure"] as? NSNumber)?.boolValue
        ?? false
      secure = enabled
      DispatchQueue.main.async { [weak self] in self?.syncOverlay() }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Block (capture overlay — recording / mirroring only)

  private func startObservers() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(captureChanged),
      name: UIScreen.capturedDidChangeNotification,
      object: nil)
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(onScreenshotTaken),
      name: UIApplication.userDidTakeScreenshotNotification,
      object: nil)
  }

  @objc private func captureChanged() {
    DispatchQueue.main.async { [weak self] in self?.syncOverlay() }
  }

  /// Show an opaque cover while secure AND the screen is being captured; remove
  /// it otherwise. The overlay is an ordinary top-most subview of the key window
  /// (no window-layer surgery), so it never shifts or clips the real UI.
  private func syncOverlay() {
    guard let window = Self.keyWindow() else { return }
    let capturing = window.screen.isCaptured
    if secure && capturing {
      if overlay == nil {
        let cover = UIView(frame: window.bounds)
        cover.backgroundColor = .black
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cover.isUserInteractionEnabled = false
        window.addSubview(cover)
        overlay = cover
      }
      overlay.map { window.bringSubviewToFront($0) }
    } else {
      overlay?.removeFromSuperview()
      overlay = nil
    }
  }

  // MARK: - Detect (screenshot notification)

  @objc private func onScreenshotTaken() {
    guard secure else { return }
    DispatchQueue.main.async { [weak self] in
      self?.channel?.invokeMethod("onScreenshot", arguments: nil)
    }
  }

  // MARK: - Helpers

  private static func keyWindow() -> UIWindow? {
    let windows = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
    return windows.first { $0.isKeyWindow } ?? windows.first
  }
}
