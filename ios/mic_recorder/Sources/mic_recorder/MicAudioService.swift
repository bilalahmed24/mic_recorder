import Flutter
import UIKit
import AVFoundation

/// Microphone capture engine for the mic_recorder plugin.
///
/// An `AVAudioEngine` input tap whose buffers are converted with
/// `AVAudioConverter` to 16-bit little-endian mono PCM at the requested
/// sample rate and forwarded on the plugin's `audio_stream` event channel.
///
/// The engine is kept alive across route changes by a recovery stack:
/// a route watchdog (2s), a route-settle debounce (0.4s window / 2s max),
/// live engine handoff (retire-before-rebuild with a generation counter so
/// stale taps cannot forward audio), a restore path when a handoff fails,
/// short recreation retries (0.7s), deferred foreground recreation (0.4s),
/// background refusal diagnosis for the '!int' (560557684) and 'what'
/// (2003329396) OSStatus codes, and silent-buffer zombie detection
/// (peak <= 12 for 20s).
///
/// Log prefixes are "mic_recorder:"/"mic_recorder EVENT:" and the NSError
/// domain is "MicAudioService"; the event sink is an instance property
/// cleared on stream cancel.
public class MicAudioService: NSObject {

    /// The Bluetooth-HFP category option, spelled for the compiling SDK.
    ///
    /// `.allowBluetooth` was renamed to `.allowBluetoothHFP` in the Xcode 26
    /// SDK (same bit, documented as available since iOS 1.0). The new
    /// spelling does not exist in Xcode 16.x SDKs, so the spelling is picked
    /// at compile time: newest toolchains use the modern name, older ones the
    /// legacy (there merely deprecated) name — identical runtime behavior on
    /// every iOS version.
    #if compiler(>=6.2)
    static let bluetoothHfpOption: AVAudioSession.CategoryOptions = .allowBluetoothHFP
    #else
    static let bluetoothHfpOption: AVAudioSession.CategoryOptions = .allowBluetooth
    #endif

    private var outputSampleRate: Double = 16000.0
    private var noOfChannels: UInt32 = 1

    private var isMicrophoneAccessed = false
    private var isAudioRecording = false

    /// Sink receiving PCM chunks on the main queue; nil while the
    /// audio_stream channel has no listener.
    ///
    /// The plugin owns exactly one service instance, so the sink lives on
    /// the instance. It is cleared on stream cancel — Flutter no-ops a
    /// sink after cancel anyway, so the observable behavior is identical;
    /// clearing only releases the stale closure earlier.
    private var audioEventSink: FlutterEventSink?

    private var audioEngine: AVAudioEngine?
    private var audioSession: AVAudioSession?

    private var audioConverter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?

    // Protects the converter because it can be used by both the audio thread and the main thread.
    private let converterLock = NSLock()

    private var routeChangeObserver: NSObjectProtocol?

    private var installedTapRouteDescription: String?
    private var lastLoggedRouteDescription: String?

    // Format used when the current tap was installed; used to detect a stale tap after a route change.
    private var installedTapFormat: AVAudioFormat?

    // MARK: - Capture recovery
    //
    // Flutter chooses the preferred input. This class follows the system route,
    // rebuilds the engine when needed, and retries when hardware is still settling.

    private var routeWatchdogTimer: Timer?

    // Prevents overlapping engine rebuilds.
    private var isRebuilding = false

    // Short retry used when a route is still settling.
    private var recreationRetryTimer: Timer?
    private let recreationRetryInterval: TimeInterval = 0.7

    // Tracks whether the input tap is still producing buffers.
    private var lastTapBufferAt: Date?
    private var engineStartedAt: Date?

    // Protects the tap liveness timestamps shared by audio and main threads.
    private let tapLivenessLock = NSLock()

    // Time without buffers that is treated as a broken input binding.
    private let tapLivenessGracePeriod: TimeInterval = 5.0

    // MARK: - Silent-buffer detection
    //
    // A zombie route (dead Bluetooth HFP link, quietly deactivated session)
    // keeps the engine "running" and the tap firing — with zeroed or
    // noise-floor buffers. Buffer ARRIVAL checks cannot see this condition;
    // only the buffer content can.

    // Wall clock of the last buffer whose peak rose above the silence
    // threshold (nil until the first buffer of a capture episode).
    private var lastSoundingBufferAt: Date?

    // Peak int16 magnitude at or below this counts as a silent buffer
    // (~ -68 dBFS; a live microphone's noise floor sits well above it, so
    // only a dead capture path stays under it for the full grace period).
    private let silentBufferPeakThreshold: Int32 = 12

    // Buffers that keep ARRIVING but stay this quiet for this long mean the
    // capture path is dead even though every other health check passes.
    private let silentBufferGracePeriod: TimeInterval = 20.0

    // True while the application is in the background.
    private var isAppBackgrounded = false

    // Set when a rebuild must wait until the app becomes active.
    private var needsForegroundRecreation = false

    private var loggedBackgroundDeferral = false

    // Delays recovery until a burst of route-change events settles.
    private var routeSettleTimer: Timer?

