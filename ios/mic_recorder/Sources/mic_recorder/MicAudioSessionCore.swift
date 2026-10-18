import AVFoundation
import Flutter
import Foundation

/// The plugin's native audio-session layer on Apple platforms,
/// implemented directly against `AVAudioSession`.
///
/// It owns the session verbs of the wire contract —
/// `configureAudioSession`, `setAudioSessionActive`,
/// `isOtherAudioPlaying` and
/// `setAllowHapticsAndSystemSoundsDuringRecording` — plus the input and
/// route queries (`getAvailableInputs`, `getCurrentRoute`,
/// `setPreferredInput`), and it forwards the OS's interruption and
/// route-change notifications to Dart on the plugin's session_events
/// channel:
///
/// * `{event: 'interruption', type: 0|1, shouldResume: Bool,
///   wasSuspended?: Bool}` — `type` 0 = began, 1 = ended; the optional
///   `wasSuspended` key is present only when the OS reports it, and its
///   absence decodes to null on the Dart side.
/// * `{event: 'routeChange', reason: Int}` — the raw
///   `AVAudioSession.RouteChangeReason` value.
///
/// The notification observers are installed once, on the main queue,
/// when the core is created and stay installed for the plugin's
/// lifetime: cancelling the session_events stream only detaches the
/// sink — the next listen simply resumes event delivery.
public final class MicAudioSessionCore: NSObject {

    // MARK: State

    /// The sink receiving session_events maps on the main queue, or nil
    /// while the channel has no listener.
    private var sessionEventSink: FlutterEventSink?

    /// The shared audio session this layer configures.
    private let audioSession: AVAudioSession

    /// Whether a deactivation should tell other apps they may resume.
    ///
    /// The setAudioSessionActive wire verb carries only the `active`
    /// flag, so this is captured from the last configureAudioSession
    /// call (the Dart-side default is true).
    private var notifyOthersOnDeactivation = true

    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?

    // MARK: Lifecycle

    public override init() {
        audioSession = AVAudioSession.sharedInstance()

        super.init()

        startObservingNotifications()
    }

    deinit {
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
        }

        if let observer = routeChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Attaches the session_events sink, or detaches it with nil. The
    /// observers are unaffected — only the sink is dropped.
    public func setSessionEventSink(_ sink: FlutterEventSink?) {
        sessionEventSink = sink
    }

    // MARK: Configuration verbs

    /// The Bluetooth-HFP category option, spelled for the compiling
    /// SDK.
    ///
    /// `.allowBluetooth` was renamed to `.allowBluetoothHFP` in the
    /// Xcode 26 SDK — the same bit, documented as available since
    /// iOS 1.0 — so the spelling is picked at compile time: newest
    /// toolchains use the modern name, older ones the (merely
    /// deprecated) legacy name. Runtime behavior is identical on every
    /// iOS version.
    #if compiler(>=6.2)
    private static let bluetoothHfpOption = AVAudioSession.CategoryOptions.allowBluetoothHFP
    #else
    private static let bluetoothHfpOption = AVAudioSession.CategoryOptions.allowBluetooth
    #endif

    /// Applies the configuration map to the shared session.
    ///
    /// The recorder's category is `.playAndRecord` in mode `.default`.
    /// The map's keys and their defaults:
    /// * `allowBluetooth` (default true) — inserts the Bluetooth-HFP
    ///   option (see `bluetoothHfpOption`);
    /// * `defaultToSpeaker` (default true) — the `.defaultToSpeaker`
    ///   option;
    /// * `notifyOthersOnDeactivation` (default true) — stored and
    ///   applied by the next deactivation;
    /// * `willPauseWhenDucked` — the Android focus flag; no iOS
    ///   effect.
    ///
    /// Returns false when the session rejects the category.
    @discardableResult
    public func configureAudioSession(config: [String: Any]) -> Bool {
        let allowBluetooth = (config["allowBluetooth"] as? Bool) ?? true
        let defaultToSpeaker = (config["defaultToSpeaker"] as? Bool) ?? true
        notifyOthersOnDeactivation = (config["notifyOthersOnDeactivation"] as? Bool) ?? true
        // willPauseWhenDucked: an Android focus-policy flag — ignored.

        var options: AVAudioSession.CategoryOptions = []

        if allowBluetooth {
            options.insert(Self.bluetoothHfpOption)
        }

        if defaultToSpeaker {
            options.insert(.defaultToSpeaker)
        }

        do {
            try audioSession.setCategory(
                .playAndRecord,
                mode: .default,
                options: options
            )

            return true
        } catch {
            print("mic_recorder: setting the audio session category failed: \(error.localizedDescription)")

            return false
        }
    }

