import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import 'config/mic_recorder_config.dart';
import 'internal/mic_logger.dart';
import 'internal/mic_output_file_writer.dart';
import 'internal/mic_platform.dart';
import 'internal/streams.dart';
import 'lifecycle/app_lifecycle_tracker.dart';
import 'models/mic_amplitude.dart';
import 'models/mic_audio_encoder.dart';
import 'models/mic_audio_interruption.dart';
import 'models/mic_recorder_events.dart';
import 'models/mic_recording_info.dart';
import 'models/mic_recorder_state.dart';
import 'models/mic_recording_file_format.dart';
import 'platform/mic_recorder_platform.dart';
import 'route/mic_route_controller.dart';
import 'session/mic_audio_session_controller.dart';

/// Production-grade microphone recording for Flutter — audio session
/// handling, interruption recovery and input device switching included.
///
/// Audio is 16-bit little-endian mono PCM, delivered on [audioStream]:
///
/// * configure once with [initialize] (session, Android foreground-service
///   notification, route switching, capture effects, log sink);
/// * start with [start], optionally in [MicRecordingMode.voiceCommand];
/// * record to files with [setOutputFile] (raw PCM or a WAV container) and
///   [setEncodedOutput] (native AAC/Opus/FLAC/AMR/Apple Lossless);
/// * watch loudness with [onAmplitude] and progress with
///   [onDurationChanged];
/// * cap episodes with [MicRecorderConfig.maxDuration] (auto-stop);
/// * pause / resume with [pause] / [resume] — interruptions pause capture
///   automatically and resume once the audio session is recovered;
/// * stop with [stop] (returns a [MicRecordingInfo]) or discard with
///   [cancel];
/// * manage the microphone permission with [checkMicrophonePermission]
///   and [requestMicrophonePermission].
///
/// Listen to [onStateChange], [onAudioInterruption], [onAudioSourceSwitched],
/// [onConversationSilence] and [onMicrophoneLost] for the full picture.
final class MicRecorder {
  MicRecorder._();

  static final MicRecorder _instance = MicRecorder._();

  /// The shared recorder instance.
  static MicRecorder get instance => _instance;

  MicRecorderConfig _config = const MicRecorderConfig();

  MicLogSink _log = defaultMicLog;

  AppLifecycleTracker? _lifecycleTracker;
  MicAudioSessionController? _session;
  MicRouteController? _route;

  StreamSubscription<bool>? _interruptionSubscription;

  bool _controllersBuilt = false;

  final SeededStream<MicRecorderState> _state$ = SeededStream<MicRecorderState>(
    MicRecorderState.stopped,
  );

  StreamController<void>? _unsubscriber;
  StreamSubscription<List<int>>? _bufferedAudioSubscription;

  final StreamController<List<int>> _audioDataStream$ =
      StreamController<List<int>>.broadcast();

  /// The active configuration.
  MicRecorderConfig get config => _config;

  /// Capture sample rate (Hz).
  int get sampleRate => _config.sampleRate;

  /// Audio is always 16-bit.
  int get bitDepth => 16;

  File? _recordedFile;
  MicOutputFileWriter? _outputFileWriter;
  MicRecordingFileFormat _outputFileFormat = MicRecordingFileFormat.pcm16;

  MicAudioEncoder? _encodedEncoder;
  String? _encodedOutputPath;

  DateTime? _episodeStartedAt;
  DateTime? _activeSince;
  Duration _accumulatedActiveDuration = Duration.zero;

  final StreamController<MicAmplitude> _amplitudeController =
      StreamController<MicAmplitude>.broadcast();
  MicAmplitude? _lastAmplitude;
  double _amplitudeDbSum = 0;
  int _amplitudeReadingCount = 0;
  double _amplitudePeakDb = MicAmplitude.silenceDbfs;
  DateTime? _lastAmplitudeEmittedAt;

  final StreamController<Duration> _durationController =
      StreamController<Duration>.broadcast();

  /// Minimum spacing between [onDurationChanged] emissions.
  static const Duration _durationEventInterval = Duration(milliseconds: 200);

  DateTime? _lastDurationEmittedAt;
  bool _maxDurationStopScheduled = false;
  bool _isFinishingEpisode = false;

  Uint8List _bufferedAudio = Uint8List(0);

  /// Wall clock of when the current buffering episode began — anchors gap
  /// attribution when no explicit disconnect timestamp exists (the
  /// pre-attach window at conversation start).
  DateTime? _bufferingStartedAt;

  /// UTC instant the current buffering episode began (null when not
  /// buffering).
  DateTime? get bufferingStartedAt => _bufferingStartedAt;

  Uint8List _voiceCommandAudioBuffer = Uint8List(0);

  /// Raw PCM audio stream (16-bit little-endian mono) — the same chunks
  /// also feed an optional output file and the RAM buffer.
  Stream<List<int>> get audioStream => _audioDataStream$.stream;

  MicRecordingMode _mode = MicRecordingMode.conversation;

  /// The mode the current recording episode runs in.
  MicRecordingMode get mode => _mode;

  bool _isInitiated = false;

  /// Whether [initialize] has been called with an explicit configuration.
  bool get isInitialized => _controllersBuilt;

  // --------------------------------------------------------------------------
  // Audio health monitoring
  // --------------------------------------------------------------------------

  /// Audio below this level is treated as silence.
  static const double _silenceRmsThreshold = 0.004;

  /// Wait this long before treating silence as a possible recording
  /// problem.
  static const Duration _silenceAlarmDuration = Duration(seconds: 30);

  /// Repeat the silence warning at this interval while the problem
  /// continues.
  static const Duration _silenceAlarmInterval = Duration(seconds: 60);

  /// Silence recovery is paced by the alarm interval (one attempt per
  /// interval while the silence continues). A paced attempt costs under a
  /// second of audio and lets the recording self-heal whenever the cause
  /// clears.
  bool _isRecoveringFromSilence = false;

  /// Periodically records basic audio-health information while recording.
  static const Duration _audioHealthHeartbeat = Duration(seconds: 120);

  // --------------------------------------------------------------------------
  // Conversation silence detection
  // --------------------------------------------------------------------------

  /// Continuous quiet audio that produces ONE [MicConversationSilenceEvent]
  /// per COMPLETED 5-minute window.
  static const Duration _conversationSilenceInterval = Duration(minutes: 5);