    // Wait briefly after the last route event before recovering.
    private let routeSettleDelay: TimeInterval = 0.4

    // Prevents continuous route events from delaying recovery forever.
    private let routeSettleMaxWait: TimeInterval = 2.0

    // Start time of the current route-settle window.
    private var routeSettleFirstPendingAt: Date?

    // Limits background engine handoffs to one attempt per second.
    private var lastHandoffAttemptAt: Date?
    private let minBackgroundHandoffInterval: TimeInterval = 1.0

    // Counts repeated route-settle failures for the same route.
    private var consecutiveSettleFailures = 0
    private var lastSettleFailRouteDescription: String?

    // OS error reported when the audio session is unavailable during engine start.
    private let sessionUnavailableStartCode = 2003329396

    // Small delay before rebuilding after the app returns to the foreground.
    private var foregroundRecreationTimer: Timer?
    private let foregroundRecreationDelay: TimeInterval = 0.4

    // OS error commonly seen when iOS refuses to activate the session in the background.
    private let backgroundStartRefusalCode = 560557684

    // Identifies the currently active engine so old taps cannot forward audio.
    private var engineGeneration = 0

    // Lifecycle observers stay installed so a failed background recovery can finish in the foreground.
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var lifecycleObserversInstalled = false

    /// Starts (or rejoins) a capture episode at `sampleRate`.
    ///
    /// A healthy live stack is reused as-is. An unhealthy stack in the
    /// foreground is torn down first; an unhealthy stack in the background
    /// is kept (no teardown, no session writes) and recovery is armed.
    public func startRecording(sampleRate: Double) -> Bool {

        outputSampleRate = sampleRate

        isAudioRecording = true

        if isMicrophoneAccessed {
            if isCaptureStackHealthy() {
                return true
            }

            if isAppBackgrounded {
                print("mic_recorder: start requested while backgrounded on an unhealthy stack (route \(inputDescription(audioSession?.currentRoute.inputs.first) ?? "none")); keeping the live engine — no teardown, no session writes; recovery armed")

                scheduleCaptureRecovery(reason: "background start (unhealthy stack)")

                return false
            }

            teardownMicrophone()
        }

        return startMicrophone()
    }

    /// Builds the 16-bit little-endian mono PCM converter for `inputFormat`
    /// (called when the first tap is installed).
    func setupAudioConverter(inputFormat: AVAudioFormat) {

        outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: outputSampleRate,
            channels: noOfChannels,
            interleaved: false
        )

        guard let outputFormat = outputFormat else { return }

        let converter = AVAudioConverter(from: inputFormat, to: outputFormat)

        converterLock.lock()

        audioConverter = converter

