import AVFoundation
import CallKit
import Foundation
import WebRTC

/// Owns the app's single `CXProvider` — the system call UI.
///
/// This is what makes an incoming call on a LOCKED iPhone ring like a phone
/// call instead of arriving as a notification banner. Before CallKit the only
/// thing a locked device got was an alert push, which iOS renders as a passive
/// banner (and, sharing a collapse id with message pushes, could be replaced by
/// the next one outright) — so calls were routinely missed.
///
/// A singleton, and deliberately independent of the Flutter engine: a PushKit
/// ring can arrive when the app is suspended or has never been launched, and
/// iOS requires it to be reported to CallKit in that same callback. So the
/// native side reports FIRST (with whatever name it has) and Dart refines it
/// afterwards via [updateCaller].
///
/// Scope matches [CallController]: exactly ONE call at a time, so there is a
/// single `currentCallID` rather than a call registry.
final class CallKitCenter: NSObject {
    static let shared = CallKitCenter()

    /// Fired when the user answers from the system call UI. The Flutter side
    /// accepts the call; if the engine isn't up yet, [VoipPushChannel] buffers
    /// this until Dart attaches.
    var onAnswer: (() -> Void)?

    /// Fired when the user declines or hangs up from the system call UI.
    var onEnd: (() -> Void)?

    private lazy var provider: CXProvider = {
        // iOS 14+ initializer: `localizedName` comes from the app's display
        // name ("Chat"), so there is nothing to keep in sync here.
        let config = CXProviderConfiguration()
        config.maximumCallsPerCallGroup = 1
        config.maximumCallGroups = 1
        // `.generic` because the handle we show is a username, not a phone
        // number or an email — iOS must not try to make it dialable.
        config.supportedHandleTypes = [.generic]
        // Video is NOT advertised: a video call still runs, it is simply
        // presented as an audio call by the system UI. Claiming video would
        // make iOS offer a camera-on answer button whose state we would then
        // have to keep in step with the in-app camera toggle for no user gain.
        config.supportsVideo = false
        let p = CXProvider(configuration: config)
        p.setDelegate(self, queue: nil)
        return p
    }()

    private var currentCallID: UUID?
    private var pendingAnswerCallID: UUID?

    /// Reports a ring to the system. Safe to call from
    /// `didReceiveIncomingPushWith`, which is REQUIRED to report before its
    /// completion handler runs — iOS terminates an app that takes a VoIP push
    /// without reporting a call, and repeat offenders stop receiving them.
    ///
    /// [completion] runs once iOS has accepted (or rejected) the report.
    func reportIncomingCall(callerName: String, completion: (() -> Void)? = nil) {
        let update = callUpdate(callerName: callerName)
        // A second VoIP push while a ring is already up (a duplicate wakeup: the
        // server's retry queue, two device rows sharing this phone's token, or
        // an APNs redelivery) MUST STILL BE REPORTED. Returning without a report
        // — what this used to do — gets the app killed with 0xBAADCA11, which
        // takes the live ring down with it, and iOS then stops delivering VoIP
        // pushes to the app at all (that kill-then-silence pattern was seen
        // on-device 2026-10-21: after one unreported push no later call rang).
        // Report it as its own call and end it immediately, leaving the real
        // ring untouched.
        if currentCallID != nil {
            let duplicate = UUID()
            provider.reportNewIncomingCall(with: duplicate, update: update) { [weak self] error in
                NSLog("NANBCALL duplicate ring reported (error: %@)",
                      error.map { String(describing: $0) } ?? "none")
                if error == nil {
                    self?.provider.reportCall(with: duplicate, endedAt: Date(), reason: .failed)
                }
                completion?()
            }
            return
        }
        let id = UUID()
        currentCallID = id
        provider.reportNewIncomingCall(with: id, update: update) { [weak self] error in
            NSLog("NANBCALL ring reported (error: %@)",
                  error.map { String(describing: $0) } ?? "none")
            if error != nil {
                // iOS refused the report (e.g. Do Not Disturb + no permission,
                // or a malformed update). Drop our handle so a later ring can
                // still be reported rather than being suppressed as "busy".
                self?.currentCallID = nil
            }
            completion?()
        }
    }

    private func callUpdate(callerName: String) -> CXCallUpdate {
        let update = CXCallUpdate()
        update.localizedCallerName = callerName.isEmpty ? "Chat" : callerName
        update.remoteHandle = CXHandle(type: .generic, value: callerName.isEmpty ? "Chat" : callerName)
        update.hasVideo = false
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false
        return update
    }

    /// Replaces the displayed caller name once Dart has resolved it. The push
    /// is content-blind (and, under sealed sender, conversation-blind), so the
    /// first report often says only "Chat"; this fills in the real peer.
    func updateCaller(_ name: String) {
        guard let id = currentCallID, !name.isEmpty else { return }
        let update = CXCallUpdate()
        update.localizedCallerName = name
        update.remoteHandle = CXHandle(type: .generic, value: name)
        provider.reportCall(with: id, updated: update)
    }

    /// Tears the system call UI down. Called when the Dart call ends for ANY
    /// reason — including "we decided not to ring after all" (a blocked or
    /// non-callable peer), which would otherwise leave a phantom ring on
    /// screen with nothing behind it.
    func endCall(reason: CXCallEndedReason = .remoteEnded) {
        guard let id = currentCallID else { return }
        currentCallID = nil
        pendingAnswerCallID = nil
        provider.reportCall(with: id, endedAt: Date(), reason: reason)
    }

    /// Whether a system call is currently up — lets the push path tell a fresh
    /// ring from a duplicate wakeup for one already showing.
    var hasActiveCall: Bool { currentCallID != nil }
}

extension CallKitCenter: CXProviderDelegate {
    func providerDidReset(_ provider: CXProvider) {
        // The system dropped every call (e.g. the provider was reset). Mirror
        // that into the app so it doesn't believe it is still in a call.
        currentCallID = nil
        pendingAnswerCallID = nil
        onEnd?()
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        guard action.callUUID == currentCallID else {
            action.fail()
            return
        }
        // Configure without activating: CallKit activates the session AFTER
        // fulfillment. Starting WebRTC here races that activation, especially
        // while the system call screen still owns the microphone.
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        do {
            try session.setCategory(.playAndRecord, with: [.allowBluetooth])
            try session.setMode(.voiceChat)
        } catch {
            session.unlockForConfiguration()
            NSLog("NANBCALL answer audio configuration failed: %@", String(describing: error))
            action.fail()
            endCall(reason: .failed)
            onEnd?()
            return
        }
        session.unlockForConfiguration()
        pendingAnswerCallID = action.callUUID
        NSLog("NANBCALL system answer awaiting audio activation")
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        // Duplicate PushKit reports have their own UUID. An action for one
        // must never hang up the real call.
        guard action.callUUID == currentCallID else {
            action.fulfill()
            return
        }
        currentCallID = nil
        pendingAnswerCallID = nil
        onEnd?()
        action.fulfill()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        RTCAudioSession.sharedInstance().audioSessionDidActivate(audioSession)
        guard let id = pendingAnswerCallID, id == currentCallID else { return }
        pendingAnswerCallID = nil
        NSLog("NANBCALL audio activated; delivering system answer")
        onAnswer?()
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        RTCAudioSession.sharedInstance().audioSessionDidDeactivate(audioSession)
    }
}