  /// Wall clock when the CURRENT 5-minute silence window began (null after
  /// a reset — recorder transitions reset the window because a paused
  /// recorder is MISSING audio, not silence).
  ///
  /// After each emission this rolls forward by exactly one
  /// [_conversationSilenceInterval], so consecutive events of one long
  /// silence tile back-to-back (T0, T0+5m, T0+10m, ...).
  DateTime? _conversationSilenceStartedAt;

  DateTime? _silenceStartedAt;
  DateTime? _lastSilenceAlarmAt;
  DateTime? _lastSoundAt;

  Timer? _audioHealthTimer;

  int _bytesCapturedSinceStart = 0;
  int _buffersCapturedSinceStart = 0;
  double _lastRms = 0;

  int _silenceRecoveryAttempts = 0;

  /// True only when an interruption caused the pause and recording should
  /// be resumed automatically when the interruption is over.
  bool _isPausedForInterruption = false;

  /// Avoids scheduling a separate reconciliation for every incoming buffer.
  static const Duration liveAudioReconcileDelay = Duration(milliseconds: 100);

  Timer? _liveAudioReconcileTimer;

  // --------------------------------------------------------------------------
  // Lifecycle
  // --------------------------------------------------------------------------

  /// Configures the recorder. Must be called before [start]; may be called
  /// again while stopped to reconfigure. Calling it lazily (never) uses
  /// [MicRecorderConfig] defaults.
  void initialize(MicRecorderConfig config) {
    if (_state$.value.isActive) {
      throw StateError(
        'MicRecorder.initialize must not be called while recording is '
        'active. Stop the recording first.',
      );
    }

    _config = config;

    _buildControllers(rebuild: _controllersBuilt);
  }

  MicAudioSessionController get _sessionController {
    _ensureControllers();
    return _session!;
  }

  MicRouteController get _routeController {
    _ensureControllers();
    return _route!;
  }

  AppLifecycleTracker get _lifecycle {
    _ensureControllers();
    return _lifecycleTracker!;
  }

  void _ensureControllers() {
    if (_controllersBuilt) return;

    _buildControllers(rebuild: false);
  }

  void _buildControllers({required bool rebuild}) {
    if (rebuild) {
      _interruptionSubscription?.cancel();
      _interruptionSubscription = null;

      _route?.dispose();
      _session?.dispose();

      _route = null;
      _session = null;
    }

    _log = _config.log ?? defaultMicLog;
    _lifecycleTracker = AppLifecycleTracker.instance;

    _session = MicAudioSessionController(
      config: _config.audioSession,
      log: _log,
      lifecycle: _lifecycleTracker!,
    );

    _route = MicRouteController(
      enabled: _config.routeSwitchingEnabled,
      log: _log,
      lifecycle: _lifecycleTracker!,
      session: _session!,
    );

    _interruptionSubscription = _session!.onAudioInterruption.listen((
      isInterrupted,
    ) async {
      if (_state$.value.isActive) {
        await _handleAudioInterruption(isInterrupted);
      }
    });

    _controllersBuilt = true;
  }

  /// Recording state changes ([MicRecorderState.stopped] initially).
  Stream<MicRecorderState> get onStateChange => _state$.stream;

  /// Emits the recording state and keeps the episode clock honest:
  /// entering `recording` starts the active-time clock, leaving it
  /// (pause/stop/error) banks the elapsed span into
  /// `_accumulatedActiveDuration`.
  void _transition(MicRecorderState state) {
    final now = DateTime.now();

    if (state == MicRecorderState.recording) {
      _activeSince ??= now;
    } else if (_activeSince != null) {
      _accumulatedActiveDuration += now.difference(_activeSince!);

      _activeSince = null;
    }

    _state$.add(state);
  }

  /// Current recording state.
  MicRecorderState get currentState => _state$.value;

  /// Interruption state (true while an interruption is in effect).
  Stream<MicAudioInterruption> get onAudioInterruption =>
      _sessionController.interruptionStream;

  /// Effective microphone source change events (see
  /// [MicAudioSourceSwitchedEvent]).
  Stream<MicAudioSourceSwitchedEvent> get onAudioSourceSwitched =>
      _routeController.onAudioSourceSwitched;

  /// Sustained conversational silence — one event per completed 5-minute
  /// window of quiet-but-flowing audio.
  Stream<MicConversationSilenceEvent> get onConversationSilence =>
      _conversationSilenceController.stream;

  /// The microphone became unavailable while backgrounded and needs the
  /// user to return to the app. Surface it through the app's own
  /// notification channel.
  Stream<MicMicrophoneLostEvent> get onMicrophoneLost =>
      _sessionController.onMicrophoneLost;

  final StreamController<MicConversationSilenceEvent>
  _conversationSilenceController =
      StreamController<MicConversationSilenceEvent>.broadcast();

  /// Whether the input priority ladder (USB/wired → Bluetooth → built-in)
  /// currently steers capture.
  bool get isRouteSwitchingEnabled => _routeController.isEnabled;

  /// Enables/disables the input priority ladder for the running recording
  /// (persisting the choice is the app's job).
  Future<void> setRouteSwitchingEnabled(bool value) =>
      _routeController.setEnabled(value);

  // --------------------------------------------------------------------------
  // Recording
  // --------------------------------------------------------------------------

