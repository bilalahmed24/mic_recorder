import AVFoundation
import Flutter
import UIKit

/// iOS entry point of the mic_recorder plugin.
///
/// Registers:
/// * the method channel `com.bilalahmed24.mic_recorder/methods` (every
///   wire verb; Android-only verbs reply `FlutterMethodNotImplemented`
///   because the Dart layer gates them behind `Platform.isAndroid` so
///   they never arrive here);
/// * the event channel `com.bilalahmed24.mic_recorder/audio_stream`
///   (raw 16-bit little-endian mono PCM from the capture engine, as
///   `FlutterStandardTypedData`);
/// * the event channel `com.bilalahmed24.mic_recorder/session_events`
///   (interruption and route-change maps from the audio-session core).
///
/// Malformed arguments on bool verbs reply `false` (the source
/// AppDelegate's behavior); `extractAmplitudes` replies
/// `FlutterError(INVALID_ARGUMENTS / EXTRACT_AMPLITUDES_FAILED)`.
public class MicRecorderPlugin: NSObject, FlutterPlugin {

    /// Capture engine backing start/pause/resume/stop and the PCM stream.
    private let audioService = MicAudioService()

    /// Audio-session core backing the configuration verbs and
    /// session_events.
    private let sessionCore = MicAudioSessionCore()

    /// The armed encoded output writer (fed from the audio-stream tee).
    private var encodedWriter: MicAudioFileWriter?

    /// The last sample rate the Dart layer started capture with — the
    /// encoded writer must be built for exactly the running rate.
    private var lastSampleRate: Double = 16000.0

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = MicRecorderPlugin()

        let methodChannel = FlutterMethodChannel(
            name: "com.bilalahmed24.mic_recorder/methods",
            binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(instance, channel: methodChannel)

        let audioStreamChannel = FlutterEventChannel(
            name: "com.bilalahmed24.mic_recorder/audio_stream",
            binaryMessenger: registrar.messenger())
        audioStreamChannel.setStreamHandler(
            AudioStreamHandler(service: instance.audioService, plugin: instance))

        let sessionEventsChannel = FlutterEventChannel(
            name: "com.bilalahmed24.mic_recorder/session_events",
            binaryMessenger: registrar.messenger())
        sessionEventsChannel.setStreamHandler(SessionEventsStreamHandler(core: instance.sessionCore))
    }

    /// Dispatches every wire verb on the methods channel.
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "startRecording":
            // The frozen wire contract sends the sample rate as an int;
            // parsed as NSNumber so Int and Double both decode. The
            // Android effect toggles are Android-only — accepted and
            // ignored here.
            guard let args = call.arguments as? [String: Any],
                  let sampleRate = args["sampleRate"] as? NSNumber
            else {
                result(false)
                return
            }

            lastSampleRate = sampleRate.doubleValue

            // An armed writer built for a different rate cannot be salvaged
            // mid-flight — drop it loudly rather than ship pitch-shifted
            // audio (parity with the Android plugin's start guard).
            if let writer = encodedWriter, writer.sampleRate != sampleRate.doubleValue {
                print("mic_recorder: dropping armed encoded output: sample-rate mismatch \(writer.sampleRate) != \(sampleRate.doubleValue)")

                writer.abort()
                encodedWriter = nil
            }

            result(audioService.startRecording(sampleRate: sampleRate.doubleValue))

        case "pauseRecording":
            guard let args = call.arguments as? [String: Any],
                  let isPausedForInterruption = args["isPausedForInterruption"] as? Bool
            else {
                result(false)
                return
            }

            result(audioService.pauseRecording(isPausedForInterruption: isPausedForInterruption))

        case "resumeRecording":
            // Android implements resume as a fresh start, which re-runs its
            // armed-encoder rate guard; iOS keeps the live engine instead,
            // so the guard runs here against the tracked capture rate.
            if let writer = encodedWriter, writer.sampleRate != lastSampleRate {
                print("mic_recorder: dropping armed encoded output: sample-rate mismatch \(writer.sampleRate) != \(lastSampleRate)")

                writer.abort()
                encodedWriter = nil
            }

            result(audioService.resumeRecording())

        case "stopRecording":
            let stopped = audioService.stopRecording()

            // Only the stop verb finalizes the encoded file — the pause
            // verbs deliberately keep the writer alive.
            encodedWriter?.finish()

            encodedWriter = nil

            result(stopped)

        case "setEncodedOutput":
            guard let args = call.arguments as? [String: Any],
                  let path = args["path"] as? String,
                  let encoder = args["encoder"] as? String
            else {
                result(false)
                return
            }

            let bitRate = (args["bitRate"] as? Int) ?? 128000

            // The Dart layer always sends the configured capture rate; the
            // last-started rate is only a fallback for foreign callers, so
            // arming BEFORE the first start works.
            let sampleRate = (args["sampleRate"] as? NSNumber)?.doubleValue
                ?? lastSampleRate

