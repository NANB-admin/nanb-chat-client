import Flutter
import Foundation

// ============================================================================
// Embedded Tor engine for iOS — now backed by ARTI (the Tor Project's pure-Rust
// Tor) via the nanb-arti-ffi static library (libnanb_arti.a, the NanbArti pod),
// REPLACING the previous C-tor (Tor.framework).
//
// Why the swap: C-tor cannot be cleanly stopped (a control SIGNAL HALT calls
// exit(), killing the host app). After a long iOS suspend its libevent loop
// wedges and never recovers in place, so background→reopen hung forever on
// "Reconnecting via Tor". We proved on-device that no in-process revival is
// possible (SIGHUP doesn't wake it; a second C-tor instance corrupts its global
// state; idling before suspend wedges anyway). Arti is a real library with a
// clean lifecycle, so the resume path is simply stop() + start() — no wedge.
//
// The `nanb_arti_*` C functions are exposed to Swift via the Runner bridging
// header (#import <NanbArti/nanb_arti.h>). We POLL the FFI for bootstrap
// progress / readiness / the SOCKS port (matching the proven Android/iOS poll
// model) and translate to the EventChannel contract — no callbacks from Rust.
//
// Channel contract — UNCHANGED (matches the Dart TorEngineChannel + Android):
//   - MethodChannel `nanb.app/tor`        : start / stop / reconnect /
//                                           prepareForBackground / wake (no args)
//   - EventChannel  `nanb.app/tor_status` : Map{phase, percent?, socksPort?, message?}
//       phase ∈ off | starting | bootstrapping | connected | error
// ============================================================================

final class TorChannel: NSObject, FlutterStreamHandler {
  static let methodChannelName = "nanb.app/tor"
  static let eventChannelName = "nanb.app/tor_status"
  private static let tag = "NANBARTI"
  private static let pollInterval: TimeInterval = 1.0
  private static let connectDeadline: TimeInterval = 180

  private var sink: FlutterEventSink?
  private var pollGeneration = 0 // bump to cancel an in-flight poll loop
  private var started = false

  static func register(with messenger: FlutterBinaryMessenger) {
    let handler = TorChannel()
    let method = FlutterMethodChannel(name: methodChannelName, binaryMessenger: messenger)
    method.setMethodCallHandler { call, result in handler.onCall(call, result: result) }
    let events = FlutterEventChannel(name: eventChannelName, binaryMessenger: messenger)
    events.setStreamHandler(handler)
  }

  // MARK: - FlutterStreamHandler

  func onListen(withArguments _: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    return nil
  }

  func onCancel(withArguments _: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  // MARK: - MethodChannel

  private func onCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "start":
      start()
      result(nil)
    case "stop":
      stop()
      result(nil)
    case "reconnect":
      reconnect()
      result(nil)
    case "prepareForBackground":
      // Pause → dormant: suspend Arti's background upkeep before the OS suspends
      // us, keeping the client + SOCKS port warm so resume is a cheap wake rather
      // than a full re-bootstrap (the slow part of a foregrounded reopen).
      setDormant(true)
      result(nil)
    case "wake":
      // Resume → wake: resume background upkeep. (Arti also auto-wakes on first
      // use, so this just gets preemptive circuits building again.)
      setDormant(false)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Lifecycle

  /// Arti's state + cache directory: the app's Application Support dir (the Rust
  /// side creates `arti-state` / `arti-cache` subdirs under it).
  private func dataDir() -> String {
    let base = (try? FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask,
      appropriateFor: nil, create: true)) ?? URL(fileURLWithPath: NSTemporaryDirectory())
    return base.appendingPathComponent("arti", isDirectory: true).path
  }

  private func start() {
    if started { return }
    started = true
    emit(phase: "starting")
    emit(phase: "bootstrapping", percent: 0)
    let dir = dataDir()
    DispatchQueue.global(qos: .utility).async { [weak self] in
      let rc = dir.withCString { nanb_arti_start($0) }
      guard let self = self else { return }
      if rc != 0 {
        self.emit(phase: "error", message: self.artiError() ?? "Tor (Arti) failed to start (\(rc)).")
        return
      }
      self.startPolling()
    }
  }

  private func stop() {
    pollGeneration += 1 // cancel any in-flight poll loop
    started = false
    DispatchQueue.global(qos: .utility).async { nanb_arti_stop() }
    emit(phase: "off")
    NSLog("\(Self.tag) stop requested")
  }

  /// Resume path (Dart calls this from `app.dart` onResumed when built-in Tor is
  /// on): cleanly stop + start a fresh Arti instance. Unlike C-tor, Arti has no
  /// exit()-only shutdown, so this just works — the iOS-suspend wedge is gone.
  private func reconnect() {
    pollGeneration += 1 // cancel any in-flight poll loop
    emit(phase: "bootstrapping", percent: 0)
    let dir = dataDir()
    DispatchQueue.global(qos: .utility).async { [weak self] in
      nanb_arti_stop() // blocks briefly for clean teardown (releases data-dir locks)
      let rc = dir.withCString { nanb_arti_start($0) }
      guard let self = self else { return }
      if rc != 0 {
        self.emit(phase: "error", message: self.artiError() ?? "Tor (Arti) restart failed (\(rc)).")
        return
      }
      self.started = true
      self.startPolling()
    }
  }

  /// Suspend/resume Arti's background activity around an app pause/resume
  /// without tearing it down (keeps the client + SOCKS port warm). Off the main
  /// thread — a FFI hop shouldn't block the platform-channel callback. The
  /// native side no-ops until the engine has bootstrapped.
  private func setDormant(_ dormant: Bool) {
    DispatchQueue.global(qos: .utility).async { nanb_arti_set_dormant(dormant) }
  }

  // MARK: - Bootstrap polling

  private func startPolling() {
    pollGeneration += 1
    let generation = pollGeneration
    let deadline = Date().addingTimeInterval(Self.connectDeadline)
    poll(generation: generation, deadline: deadline)
  }

  private func poll(generation: Int, deadline: Date) {
    if generation != pollGeneration { return }

    let pct = Int(nanb_arti_bootstrap_pct())
    if nanb_arti_is_ready() {
      let port = Int(nanb_arti_socks_port())
      if port > 0 {
        NSLog("\(Self.tag) connected: socks=\(port)")
        emit(phase: "connected", percent: 100, socksPort: port)
        return
      }
    }
    if Date() > deadline {
      emit(phase: "error",
           message: artiError() ?? "Tor (Arti) is taking longer than usual (stalled at \(pct)%).")
      return
    }
    emit(phase: "bootstrapping", percent: pct)

    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.pollInterval) { [weak self] in
      self?.poll(generation: generation, deadline: deadline)
    }
  }

  // MARK: - Helpers

  /// Copies the Rust side's last error string (valid only until the next FFI
  /// error), or nil.
  private func artiError() -> String? {
    guard let ptr = nanb_arti_last_error() else { return nil }
    let s = String(cString: ptr)
    return s.isEmpty ? nil : s
  }

  private func emit(phase: String, percent: Int? = nil, socksPort: Int? = nil, message: String? = nil) {
    var map: [String: Any] = ["phase": phase]
    if let percent = percent { map["percent"] = percent }
    if let socksPort = socksPort { map["socksPort"] = socksPort }
    if let message = message { map["message"] = message }
    DispatchQueue.main.async { [weak self] in self?.sink?(map) }
  }
}