  /// Starts a recording episode.
  ///
  /// In [MicRecordingMode.voiceCommand] the recorder listens continuously
  /// (silence is expected — no silence alarms fire and only the most recent
  /// audio tail is retained); in [MicRecordingMode.conversation] silence
  /// detection is armed.
  Future<bool> start({
    MicRecordingMode mode = MicRecordingMode.conversation,
  }) async {
    _ensureControllers();

    if (_state$.value.isActive) return true;

    await _resetStreams();

    _unsubscriber = StreamController<void>.broadcast();

    // Never start capture while the app is not in the foreground: iOS
    // forbids the session writes and Android's focus request would race
    // the launch.
    await _lifecycle.onStateChange.firstWhere(
      (state) => _isInitiated || state == AppLifecycleState.resumed,
    );

    await _sessionController.init();

    _isInitiated = true;

    // Apply the preferred input before recording starts.
    await _routeController.prepare();

    final isRecorderStarted = await MicRecorderPlatform.instance.startRecording(
      _config.sampleRate,
      androidEchoCancel: _config.androidEchoCancel,
      androidNoiseSuppress: _config.androidNoiseSuppress,
      androidAutoGain: _config.androidAutoGain,
    );

    if (!isRecorderStarted) {
      _transition(MicRecorderState.error);

      return false;
    }

    _mode = mode;

    // A fresh episode: reset the duration clock and the amplitude
    // statistics so neither inherits the previous recording.
    _episodeStartedAt = DateTime.now().toUtc();
    _accumulatedActiveDuration = Duration.zero;
    _resetAmplitudeTracking();
    _lastDurationEmittedAt = null;
    _maxDurationStopScheduled = false;
    _durationController.add(Duration.zero);

    // Keep the preferred input up to date while recording.
    await _routeController.start();

    _transition(MicRecorderState.recording);

    await _showForegroundNotification(_activeRecordingTitle);

    _resetAudioHealthTracking();

    _audioHealthTimer?.cancel();

    _audioHealthTimer = Timer.periodic(
      _audioHealthHeartbeat,
      (_) => _logAudioHealth(),
    );

    if (_unsubscriber == null) return false;

    // Forward audio to listeners and optionally write it to a file.
    takeUntil(
      MicRecorderPlatform.instance.audioDataStream(),
      _unsubscriber!.stream,
    ).listen((data) {
      _audioDataStream$.add(data);
      _outputFileWriter?.add(data);

      _onAudioDataReceived(data);

      if (_mode == MicRecordingMode.voiceCommand) {
        _voiceCommandAudioBuffer =
            Uint8List(_voiceCommandAudioBuffer.length + data.length)
              ..setAll(0, _voiceCommandAudioBuffer)
              ..setAll(_voiceCommandAudioBuffer.length, data);
      }
    });

    if (_mode == MicRecordingMode.voiceCommand) {
      // Keep only the most recent five minutes of voice-command audio.
      takeUntil(
        Stream<void>.periodic(MicAudioSessionController.periodicDuration * 300),
        _unsubscriber!.stream,
      ).listen((_) {
        _voiceCommandAudioBuffer = Uint8List(0);
      });
    }

    return true;
  }

  String get _activeRecordingTitle => _mode == MicRecordingMode.voiceCommand
      ? _config.androidForegroundService.titleWhenListening
      : _config.androidForegroundService.titleWhenRecording;

  /// Pauses the recording (the capture stack is torn down until
  /// [resume] or an interruption-end triggers a restart).
  ///
  /// Throws [StateError] when no recording is running — pausing an idle
  /// recorder would otherwise park a phantom `paused` episode.
  Future<void> pause() async {
    if (!_state$.value.isRecording) {
      throw StateError(
        'pause() requires a running recording '
        '(current state: ${_state$.value.name}).',
      );
    }

    await MicRecorderPlatform.instance.pauseRecording(false);

    _transition(MicRecorderState.paused);

    // A paused recorder delivers no audio — the conversation-silence
    // window must not span the pause.
    _resetConversationSilenceTracking();

    await _showForegroundNotification(
      _config.androidForegroundService.titleWhenPaused,
    );
  }

  /// Resumes a paused recording.
  Future<bool> resume() async {
    if (await _sessionController.isAndroidMicHeldByCall()) {
      return false;
    }

    _cancelInterruptionResumeTimers();

    final isResumed = await MicRecorderPlatform.instance.resumeRecording();

    if (!isResumed) {
      _log(MicLogLevel.error, 'audioRecorderResumeFailed', {
        'state': _state$.value.name,
        'recovery': 'manual-resume',
      });

      return false;
    }

    // A manual resume clears any pending automatic interruption resume.
    _isPausedForInterruption = false;

    await _showForegroundNotification(_activeRecordingTitle);

    _sessionController.markInterruptionResolved();

    await _sessionController.reassertActivation();

    _transition(MicRecorderState.recording);

    // Silence accumulates afresh from the resume — the paused gap must not
    // count as conversational silence.
    _resetConversationSilenceTracking();

    return true;
  }

  /// Stops the recording, tears the audio session down and returns what
  /// was captured (null when the recorder was not active).
  ///
  /// [reason] flows into the returned [MicRecordingInfo.stopReason] —
  /// the automatic max-duration stop passes
  /// [MicRecordingStopReason.maxDurationReached] itself.
  Future<MicRecordingInfo?> stop({
    MicRecordingStopReason reason = MicRecordingStopReason.manual,
  }) => _finishEpisode(discard: false, reason: reason);

  /// Stops the recording like [stop] but discards every output file the
  /// episode produced (the encoded file and the Dart-written file) — the
  /// recording is thrown away.
  Future<void> cancel() => _finishEpisode(discard: true);

  Future<MicRecordingInfo?> _finishEpisode({
    required bool discard,
    MicRecordingStopReason reason = MicRecordingStopReason.manual,
  }) async {
    // Re-entry guard: the automatic max-duration stop, a manual stop and
    // a dispose-triggered stop can race — the first one owns the episode.
    if (_isFinishingEpisode) return null;

    _isFinishingEpisode = true;

    try {
      return await _finishEpisodeLocked(discard: discard, reason: reason);
    } finally {
      _isFinishingEpisode = false;
    }
  }

  Future<MicRecordingInfo?> _finishEpisodeLocked({
    required bool discard,
    required MicRecordingStopReason reason,
  }) async {
    final wasActive = _state$.value.isActive;

    _disposeAudioHealthTracking();

    // Stopping permanently clears any pending interruption resume.
    _isPausedForInterruption = false;

    _cancelInterruptionResumeTimers();

    await _resetStreams();

    if (discard) {
      await _discardOutputFileWriter();
    } else {
      await _closeOutputFileWriter();
    }

    // The native stop finishes the armed encoded encoder (the pause verbs
    // never do); a discard instead aborts and deletes it BEFORE the engine
    // stops, so the engine's finish call finds nothing to finalize.
    if (discard && _encodedEncoder != null) {
      await MicRecorderPlatform.instance.clearEncodedOutput();
    }

    await MicRecorderPlatform.instance.stopRecording();

    if (discard) _resetEncodedOutputArming();

    await _routeController.stop();

    await stopAudioBuffering();

    _sessionController.markInterruptionResolved();

    await _sessionController.resetService();

    await _removeForegroundNotification();

    _transition(MicRecorderState.stopped);

    // The final duration (the transition above banked the active span) —
    // a UI timer fed by [onDurationChanged] lands on the exact total.
    if (wasActive) {
      _durationController.add(_accumulatedActiveDuration);
    }

    _bufferedAudio = Uint8List(0);

    _bufferingStartedAt = null;

    if (!wasActive) return null;

    final episodeStartedAt = _episodeStartedAt;

    final info = MicRecordingInfo(
      startedAtUtc: episodeStartedAt ?? DateTime.now().toUtc(),
      duration: _accumulatedActiveDuration,
      sizeBytes: await _episodeSizeBytes(),
      sampleRate: _config.sampleRate,
      bitDepth: bitDepth,
      channels: 1,
      stopReason: reason,
      path: discard
          ? null
          : _encodedEncoder != null
          ? _encodedOutputPath
          : _recordedFile?.path,
      encoder: discard ? null : _encodedEncoder,
      fileFormat: discard || _encodedEncoder != null || _recordedFile == null
          ? null
          : _outputFileFormat,
    );

    if (discard) {
      _episodeStartedAt = null;

      _accumulatedActiveDuration = Duration.zero;
    } else {
      _outputFileWriter = null;

      _recordedFile = null;

      _lastRecordingInfo = info;
    }

    _resetEncodedOutputArming();

    return discard ? null : info;
  }