            encodedWriter?.abort()

            encodedWriter = MicAudioFileWriter.create(
                path: path,
                wireName: encoder,
                sampleRate: sampleRate,
                bitRate: bitRate)

            result(encodedWriter != nil)

        case "clearEncodedOutput":
            encodedWriter?.abort()

            encodedWriter = nil

            result(true)

        case "checkMicPermission":
            result(AVAudioSession.sharedInstance().recordPermission == .granted)

        case "requestMicPermission":
            // The classic request API (the AVAudioApplication successor
            // needs iOS 17; the deployment target is 15.0). Deprecation
            // warnings on newer SDKs are expected and benign.
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                result(granted)
            }

        case "microphoneInterrupted":
            result(audioService.microphoneInterrupted())

        case "extractAmplitudes":
            guard let args = call.arguments as? [String: Any],
                  let filePath = args["filePath"] as? String,
                  let barCount = args["barCount"] as? Int
            else {
                result(FlutterError(
                    code: "INVALID_ARGUMENTS",
                    message: "extractAmplitudes requires filePath (String) and barCount (Int)",
                    details: nil))
                return
            }

            // Decode off the platform thread; reply on the main thread —
            // heavy work must never block the platform channel.
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }

                do {
                    let amplitudes = try self.audioService.extractAmplitudes(
                        filePath: filePath,
                        barCount: barCount)

                    DispatchQueue.main.async { result(amplitudes) }
                } catch {
                    DispatchQueue.main.async {
                        result(FlutterError(
                            code: "EXTRACT_AMPLITUDES_FAILED",
                            message: error.localizedDescription,
                            details: nil))
                    }
                }
            }

        case "configureAudioSession":
            guard let args = call.arguments as? [String: Any],
                  let config = args["config"] as? [String: Any]
            else {
                result(false)
                return
            }

            result(sessionCore.configureAudioSession(config: config))

        case "setAudioSessionActive":
            guard let args = call.arguments as? [String: Any],
                  let active = args["active"] as? Bool
            else {
                result(false)
                return
            }

            result(sessionCore.setAudioSessionActive(active: active))

        case "isOtherAudioPlaying":
            result(sessionCore.isOtherAudioPlaying())

        case "setAllowHapticsAndSystemSoundsDuringRecording":
            guard let args = call.arguments as? [String: Any],
                  let enabled = args["enabled"] as? Bool
            else {
                result(false)
                return
            }

            result(sessionCore.setAllowHapticsAndSystemSoundsDuringRecording(enabled: enabled))

        case "getAvailableInputs":
            result(sessionCore.getAvailableInputs())

        case "getCurrentRoute":
            result(sessionCore.getCurrentRoute())

        case "setPreferredInput":
            guard let args = call.arguments as? [String: Any],
                  let uid = args["uid"] as? String
            else {
                result(false)
                return
            }

            result(sessionCore.setPreferredInput(uid: uid))

        case "setBluetoothStatus",
             "getRouteState",
             "isMusicActive",
             "getAudioMode",
             "getAudioDevices",
             "showForegroundNotification",
             "removeForegroundNotification":
            // Android-only verbs — the Dart layer gates them behind
            // Platform.isAndroid so they are unreachable on iOS; the
            // not-implemented reply keeps the contract honest for any
            // other caller.
            result(FlutterMethodNotImplemented)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// Feeds the armed encoded writer from the audio-stream tee.
    ///
    /// `fileprivate` because the tee lives in this file's
    /// `AudioStreamHandler` — a separate class, so `private` would
    /// hide the member from it.
    fileprivate func feedEncodedOutput(_ data: Data) {
        encodedWriter?.write(data)
    }
}

/// Stream handler for the audio_stream channel: raw PCM bytes produced by
/// the capture engine, teed into the plugin's armed encoded writer.
private final class AudioStreamHandler: NSObject, FlutterStreamHandler {

    private let service: MicAudioService
    private weak var plugin: MicRecorderPlugin?

    init(service: MicAudioService, plugin: MicRecorderPlugin) {
        self.service = service
        self.plugin = plugin
        super.init()
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        let feed = plugin

        service.setAudioEventSink(sink: { event in
            if let typed = event as? FlutterStandardTypedData {
                feed?.feedEncodedOutput(typed.data)
            }

            events(event)
        })

        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        // Release the stale sink immediately (a canceled
        // FlutterEventSink no-ops, so this is observably identical).
        service.clearAudioEventSink()

        return nil
    }
}

/// Stream handler for the session_events channel: interruption and
/// route-change maps from the audio-session core.
private final class SessionEventsStreamHandler: NSObject, FlutterStreamHandler {

    private let core: MicAudioSessionCore

    init(core: MicAudioSessionCore) {
        self.core = core
        super.init()
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        core.setSessionEventSink(events)

        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        // Only the sink is dropped — the core's observers stay installed
        // for the plugin's lifetime.
        core.setSessionEventSink(nil)

        return nil
    }
}
