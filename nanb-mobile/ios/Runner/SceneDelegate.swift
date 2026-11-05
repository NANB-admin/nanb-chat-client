import Flutter
import UIKit

/// App-switcher (multitasking) snapshot privacy cover.
///
/// When the app moves to the background iOS captures a snapshot of its UI and
/// shows it in the app switcher (and keeps it in the snapshot cache on disk).
/// Without intervention that snapshot is the last open chat in PLAINTEXT, which
/// leaks into the multitasking preview and any on-device forensic read of the
/// snapshot cache. `SecureScreenChannel` only covers ACTIVE screen recording /
/// mirroring (`UIScreen.isCaptured`) — it does NOT obscure the backgrounding
/// snapshot — so we handle that here.
///
/// We add an opaque, blurred cover over the scene's key window as the scene is
/// about to deactivate (the point at which iOS takes the snapshot) and remove it
/// once the scene becomes active again. This is UNCONDITIONAL — it runs whether
/// or not the in-app lock ("app lock") is enabled — so the switcher preview
/// never shows chat content.
///
/// Implementation note: we drive this from `UIScene` lifecycle NOTIFICATIONS
/// rather than overriding `FlutterSceneDelegate`'s `sceneWillResignActive(_:)` /
/// `sceneDidBecomeActive(_:)`. The base `FlutterSceneDelegate` forwards those
/// scene callbacks to registered plugins; overriding them here would require
/// calling `super`, and observing the notifications instead lets that forwarding
/// run untouched while still obscuring the snapshot. The cover is an ordinary
/// top-most subview of the key window (never window-layer surgery), so it can't
/// shift or clip the real UI — see the CALayer note in `SecureScreenChannel`.
class SceneDelegate: FlutterSceneDelegate {

  /// The opaque privacy cover shown while the app is inactive/backgrounded.
  /// Nil while the app is active and no cover is shown.
  private var privacyCover: UIView?

  override init() {
    super.init()
    let center = NotificationCenter.default
    // Show as the scene resigns active (snapshot is taken around here), hide on
    // return to active. Observed with object: nil — this app is single-scene
    // (UIApplicationSupportsMultipleScenes == false).
    center.addObserver(
      self,
      selector: #selector(showPrivacyCover),
      name: UIScene.willDeactivateNotification,
      object: nil)
    center.addObserver(
      self,
      selector: #selector(hidePrivacyCover),
      name: UIScene.didActivateNotification,
      object: nil)
  }

  @objc private func showPrivacyCover() {
    guard privacyCover == nil, let window = Self.keyWindow() else { return }
    let cover = UIView(frame: window.bounds)
    // Opaque background first so the cover fully obscures the UI even behind the
    // blur and with "Reduce Transparency" on; adapts to light/dark.
    cover.backgroundColor = .systemBackground
    cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    cover.isUserInteractionEnabled = false

    let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    blur.frame = cover.bounds
    blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    cover.addSubview(blur)

    window.addSubview(cover)
    window.bringSubviewToFront(cover)
    privacyCover = cover
  }

  @objc private func hidePrivacyCover() {
    privacyCover?.removeFromSuperview()
    privacyCover = nil
  }

  /// The app's key window, resolved across connected scenes (mirrors
  /// `SecureScreenChannel.keyWindow()` so both overlays target the same window).
  private static func keyWindow() -> UIWindow? {
    let windows = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
    return windows.first { $0.isKeyWindow } ?? windows.first
  }
}