        converterLock.unlock()
    }

    // Rebuild the converter when the input sample rate or channel count changes.
    private func converterFor(_ format: AVAudioFormat) -> AVAudioConverter? {
        guard let outputFormat = outputFormat else { return nil }

        converterLock.lock()

        defer { converterLock.unlock() }

        if let existing = audioConverter,
           existing.inputFormat.sampleRate == format.sampleRate,
           existing.inputFormat.channelCount == format.channelCount {
            return existing
        }

        if let existing = audioConverter {
            print("mic_recorder: tap buffers arrived at \(format.sampleRate)Hz/\(format.channelCount)ch; rebuilding converter (was \(existing.inputFormat.sampleRate)Hz/\(existing.inputFormat.channelCount)ch)")
        }

        let converter = AVAudioConverter(from: format, to: outputFormat)

        audioConverter = converter

        return converter
    }

    /// Initial setup: configure the audio session and create the first engine.
    public func startMicrophone() -> Bool {

        isMicrophoneAccessed = true

        installLifecycleObservers()

        audioSession = AVAudioSession.sharedInstance()

        // The singleton never returns nil; the optional binding keeps the
        // property typed as AVAudioSession? (set to nil by a full teardown).
        guard let session = audioSession else { return false }

        if isAppBackgrounded && session.currentRoute.inputs.isEmpty {
            print("mic_recorder: initial start refused while backgrounded (no input route — the route is between devices); no session writes, no engine created, no settle burn; retry nets stay armed")

            return false
        }

        audioEngine = AVAudioEngine()

        do {
            // The capture engine re-asserts .playAndRecord with
            // [.allowBluetoothHFP, .defaultToSpeaker] unconditionally.
            // With the DEFAULT Dart config this equals
            // configureAudioSession's options; a user config that disables
            // allowBluetooth or defaultToSpeaker is overridden once engine
            // capture starts. Known interplay, kept for capture fidelity.
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [Self.bluetoothHfpOption, .defaultToSpeaker]
            )
            try session.setPreferredSampleRate(outputSampleRate)

            guard let audioEngine = audioEngine else { return false }

            let inputNode = audioEngine.inputNode

            guard let inputFormat = settleInputFormat(of: inputNode) else {
                let unsettled = inputNode.outputFormat(forBus: 0)

                print("mic_recorder: input route did not settle after activation (rate=\(unsettled.sampleRate), channels=\(unsettled.channelCount)); refusing zombie tap")

                teardownMicrophone()

                scheduleRecreationRetry(reason: "initial start settle retry")

                return false
            }

            setupAudioConverter(inputFormat: inputFormat)

            // Let the input node choose its live format when the tap is installed.
            // Only the current engine is allowed to forward audio during a handoff.
            engineGeneration += 1
            let generation = engineGeneration

            inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] (buffer, time) in
                guard let self = self, self.engineGeneration == generation else { return }

                self.processAudioBuffer(buffer)
            }

            installedTapFormat = inputFormat
            installedTapRouteDescription = inputDescription(session.currentRoute.inputs.first)

            audioEngine.prepare()

            // Install observers before starting the engine so early changes are not missed.
            installRouteObserver()
            installEngineConfigObserver(for: audioEngine)

            try audioEngine.start()

            tapLivenessLock.lock()
            lastTapBufferAt = nil
            engineStartedAt = Date()
            lastSoundingBufferAt = nil
            tapLivenessLock.unlock()

            startRouteWatchdog()

            consecutiveSettleFailures = 0
            lastSettleFailRouteDescription = nil

            return true

        } catch {
            print("Error starting audio engine: \(error.localizedDescription)")

            if (error as NSError).code == backgroundStartRefusalCode {
                print("mic_recorder: engine start refused (OSStatus \(backgroundStartRefusalCode) '!int'): the audio SESSION is inactive and iOS refuses to (re-)activate it while the app is backgrounded")
            }

            if (error as NSError).code == sessionUnavailableStartCode {
                print("mic_recorder: engine start refused (OSStatus \(sessionUnavailableStartCode) 'what'): the audio SESSION is unavailable (torn down / inactive); iOS refuses the engine's implicit session activation")
            }

            // Remove observers and reset the capture stack when startup fails.
            teardownMicrophone()

            return false
        }
    }

    private func stopAudioEngine() {
        guard let audioEngine = audioEngine else { return }

        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)

        if audioEngine.isRunning {
            audioEngine.stop()
        }

        audioEngine.reset()
    }

    // Fully stop and clear the capture stack.
    private func teardownMicrophone() {
        stopAudioEngine()

        if let observer = routeChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            routeChangeObserver = nil
        }

        audioEngine = nil
        audioConverter = nil
        installedTapFormat = nil
        installedTapRouteDescription = nil
        isMicrophoneAccessed = false

        cancelRecreationRetry()
        cancelForegroundRecreation()

        cancelRouteSettleTimer()
        routeSettleFirstPendingAt = nil
        consecutiveSettleFailures = 0
        lastSettleFailRouteDescription = nil

        tapLivenessLock.lock()
        lastTapBufferAt = nil
        engineStartedAt = nil
        lastSoundingBufferAt = nil
        tapLivenessLock.unlock()

        stopRouteWatchdog()
        removeEngineConfigObserver()
        lastLoggedRouteDescription = nil
    }

    // Returns true when the tap format no longer matches the input node.
    private func isTapFormatStale() -> Bool {
        guard let engine = audioEngine, let installed = installedTapFormat else {
            return true
        }

        let current = engine.inputNode.outputFormat(forBus: 0)

        return current.sampleRate != installed.sampleRate
            || current.channelCount != installed.channelCount
    }


    // Returns true when the input node format could belong to the current route.
    // A stereo format on a Bluetooth HFP route is a pre-negotiation zombie:
    // the SCO link is mono, so a 2-channel tap there captures garbage.
    private func isPlausibleInputFormat(_ format: AVAudioFormat, portType: AVAudioSession.Port?) -> Bool {
        if format.sampleRate <= 0 || format.channelCount == 0 { return false }

        if portType == .bluetoothHFP && format.channelCount != 1 { return false }

        return true
    }

    private func settleInputFormat(of inputNode: AVAudioInputNode) -> AVAudioFormat? {
        var format = inputNode.outputFormat(forBus: 0)

        var attempts = 0

        while attempts < 10 {
            if isPlausibleInputFormat(format, portType: audioSession?.currentRoute.inputs.first?.portType) {
                return format
            }

            attempts += 1

            Thread.sleep(forTimeInterval: 0.05)

            format = inputNode.outputFormat(forBus: 0)
        }

        return nil
    }

    private func inputDescription(_ port: AVAudioSessionPortDescription?) -> String? {
        port.map { "\($0.portType.rawValue)('\($0.portName)')" }
    }

    // Check the capture stack every two seconds while recording.
    private func startRouteWatchdog() {
        stopRouteWatchdog()

        routeWatchdogTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.routeWatchdogTick()
        }
    }

    private func stopRouteWatchdog() {
        routeWatchdogTimer?.invalidate()
        routeWatchdogTimer = nil
    }

    // Detect broken capture state and start recovery when needed.
    private func routeWatchdogTick() {
        guard isAudioRecording, let session = audioSession else { return }

        let currentInput = session.currentRoute.inputs.first

        let currentDescription = inputDescription(currentInput) ?? "none"

        if currentDescription != lastLoggedRouteDescription {
            let availableInputs = session.availableInputs ?? []
            let availableDescription = availableInputs
                .map { "\($0.portType.rawValue)('\($0.portName)')" }
                .joined(separator: ", ")

            print("mic_recorder: input route now \(currentDescription); available inputs: [\(availableDescription)]")

            lastLoggedRouteDescription = currentDescription
        }

        if isAppBackgrounded && needsForegroundRecreation { return }

        if let problem = captureStackProblem(currentDescription: currentDescription, currentPortType: currentInput?.portType) {
            print("mic_recorder: \(problem.logLine) (route \(currentDescription)); recreating")

            recreateEngineAfterChange(reason: "watchdog (\(problem.shortReason))")
        }
    }

    // Shared health check used by the watchdog, retries, and start/resume paths.
    private func captureStackProblem(currentDescription: String, currentPortType: AVAudioSession.Port?) -> (logLine: String, shortReason: String)? {
        guard let engine = audioEngine else {
            return ("engine missing while recording", "engine missing")
        }

        if !engine.isRunning {
            return ("engine stopped while recording", "engine stopped")
        }

        if installedTapRouteDescription != currentDescription {
            return (
                "tap route mismatch (tap installed on \(installedTapRouteDescription ?? "none"), current \(currentDescription))",
                "route mismatch"
            )
        }

        if isTapFormatStale() {
            let nodeFormat = engine.inputNode.outputFormat(forBus: 0)

            return (
                "tap format stale (tap installed at \(installedTapFormat?.sampleRate ?? 0)Hz/\(installedTapFormat?.channelCount ?? 0)ch, input node now \(nodeFormat.sampleRate)Hz/\(nodeFormat.channelCount)ch)",
                "stale tap format"
            )
        }

        // The node format can stay self-consistent while the tap was bound to
        // a pre-negotiation zombie format; the mono HFP route exposes it.
        if currentPortType == .bluetoothHFP,
           let installed = installedTapFormat,
           installed.channelCount != 1 {
            return (
                "tap format stale (\(installed.channelCount)ch tap on the mono Bluetooth route)",
                "stereo tap on mono route"
            )
        }

        tapLivenessLock.lock()

        let lastBuffer = lastTapBufferAt
        let startedAt = engineStartedAt

        tapLivenessLock.unlock()

        if let reference = lastBuffer ?? startedAt {
            let silence = Date().timeIntervalSince(reference)

            if silence > tapLivenessGracePeriod {
                return (
                    "no tap buffers for \(Int(silence))s while engine running",
                    "silent engine"
                )
            }
        }

        // Buffers ARE arriving (the liveness check above passed) — but a
        // zombie route keeps delivering them zeroed. Content is the only
        // signal that distinguishes a dead capture path from a quiet room,
        // and only for this long unbroken quiet counts as broken.
        tapLivenessLock.lock()

        let lastSounding = lastSoundingBufferAt

        tapLivenessLock.unlock()

        if let lastSounding = lastSounding {
            let silentFor = Date().timeIntervalSince(lastSounding)

            if silentFor > silentBufferGracePeriod {
                return (
                    "silent tap buffers for \(Int(silentFor))s while engine running (peak <= \(silentBufferPeakThreshold); zombie route suspected)",
                    "silent buffers"
                )
            }
        }

        return nil
    }

    private func isCaptureStackHealthy() -> Bool {
        guard let session = audioSession else { return false }

        let currentInput = session.currentRoute.inputs.first
        let currentDescription = inputDescription(currentInput) ?? "none"

        return captureStackProblem(currentDescription: currentDescription, currentPortType: currentInput?.portType) == nil
    }

    // Recover when AVAudioEngine reports an input configuration change.

    private var engineConfigObserver: NSObjectProtocol?

    private func installEngineConfigObserver(for engine: AVAudioEngine) {
        removeEngineConfigObserver()

        engineConfigObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, let engine = self.audioEngine else { return }

            let format = engine.inputNode.outputFormat(forBus: 0)

            print("mic_recorder EVENT: engineConfigurationChange — input format \(format.sampleRate)Hz/\(format.channelCount)ch (engine running: \(engine.isRunning)); recovering")

            guard self.isAudioRecording, !self.isRebuilding else { return }

            self.scheduleCaptureRecovery(reason: "engine configuration change")
        }
    }

    private func removeEngineConfigObserver() {
        if let observer = engineConfigObserver {
            NotificationCenter.default.removeObserver(observer)
            engineConfigObserver = nil
        }
    }

    // Convert route-change codes into readable log messages.
    private static func routeChangeReasonName(_ raw: UInt) -> String {
        switch raw {
        case AVAudioSession.RouteChangeReason.unknown.rawValue:
            return "unknown(0)"
        case AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue:
            return "newDeviceAvailable(1)"
        case AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue:
            return "oldDeviceUnavailable(2)"
        case AVAudioSession.RouteChangeReason.categoryChange.rawValue:
            return "categoryChange(3)"
        case AVAudioSession.RouteChangeReason.override.rawValue:
            return "override(4)"
        case AVAudioSession.RouteChangeReason.wakeFromSleep.rawValue:
            return "wakeFromSleep(5)"
        case AVAudioSession.RouteChangeReason.noSuitableRouteForCategory.rawValue:
            return "noSuitableRouteForCategory(6)"
        case AVAudioSession.RouteChangeReason.routeConfigurationChange.rawValue:
            return "routeConfigurationChange(7)"
        default:
            return "unmapped(\(raw))"
        }
    }

    // Follow route changes; input selection itself is handled by Flutter.

    private func installRouteObserver() {
        if let observer = routeChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            routeChangeObserver = nil
        }

        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self else { return }

            let rawReason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let reasonName = rawReason
                .map { MicAudioService.routeChangeReasonName($0) } ?? "unknown"
            let current = self.inputDescription(self.audioSession?.currentRoute.inputs.first) ?? "none"

            print("mic_recorder EVENT: routeChange (\(reasonName)) — input now \(current)")

            guard self.isAudioRecording, !self.isRebuilding else { return }

            self.scheduleCaptureRecovery(reason: "route change")
        }
    }

    // Debounce route changes so a burst triggers one recovery attempt.
    private func scheduleCaptureRecovery(reason: String) {
        if isAppBackgrounded && needsForegroundRecreation {
            // A live input route means the session is back; give the background
            // recovery another chance instead of waiting for the foreground.
            guard let session = audioSession, session.currentRoute.inputs.first != nil else { return }

            needsForegroundRecreation = false
            loggedBackgroundDeferral = false

            print("mic_recorder: input route returned while a rebuild was deferred (route \(inputDescription(session.currentRoute.inputs.first) ?? "none")); background recovery re-armed")
        }

        let now = Date()

        if routeSettleFirstPendingAt == nil {
            routeSettleFirstPendingAt = now
        } else if let firstPending = routeSettleFirstPendingAt,
                  now.timeIntervalSince(firstPending) >= routeSettleMaxWait {
            cancelRouteSettleTimer()
            routeSettleFirstPendingAt = nil

            recreateIfUnhealthy(reason: "\(reason) (burst max-wait)")

            return
        }

        cancelRouteSettleTimer()

        routeSettleTimer = Timer.scheduledTimer(withTimeInterval: routeSettleDelay, repeats: false) { [weak self] _ in
            guard let self = self else { return }

            self.routeSettleTimer = nil
            self.routeSettleFirstPendingAt = nil

            self.recreateIfUnhealthy(reason: reason)
        }
    }

    private func cancelRouteSettleTimer() {
        routeSettleTimer?.invalidate()
        routeSettleTimer = nil
    }

    // Replace the engine while keeping the audio session alive.
    @discardableResult
    private func recreateEngineAfterChange(reason: String) -> Bool {
        guard !isRebuilding else { return false }

        guard !(isAppBackgrounded && needsForegroundRecreation) else { return false }

        guard isAudioRecording, let session = audioSession else { return false }

        let current = inputDescription(session.currentRoute.inputs.first) ?? "none"

        if session.currentRoute.inputs.isEmpty {
            return false
        }

        if isAppBackgrounded,
           let lastAttempt = lastHandoffAttemptAt,
           Date().timeIntervalSince(lastAttempt) < minBackgroundHandoffInterval {
            return false
        }

        if lastSettleFailRouteDescription != nil, lastSettleFailRouteDescription != current {
            consecutiveSettleFailures = 0
            lastSettleFailRouteDescription = nil
        }

        isRebuilding = true

        defer { isRebuilding = false }

        lastHandoffAttemptAt = Date()

        let retiringEngine = audioEngine

        print("mic_recorder: live engine handoff after \(reason) (previous input \(installedTapRouteDescription ?? "none"), current route \(current)); session untouched")

        // Keep the old stack's state so it can be restored if the new engine fails.
        let previousTapFormat = installedTapFormat
        let previousTapRoute = installedTapRouteDescription

        // Retire the old engine BEFORE building the next one: while its IO is
        // still running the hardware stays pinned to the previous route's
        // format, and a stale tap keeps forwarding garbage after a route change.
        if let retiringEngine = retiringEngine {
            retiringEngine.inputNode.removeTap(onBus: 0)

            if retiringEngine.isRunning {
                retiringEngine.stop()
            }

            retiringEngine.reset()
        }

        // Do not reconfigure the audio session during a mid-recording route change.
        let newEngine = AVAudioEngine()

        guard let inputFormat = settleInputFormat(of: newEngine.inputNode) else {
            let unsettled = newEngine.inputNode.outputFormat(forBus: 0)

            print("mic_recorder: input route did not settle for the new engine (rate=\(unsettled.sampleRate), channels=\(unsettled.channelCount)); refusing zombie tap (retry armed)")

            consecutiveSettleFailures += 1
            lastSettleFailRouteDescription = current

            return noteHandoffFailure(previousTapFormat: previousTapFormat,
                                      previousTapRoute: previousTapRoute,
                                      retiringEngine: retiringEngine,
                                      newEngine: newEngine,
                                      reason: reason,
                                      sessionRefused: false)
        }

        let inputNode = newEngine.inputNode

        let generation = engineGeneration + 1

        // Install a live-format tap and ignore buffers from older engines.
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] (buffer, time) in
            guard let self = self, self.engineGeneration == generation else { return }

            self.processAudioBuffer(buffer)
        }

        // Register the observers before starting the new engine.
        installRouteObserver()
        installEngineConfigObserver(for: newEngine)

        do {
            try newEngine.start()
        } catch {
            print("Error starting audio engine: \(error.localizedDescription)")

            if (error as NSError).code == backgroundStartRefusalCode {
                print("mic_recorder: engine start refused (OSStatus \(backgroundStartRefusalCode) '!int'): the audio SESSION is down and iOS refuses to (re-)activate it while the app is backgrounded")
            }

            if (error as NSError).code == sessionUnavailableStartCode {
                print("mic_recorder: engine start refused (OSStatus \(sessionUnavailableStartCode) 'what'): the audio SESSION is unavailable (torn down / inactive); iOS refuses the engine's implicit session activation")
            }

            return noteHandoffFailure(previousTapFormat: previousTapFormat,
                                      previousTapRoute: previousTapRoute,
                                      retiringEngine: retiringEngine,
                                      newEngine: newEngine,
                                      reason: reason,
                                      sessionRefused: true)
        }

        // The previous engine was already retired before this one started.
        audioEngine = newEngine
        engineGeneration = generation

        installedTapFormat = inputFormat
        installedTapRouteDescription = inputDescription(session.currentRoute.inputs.first) ?? current

        tapLivenessLock.lock()
        lastTapBufferAt = nil
        engineStartedAt = Date()
        lastSoundingBufferAt = nil
        tapLivenessLock.unlock()

        startRouteWatchdog()

        cancelRecreationRetry()
        cancelForegroundRecreation()
        needsForegroundRecreation = false
        loggedBackgroundDeferral = false

        consecutiveSettleFailures = 0
        lastSettleFailRouteDescription = nil

        print("mic_recorder: handoff complete — engine now on \(installedTapRouteDescription ?? current); the audio session was never stopped")

        return true
    }

    // Restore the previous engine when a handoff fails and schedule another recovery attempt.
    private func noteHandoffFailure(previousTapFormat: AVAudioFormat?,
                                    previousTapRoute: String?,
                                    retiringEngine: AVAudioEngine?,
                                    newEngine: AVAudioEngine?,
                                    reason: String,
                                    sessionRefused: Bool) -> Bool {
        // Discard the new engine because it was not successfully adopted.
        if let newEngine = newEngine {
            newEngine.inputNode.removeTap(onBus: 0)

            if newEngine.isRunning {
                newEngine.stop()
            }

            newEngine.reset()
        }

        // Restore bookkeeping for the engine that is still active.
        installedTapFormat = previousTapFormat
        installedTapRouteDescription = previousTapRoute

        // Point the configuration observer back to the active engine.
        if let retiringEngine = retiringEngine {
            installEngineConfigObserver(for: retiringEngine)
        } else {
            removeEngineConfigObserver()
        }

        // Keep the route observer and watchdog running for another retry.
        installRouteObserver()
        startRouteWatchdog()

        if isAppBackgrounded {
            if sessionRefused {
                needsForegroundRecreation = true

                if !loggedBackgroundDeferral {
                    loggedBackgroundDeferral = true

                    print("mic_recorder: engine handoff refused while app is backgrounded (session unavailable); rebuild deferred until the app returns to foreground (fast retry suppressed)")
                }
            } else {
                // The route is still present, so the session is alive: keep
                // retrying on the watchdog cadence instead of parking a stale
                // tap until the foreground (Bluetooth SCO can take several
                // attempts to settle while the device is locked).
                print("mic_recorder: input route did not settle while backgrounded (attempt \(consecutiveSettleFailures)); watchdog retries continue — no session debt")
            }
        } else {
            print("mic_recorder: engine handoff failed (\(reason)); retry machinery re-armed (fast retry in \(Int(recreationRetryInterval * 1000))ms, watchdog backstop 2s)")

            scheduleRecreationRetry(reason: "recreation retry")
        }

        return false
    }

    // Retry a failed engine rebuild after a short delay.
    private func scheduleRecreationRetry(reason: String) {
        cancelRecreationRetry()

        recreationRetryTimer = Timer.scheduledTimer(withTimeInterval: recreationRetryInterval, repeats: false) { [weak self] _ in
            guard let self = self else { return }

            self.recreationRetryTimer = nil

            self.recreateIfUnhealthy(reason: reason)
        }
    }

    private func cancelRecreationRetry() {
        recreationRetryTimer?.invalidate()
        recreationRetryTimer = nil
    }

    // Rebuild only when the capture stack is actually unhealthy.
    private func recreateIfUnhealthy(reason: String) {
        guard isAudioRecording, !isRebuilding, let session = audioSession else { return }

        if isAppBackgrounded && needsForegroundRecreation { return }

        let currentInput = session.currentRoute.inputs.first
        let currentDescription = inputDescription(currentInput) ?? "none"

        guard let problem = captureStackProblem(currentDescription: currentDescription, currentPortType: currentInput?.portType) else { return }

        print("mic_recorder: \(problem.logLine) (route \(currentDescription)); recreating")

        recreateEngineAfterChange(reason: "\(reason) (\(problem.shortReason))")
    }

    // React to app background/foreground changes during recording.

    // Install lifecycle observers once.
    private func installLifecycleObservers() {
        guard !lifecycleObserversInstalled else { return }

        lifecycleObserversInstalled = true

        lifecycleObservers.append(
            NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.handleAppBackgrounded()
            }
        )

        lifecycleObservers.append(
            NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.handleAppActivated()
            }
        )
    }

    // Cancel retries when entering the background; recovery can resume later.
    private func handleAppBackgrounded() {
        isAppBackgrounded = true
        loggedBackgroundDeferral = false

        cancelRecreationRetry()
        cancelForegroundRecreation()
    }

    // Re-check the capture stack when the app becomes active.
    private func handleAppActivated() {
        let wasBackgrounded = isAppBackgrounded

        isAppBackgrounded = false
        loggedBackgroundDeferral = false

        consecutiveSettleFailures = 0
        lastSettleFailRouteDescription = nil

        guard wasBackgrounded, isAudioRecording else {
            needsForegroundRecreation = false
            return
        }

        guard needsForegroundRecreation || !isCaptureStackHealthy() else {
            needsForegroundRecreation = false
            return
        }

        needsForegroundRecreation = false

        print("mic_recorder: app active again; capture stack needs a rebuild after background (route \(inputDescription(audioSession?.currentRoute.inputs.first) ?? "none"))")

        scheduleForegroundRecreation()
    }

    // Delay the foreground rebuild slightly so the audio session and route can settle.
    private func scheduleForegroundRecreation() {
        cancelForegroundRecreation()

        foregroundRecreationTimer = Timer.scheduledTimer(
            withTimeInterval: foregroundRecreationDelay,
            repeats: false
        ) { [weak self] _ in
            guard let self = self else { return }

            self.foregroundRecreationTimer = nil

            guard self.isAudioRecording, !self.isAppBackgrounded else { return }

            self.recreateIfUnhealthy(reason: "foreground resume")
        }
    }

    private func cancelForegroundRecreation() {
        foregroundRecreationTimer?.invalidate()
        foregroundRecreationTimer = nil
    }

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        // Record every received buffer so the watchdog can detect a stalled input.
        tapLivenessLock.lock()
        lastTapBufferAt = Date()

        // Start the sounding-audio clock on the first buffer of a capture
        // episode; from then on only buffers with real content move it.
        if lastSoundingBufferAt == nil {
            lastSoundingBufferAt = lastTapBufferAt
        }

        tapLivenessLock.unlock()

        guard isAudioRecording else { return }

        guard let outputFormat = outputFormat,
              let converter = converterFor(buffer.format) else { return }

        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * (outputFormat.sampleRate / buffer.format.sampleRate))

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: capacity
        ) else { return }

        var error: NSError?
        converter.convert(to: outputBuffer, error: &error) { inNumPackets, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        if let error = error {
            print("Audio conversion error: \(error.localizedDescription)")
            return
        }

        if let data = outputBuffer.int16ChannelData {
            let bufferPointer = UnsafeBufferPointer(
                start: data[0],
                count: Int(outputBuffer.frameLength) * Int(outputBuffer.format.channelCount)
            )
            let pcm16Data = Data(buffer: bufferPointer)

            // Peak of the converted PCM: the watchdog's only window into a
            // capture path that delivers buffers without content.
            var peak: Int32 = 0

            pcm16Data.withUnsafeBytes { rawBuffer in
                let samples = rawBuffer.bindMemory(to: Int16.self)

                for sample in samples {
                    let magnitude = abs(Int32(sample))

                    if magnitude > peak { peak = magnitude }
                }
            }

            if peak > silentBufferPeakThreshold {
                tapLivenessLock.lock()
                lastSoundingBufferAt = Date()
                tapLivenessLock.unlock()
            }

            if isAudioRecording {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, let sink = self.audioEventSink else { return }
                    sink(FlutterStandardTypedData(bytes: pcm16Data))
                }
            }
        }

    }

    /// Handle a microphone interruption and try to recover the capture stack:
    /// full teardown (engine down, session deactivated and released).
    public func microphoneInterrupted() -> Bool {

        pauseRecording(isPausedForInterruption: true)

        do {
            try audioSession?.setActive(false)
        } catch {
            print("Error deactivating audio session: \(error.localizedDescription)")
        }

        teardownMicrophone()

        audioSession = nil

        return true
    }

    /// Resume recording only when the capture stack is healthy.
    public func resumeRecording() -> Bool {

        isAudioRecording = true


        if isMicrophoneAccessed {
            if isCaptureStackHealthy() {
                return true
            }

            if isAppBackgrounded {
                print("mic_recorder: resume requested while backgrounded on an unhealthy stack (route \(inputDescription(audioSession?.currentRoute.inputs.first) ?? "none")); keeping the live engine — no teardown, no session writes; recovery armed")

                scheduleCaptureRecovery(reason: "background resume (unhealthy stack)")

                return false
            }

            teardownMicrophone()
        }

        return startMicrophone()
    }

    /// Pause recording; `isPausedForInterruption` keeps the stack alive for a
    /// system interruption, otherwise this is a full teardown via
    /// `microphoneInterrupted()`.
    public func pauseRecording(isPausedForInterruption: Bool) -> Bool {

        if isPausedForInterruption {
            isAudioRecording = false
        } else {
            microphoneInterrupted()
        }

        return true
    }

    /// Stops recording with a full teardown (session deactivation included).
    ///
    /// Convenience for the wire verb `stopRecording` — exactly the source
    /// AppDelegate's dispatch mapping (stop = pauseRecording(false)).
    public func stopRecording() -> Bool {
        return pauseRecording(isPausedForInterruption: false)
    }

    /// Attaches the audio_stream sink (called on channel listen).
    public func setAudioEventSink(sink: @escaping FlutterEventSink) {
        audioEventSink = sink
    }

    /// Detaches the audio_stream sink (called on channel cancel).
    ///
    /// Clearing it is observably identical to leaving it (Flutter no-ops a
    /// canceled sink) and only releases the closure earlier.
    public func clearAudioEventSink() {
        audioEventSink = nil
    }


    /// Decodes the audio file at `filePath` into `barCount` normalized RMS
    /// bars (each clamped to 0.1–1.0 so the waveform stays visible).
    ///
    /// Heavy decode — call off the platform main thread. Throws on a
    /// missing audio track or a failed read.
    public func extractAmplitudes(filePath: String, barCount: Int) throws -> [Double] {
        let audioURL = URL(fileURLWithPath: filePath)

        let asset = AVURLAsset(url: audioURL)

        guard let audioTrack = asset.tracks(withMediaType: .audio).first else {
            throw NSError(
                domain: "MicAudioService",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "No audio track found"])
        }

        let reader = try AVAssetReader(asset: asset)

        // Use the fixed output rate for waveform calculations.
        let outputSampleRate: Double = 16000.0

        // Give the audio settings an explicit type to keep Swift's type checker happy.
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: outputSampleRate,
            AVNumberOfChannelsKey: 1
        ]

        let readerOutput = AVAssetReaderTrackOutput(
            track: audioTrack,
            outputSettings: outputSettings
        )
        readerOutput.alwaysCopiesSampleData = false
        reader.add(readerOutput)

        guard reader.startReading() else {
            throw NSError(
                domain: "MicAudioService",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Failed to start reading"])
        }

        // Calculate sample counts using the output sample rate.
        let durationSeconds = CMTimeGetSeconds(audioTrack.timeRange.duration)
        let totalSamples = Int(durationSeconds * outputSampleRate)

        if totalSamples <= 0 {
            reader.cancelReading()
            return []
        }

        var bucketSums = [Double](repeating: 0.0, count: barCount)
        var bucketCounts = [Int](repeating: 0, count: barCount)
        var sampleIndex = 0

        while reader.status == .reading {
            guard let sampleBuffer = readerOutput.copyNextSampleBuffer() else {
                break
            }
            defer { CMSampleBufferInvalidate(sampleBuffer) }

            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                continue
            }

            let length = CMBlockBufferGetDataLength(blockBuffer)
            var dataPointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(
                blockBuffer,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: nil,
                dataPointerOut: &dataPointer
            )
            guard let dataPointer = dataPointer else { continue }

            let sampleCount = length / 2  // 16-bit mono = 2 bytes per sample

            dataPointer.withMemoryRebound(
                to: Int16.self,
                capacity: sampleCount
            ) { samples in
                for i in 0..<sampleCount {
                    let sample = Double(samples[i])
                    let bucketIndex = min(
                        Int(Double(sampleIndex) * Double(barCount) / Double(totalSamples)),
                        barCount - 1
                    )
                    bucketSums[bucketIndex] += sample * sample
                    bucketCounts[bucketIndex] += 1
                    sampleIndex += 1
                }
            }
        }

        if reader.status == .failed {
            throw reader.error ?? NSError(
                domain: "MicAudioService",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Reading failed"])
        }

        // Calculate RMS for each waveform bucket.
        var maxRms: Double = 1.0
        var rmsValues = [Double](repeating: 0.0, count: barCount)
        for i in 0..<barCount {
            if bucketCounts[i] > 0 {
                rmsValues[i] = (bucketSums[i] / Double(bucketCounts[i])).squareRoot()
                if rmsValues[i] > maxRms { maxRms = rmsValues[i] }
            }
        }

        // Normalize values to 0.0–1.0 so the waveform remains visible.
        return (0..<barCount).map { i in
            let normalized = rmsValues[i] / maxRms
            return max(0.1, min(1.0, normalized))
        }
    }
}