  Future<int> _episodeSizeBytes() async {
    final encodedOutputPath = _encodedOutputPath;

    if (encodedOutputPath != null) {
      final encodedFile = File(encodedOutputPath);

      if (await encodedFile.exists()) return await encodedFile.length();
    }

    final outputFile = _recordedFile;

    if (outputFile != null && await outputFile.exists()) {
      return await outputFile.length();
    }

    return _bytesCapturedSinceStart;
  }

  void _resetEncodedOutputArming() {
    _encodedEncoder = null;

    _encodedOutputPath = null;
  }

  /// The interruption state machine: pauses capture when an interruption
  /// begins and auto-resumes when it ends and the session is live again.
  Future<void> _handleAudioInterruption(
    bool isInterrupted, {
    String recovery = 'interruption-end',
  }) async {
    if (isInterrupted) {
      final wasRecordingBeforeInterruption = _state$.value.isRecording;

      if (!wasRecordingBeforeInterruption) {
        return;
      }

      final isPaused = await MicRecorderPlatform.instance.pauseRecording(true);

      if (!isPaused) {
        _log(MicLogLevel.error, 'audioRecorderPauseFailed', {
          'state': _state$.value.name,
        });
      }

      _transition(MicRecorderState.paused);

      _isPausedForInterruption = true;

      // Interruption pause = no audio flowing, not silence.
      _resetConversationSilenceTracking();

      await _showForegroundNotification(
        _config.androidForegroundService.titleWhenInterrupted,
      );
    } else if (_isPausedForInterruption) {
      // Only automatically resume a pause that was caused by an
      // interruption.
      _isPausedForInterruption = false;

      // Make sure the audio session is active before resuming the
      // recorder.
      await _sessionController.init();

      final isMicHeldByCall = await _sessionController.isAndroidMicHeldByCall();

      if (isMicHeldByCall) {
        // Keep the flag set so a later foreground or audio-data event can
        // retry.
        _isPausedForInterruption = true;

        return;
      }

      final isResumed = await MicRecorderPlatform.instance.resumeRecording();

      if (!isResumed) {
        _log(MicLogLevel.error, 'audioRecorderResumeFailed', {
          'state': _state$.value.name,
          'recovery': recovery,
        });

        // Keep the flag set so a later foreground or audio-data event can
        // retry.
        _isPausedForInterruption = true;

        return;
      }

      await _showForegroundNotification(_activeRecordingTitle);

      await _sessionController.reassertActivation();

      _log(MicLogLevel.debug, 'audioInterruptionResumeReconciled', {
        'reason': recovery,
        'state': _state$.value.name,
        'appLifecycleState': '${_lifecycle.currentState}',
      });

      _transition(MicRecorderState.recording);

      // Auto-resumed after an interruption: the conversation-silence
      // window restarts from now.
      _resetConversationSilenceTracking();
    }
  }

  // When audio starts arriving again, native capture is already working, so
  // update the Dart state without waiting for another lifecycle event.
  void _scheduleLiveAudioReconcile() {
    _liveAudioReconcileTimer?.cancel();

    _liveAudioReconcileTimer = Timer(liveAudioReconcileDelay, () async {
      if (!_isPausedForInterruption ||
          !_state$.value.isActive ||
          (await _sessionController.isOtherAudioPlaying())) {
        return;
      }

      _log(MicLogLevel.debug, 'audioInterruptionResumeReconciled', {
        'reason': 'live-audio',
        'state': _state$.value.name,
        'appLifecycleState': '${_lifecycle.currentState}',
      });

      unawaited(() async {
        try {
          await _handleAudioInterruption(false, recovery: 'live-audio');
        } catch (_) {}
      }());
    });
  }

  void _cancelInterruptionResumeTimers() {
    _liveAudioReconcileTimer?.cancel();
    _liveAudioReconcileTimer = null;
  }

  Future<void> _resetStreams() async {
    _unsubscriber?.add(null);

    // Fake-async law: broadcast close futures never resolve under a fake
    // event loop — fire-and-forget.
    unawaited(_unsubscriber?.close() ?? Future<void>.value());

    _unsubscriber = null;
  }

  // --------------------------------------------------------------------------
  // Foreground service notification (Android)
  // --------------------------------------------------------------------------

  Future<void> _showForegroundNotification(String title) async {
    if (!_config.androidForegroundService.enabled) return;
    if (!micIsAndroid) return;

    try {
      final fgs = _config.androidForegroundService;

      final success = await MicRecorderPlatform.instance
          .showForegroundNotification(
            title,
            channelName: fgs.channelName,
            channelDescription: fgs.channelDescription,
            icon: fgs.icon,
          );

      if (!success) {
        _log(MicLogLevel.warn, 'foregroundServiceStartFailed', {
          'title': title,
        });
      }
    } catch (e) {
      _log(MicLogLevel.warn, 'foregroundServiceStartFailed', {
        'title': title,
        'error': e.toString(),
      });
    }
  }

  Future<void> _removeForegroundNotification() async {
    if (!_config.androidForegroundService.enabled) return;
    if (!micIsAndroid) return;

    try {
      await MicRecorderPlatform.instance.removeForegroundNotification();
    } catch (e) {
      _log(MicLogLevel.warn, 'foregroundServiceStopFailed', {
        'error': e.toString(),
      });
    }
  }

  // --------------------------------------------------------------------------
  // Silence detection & audio health
  // --------------------------------------------------------------------------

  void _resetAudioHealthTracking() {
    _silenceStartedAt = null;
    _lastSilenceAlarmAt = null;
    _lastSoundAt = DateTime.now();
    _bytesCapturedSinceStart = 0;
    _buffersCapturedSinceStart = 0;
    _lastRms = 0;
    _silenceRecoveryAttempts = 0;

    _resetConversationSilenceTracking();
  }

