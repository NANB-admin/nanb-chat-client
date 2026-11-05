import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  // Retains the monotonic-clock channel (registered below) for the app's
  // lifetime so it keeps handling calls.
  private var monotonicClockChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Plan D Task 15 — request notification authorization + register
    // for remote notifications so APNs delivers wakeup pushes. The
    // firebase_messaging plugin (registered via GeneratedPluginRegistrant
    // in didInitializeImplicitFlutterEngine) consumes the APNs token
    // automatically once registration completes.
    UNUserNotificationCenter.current().requestAuthorization(
      options: [.alert, .badge, .sound]
    ) { granted, _ in
      if granted {
        DispatchQueue.main.async {
          application.registerForRemoteNotifications()
        }
      }
    }
    // PushKit (VoIP) registration for the CallKit ring. Started HERE, before
    // the Flutter engine, because a VoIP push can arrive during a cold launch
    // and iOS requires it to be reported to CallKit in that same callback —
    // there is no waiting for Dart. Needs NO notification permission: a VoIP
    // push is not a notification, which is also why it reaches a locked phone
    // that an alert push can only buzz at.
    VoipPushChannel.shared.startRegistration()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    let registry = engineBridge.pluginRegistry
    GeneratedPluginRegistrant.register(with: registry)
    // FlutterImplicitEngineBridge exposes a FlutterPluginRegistry, not a raw
    // FlutterEngine. Pull this plugin's registrar from it and hand its binary
    // messenger to the channel — the canonical Swift-plugin registration path.
    if let registrar = registry.registrar(forPlugin: "NanbCryptoChannel") {
      NanbCryptoChannel.register(with: registrar.messenger())
    }
    // Embedded Tor engine (counterpart to Android's TorChannel) — drives the
    // `nanb.app/tor` + `nanb.app/tor_status` channels the Dart TorEngineChannel
    // expects, so the SOCKS-aware networking can route through in-app Tor.
    if let torRegistrar = registry.registrar(forPlugin: "TorChannel") {
      TorChannel.register(with: torRegistrar.messenger())
    }
    // Mirrors the few values the Notification Service Extension needs into the
    // shared App Group container (the NSE can't read the app's keychain).
    if let sharedRegistrar = registry.registrar(forPlugin: "SharedStoreChannel") {
      SharedStoreChannel.register(with: sharedRegistrar.messenger())
    }
    // Collects content the share extension parked in the App Group container
    // ("Share via Chat" from another app's share sheet). Counterpart to
    // Android's MainActivity incoming_share handler. Dart side:
    // lib/core/platform/incoming_share_channel.dart.
    if let shareRegistrar = registry.registrar(forPlugin: "IncomingShareChannel") {
      IncomingShareChannel.register(with: shareRegistrar.messenger())
    }
    // FLAG_SECURE-equivalent screenshot blocking + detection (counterpart to
    // Android's MainActivity secure_screen handler). Dart side:
    // lib/core/platform/secure_screen.dart.
    if let secureRegistrar = registry.registrar(forPlugin: "SecureScreenChannel") {
      SecureScreenChannel.register(with: secureRegistrar.messenger())
    }
    // Keep the screen awake for the live span of a call (counterpart to Android's
    // MainActivity call_window handler → FLAG_KEEP_SCREEN_ON). Without this an
    // iPhone Auto-Locks mid video call and suspends the app, dropping the call.
    // Dart side: lib/core/platform/call_window.dart.
    if let callWindowRegistrar = registry.registrar(forPlugin: "CallWindowChannel") {
      CallWindowChannel.register(with: callWindowRegistrar.messenger())
    }
    // CallKit ring bridge: hands Dart the PushKit token to register, replays
    // any incoming-call / answer / hangup events that landed before this
    // engine existed, and lets Dart refine the caller name + end the system
    // call UI. Dart side: lib/core/push/voip_push_channel.dart.
    if let voipRegistrar = registry.registrar(forPlugin: "VoipPushChannel") {
      VoipPushChannel.register(with: voipRegistrar.messenger())
    }
    // Boot-relative monotonic clock for the passcode brute-force lockout —
    // counterpart to Android's SystemClock.elapsedRealtime(). systemUptime is
    // unaffected by wall-clock changes, so "roll the clock forward to skip the
    // lockout" can't work. Dart side: lib/core/platform/monotonic_clock.dart.
    if let clockRegistrar = registry.registrar(forPlugin: "MonotonicClock") {
      let channel = FlutterMethodChannel(
        name: "nanb.app/monotonic_clock",
        binaryMessenger: clockRegistrar.messenger())
      channel.setMethodCallHandler { call, result in
        if call.method == "elapsedRealtimeMs" {
          result(Int(ProcessInfo.processInfo.systemUptime * 1000))
        } else {
          result(FlutterMethodNotImplemented)
        }
      }
      self.monotonicClockChannel = channel
    }
  }
}
