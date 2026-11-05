import Flutter
import Foundation
import PushKit

/// PushKit (VoIP) receiver and the `nanb.app/voip_push` bridge to Dart.
///
/// Why PushKit at all: an ordinary alert push cannot ring a locked iPhone — iOS
/// renders it as a passive banner and runs no app code, so an incoming call
/// looked like (and was easily lost among) chat notifications. A VoIP push is
/// delivered even when the app is suspended or has never been launched, and it
/// is the only way to reach `CallKitCenter` in time to ring.
///
/// **The hard iOS rule this class exists to honour:** every VoIP push MUST be
/// reported to CallKit inside `didReceiveIncomingPushWith`, before its
/// completion handler runs. iOS kills an app that doesn't, and a repeat
/// offender stops receiving VoIP pushes altogether. So the report happens here,
/// natively and unconditionally, with whatever caller name is to hand — never
/// gated on the Flutter engine, which may not exist yet.
///
/// Dart then refines it: it resolves the real conversation (opening the inlined
/// sealed blob, which the server cannot do for us) and the peer's name, mirrors
/// them back with `updateCaller`, and drives accept/hangup. Events that land
/// before Dart attaches are buffered in [pending] and drained by
/// `takePendingEvents`, which is what makes "answer from the lock screen with
/// the app killed" work.
///
/// Channel contract (mirrors `VoipPushChannel` on the Dart side):
///   - Dart → native: `getToken`, `takePendingEvents`, `updateCaller(name)`,
///     `endCall`
///   - native → Dart: `voipToken(token)`, `incomingCall(payload)`, `answerCall`,
///     `endCall`
final class VoipPushChannel: NSObject {
    static let shared = VoipPushChannel()

    static let channelName = "nanb.app/voip_push"

    private var channel: FlutterMethodChannel?
    private var registry: PKPushRegistry?
    private var token: String?

    /// Native→Dart events that arrived while no engine was attached. Each is
    /// `["event": <name>, ...payload]`.
    private var pending: [[String: Any]] = []

    /// Starts PushKit registration. Called from `didFinishLaunchingWithOptions`
    /// — BEFORE the Flutter engine — so the delegate is in place for a push
    /// that arrives during a cold launch.
    func startRegistration() {
        guard registry == nil else { return }
        NSLog("NANBCALL pushkit registration started")
        let r = PKPushRegistry(queue: .main)
        r.delegate = self
        r.desiredPushTypes = [.voIP]
        registry = r
        // Route the system call UI's buttons into Dart.
        CallKitCenter.shared.onAnswer = { [weak self] in
            self?.emit(["event": "answerCall"])
        }
        CallKitCenter.shared.onEnd = { [weak self] in
            self?.emit(["event": "endCall"])
        }
    }

    static func register(with messenger: FlutterBinaryMessenger) {
        let instance = VoipPushChannel.shared
        let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
        instance.channel = channel
        channel.setMethodCallHandler { call, result in instance.onCall(call, result: result) }
    }

    private func onCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "getToken":
            result(token)
        case "takePendingEvents":
            let drained = pending
            pending = []
            result(drained)
        case "updateCaller":
            let name = (call.arguments as? [String: Any])?["name"] as? String ?? ""
            CallKitCenter.shared.updateCaller(name)
            result(nil)
        case "endCall":
            CallKitCenter.shared.endCall()
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// Delivers an event to Dart, buffering it when no engine is listening.
    /// Buffering (rather than dropping) is the whole cold-launch path: the
    /// answer tap happens seconds before Dart exists.
    private func emit(_ event: [String: Any]) {
        guard let channel = channel else {
            pending.append(event)
            return
        }
        channel.invokeMethod(event["event"] as? String ?? "", arguments: event)
    }
}

extension VoipPushChannel: PKPushRegistryDelegate {
    func pushRegistry(
        _ registry: PKPushRegistry,
        didUpdate pushCredentials: PKPushCredentials,
        for type: PKPushType
    ) {
        guard type == .voIP else { return }
        let hex = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
        // Only a short prefix: enough to tell a changed token apart in a log.
        NSLog("NANBCALL voip token %@... (was %@...)",
              String(hex.prefix(8)), String((token ?? "none").prefix(8)))
        token = hex
        emit(["event": "voipToken", "token": hex])
    }

    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        guard type == .voIP else { return }
        token = nil
    }

    func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping () -> Void
    ) {
        guard type == .voIP else {
            completion()
            return
        }
        // Release builds have no console; these NANBCALL lines are what the
        // device syslog shows when a ring goes missing (a 0xBAADCA11 kill means
        // the app took a VoIP push and never reported it — they say how far it
        // got). Read them with `pymobiledevice3 syslog live`.
        NSLog("NANBCALL voip push received (call already up: %@)",
              CallKitCenter.shared.hasActiveCall ? "yes" : "no")
        // REPORT FIRST — see the class doc. The server is content-blind (and,
        // under sealed sender, conversation-blind), so there is no real name in
        // the payload; CallKitCenter falls back to the app name and Dart
        // replaces it via `updateCaller` once it has decrypted enough to know.
        CallKitCenter.shared.reportIncomingCall(callerName: "") {
            completion()
        }
        var event: [String: Any] = ["event": "incomingCall"]
        for (key, value) in payload.dictionaryPayload {
            guard let k = key as? String else { continue }
            // Only the string routing keys we put on the wire (envelope_id,
            // conversation_id, push_kind, sealed_payload).
            if let s = value as? String { event[k] = s }
        }
        emit(event)
    }
}