  /// Breaks the conversation-silence window. Called on sounding audio, on
  /// recorder pause/resume transitions (a paused recorder delivers no
  /// audio — that is missing audio, not silence), and on recording
  /// start/stop.
  void _resetConversationSilenceTracking() {
    _conversationSilenceStartedAt = null;
  }

  void _disposeAudioHealthTracking() {
    _audioHealthTimer?.cancel();
    _audioHealthTimer = null;

    _resetConversationSilenceTracking();
  }

  /// Calculates RMS for 16-bit little-endian mono PCM data.
  double _computeRms(List<int> data) {
    final byteCount = data.length & ~1;

    if (byteCount == 0) return 0;

    final sampleCount = byteCount ~/ 2;

    var sumSquares = 0.0;

    for (var i = 0; i + 1 < byteCount; i += 2) {
      final sample = data[i] | (data[i + 1] << 8);

      final signedSample = sample >= 0x8000 ? sample - 0x10000 : sample;

      sumSquares += (signedSample / 32768.0) * (signedSample / 32768.0);
    }

    return math.sqrt(sumSquares / sampleCount);
  }

  void _onAudioDataReceived(List<int> data) {
    // If native audio has recovered while Dart still thinks we are paused,
    // bring the Dart state back in sync.
    if (_isPausedForInterruption) {
      _scheduleLiveAudioReconcile();
    } else if (_state$.value.isRecording &&
        _sessionController.isInterruptionActive) {
      // Buffers are flowing, so the microphone is ours: any lingering
      // interruption state is stale and must not keep the error state up.
      _sessionController.markInterruptionResolved();
    }

    _bytesCapturedSinceStart += data.length;
    _buffersCapturedSinceStart++;

    final rms = _computeRms(data);

    _lastRms = rms;

    final now = DateTime.now();

    _updateAmplitude(rms, now);

    _updateDuration(now);

    if (rms >= _silenceRmsThreshold) {
      final silenceStartedAt = _silenceStartedAt;

      if (silenceStartedAt != null) {
        final silencedFor = now.difference(silenceStartedAt);

        // Only log the end of a silence period when it was long enough to
        // be considered suspicious.
        if (silencedFor >= _silenceAlarmDuration) {
          _log(MicLogLevel.warn, 'microphoneSilenceEnded', {
            'durationMs': silencedFor.inMilliseconds,
            'mode': _mode.name,
            'state': _state$.value.name,
            'appLifecycleState': '${_lifecycle.currentState}',
          });
        }

        _silenceStartedAt = null;
        _lastSilenceAlarmAt = null;
        _silenceRecoveryAttempts = 0;
      }

      _lastSoundAt = now;

      // Sounding audio ends any conversation-silence window.
      _resetConversationSilenceTracking();

      return;
    }

    _silenceStartedAt ??= now;

    // This window accumulates only while buffers FLOW and are quiet (share
    // the same RMS classification), resets on recorder transitions, and
    // only applies to conversation recordings.
    if (_mode == MicRecordingMode.conversation) {
      _conversationSilenceStartedAt ??= now;

      final windowStartedAt = _conversationSilenceStartedAt!;

      final windowElapsedMs = now.difference(windowStartedAt).inMilliseconds;

      // A jump of two-or-more intervals between consecutive buffers means
      // the audio pipeline stalled (suspension / freeze), not observed
      // silence — the skipped stretch is unclaimable: restart the window
      // from now without emitting anything.
      if (windowElapsedMs >= 2 * _conversationSilenceInterval.inMilliseconds) {
        _conversationSilenceStartedAt = now;
      } else if (windowElapsedMs >=
          _conversationSilenceInterval.inMilliseconds) {
        // Roll the window forward BEFORE emitting: an emit-side failure
        // must not re-fire the same window on the next buffer. Rolling by
        // exactly one interval tiles consecutive events back-to-back
        // (T0, T0+5m, T0+10m, ...) with no drift.
        _conversationSilenceStartedAt = windowStartedAt.add(
          _conversationSilenceInterval,
        );

        unawaited(() async {
          final routeState = micIsAndroid
              ? await MicRecorderPlatform.instance.getRouteState()
              : null;

          _conversationSilenceController.add(
            MicConversationSilenceEvent(
              startedAtUtc: windowStartedAt.toUtc(),
              duration: Duration(milliseconds: windowElapsedMs),
              lastRms: _lastRms,
              silenceThreshold: _silenceRmsThreshold,
              bytesCapturedSinceStart: _bytesCapturedSinceStart,
              buffersCapturedSinceStart: _buffersCapturedSinceStart,
              silenceRecoveryAttempts: _silenceRecoveryAttempts,
              routeState: routeState,
            ),
          );
        }());
      }
    }

    final silencedFor = now.difference(_silenceStartedAt!);

    if (silencedFor < _silenceAlarmDuration) return;

    final lastSilenceAlarmAt = _lastSilenceAlarmAt;

    final shouldAlarm =
        lastSilenceAlarmAt == null ||
        now.difference(lastSilenceAlarmAt) >= _silenceAlarmInterval;

    if (!shouldAlarm) return;

    _lastSilenceAlarmAt = now;

    // Log sustained silence and try to restore the audio session.
    _log(MicLogLevel.error, 'microphoneSilenceDetected', {
      'durationMs': silencedFor.inMilliseconds,
      'lastRms': _lastRms,
      'threshold': _silenceRmsThreshold,
      'bytesCapturedSinceStart': _bytesCapturedSinceStart,
      'mode': _mode.name,
      'state': _state$.value.name,
      'appLifecycleState': '${_lifecycle.currentState}',
    });

    unawaited(_attemptSilenceRecovery(silencedFor));
  }