    /// Activates or deactivates the shared session.
    ///
    /// A deactivation passes `.notifyOthersOnDeactivation` when the
    /// last configureAudioSession captured that flag, so other apps
    /// that paused for this session learn they may resume; an
    /// activation passes no options.
    @discardableResult
    public func setAudioSessionActive(active: Bool) -> Bool {
        var options: AVAudioSession.SetActiveOptions = []

        if !active && notifyOthersOnDeactivation {
            options.insert(.notifyOthersOnDeactivation)
        }

        do {
            try audioSession.setActive(active, options: options)

            return true
        } catch {
            print("mic_recorder: setting the audio session active=\(active) failed: \(error.localizedDescription)")

            return false
        }
    }

    /// Whether audio from other (non-this-app) sources is currently
    /// playing.
    public func isOtherAudioPlaying() -> Bool {
        return audioSession.isOtherAudioPlaying
    }

    /// Sets the session's allow-haptics-and-system-sounds flag.
    ///
    /// The flag is an `AVAudioSession` property in its own right — it
    /// is NOT a category option — so it is applied with the session's
    /// dedicated setter (available since iOS 13; the deployment target
    /// is 15.0, so no availability guard is needed).
    @discardableResult
    public func setAllowHapticsAndSystemSoundsDuringRecording(enabled: Bool) -> Bool {
        do {
            try audioSession.setAllowHapticsAndSystemSoundsDuringRecording(enabled)

            return true
        } catch {
            print("mic_recorder: setting haptics and system sounds during recording failed: \(error.localizedDescription)")

            return false
        }
    }

    // MARK: Input and route queries

    /// The available input ports as `{uid, portType, portName}` maps —
    /// empty when the session reports none.
    public func getAvailableInputs() -> [[String: Any]] {
        return (audioSession.availableInputs ?? []).map(encodePort)
    }

    /// The current route as `{inputs: [...], outputs: [...]}` with
    /// `{uid, portType, portName}` port maps.
    public func getCurrentRoute() -> [String: Any] {
        return [
            "inputs": audioSession.currentRoute.inputs.map(encodePort),
            "outputs": audioSession.currentRoute.outputs.map(encodePort)
        ]
    }

    /// Selects the available input whose `uid` matches, for subsequent
    /// capture. Returns false when no input matches or the session
    /// rejects the change.
    @discardableResult
    public func setPreferredInput(uid: String) -> Bool {
        guard let input = (audioSession.availableInputs ?? []).first(where: { $0.uid == uid }) else {
            return false
        }

        do {
            try audioSession.setPreferredInput(input)

            return true
        } catch {
            print("mic_recorder: preferring input \(uid) failed: \(error.localizedDescription)")

            return false
        }
    }

    /// Encodes one port description with the wire keys.
    private func encodePort(_ port: AVAudioSessionPortDescription) -> [String: Any] {
        return [
            "uid": port.uid,
            "portType": port.portType.rawValue,
            "portName": port.portName
        ]
    }

    // MARK: Notification observers

    /// Installs the interruption and route-change observers on the
    /// main queue — once, at init.
    private func startObservingNotifications() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.forwardInterruption(notification)
        }

        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.forwardRouteChange(notification)
        }
    }

    /// Decodes an interruption notification and forwards it on
    /// session_events:
    /// `{event: 'interruption', type: 0|1, shouldResume, wasSuspended?}`.
    private func forwardInterruption(_ notification: Notification) {
        guard let sink = sessionEventSink else { return }

        let userInfo = notification.userInfo ?? [:]

        guard let rawType = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }

        let rawOptions = (userInfo[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.uintValue ?? 0
        let shouldResume = (rawOptions & AVAudioSession.InterruptionOptions.shouldResume.rawValue) != 0

        var event: [String: Any] = [
            "event": "interruption",
            "type": type == .began ? 0 : 1,
            "shouldResume": shouldResume
        ]

        // Reported since iOS 10.3 — the deployment target (15.0) is
        // newer, so the key needs no availability guard: it is simply
        // absent when the OS does not report it, and Dart then decodes
        // null.
        if let wasSuspended = userInfo[AVAudioSessionInterruptionWasSuspendedKey] as? NSNumber {
            event["wasSuspended"] = wasSuspended.boolValue
        }

        sink(event)
    }

    /// Decodes a route-change notification and forwards it on
    /// session_events: `{event: 'routeChange', reason: Int}`.
    private func forwardRouteChange(_ notification: Notification) {
        guard let sink = sessionEventSink else { return }

        guard let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue else { return }

        sink([
            "event": "routeChange",
            "reason": Int(reason)
        ])
    }
}