  Future<void> _attemptSilenceRecovery(Duration silencedFor) async {
    // Silence during voice-command listening is expected and should not
    // trigger recovery.
    if (_mode == MicRecordingMode.voiceCommand) return;

    if (!_state$.value.isRecording) return;

    // While backgrounded the native layers own recovery: iOS forbids
    // background session writes (its watchdog rebuilds the engine in
    // place), and Android keeps rebuilding the AudioRecord on its own
    // paced schedule. A Dart-driven restart is a foreground tool.
    if (_lifecycle.currentState != AppLifecycleState.resumed) {
      return;
    }

    // The previous attempt may still be awaiting session re-activation.
    if (_isRecoveringFromSilence) return;

    _isRecoveringFromSilence = true;

    _silenceRecoveryAttempts++;

    _log(MicLogLevel.warn, 'microphoneSilenceRecoveryAttempted', {
      'attempt': _silenceRecoveryAttempts,
      'silenceDurationMs': silencedFor.inMilliseconds,
    });

    try {
      // A REAL capture-stack restart through the existing channel verbs.
      //
      // pause(false) tears the native recorder down (Android: AudioRecord
      // stop/release + SCO off; iOS: engine teardown); the session reset +
      // init re-configures and EXPLICITLY re-activates the audio session;
      // resume then opens a fresh recorder/engine on the current route. If
      // re-activation fails, init() raises the interruption flow, which
      // auto-resumes recording once it succeeds.
      await MicRecorderPlatform.instance.pauseRecording(false);

      await _sessionController.resetService();

      await _sessionController.init();

      final isRestarted = await MicRecorderPlatform.instance.resumeRecording();

      if (isRestarted) {
        _sessionController.markInterruptionResolved();

        await _sessionController.reassertActivation();
      }

      _log(MicLogLevel.warn, 'microphoneSilenceRecoveryAttempted', {
        'attempt': _silenceRecoveryAttempts,
        'silenceDurationMs': silencedFor.inMilliseconds,
        'captureRestarted': isRestarted,
      });
    } catch (_) {
    } finally {
      _isRecoveringFromSilence = false;
    }
  }

  void _logAudioHealth() {
    if (!_state$.value.isActive) return;

    final now = DateTime.now();

    final silenceMs = _silenceStartedAt == null
        ? 0
        : now.difference(_silenceStartedAt!).inMilliseconds;

    _log(MicLogLevel.debug, 'audioHealthHeartbeat', {
      'state': _state$.value.name,
      'mode': _mode.name,
      'bytesCapturedSinceStart': _bytesCapturedSinceStart,
      'buffersCapturedSinceStart': _buffersCapturedSinceStart,
      'lastRms': _lastRms,
      'currentSilenceMs': silenceMs,
      'secondsSinceLastSound': _lastSoundAt == null
          ? null
          : now.difference(_lastSoundAt!).inSeconds,
      'appLifecycleState': '${_lifecycle.currentState}',
    });
  }

  // --------------------------------------------------------------------------
  // File output
  // --------------------------------------------------------------------------

  /// Arms PCM file output to [filePath].
  ///
  /// * [MicRecordingFileFormat.pcm16] (default) — headerless 16-bit
  ///   little-endian mono PCM, appended to the file when it exists and
  ///   [deleteExistingFile] is `false` (deleted first when `true`, the
  ///   default);
  /// * [MicRecordingFileFormat.wav] — a RIFF/WAVE container with the
  ///   canonical 44-byte header, sized when the file is closed.
  ///
  /// Audio captured from now on is appended; call again with a new path
  /// to roll the file, or [clearOutputFile] to stop writing.
  Future<File?> setOutputFile(
    String filePath, {
    bool deleteExistingFile = true,
    MicRecordingFileFormat format = MicRecordingFileFormat.pcm16,
  }) async {
    await _closeOutputFileWriter();

    final file = File(filePath);

    if (deleteExistingFile && file.existsSync()) {
      try {
        file.deleteSync();
      } catch (e) {
        _log(MicLogLevel.warn, 'outputFileDeleteFailed', {
          'path': filePath,
          'error': e.toString(),
        });
      }
    }

    _recordedFile = file;

    _outputFileFormat = format;

    _outputFileWriter = format == MicRecordingFileFormat.wav
        ? await MicWavFileWriter.create(
            file,
            sampleRate: _config.sampleRate,
            channels: 1,
            bitDepth: 16,
          )
        : await MicRawPcmFileWriter.create(
            file,
            sampleRate: _config.sampleRate,
            channels: 1,
            bitDepth: 16,
          );

    return file;
  }

  /// The file audio is currently being written to (null when none).
  File? get outputFile => _recordedFile;

  /// The format the last [setOutputFile] armed (null when none).
  MicRecordingFileFormat? get outputFileFormat =>
      _outputFileWriter == null ? null : _outputFileFormat;

  /// Flushes (and for WAV, finalizes the header of) the output file;
  /// the audio stream keeps flowing.
  Future<void> clearOutputFile() async {
    await _closeOutputFileWriter();

    _recordedFile = null;
  }

  Future<void> _closeOutputFileWriter() async {
    await _outputFileWriter?.close();

    _outputFileWriter = null;
  }

  Future<void> _discardOutputFileWriter() async {
    await _outputFileWriter?.discard();

    _outputFileWriter = null;

    _recordedFile = null;
  }

  // --------------------------------------------------------------------------
  // Encoded output (native encoders)
  // --------------------------------------------------------------------------

  /// Arms native encoded file output: captured audio is ALSO encoded to
  /// [path] — pick the extension from [MicAudioEncoder.fileExtension]
  /// (e.g. `.m4a` for [MicAudioEncoder.aacLc]). Runs alongside the raw
  /// stream and [setOutputFile] from the same capture.
  ///
  /// Call before [start], or mid-recording (audio captured from now on —
  /// nothing is retroactively encoded). One encoded output at a time;
  /// [stop] finalizes the file, [cancel] deletes it, and
  /// [clearEncodedOutput] disarms it early (deleting any partial file).
  ///
  /// Throws [StateError] when another encoded output is already armed or
  /// the encoder's sample-rate requirement is not met, and
  /// [UnsupportedError] when the encoder is unavailable on this platform.
  Future<File> setEncodedOutput(
    String path, {
    required MicAudioEncoder encoder,
    int? bitRate,
  }) async {
    if (_encodedEncoder != null) {
      throw StateError(
        'An encoded output is already armed ($_encodedOutputPath). '
        'Clear it with clearEncodedOutput() first.',
      );
    }

    if (!encoder.isSupportedOn(android: micIsAndroid, ios: !micIsAndroid)) {
      throw UnsupportedError(
        'MicAudioEncoder.${encoder.name} is not available on this platform.',
      );
    }

    final requiredSampleRate = encoder.requiredSampleRate;

    if (requiredSampleRate != null &&
        requiredSampleRate != _config.sampleRate) {
      throw StateError(
        'MicAudioEncoder.${encoder.name} requires '
        '$requiredSampleRate Hz capture '
        '(configured: ${_config.sampleRate} Hz).',
      );
    }

    final requestedBitRate = bitRate ?? encoder.defaultBitRate;

    // AAC-LC tops out at 6144 bits per 1024-sample frame per channel —
    // 6 × sampleRate bits/second for mono capture. Apple's encoder
    // refuses higher rates outright (and other encoders vary), so the
    // default stays portable by clamping to the ceiling.
    final effectiveBitRate = encoder == MicAudioEncoder.aacLc
        ? math.min(requestedBitRate!, 6 * _config.sampleRate)
        : requestedBitRate;

    final isArmed = await MicRecorderPlatform.instance.setEncodedOutput(
      path,
      encoder,
      bitRate: effectiveBitRate,
      sampleRate: _config.sampleRate,
    );

    if (!isArmed) {
      throw StateError(
        'The platform rejected the encoded output request for $path.',
      );
    }

    _encodedEncoder = encoder;

    _encodedOutputPath = path;

    _log(MicLogLevel.debug, 'encodedOutputArmed', {
      'path': path,
      'encoder': encoder.wireName,
      'bitRate': effectiveBitRate,
    });

    return File(path);
  }

  /// The armed encoded output file (null when none is armed).
  File? get encodedOutputFile =>
      _encodedOutputPath == null ? null : File(_encodedOutputPath!);

  /// Disarms the encoded output — and deletes the (partial) file it was
  /// writing. The recording itself keeps going.
  Future<void> clearEncodedOutput() async {
    await MicRecorderPlatform.instance.clearEncodedOutput();

    _log(MicLogLevel.debug, 'encodedOutputCleared');

    _resetEncodedOutputArming();
  }

  // --------------------------------------------------------------------------
  // Episode observability
  // --------------------------------------------------------------------------

  /// When the current (or most recently completed) episode started, UTC —
  /// null before the first [start] and after a [cancel].
  DateTime? get recordingStartedAt => _episodeStartedAt;

  /// The most recently COMPLETED episode's result (see [stop]), or null
  /// before the first one — an app that armed
  /// [MicRecorderConfig.maxDuration] learns the auto-stop landed here
  /// (with [MicRecordingStopReason.maxDurationReached]) or on
  /// [onStateChange].
  MicRecordingInfo? get lastRecordingInfo => _lastRecordingInfo;

  MicRecordingInfo? _lastRecordingInfo;

  /// How long capture has been live — paused spans excluded.
  ///
  /// Null before the first [start]; after [stop] it freezes at the
  /// episode's final duration; [cancel] clears it.
  Duration? get elapsedDuration {
    final activeSince = _activeSince;

    final isActive = activeSince != null;

    if (!isActive &&
        _episodeStartedAt == null &&
        _accumulatedActiveDuration == Duration.zero) {
      return null;
    }

    return _accumulatedActiveDuration +
        (isActive ? DateTime.now().difference(activeSince) : Duration.zero);
  }

  // --------------------------------------------------------------------------
  // Episode duration
  // --------------------------------------------------------------------------

  /// The live episode clock — emits the active capture duration while
  /// recording (paused spans excluded), starting at [Duration.zero] on
  /// [start] and finishing with the episode's exact total on [stop].
  ///
  /// Ticks arrive with the audio (throttled to ~200 ms) — the recorder
  /// has no wall-clock timer, so a frozen capture pipeline stops the
  /// clock instead of lying about it. See [elapsedDuration] for the
  /// always-current value.
  Stream<Duration> get onDurationChanged => _durationController.stream;

  void _updateDuration(DateTime now) {
    // Only active capture advances the clock — a paused recorder delivers
    // no audio, and a brief reconcile burst during an interruption pause
    // is self-correcting (the pause transition banks the real span).
    final activeSince = _activeSince;

    if (activeSince == null) return;

    final elapsed = _accumulatedActiveDuration + now.difference(activeSince);

    final lastEmittedAt = _lastDurationEmittedAt;

    if (lastEmittedAt == null ||
        now.difference(lastEmittedAt) >= _durationEventInterval) {
      _lastDurationEmittedAt = now;

      _durationController.add(elapsed);
    }

    _checkMaxDuration(elapsed);
  }

  void _checkMaxDuration(Duration elapsed) {
    final maxDuration = _config.maxDuration;

    if (maxDuration == null || _maxDurationStopScheduled) return;

    if (elapsed < maxDuration) return;

    _maxDurationStopScheduled = true;

    _log(MicLogLevel.debug, 'maxDurationReached', {
      'maxDurationMs': maxDuration.inMilliseconds,
      'elapsedMs': elapsed.inMilliseconds,
    });

    unawaited(stop(reason: MicRecordingStopReason.maxDurationReached));
  }

  // --------------------------------------------------------------------------
  // Amplitude metering
  // --------------------------------------------------------------------------

  /// Live loudness (dBFS) while audio flows — throttled to at most one
  /// event per [MicRecorderConfig.amplitudeInterval] (100 ms by default);
  /// [amplitude] always holds the freshest per-chunk reading.
  Stream<MicAmplitude> get onAmplitude => _amplitudeController.stream;

  /// The most recent loudness reading, or null before audio flows.
  MicAmplitude? get amplitude => _lastAmplitude;

  void _resetAmplitudeTracking() {
    _amplitudeDbSum = 0;

    _amplitudeReadingCount = 0;

    _amplitudePeakDb = MicAmplitude.silenceDbfs;

    _lastAmplitudeEmittedAt = null;

    _lastAmplitude = null;
  }

  void _updateAmplitude(double rms, DateTime now) {
    final db = rms <= 0
        ? MicAmplitude.silenceDbfs
        : math.max(20 * math.log(rms) / math.ln10, MicAmplitude.silenceDbfs);

    _amplitudeDbSum += db;

    _amplitudeReadingCount++;

    if (db > _amplitudePeakDb) _amplitudePeakDb = db;

    final current = db.clamp(MicAmplitude.silenceDbfs, 0.0).toDouble();

    final average = (_amplitudeDbSum / _amplitudeReadingCount)
        .clamp(MicAmplitude.silenceDbfs, 0.0)
        .toDouble();

    _lastAmplitude = MicAmplitude(
      currentDbfs: current,
      averageDbfs: average,
      peakDbfs: _amplitudePeakDb
          .clamp(MicAmplitude.silenceDbfs, 0.0)
          .toDouble(),
    );

    final interval = _config.amplitudeInterval;

    final lastEmittedAt = _lastAmplitudeEmittedAt;

    if (lastEmittedAt != null && now.difference(lastEmittedAt) < interval) {
      return;
    }

    _lastAmplitudeEmittedAt = now;

    _amplitudeController.add(_lastAmplitude!);
  }

  // --------------------------------------------------------------------------
  // Permissions
  // --------------------------------------------------------------------------

  /// Whether the microphone permission is currently granted.
  ///
  /// Recording does not request permissions by itself — gate [start] on
  /// this (and [requestMicrophonePermission]) so an explicit user journey
  /// precedes the first capture.
  Future<bool> checkMicrophonePermission() =>
      MicRecorderPlatform.instance.checkMicPermission();

  /// Requests the microphone permission; resolves with the grant.
  Future<bool> requestMicrophonePermission() =>
      MicRecorderPlatform.instance.requestMicPermission();

  // --------------------------------------------------------------------------
  // RAM buffering
  // --------------------------------------------------------------------------

  /// Starts (or returns `true` if already) buffering all captured audio in
  /// RAM — the harvested buffer feeds conversation hand-offs.
  Future<bool> startAudioBuffering() async {
    if (_bufferedAudioSubscription != null) return true;

    final isRecordingStarted = await start();

    if (!isRecordingStarted) return false;

    _bufferedAudio = Uint8List(0);

    _bufferingStartedAt = DateTime.now().toUtc();

    _log(MicLogLevel.trace, 'audioBufferingStarted');

    _bufferedAudioSubscription = _audioDataStream$.stream.listen((data) {
      _bufferedAudio = Uint8List(_bufferedAudio.length + data.length)
        ..setAll(0, _bufferedAudio)
        ..setAll(_bufferedAudio.length, data);
    });

    return true;
  }

  /// Stops buffering and returns the buffered audio.
  Future<Uint8List> stopAudioBuffering() async {
    if (_bufferedAudioSubscription == null) return Uint8List(0);

    final bufferedAudio = _bufferedAudio;

    // Fake-async law: broadcast cancel futures never resolve under a fake
    // event loop — fire-and-forget (the buffer was already read above).
    unawaited(_bufferedAudioSubscription?.cancel() ?? Future<void>.value());
    _bufferedAudioSubscription = null;

    _bufferedAudio = Uint8List(0);

    _bufferingStartedAt = null;

    _log(MicLogLevel.trace, 'audioBufferingStopped');

    return bufferedAudio;
  }

  /// Atomically drains the buffered audio WITHOUT stopping the buffering
  /// subscription. The read-and-clear swap is synchronous, so on Dart's
  /// single-threaded event loop no producer can interleave between the two
  /// — whichever consumer harvests first gets the segment exactly once.
  Uint8List drainBufferedAudio() {
    final drained = _bufferedAudio;

    _bufferedAudio = Uint8List(0);

    return drained;
  }

  /// The most recent voice-command audio tail (up to 10 seconds) — the
  /// pre-trigger audio for wake-word style flows.
  Uint8List get voiceCommandAudio {
    final bytesPerSample = bitDepth ~/ 8;
    const sampleLength = 10;
    final start =
        _voiceCommandAudioBuffer.lengthInBytes -
        sampleRate * sampleLength * bytesPerSample;

    // Return all available audio when less than 10 seconds has been
    // collected.
    if (start < 0) return _voiceCommandAudioBuffer;

    return _voiceCommandAudioBuffer.sublist(start);
  }

  /// Re-emits the conversation-creation window's audio onto [audioStream]:
  /// drains the RAM buffer, combines it with the voice-command tail, and
  /// pushes the combined audio so late subscribers (chunk uploaders,
  /// transcribers) receive it — while the still-armed buffering
  /// subscription re-captures it. Clears the voice-command buffer.
  Future<void> emitInitialAudio() async {
    final initialBufferedAudio = drainBufferedAudio();

    final voiceCommandAudio = this.voiceCommandAudio;

    final initialAudio =
        Uint8List(voiceCommandAudio.length + initialBufferedAudio.length)
          ..setAll(0, voiceCommandAudio)
          ..setAll(voiceCommandAudio.length, initialBufferedAudio);

    if (initialAudio.isNotEmpty) {
      // Ensure the RAM buffer is armed so this audio is captured for
      // transcription at pipe attach (it normally already is — armed at
      // conversation start or by a mid-stream disconnect).
      if (_bufferedAudioSubscription == null) {
        final isBufferingStarted = await startAudioBuffering();

        if (!isBufferingStarted) return;
      }

      _audioDataStream$.add(initialAudio);
    }

    _voiceCommandAudioBuffer = Uint8List(0);
  }

  // --------------------------------------------------------------------------
  // Diagnostics
  // --------------------------------------------------------------------------

  /// Native route diagnostics (Android only; null elsewhere and on
  /// failure).
  Future<Map<String, Object?>?> getRouteState() async {
    if (!micIsAndroid) return null;

    try {
      return await MicRecorderPlatform.instance.getRouteState();
    } catch (_) {
      return null;
    }
  }

  /// Decodes [filePath] into [barCount] normalized (0.1–1.0) RMS bars for
  /// waveform rendering (any common audio container).
  Future<List<double>?> extractAmplitudes({
    required String filePath,
    int barCount = 60,
  }) => MicRecorderPlatform.instance.extractAmplitudes(
    filePath: filePath,
    barCount: barCount,
  );

  /// Whether another app's audio is currently playing (music, or a call
  /// holding the microphone).
  Future<bool> isOtherAudioPlaying() =>
      _sessionController.isOtherAudioPlaying();

  /// Whether a call (POTS or VoIP) currently holds the microphone (Android
  /// only).
  Future<bool> isAndroidMicHeldByCall() =>
      _sessionController.isAndroidMicHeldByCall();

  // --------------------------------------------------------------------------
  // Teardown
  // --------------------------------------------------------------------------

  /// Tears the recorder down completely (engine detach / hot restart).
  Future<void> dispose() async {
    if (_state$.value.isActive) {
      await stop();
    } else if (_encodedEncoder != null) {
      // An armed-but-idle encoder would otherwise leak its native codec.
      await MicRecorderPlatform.instance.clearEncodedOutput();

      _resetEncodedOutputArming();
    }

    // Fake-async law: broadcast close/cancel futures never resolve under a
    // fake event loop — the teardown below is fire-and-forget.
    unawaited(_conversationSilenceController.close());

    unawaited(_amplitudeController.close());

    unawaited(_durationController.close());

    final interruptionSubscription = _interruptionSubscription;

    _interruptionSubscription = null;

    unawaited(interruptionSubscription?.cancel() ?? Future<void>.value());

    await _route?.dispose();
    _route = null;

    await _session?.dispose();
    _session = null;

    _lifecycleTracker = null;

    unawaited(_audioDataStream$.close());

    _state$.close();

    _controllersBuilt = false;
  }
}
