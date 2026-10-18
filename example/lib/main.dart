/// Example app for the mic_recorder plugin.
///
/// This single-file Material 3 demo exercises every public member of
/// `package:mic_recorder`:
///
///  * lifecycle — [MicRecorder.initialize], [MicRecorder.start],
///    [MicRecorder.pause], [MicRecorder.resume], [MicRecorder.stop]
///    (the returned [MicRecordingInfo] lands in a result card),
///    [MicRecorder.cancel] (discards the episode) and [MicRecorder.dispose]
///    (behind a confirmation dialog, because the singleton teardown is
///    terminal);
///  * permissions — [MicRecorder.checkMicrophonePermission] and
///    [MicRecorder.requestMicrophonePermission] on a pre-flight gate card
///    shown before the first start;
///  * streams — [MicRecorder.audioStream] (live RMS meter with peak hold),
///    [MicRecorder.onStateChange], [MicRecorder.onAudioInterruption],
///    [MicRecorder.onAudioSourceSwitched],
///    [MicRecorder.onConversationSilence] and [MicRecorder.onMicrophoneLost]
///    (timestamped event log);
///  * metering — [MicRecorder.onAmplitude] (dBFS current / average / peak
///    meter, throttled by [MicRecorderConfig.amplitudeInterval]), the
///    [MicRecorder.amplitude] getter, [MicRecorder.onDurationChanged]
///    (live mm:ss episode clock) and [MicRecorder.elapsedDuration];
///  * RAM buffering — [MicRecorder.startAudioBuffering],
///    [MicRecorder.stopAudioBuffering], [MicRecorder.drainBufferedAudio],
///    [MicRecorder.voiceCommandAudio] and [MicRecorder.emitInitialAudio];
///  * file output — [MicRecorder.setOutputFile] (raw pcm16 or a WAV
///    container the plugin writes itself), [MicRecorder.outputFile],
///    [MicRecorder.outputFileFormat], [MicRecorder.clearOutputFile] and
///    [MicRecorder.extractAmplitudes];
///  * encoded output — [MicRecorder.setEncodedOutput],
///    [MicRecorder.clearEncodedOutput] and
///    [MicRecorder.encodedOutputFile] (native AAC-LC / Apple Lossless /
///    Opus / FLAC / AMR-NB / AMR-WB);
///  * routing and diagnostics — [MicRecorder.isRouteSwitchingEnabled],
///    [MicRecorder.setRouteSwitchingEnabled], [MicRecorder.getRouteState],
///    [MicRecorder.isOtherAudioPlaying] and
///    [MicRecorder.isAndroidMicHeldByCall];
///  * configuration — [MicRecorderConfig] with every section
///    (sample rate, amplitude interval, max duration, Android capture
///    effects, audio session, Android foreground service, route switching
///    and the log sink).
///
/// Types that the live flow never hands to the app (device models, the
/// platform decoders and sample event instances) are shown in the API type
/// gallery, see `api_gallery.dart`.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mic_recorder/mic_recorder.dart';

import 'api_gallery.dart';

/// dB floor of the live level meter.
const double _meterFloorDb = -60;

/// Peak-hold decay applied per received chunk (dB per chunk).
const double _peakDecayDbPerChunk = 1.5;

/// Maximum number of entries kept in the event log.
const int _maxLogEntries = 300;

void main() => runApp(const MicRecorderExampleApp());

/// Root of the demo: Material 3 light/dark themes seeded with a red
/// scheme, plus a theme-mode menu in the app bar.
class MicRecorderExampleApp extends StatefulWidget {
  /// Creates the example app.
  const MicRecorderExampleApp({super.key});

  @override
  State<MicRecorderExampleApp> createState() => _MicRecorderExampleAppState();
}

class _MicRecorderExampleAppState extends State<MicRecorderExampleApp> {
  ThemeMode _themeMode = ThemeMode.system;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'mic_recorder example',
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFFDC2626),
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: const Color(0xFFDC2626),
        brightness: Brightness.dark,
      ),
      themeMode: _themeMode,
      home: _MicRecorderHomePage(
        themeMode: _themeMode,
        onThemeModeSelected: (mode) => setState(() => _themeMode = mode),
      ),
    );
  }
}

/// The demo home page: owns the recorder wiring, all cards and the
/// configuration screen route.
class _MicRecorderHomePage extends StatefulWidget {
  const _MicRecorderHomePage({
    required this.themeMode,
    required this.onThemeModeSelected,
  });

  /// Currently selected [ThemeMode] (owned by the app root).
  final ThemeMode themeMode;

  /// Notifies the app root that the user picked a new theme mode.
  final ValueChanged<ThemeMode> onThemeModeSelected;

  @override
  State<_MicRecorderHomePage> createState() => _MicRecorderHomePageState();
}

class _MicRecorderHomePageState extends State<_MicRecorderHomePage>
    with SingleTickerProviderStateMixin {
  /// Drives the pulsing microphone dot while recording.
  late final AnimationController _pulse;

  /// Timestamped event log entries (newest rendered first, capped).
  final List<_LogEntry> _logEntries = <_LogEntry>[];

  /// Live audio accounting, updated per chunk WITHOUT [setState] so the
  /// UI does not rebuild on every audio buffer.
  final ValueNotifier<_AudioStats> _audioStats = ValueNotifier<_AudioStats>(
    const _AudioStats(),
  );

  /// Current meter level in dB (null until the first chunk arrives).
  final ValueNotifier<double?> _levelDb = ValueNotifier<double?>(null);

  /// Peak-hold level in dB (decays as quiet chunks keep flowing).
  final ValueNotifier<double> _peakDb = ValueNotifier<double>(_meterFloorDb);

  StreamSubscription<List<int>>? _audioSubscription;

  /// Subscription to the orchestrator's amplitude stream (initialize()
  /// never rebuilds it — one subscription lasts the app lifetime).
  StreamSubscription<MicAmplitude>? _amplitudeSubscription;

  /// Subscription to the orchestrator's duration stream.
  StreamSubscription<Duration>? _durationSubscription;

  /// Latest dBFS reading from [MicRecorder.onAmplitude] (throttled to
  /// MicRecorderConfig.amplitudeInterval; null until audio flows).
  final ValueNotifier<MicAmplitude?> _amplitude = ValueNotifier<MicAmplitude?>(
    null,
  );

  /// Freshest reading from the [MicRecorder.amplitude] getter (updated
  /// per chunk — at least as fresh as [_amplitude]).
  final ValueNotifier<MicAmplitude?> _amplitudeNow =
      ValueNotifier<MicAmplitude?>(null);

  /// Live episode clock, fed by [MicRecorder.onDurationChanged] (null
  /// before the first start; the exact total after stop()).
  final ValueNotifier<Duration?> _episodeDuration = ValueNotifier<Duration?>(
    null,
  );

  /// Subscriptions to the recorder's five event streams. The three
  /// controller-backed streams are re-subscribed whenever
  /// `MicRecorder.initialize` rebuilds the controllers.
  final List<StreamSubscription<void>> _eventSubscriptions =
      <StreamSubscription<void>>[];

  /// Last state seen on [MicRecorder.onStateChange] (drives the UI).
  MicRecorderState _lastState = MicRecorderState.stopped;

  /// Last recording mode started (drives the mode pill).
  MicRecordingMode _lastMode = MicRecordingMode.conversation;

  /// Cached [MicRecorder.isRouteSwitchingEnabled] — the getter is
  /// controller-backed, so it must NOT be read after [MicRecorder.dispose].
  bool _routeSwitchingEnabled = false;

  /// Whether the demo's log sink is attached via [MicRecorderConfig.log].
  bool _logSinkEnabled = true;

  /// Whether the permissions banner is shown.
  bool _permissionHint = false;

  /// Result of the last checkMicrophonePermission() call (null while
  /// unchecked).
  bool? _micPermissionGranted;

  /// Whether a recording has been started at least once (hides the
  /// pre-flight permission gate card afterwards).
  bool _startedOnce = false;

  /// Whether a manual stop() / cancel() / dispose() is currently in flight
  /// — used to tell maxDuration auto-stops apart from those.
  bool _manualStopRequested = false;

  /// Whether [MicRecorder.dispose] has been run (terminal for the
  /// singleton — the demo stops touching controller-backed members).
  bool _disposed = false;

  // ---- RAM buffering accounting (derived from byte accounting) ----

  /// Whether [MicRecorder.startAudioBuffering] is currently armed.
  bool _bufferArmed = false;

  /// Value of the episode byte counter when buffering was armed.
  int _episodeBytesAtBufferArm = 0;

  /// Bytes harvested out of the current buffering episode.
  int _drainedInEpisode = 0;

  /// Cumulative bytes harvested across all episodes.
  int _totalHarvestedBytes = 0;

  /// Bytes returned by the most recent harvest (drain or stop).
  int _lastHarvestBytes = 0;

  /// Length of the most recent [MicRecorder.voiceCommandAudio] sample.
  int _lastVoiceTailBytes = 0;

  // ---- File output accounting ----

  /// Whether the 'record to file' switch is on.
  bool _recordToFile = false;

  /// Container format armed for the Dart-written output.
  MicRecordingFileFormat _fileFormat = MicRecordingFileFormat.wav;

  /// File currently armed for output (the plugin's writer owns the
  /// container — WAV header included).
  File? _armedFile;

  /// Last file the plugin's writer closed (ready for amplitude
  /// extraction).
  File? _lastCompletedFile;

  // ---- Encoded output accounting ----

  /// Encoder selected in the encoded-output card.
  MicAudioEncoder _selectedEncoder = MicAudioEncoder.aacLc;

  /// Bit-rate field of the encoded-output card (empty = encoder default).
  final TextEditingController _bitRateController = TextEditingController();

  /// Result of the most recently completed episode — the object stop()
  /// returned, or the recorder's lastRecordingInfo after an auto-stop.
  MicRecordingInfo? _lastRecordingInfo;

  /// Bars returned by the last successful extractAmplitudes call.
  List<double>? _waveformBars;

  /// Graceful error message when extraction failed (null result).
  String? _waveformError;

  // ---- Diagnostics ----

  bool? _otherAudioPlaying;
  bool? _micHeldByCall;
  Map<String, Object?>? _routeState;

  @override
  void initState() {
    super.initState();

    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );

    // Configure the recorder once, up front, so the log sink is live from
    // the very first controller construction (otherwise the plugin would
    // build its controllers lazily with MicRecorderConfig defaults).
    MicRecorder.instance.initialize(MicRecorderConfig(log: _onPluginLog));

    // Cache the route-switching flag while the controllers exist.
    _routeSwitchingEnabled = MicRecorder.instance.isRouteSwitchingEnabled;

    _subscribeEventStreams();

    // The audio stream is a broadcast stream: the demo keeps one
    // subscription alive for the whole app lifetime.
    _audioSubscription = MicRecorder.instance.audioStream.listen(_onAudioChunk);

    // The amplitude and duration streams live on the recorder itself
    // (initialize() never rebuilds them), so one subscription each lasts
    // the whole app lifetime as well.
    _amplitudeSubscription = MicRecorder.instance.onAmplitude.listen(
      (reading) => _amplitude.value = reading,
    );
    _durationSubscription = MicRecorder.instance.onDurationChanged.listen(
      (elapsed) => _episodeDuration.value = elapsed,
    );
  }

  @override
  void dispose() {
    _pulse.dispose();
    _audioSubscription?.cancel();
    _amplitudeSubscription?.cancel();
    _durationSubscription?.cancel();
    for (final subscription in _eventSubscriptions) {
      subscription.cancel();
    }
    _eventSubscriptions.clear();
    _bitRateController.dispose();
    _levelDb.dispose();
    _peakDb.dispose();
    _amplitude.dispose();
    _amplitudeNow.dispose();
    _episodeDuration.dispose();
    _audioStats.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('mic_recorder example'),
        actions: <Widget>[
          IconButton(
            tooltip: 'API type gallery',
            icon: const Icon(Icons.category_outlined),
            onPressed: _openGallery,
          ),
          IconButton(
            tooltip: 'Configuration',
            icon: const Icon(Icons.settings_outlined),
            onPressed: _disposed ? null : _openConfigScreen,
          ),
          _buildThemeMenu(),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: <Widget>[
          if (_disposed) _buildDisposedBanner(context),
          if (_permissionHint) _buildPermissionBanner(context),
          if (_lastState == MicRecorderState.error) _buildErrorBanner(context),
          if (!_disposed && (!_startedOnce || _permissionHint))
            _buildPermissionGateCard(context),
          _buildStatusCard(context),
          _buildControlsCard(context),
          if (_lastRecordingInfo != null) _buildResultCard(context),
          _buildLiveAudioCard(context),
          _buildBufferingCard(context),
          _buildFileOutputCard(context),
          _buildEncodedOutputCard(context),
          _buildRoutingCard(context),
          _buildEventLogCard(context),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  /// Theme-mode menu required by the app-root [MaterialApp].
  Widget _buildThemeMenu() {
    final icons = <ThemeMode, IconData>{
      ThemeMode.system: Icons.brightness_auto_outlined,
      ThemeMode.light: Icons.light_mode_outlined,
      ThemeMode.dark: Icons.dark_mode_outlined,
    };
    return PopupMenuButton<ThemeMode>(
      tooltip: 'Theme mode',
      icon: Icon(icons[widget.themeMode] ?? Icons.brightness_auto_outlined),
      initialValue: widget.themeMode,
      onSelected: widget.onThemeModeSelected,
      itemBuilder: (context) => const <PopupMenuEntry<ThemeMode>>[
        PopupMenuItem(value: ThemeMode.system, child: Text('System')),
        PopupMenuItem(value: ThemeMode.light, child: Text('Light')),
        PopupMenuItem(value: ThemeMode.dark, child: Text('Dark')),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Banners
  // ---------------------------------------------------------------------------

  /// Explains that the plugin never requests permissions itself.
  Widget _buildPermissionBanner(BuildContext context) {
    return _Banner(
      icon: Icons.privacy_tip_outlined,
      color: Colors.amber.shade800,
      title: 'Permissions are not requested by the plugin',
      body:
          'Recording could not start. mic_recorder deliberately does not ask '
          'for permissions itself — run checkMicrophonePermission() / '
          'requestMicrophonePermission() in the pre-flight gate card, or '
          'grant them in the system settings, then try again:\n'
          '• Android: RECORD_AUDIO, plus POST_NOTIFICATIONS on Android 13+ '
          '(for the recording foreground service).\n'
          '• iOS: NSMicrophoneUsageDescription must be present in '
          'Info.plist.\n'
          'The exact snippets are in README.md.',
      onDismiss: () => setState(() => _permissionHint = false),
    );
  }

  /// Shown when the recorder reported the error state.
  Widget _buildErrorBanner(BuildContext context) {
    return _Banner(
      icon: Icons.error_outline,
      color: Theme.of(context).colorScheme.error,
      title: 'Recorder error state',
      body:
          'The native side refused to start capture. This usually means the '
          'microphone permission is missing (see README.md) or another app '
          'holds exclusive access to the input.',
    );
  }

  /// Shown after the terminal [MicRecorder.dispose].
  Widget _buildDisposedBanner(BuildContext context) {
    return _Banner(
      icon: Icons.power_settings_new,
      color: Theme.of(context).colorScheme.error,
      title: 'MicRecorder disposed',
      body:
          'dispose() permanently tears the singleton down — its streams are '
          'closed and initialize() cannot revive them. Restart the app (a '
          'hot restart also works) to record again. From here on this demo '
          'no longer reads controller-backed getters.',
    );
  }

  // ---------------------------------------------------------------------------
  // Permission pre-flight gate card
  // ---------------------------------------------------------------------------

  /// Pre-flight gate for the first start — the permission verbs in
  /// action. The card stays visible until the first successful start, and
  /// re-appears whenever a failure suggests the permission went missing.
  Widget _buildPermissionGateCard(BuildContext context) {
    return _SectionCard(
      title: 'Permissions (pre-flight gate)',
      subtitle:
          'checkMicrophonePermission() reports the current grant without a '
          'prompt; requestMicrophonePermission() runs the OS journey. Gate '
          'start() on the result — the plugin never requests permissions '
          'itself.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _diagnosticRow(
            context,
            'checkMicrophonePermission()',
            _micPermissionLabel(),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              OutlinedButton.icon(
                onPressed: _disposed ? null : _checkMicPermission,
                icon: const Icon(Icons.rule_outlined, size: 18),
                label: const Text('checkMicrophonePermission()'),
              ),
              FilledButton.tonalIcon(
                onPressed: _disposed ? null : _requestMicPermission,
                icon: const Icon(Icons.mic_none, size: 18),
                label: const Text('requestMicrophonePermission()'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Status text for the permission card (null = never checked).
  String _micPermissionLabel() {
    final granted = _micPermissionGranted;
    if (granted == null) return '— (not checked yet)';
    return granted ? 'true (granted)' : 'false (denied)';
  }

  Future<void> _checkMicPermission() async {
    if (_disposed) return;
    try {
      final granted = await MicRecorder.instance.checkMicrophonePermission();
      if (!mounted) return;
      setState(() => _micPermissionGranted = granted);
      _logAction('checkMicrophonePermission() → $granted');
    } catch (e) {
      _logAction('checkMicrophonePermission() threw $e');
    }
  }

  Future<void> _requestMicPermission() async {
    if (_disposed) return;
    try {
      final granted = await MicRecorder.instance.requestMicrophonePermission();
      if (!mounted) return;
      setState(() {
        _micPermissionGranted = granted;
        if (!granted) _permissionHint = true;
      });
      _logAction('requestMicrophonePermission() → $granted');
    } catch (e) {
      _logAction('requestMicrophonePermission() threw $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Status card
  // ---------------------------------------------------------------------------

  Widget _buildStatusCard(BuildContext context) {
    final recorder = MicRecorder.instance;
    final stateColor = _stateColor(recorder.currentState);

    return _SectionCard(
      title: 'Status',
      subtitle:
          'onStateChange drives the chip; onDurationChanged drives the '
          'mm:ss clock; isInitialized, sampleRate, bitDepth, mode, '
          'currentState, recordingStartedAt, elapsedDuration and '
          'bufferingStartedAt are shown as pills.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              StreamBuilder<MicRecorderState>(
                stream: _disposed ? null : recorder.onStateChange,
                builder: (context, snapshot) {
                  final state = snapshot.data ?? _lastState;
                  return _StateChip(state: state);
                },
              ),
              const SizedBox(width: 12),
              _PulsingDot(controller: _pulse, color: stateColor),
              const SizedBox(width: 8),
              Icon(Icons.mic, size: 18, color: stateColor),
              const SizedBox(width: 12),
              Icon(Icons.timer_outlined, size: 18, color: stateColor),
              const SizedBox(width: 8),
              ValueListenableBuilder<Duration?>(
                valueListenable: _episodeDuration,
                builder: (context, elapsed, _) => Text(
                  _formatDurationClock(elapsed),
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const Spacer(),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              _StatPill(
                label: 'isInitialized',
                value: recorder.isInitialized ? 'yes' : 'no',
              ),
              _StatPill(
                label: 'sampleRate',
                value: '${recorder.sampleRate} Hz',
              ),
              _StatPill(label: 'bitDepth', value: '${recorder.bitDepth} bit'),
              _StatPill(label: 'mode', value: _lastMode.name),
              _StatPill(
                label: 'currentState',
                value: recorder.currentState.name,
              ),
              _StatPill(
                label: 'recordingStartedAt',
                value: _formatTimestamp(recorder.recordingStartedAt),
              ),
              _StatPill(
                label: 'elapsedDuration',
                value: _formatDurationClock(recorder.elapsedDuration),
              ),
              _StatPill(
                label: 'bufferingStartedAt',
                value: _formatTimestamp(
                  _disposed ? null : recorder.bufferingStartedAt,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            _configSummary(recorder.config),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  String _configSummary(MicRecorderConfig config) {
    final session = config.audioSession;
    final fgs = config.androidForegroundService;
    final sessionFlags = <String>[
      'bluetooth ${session.allowBluetooth ? 'on' : 'off'}',
      'speaker ${session.defaultToSpeaker ? 'on' : 'off'}',
      'notify ${session.notifyOthersOnDeactivation ? 'on' : 'off'}',
      'duck→pause ${session.androidWillPauseWhenDucked ? 'on' : 'off'}',
    ].join(' · ');
    final effects = config.wantsAndroidAudioEffects
        ? <String>[
            'echo ${config.androidEchoCancel ? 'on' : 'off'}',
            'noise ${config.androidNoiseSuppress ? 'on' : 'off'}',
            'gain ${config.androidAutoGain ? 'on' : 'off'}',
          ].join(' · ')
        : 'effects off';
    final maxDuration = config.maxDuration;
    final maxDurationLabel = maxDuration == null
        ? 'none'
        : _formatDurationClock(maxDuration);
    return '${config.sampleRate} Hz · route switching '
        '${config.routeSwitchingEnabled ? 'on' : 'off'} · FGS '
        '${fgs.enabled ? 'on' : 'off'} · $sessionFlags · amplitude every '
        '${config.amplitudeInterval.inMilliseconds} ms · $effects · '
        'maxDuration $maxDurationLabel · '
        'log ${config.log != null ? 'sink attached' : 'defaultMicLog'}';
  }

  // ---------------------------------------------------------------------------
  // Controls card
  // ---------------------------------------------------------------------------

  Widget _buildControlsCard(BuildContext context) {
    final active = _lastState.isActive;

    return _SectionCard(
      title: 'Controls',
      subtitle:
          'start(mode:) / pause() / resume() / stop() / cancel(). stop() '
          'returns the MicRecordingInfo shown in the result card; cancel() '
          'discards the episode and every file it wrote; dispose() sits '
          'behind a confirmation dialog because the singleton teardown is '
          'terminal.',
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: <Widget>[
          FilledButton.icon(
            onPressed: (!_disposed && !active)
                ? () => _startRecording(MicRecordingMode.conversation)
                : null,
            icon: const Icon(Icons.fiber_manual_record, size: 18),
            label: const Text('Start (conversation)'),
          ),
          FilledButton.tonalIcon(
            onPressed: (!_disposed && !active)
                ? () => _startRecording(MicRecordingMode.voiceCommand)
                : null,
            icon: const Icon(Icons.graphic_eq, size: 18),
            label: const Text('Start (voice command)'),
          ),
          OutlinedButton.icon(
            onPressed: (!_disposed && _lastState.isRecording)
                ? _pauseRecording
                : null,
            icon: const Icon(Icons.pause, size: 18),
            label: const Text('Pause'),
          ),
          OutlinedButton.icon(
            onPressed: (!_disposed && _lastState == MicRecorderState.paused)
                ? _resumeRecording
                : null,
            icon: const Icon(Icons.play_arrow, size: 18),
            label: const Text('Resume'),
          ),
          FilledButton.icon(
            onPressed: (!_disposed && active) ? _stopRecording : null,
            icon: const Icon(Icons.stop, size: 18),
            label: const Text('Stop'),
          ),
          OutlinedButton.icon(
            onPressed: (!_disposed && active) ? _confirmCancelRecording : null,
            icon: const Icon(Icons.delete_sweep_outlined, size: 18),
            label: const Text('Cancel (discard)…'),
          ),
          OutlinedButton.icon(
            onPressed: !_disposed ? _confirmDispose : null,
            icon: const Icon(Icons.delete_forever_outlined, size: 18),
            label: const Text('Dispose…'),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Stop result card
  // ---------------------------------------------------------------------------

  /// The result of the most recently completed episode — the object
  /// stop() returned, or (after a maxDuration auto-stop) what the
  /// recorder published through lastRecordingInfo.
  Widget _buildResultCard(BuildContext context) {
    final theme = Theme.of(context);
    final info = _lastRecordingInfo!;
    final autoStopped =
        info.stopReason == MicRecordingStopReason.maxDurationReached;

    return _SectionCard(
      title: 'Stop result (MicRecordingInfo)',
      subtitle:
          'stop() returns it directly; after a MicRecorderConfig '
          'maxDuration auto-stop the demo picks it up through the '
          'lastRecordingInfo getter instead (no manual stop happened).',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (autoStopped) ...<Widget>[
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.amber.shade800.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: Colors.amber.shade800.withValues(alpha: 0.5),
                ),
              ),
              child: Text(
                'maxDuration reached — the recorder stopped itself and '
                'reported stopReason == maxDurationReached via '
                'lastRecordingInfo.',
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
          _diagnosticRow(
            context,
            'duration',
            _formatDurationClock(info.duration),
          ),
          _diagnosticRow(
            context,
            'sizeBytes',
            '${_formatBytes(info.sizeBytes)} (${info.sizeBytes})',
          ),
          _PathRow(label: 'path', path: info.path ?? '— (stream only)'),
          _diagnosticRow(context, 'encoder', info.encoder?.name ?? '—'),
          _diagnosticRow(
            context,
            'fileFormat',
            info.fileFormat?.wireName ?? '—',
          ),
          _diagnosticRow(context, 'stopReason', info.stopReason.name),
          _diagnosticRow(
            context,
            'startedAtUtc',
            _formatTimestamp(info.startedAtUtc),
          ),
          _diagnosticRow(
            context,
            'sampleRate × bitDepth × channels',
            '${info.sampleRate} Hz · ${info.bitDepth} bit · ${info.channels}',
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Live audio card
  // ---------------------------------------------------------------------------

  Widget _buildLiveAudioCard(BuildContext context) {
    final amplitudeIntervalMs = _disposed
        ? null
        : MicRecorder.instance.config.amplitudeInterval.inMilliseconds;

    return _SectionCard(
      title: 'Live audio',
      subtitle:
          'audioStream delivers raw 16-bit little-endian mono PCM chunks; '
          'the demo computes an RMS per chunk and renders a −60 dB-floor '
          'meter with peak hold. Meter updates flow through '
          'ValueNotifiers — no per-chunk setState.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _LevelMeter(
            levelDb: _levelDb,
            peakDb: _peakDb,
            active: _lastState.isActive,
          ),
          const SizedBox(height: 8),
          ValueListenableBuilder<_AudioStats>(
            valueListenable: _audioStats,
            builder: (context, stats, _) => Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                _StatPill(
                  label: 'streamed bytes',
                  value: _formatBytes(stats.bytes),
                ),
                _StatPill(label: 'streamed chunks', value: '${stats.chunks}'),
                _StatPill(
                  label: 'last rms',
                  value: stats.lastRms.toStringAsFixed(5),
                ),
              ],
            ),
          ),
          const Divider(),
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  'Amplitude metering (onAmplitude / amplitude)',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'onAmplitude emits MicAmplitude readings in dBFS, throttled to '
            'at most one event per MicRecorderConfig.amplitudeInterval '
            '(now ${amplitudeIntervalMs ?? '—'} ms); the amplitude getter '
            'always holds the freshest per-chunk reading.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          _DbfsMeter(amplitude: _amplitude, active: _lastState.isActive),
          const SizedBox(height: 8),
          ValueListenableBuilder<MicAmplitude?>(
            valueListenable: _amplitudeNow,
            builder: (context, reading, _) => Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                _StatPill(
                  label: 'amplitude (getter)',
                  value: reading == null
                      ? '—'
                      : '${reading.currentDbfs.toStringAsFixed(1)} dBFS',
                ),
                _StatPill(
                  label: 'isSilent',
                  value: reading == null ? '—' : '${reading.isSilent}',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // RAM buffering card
  // ---------------------------------------------------------------------------

  Widget _buildBufferingCard(BuildContext context) {
    return _SectionCard(
      title: 'RAM buffering',
      subtitle:
          'startAudioBuffering() implicitly starts recording (conversation '
          'mode) — it does NOT arm the record-to-file switch. In-buffer '
          'bytes are derived from byte accounting: chunks seen since the '
          'arm minus what was harvested.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              FilledButton.tonalIcon(
                onPressed: (!_disposed && !_bufferArmed)
                    ? _startBuffering
                    : null,
                icon: const Icon(Icons.download_for_offline_outlined, size: 18),
                label: const Text('startAudioBuffering()'),
              ),
              OutlinedButton.icon(
                onPressed: (!_disposed && _bufferArmed) ? _stopBuffering : null,
                icon: const Icon(Icons.file_download_done_outlined, size: 18),
                label: const Text('stopAudioBuffering()'),
              ),
              OutlinedButton.icon(
                onPressed: (!_disposed && _bufferArmed) ? _drainBuffer : null,
                icon: const Icon(Icons.content_cut, size: 18),
                label: const Text('drainBufferedAudio()'),
              ),
              OutlinedButton.icon(
                onPressed: !_disposed ? _sampleVoiceTail : null,
                icon: const Icon(Icons.queue_music_outlined, size: 18),
                label: const Text('voiceCommandAudio'),
              ),
              FilledButton.tonalIcon(
                onPressed: (!_disposed && _bufferArmed)
                    ? _emitInitialAudio
                    : null,
                icon: const Icon(Icons.replay_outlined, size: 18),
                label: const Text('emitInitialAudio()'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ValueListenableBuilder<_AudioStats>(
            valueListenable: _audioStats,
            builder: (context, stats, _) => Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                _StatPill(
                  label: 'in buffer (est.)',
                  value: _formatBytes(_estimatedInBufferBytes(stats)),
                ),
                _StatPill(
                  label: 'harvested total',
                  value: _formatBytes(_totalHarvestedBytes),
                ),
                _StatPill(
                  label: 'last harvest',
                  value: _formatBytes(_lastHarvestBytes),
                ),
                _StatPill(
                  label: 'last voice tail',
                  value: _formatBytes(_lastVoiceTailBytes),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          _diagnosticRow(
            context,
            'bufferingStartedAt',
            _formatTimestamp(
              _disposed ? null : MicRecorder.instance.bufferingStartedAt,
            ),
          ),
        ],
      ),
    );
  }

  /// Estimated bytes currently sitting in the plugin's RAM buffer.
  ///
  /// The plugin intentionally exposes no live buffer-length getter, so the
  /// demo derives it: bytes streamed since the arm minus bytes harvested
  /// since then. [MicRecorder.emitInitialAudio] drains the RAM buffer before
  /// re-emitting it onto the stream; the demo counts that internal drain as
  /// harvested so the re-emitted bytes do not inflate the estimate.
  int _estimatedInBufferBytes(_AudioStats stats) {
    if (!_bufferArmed) return 0;
    final seenSinceArm = stats.bytes - _episodeBytesAtBufferArm;
    return math.max(0, seenSinceArm - _drainedInEpisode);
  }

  // ---------------------------------------------------------------------------
  // File output card
  // ---------------------------------------------------------------------------

  Widget _buildFileOutputCard(BuildContext context) {
    final theme = Theme.of(context);
    final active = _lastState.isActive;
    final outputPath = _disposed ? null : MicRecorder.instance.outputFile?.path;
    final outputFormat = _disposed
        ? null
        : MicRecorder.instance.outputFileFormat?.wireName;

    return _SectionCard(
      title: 'File output',
      subtitle:
          'setOutputFile(path, format:) — the plugin writes the container '
          'itself: pcm16 is headerless raw PCM, wav gets the canonical '
          '44-byte RIFF header with the sizes patched when the writer '
          'closes (on stop() or clearOutputFile()). extractAmplitudes() '
          'can then decode the file.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Record to file'),
            subtitle: Text(
              'Arms a fresh timestamped file per recording under '
              '${Directory.systemTemp.path}.',
            ),
            value: _recordToFile,
            onChanged: (_disposed || active) ? null : _setRecordToFile,
          ),
          const SizedBox(height: 4),
          SegmentedButton<MicRecordingFileFormat>(
            segments: const <ButtonSegment<MicRecordingFileFormat>>[
              ButtonSegment<MicRecordingFileFormat>(
                value: MicRecordingFileFormat.pcm16,
                label: Text('pcm16 (raw)'),
              ),
              ButtonSegment<MicRecordingFileFormat>(
                value: MicRecordingFileFormat.wav,
                label: Text('wav (container)'),
              ),
            ],
            selected: <MicRecordingFileFormat>{_fileFormat},
            onSelectionChanged: (_disposed || active || !_recordToFile)
                ? null
                : (selection) => unawaited(_changeFileFormat(selection.first)),
          ),
          const SizedBox(height: 6),
          _PathRow(label: 'outputFile (getter)', path: outputPath ?? '—'),
          _diagnosticRow(
            context,
            'outputFileFormat (getter)',
            outputFormat ?? '— (nothing armed)',
          ),
          if (_armedFile != null)
            _PathRow(label: 'armed file', path: _armedFile!.path),
          if (_lastCompletedFile != null)
            _PathRow(
              label: 'last completed file',
              path: _lastCompletedFile!.path,
            ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              OutlinedButton.icon(
                onPressed: (!_disposed && _armedFile != null)
                    ? _clearOutputFile
                    : null,
                icon: const Icon(Icons.delete_outline, size: 18),
                label: const Text('clearOutputFile()'),
              ),
              FilledButton.tonalIcon(
                onPressed: (!_disposed && _lastCompletedFile != null)
                    ? _renderWaveform
                    : null,
                icon: const Icon(Icons.waves_outlined, size: 18),
                label: const Text('extractAmplitudes(60 bars)'),
              ),
            ],
          ),
          if (_waveformError != null) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              _waveformError!,
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ],
          if (_waveformBars != null) ...<Widget>[
            const SizedBox(height: 8),
            SizedBox(
              height: 96,
              child: CustomPaint(
                painter: _WaveformPainter(
                  bars: _waveformBars!,
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Encoded output card (native encoders)
  // ---------------------------------------------------------------------------

  Widget _buildEncodedOutputCard(BuildContext context) {
    final theme = Theme.of(context);
    final encoder = _selectedEncoder;
    final sampleRate = MicRecorder.instance.sampleRate;
    final armedPath = _disposed
        ? null
        : MicRecorder.instance.encodedOutputFile?.path;
    final supported = encoder.isSupportedOn(
      android: defaultTargetPlatform == TargetPlatform.android,
      ios: defaultTargetPlatform == TargetPlatform.iOS,
    );
    final bitRateText = encoder.defaultBitRate == null
        ? ''
        : _bitRateController.text.trim();
    final bitRate = bitRateText.isEmpty ? null : int.tryParse(bitRateText);
    final bitRateInvalid = bitRateText.isNotEmpty && bitRate == null;
    final blockReason = _encodedArmBlockReason(
      encoder,
      supported: supported,
      sampleRate: sampleRate,
      bitRateInvalid: bitRateInvalid,
    );
    final canArm = !_disposed && blockReason == null && armedPath == null;
    final canClear = !_disposed && armedPath != null;

    return _SectionCard(
      title: 'Encoded output (native encoders)',
      subtitle:
          'setEncodedOutput(path, encoder:, bitRate:) arms a native encoder '
          'that runs alongside the raw stream and the Dart file writer — '
          'stop() finalizes the file, cancel() deletes it and '
          'clearEncodedOutput() disarms it early. The suggested file name '
          'ends in ${encoder.fileExtension} (MicAudioEncoder.fileExtension).',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          InputDecorator(
            decoration: const InputDecoration(
              labelText: 'encoder',
              border: OutlineInputBorder(),
            ),
            child: DropdownButton<MicAudioEncoder>(
              value: encoder,
              isDense: true,
              isExpanded: true,
              underline: SizedBox.shrink(),
              items: <DropdownMenuItem<MicAudioEncoder>>[
                for (final value in MicAudioEncoder.values)
                  DropdownMenuItem<MicAudioEncoder>(
                    value: value,
                    enabled: value.isSupportedOn(
                      android: defaultTargetPlatform == TargetPlatform.android,
                      ios: defaultTargetPlatform == TargetPlatform.iOS,
                    ),
                    child: Text(_encoderLabel(value)),
                  ),
              ],
              onChanged: _disposed
                  ? null
                  : (value) {
                      if (value != null) {
                        setState(() => _selectedEncoder = value);
                      }
                    },
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: TextFormField(
              controller: _bitRateController,
              enabled: encoder.defaultBitRate != null,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: 'bitRate (bits/second)',
                hintText: encoder.defaultBitRate == null
                    ? 'lossless — no bit rate to set'
                    : 'default: ${encoder.defaultBitRate}',
                border: const OutlineInputBorder(),
                errorText: bitRateInvalid ? 'bitRate must be an integer' : null,
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          if (blockReason != null) ...<Widget>[
            Text(blockReason, style: TextStyle(color: theme.colorScheme.error)),
            const SizedBox(height: 8),
          ],
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              FilledButton.tonalIcon(
                onPressed: canArm ? _armEncodedOutput : null,
                icon: const Icon(Icons.library_music_outlined, size: 18),
                label: const Text('setEncodedOutput()'),
              ),
              OutlinedButton.icon(
                onPressed: canClear ? _clearEncodedOutput : null,
                icon: const Icon(Icons.link_off_outlined, size: 18),
                label: const Text('clearEncodedOutput()'),
              ),
            ],
          ),
          _PathRow(label: 'encodedOutputFile (getter)', path: armedPath ?? '—'),
        ],
      ),
    );
  }

  /// Dropdown label for one encoder — container extension plus platform
  /// availability.
  String _encoderLabel(MicAudioEncoder encoder) {
    var availability = '';
    if (!encoder.android) availability = ' — iOS only';
    if (!encoder.ios) availability = ' — Android only';
    return '${encoder.name} (${encoder.fileExtension})$availability';
  }

  /// Why the arm button is disabled (null when arming is possible).
  String? _encodedArmBlockReason(
    MicAudioEncoder encoder, {
    required bool supported,
    required int sampleRate,
    required bool bitRateInvalid,
  }) {
    if (!supported) {
      return 'MicAudioEncoder.${encoder.name} is not available on this '
          'platform (isSupportedOn() → false).';
    }

    final requiredRate = encoder.requiredSampleRate;

    if (requiredRate != null && requiredRate != sampleRate) {
      return 'MicAudioEncoder.${encoder.name} requires $requiredRate Hz '
          'capture (AMR-NB: 8 kHz, AMR-WB: 16 kHz) — the configuration '
          'runs $sampleRate Hz. Pick that sample rate in Configuration.';
    }

    if (bitRateInvalid) {
      return 'bitRate must be an integer (bits/second) — or leave it empty '
          'for the encoder default.';
    }

    return null;
  }

  Future<void> _armEncodedOutput() async {
    if (_disposed) return;

    final encoder = _selectedEncoder;

    // bitRate applies to the lossy encoders only — a lossless encoder has
    // no bit rate to set (the field is disabled, but stale text could be
    // left over from an earlier lossy selection).
    final bitRateText = encoder.defaultBitRate == null
        ? ''
        : _bitRateController.text.trim();
    final bitRate = bitRateText.isEmpty ? null : int.tryParse(bitRateText);

    try {
      final file = File(
        '${Directory.systemTemp.path}'
        '${Platform.pathSeparator}'
        'mic_recorder_demo_${_timestamp()}${encoder.fileExtension}',
      );

      await MicRecorder.instance.setEncodedOutput(
        file.path,
        encoder: encoder,
        bitRate: bitRate,
      );

      if (mounted) setState(() {});

      _logAction(
        'setEncodedOutput(${encoder.name}) armed '
        '${encoder.fileExtension} (bitRate: '
        '${bitRate ?? encoder.defaultBitRate ?? 'lossless'})',
      );
    } catch (e) {
      _logAction('setEncodedOutput() failed: $e');
    }
  }

  Future<void> _clearEncodedOutput() async {
    if (_disposed) return;
    try {
      await MicRecorder.instance.clearEncodedOutput();
      if (mounted) setState(() {});
      _logAction('clearEncodedOutput() → disarmed (partial file deleted)');
    } catch (e) {
      _logAction('clearEncodedOutput() threw $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Routing & diagnostics card
  // ---------------------------------------------------------------------------

  Widget _buildRoutingCard(BuildContext context) {
    final theme = Theme.of(context);

    return _SectionCard(
      title: 'Routing & diagnostics',
      subtitle:
          'isRouteSwitchingEnabled / setRouteSwitchingEnabled steer the '
          'USB/wired → Bluetooth → built-in input priority ladder.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Priority route switching'),
            subtitle: const Text(
              'isRouteSwitchingEnabled / setRouteSwitchingEnabled',
            ),
            value: _routeSwitchingEnabled,
            onChanged: _disposed ? null : _setRouteSwitching,
          ),
          const Divider(),
          Row(
            children: <Widget>[
              Expanded(
                child: Text('Diagnostics', style: theme.textTheme.titleSmall),
              ),
              IconButton(
                tooltip: 'Refresh diagnostics',
                icon: const Icon(Icons.refresh),
                onPressed: _disposed ? null : _runDiagnostics,
              ),
            ],
          ),
          _diagnosticRow(
            context,
            'isOtherAudioPlaying()',
            _formatBool(_otherAudioPlaying),
          ),
          _diagnosticRow(
            context,
            'isAndroidMicHeldByCall()',
            _micHeldByCallLabel(),
          ),
          _diagnosticRow(
            context,
            'bufferingStartedAt',
            _formatTimestamp(
              _disposed ? null : MicRecorder.instance.bufferingStartedAt,
            ),
          ),
          const SizedBox(height: 4),
          Text('getRouteState()', style: theme.textTheme.labelSmall),
          ..._routeStateRows(theme),
        ],
      ),
    );
  }

  /// Renders the raw route-state map with its keys sorted (null means the
  /// verb is Android-only and returned nothing).
  List<Widget> _routeStateRows(ThemeData theme) {
    final map = _routeState;
    if (map == null) {
      return <Widget>[
        Text(
          'null (Android-only verb; null on iOS and on failure)',
          style: theme.textTheme.bodySmall,
        ),
      ];
    }
    final entries = map.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return <Widget>[
      for (final entry in entries)
        Padding(
          padding: const EdgeInsets.only(left: 8),
          child: Text(
            '${entry.key}: ${entry.value}',
            style: theme.textTheme.bodySmall,
          ),
        ),
    ];
  }

  /// Display text for the Android-only mic-held-by-call diagnostic.
  String _micHeldByCallLabel() {
    final heldByCall = _micHeldByCall;
    if (heldByCall == null) {
      return '—';
    }
    return Platform.isIOS
        ? '$heldByCall (Android-only — always false on iOS)'
        : '$heldByCall';
  }

  Widget _diagnosticRow(BuildContext context, String label, String value) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(child: Text(label, style: theme.textTheme.bodySmall)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Event log card
  // ---------------------------------------------------------------------------

  Widget _buildEventLogCard(BuildContext context) {
    final theme = Theme.of(context);

    return _SectionCard(
      title: 'Event log',
      subtitle:
          'onStateChange · onAudioInterruption · onAudioSourceSwitched · '
          'onConversationSilence · onMicrophoneLost · MicLogSink — capped '
          'at $_maxLogEntries entries.',
      trailing: TextButton.icon(
        onPressed: _logEntries.isEmpty
            ? null
            : () => setState(_logEntries.clear),
        icon: const Icon(Icons.clear_all, size: 18),
        label: const Text('Clear'),
      ),
      child: _logEntries.isEmpty
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'No events yet — start a recording to watch state changes, '
                'interruptions, source switches, silence windows and plugin '
                'log lines stream in.',
                style: theme.textTheme.bodySmall,
              ),
            )
          : SizedBox(
              height: 280,
              child: ListView.builder(
                itemCount: _logEntries.length,
                itemBuilder: (context, index) {
                  final entry = _logEntries[_logEntries.length - 1 - index];
                  return _LogEntryTile(entry: entry);
                },
              ),
            ),
    );
  }

  // ---------------------------------------------------------------------------
  // Recording actions
  // ---------------------------------------------------------------------------

  /// Starts a recording episode in [mode], arming a fresh output file
  /// first (in the selected format) when the record-to-file switch is on.
  Future<void> _startRecording(MicRecordingMode mode) async {
    if (_disposed) return;

    Object? failure;
    var started = false;

    try {
      if (_recordToFile) {
        await _armOutputFile();
      }
      started = await MicRecorder.instance.start(mode: mode);
    } catch (e) {
      failure = e;
    }

    if (!mounted) return;

    setState(() {
      _lastMode = MicRecorder.instance.mode;
      if (!started || failure != null) {
        // Either the native start refused (or threw) — both are usually a
        // missing permission, which the plugin never requests itself.
        _permissionHint = true;
      }
      if (started && failure == null) {
        _startedOnce = true;
      }
    });

    _logAction(
      'start(${mode.name}) → '
      '${failure != null
          ? 'threw $failure'
          : started
          ? 'true'
          : 'false'}',
    );

    if (started && failure == null) {
      unawaited(_runDiagnostics());
    } else {
      // Refresh the pre-flight gate so the card reflects the grant state
      // after the failed attempt.
      unawaited(_checkMicPermission());
    }
  }

  Future<void> _pauseRecording() async {
    if (_disposed) return;
    try {
      await MicRecorder.instance.pause();
    } catch (e) {
      _logAction('pause() threw $e');
    }
  }

  Future<void> _resumeRecording() async {
    if (_disposed) return;
    try {
      final resumed = await MicRecorder.instance.resume();
      _logAction(
        resumed
            ? 'resume() → true'
            : 'resume() → false (blocked — a call may be holding the '
                  'microphone)',
      );
    } catch (e) {
      _logAction('resume() threw $e');
    }
  }

  Future<void> _stopRecording() async {
    if (_disposed || !_lastState.isActive) return;

    MicRecordingInfo? info;

    _manualStopRequested = true;

    try {
      // stop() flushes and closes the plugin's output writers (the WAV
      // header sizes are the plugin's job now) and returns the episode
      // result.
      info = await MicRecorder.instance.stop();
      _lastRecordingInfo = info;
      _finalizeArmedFile();

      if (info == null) {
        _logAction('stop() → null (no active episode left)');
      } else {
        _logAction(
          'stop() → MicRecordingInfo(duration: '
          '${_formatDurationClock(info.duration)}, '
          'sizeBytes: ${info.sizeBytes}, '
          'stopReason: ${info.stopReason.name})',
        );
      }
    } catch (e) {
      _logAction('stop() threw $e');
    } finally {
      _manualStopRequested = false;
    }

    if (mounted) {
      setState(() {});
      unawaited(_runDiagnostics());
    }
  }

  /// cancel() deletes every output the episode produced, so it sits behind
  /// a confirmation dialog like dispose() does.
  Future<void> _confirmCancelRecording() async {
    if (_disposed || !_lastState.isActive) return;

    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Cancel this recording?'),
            content: const Text(
              'cancel() stops the episode like stop() but discards every '
              'output it produced: the Dart-written file and the encoded '
              'file are deleted, and no MicRecordingInfo is reported back.',
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Keep recording'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Discard'),
              ),
            ],
          ),
        ) ??
        false;

    if (!confirmed || !mounted) return;

    await _cancelRecording();
  }

  /// Stops like stop() but discards the episode — the Dart-written file
  /// and the encoded file are deleted.
  Future<void> _cancelRecording() async {
    if (_disposed || !_lastState.isActive) return;

    _manualStopRequested = true;

    try {
      await MicRecorder.instance.cancel();
      _logAction('cancel() → episode discarded (all outputs deleted)');
    } catch (e) {
      _logAction('cancel() threw $e');
    } finally {
      _manualStopRequested = false;
    }

    if (mounted) setState(() {});
  }

  /// Picks up the result of an episode that ended without a manual stop —
  /// a MicRecorderConfig.maxDuration auto-stop — through the
  /// lastRecordingInfo getter.
  ///
  /// The recorder assigns the info behind the state event (after its
  /// file-size awaits resolve), so this polls briefly until it lands.
  Future<void> _surfaceAutoStopResult() async {
    for (var attempt = 0; attempt < 6; attempt++) {
      final info = MicRecorder.instance.lastRecordingInfo;

      if (info != null) {
        if (!mounted) return;
        setState(() => _lastRecordingInfo = info);
        _logAction(
          'episode auto-stopped — lastRecordingInfo.stopReason == '
          '${info.stopReason.name}',
        );
        return;
      }

      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    _logAction('auto-stop detected, but lastRecordingInfo stayed null');
  }

  /// dispose() is terminal for the singleton, so it lives behind a
  /// confirmation dialog.
  Future<void> _confirmDispose() async {
    if (_disposed) return;

    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Dispose MicRecorder?'),
            content: const Text(
              'dispose() permanently tears the recorder down: its streams '
              'are closed and initialize() cannot revive them. The app '
              'will have to be restarted to record again.\n'
              'The method exists for engine-detach / hot-restart flows.',
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Dispose'),
              ),
            ],
          ),
        ) ??
        false;

    if (!confirmed || !mounted) return;

    try {
      // dispose() stops an active episode itself — flag it so the state
      // listener does not mistake that for a maxDuration auto-stop.
      _manualStopRequested = true;
      await MicRecorder.instance.dispose();
    } catch (e) {
      _logAction('dispose() threw $e');
    } finally {
      _manualStopRequested = false;
    }
    if (!mounted) return;

    setState(() => _disposed = true);

    // The streams are closed now; drop the subscriptions so nothing tries
    // to touch the torn-down controllers again.
    for (final subscription in _eventSubscriptions) {
      subscription.cancel();
    }
    _eventSubscriptions.clear();
    _audioSubscription?.cancel();
    _audioSubscription = null;
    _amplitudeSubscription?.cancel();
    _amplitudeSubscription = null;
    _durationSubscription?.cancel();
    _durationSubscription = null;

    _pulse.stop();
    _pulse.value = 0;

    _logAction('dispose() completed — restart the app to record again');
  }

  // ---------------------------------------------------------------------------
  // RAM buffering actions
  // ---------------------------------------------------------------------------

  Future<void> _startBuffering() async {
    if (_disposed || _bufferArmed) return;

    try {
      final started = await MicRecorder.instance.startAudioBuffering();
      if (!mounted) return;
      if (!started) {
        setState(() => _permissionHint = true);
        _logAction('startAudioBuffering() → false');
        return;
      }
      setState(() {
        _bufferArmed = true;
        _episodeBytesAtBufferArm = _audioStats.value.bytes;
        _drainedInEpisode = 0;
      });
      _logAction('startAudioBuffering() → true (buffering)');
    } catch (e) {
      _logAction('startAudioBuffering() threw $e');
    }
  }

  Future<void> _stopBuffering() async {
    if (!_bufferArmed) return;
    try {
      final harvested = await MicRecorder.instance.stopAudioBuffering();
      if (!mounted) return;
      setState(() {
        _bufferArmed = false;
        _totalHarvestedBytes += harvested.lengthInBytes;
        _lastHarvestBytes = harvested.lengthInBytes;
      });
      _logAction(
        'stopAudioBuffering() → ${_formatBytes(harvested.lengthInBytes)}',
      );
    } catch (e) {
      _logAction('stopAudioBuffering() threw $e');
    }
  }

  void _drainBuffer() {
    if (!_bufferArmed) return;

    final drained = MicRecorder.instance.drainBufferedAudio();

    setState(() {
      _drainedInEpisode += drained.lengthInBytes;
      _totalHarvestedBytes += drained.lengthInBytes;
      _lastHarvestBytes = drained.lengthInBytes;
    });

    _logAction('drainBufferedAudio() → ${_formatBytes(drained.lengthInBytes)}');
  }

  /// Samples the (up to) 10-second voice-command tail.
  void _sampleVoiceTail() {
    final tail = _disposed
        ? Uint8List(0)
        : MicRecorder.instance.voiceCommandAudio;
    setState(() => _lastVoiceTailBytes = tail.lengthInBytes);

    final hint = _lastMode == MicRecordingMode.voiceCommand
        ? ''
        : ' (record in voice-command mode to grow the tail)';

    _logAction('voiceCommandAudio → ${_formatBytes(tail.lengthInBytes)}$hint');
  }

  /// Pushes the conversation-creation window's audio back onto the stream
  /// for late subscribers.
  Future<void> _emitInitialAudio() async {
    if (_disposed) return;

    // emitInitialAudio() drains the RAM buffer before re-emitting it (joined
    // with the voice-command tail), so account for that internal drain here
    // — the tail itself was never part of the RAM buffer.
    final drainedFromRamBuffer = _estimatedInBufferBytes(_audioStats.value);

    final tailBefore = MicRecorder.instance.voiceCommandAudio.lengthInBytes;

    final wasArmed = _bufferArmed;

    try {
      await MicRecorder.instance.emitInitialAudio();
      if (!mounted) return;
      final nowArmed =
          !_disposed && MicRecorder.instance.bufferingStartedAt != null;
      setState(() {
        if (!wasArmed && nowArmed) {
          // emitInitialAudio() arms buffering itself when audio is available
          // but nothing was buffered yet.
          _bufferArmed = true;
          _episodeBytesAtBufferArm = _audioStats.value.bytes;
          _drainedInEpisode = 0;
        } else if (wasArmed) {
          // The drained bytes flow back through the stream (the still-armed
          // buffering subscription re-captures them), so counting the drain
          // here keeps the in-buffer estimate exact.
          _drainedInEpisode += drainedFromRamBuffer;
          _totalHarvestedBytes += drainedFromRamBuffer;
          _lastHarvestBytes = drainedFromRamBuffer;
        }
      });
      _logAction(
        'emitInitialAudio() re-emitted '
        '${_formatBytes(drainedFromRamBuffer + tailBefore)}',
      );
    } catch (e) {
      _logAction('emitInitialAudio() threw $e');
    }
  }

  // ---------------------------------------------------------------------------
  // File output actions
  // ---------------------------------------------------------------------------

  /// Toggles file recording. Toggling on while stopped pre-arms a file in
  /// the selected format; the start buttons roll a fresh timestamped file
  /// per episode.
  Future<void> _setRecordToFile(bool value) async {
    if (_disposed || _lastState.isActive) return;

    if (value) {
      setState(() => _recordToFile = true);
      await _armOutputFile();
    } else {
      await MicRecorder.instance.clearOutputFile();
      _finalizeArmedFile();
      if (!mounted) return;
      setState(() => _recordToFile = false);
    }
    if (mounted) setState(() {});
  }

  /// Selects the file container format; a currently armed file is
  /// re-armed in the new format (only reachable while stopped).
  Future<void> _changeFileFormat(MicRecordingFileFormat format) async {
    if (_disposed || _lastState.isActive) return;

    setState(() => _fileFormat = format);

    if (_armedFile != null) {
      await _armOutputFile();
      if (mounted) setState(() {});
    }
  }

  /// Arms a fresh timestamped output file in the selected format — the
  /// plugin's writer creates the container (the WAV header included)
  /// itself.
  Future<bool> _armOutputFile() async {
    try {
      final extension = _fileFormat == MicRecordingFileFormat.wav
          ? '.wav'
          : '.pcm';
      final file = File(
        '${Directory.systemTemp.path}'
        '${Platform.pathSeparator}'
        'mic_recorder_demo_${_timestamp()}$extension',
      );
      await MicRecorder.instance.setOutputFile(file.path, format: _fileFormat);
      _armedFile = file;
      _logAction('armed ${_fileFormat.wireName} output ${file.path}');
      return true;
    } catch (e) {
      _logAction('arming the output file failed: $e');
      return false;
    }
  }

  /// Stops writing and finalizes the armed file.
  Future<void> _clearOutputFile() async {
    if (_disposed) return;
    try {
      await MicRecorder.instance.clearOutputFile();
      _finalizeArmedFile();
    } catch (e) {
      _logAction('clearOutputFile() threw $e');
    }
    if (mounted) setState(() {});
  }

  /// Bookkeeping after the plugin's writer flushed and closed the armed
  /// file (stop() and clearOutputFile() both finalize the WAV container
  /// themselves): remember it for extractAmplitudes().
  void _finalizeArmedFile() {
    final armed = _armedFile;
    if (armed == null) return;
    _lastCompletedFile = armed;
    _armedFile = null;
    _logAction('output file closed: ${armed.path}');
  }

  /// Decodes 60 amplitude bars from the last completed WAV. A null result
  /// surfaces as a graceful error message.
  Future<void> _renderWaveform() async {
    final file = _lastCompletedFile;
    if (file == null || _disposed) return;

    Object? failure;
    List<double>? bars;
    try {
      bars = await MicRecorder.instance.extractAmplitudes(
        filePath: file.path,
        barCount: 60,
      );
    } catch (e) {
      failure = e;
    }
    if (!mounted) return;

    setState(() {
      if (bars != null && bars.isNotEmpty) {
        _waveformBars = bars;
        _waveformError = null;
      } else {
        _waveformBars = null;
        _waveformError = failure == null
            ? 'extractAmplitudes() returned null — the decoder could not '
                  'read the file (or produced no bars).'
            : 'extractAmplitudes() failed: $failure';
      }
    });

    _logAction(
      'extractAmplitudes(barCount: 60) → '
      '${bars == null ? 'null' : '${bars.length} bars'}',
    );
  }

  // ---------------------------------------------------------------------------
  // Routing actions
  // ---------------------------------------------------------------------------

  Future<void> _setRouteSwitching(bool value) async {
    if (_disposed) return;
    try {
      await MicRecorder.instance.setRouteSwitchingEnabled(value);
      if (!mounted) return;
      setState(() => _routeSwitchingEnabled = value);
      _logAction('setRouteSwitchingEnabled($value)');
    } catch (e) {
      _logAction('setRouteSwitchingEnabled() threw $e');
    }
  }

  /// Runs the one-shot diagnostics verbs and caches their results.
  Future<void> _runDiagnostics() async {
    if (_disposed) return;

    bool? otherAudioPlaying;
    bool? micHeldByCall;
    Map<String, Object?>? routeState;

    try {
      otherAudioPlaying = await MicRecorder.instance.isOtherAudioPlaying();
    } catch (_) {}
    try {
      micHeldByCall = await MicRecorder.instance.isAndroidMicHeldByCall();
    } catch (_) {}
    try {
      routeState = await MicRecorder.instance.getRouteState();
    } catch (_) {}

    if (!mounted) return;

    setState(() {
      _otherAudioPlaying = otherAudioPlaying;
      _micHeldByCall = micHeldByCall;
      _routeState = routeState;
    });
  }

  // ---------------------------------------------------------------------------
  // Navigation
  // ---------------------------------------------------------------------------

  void _openGallery() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (context) => const ApiTypeGallery()),
    );
  }

  /// Opens the configuration screen and applies the returned draft via
  /// [MicRecorder.initialize] (guarded against its StateError).
  Future<void> _openConfigScreen() async {
    if (_disposed) return;

    final result = await Navigator.of(context).push<(MicRecorderConfig, bool)>(
      MaterialPageRoute<(MicRecorderConfig, bool)>(
        builder: (context) => _ConfigScreen(
          initialConfig: MicRecorder.instance.config,
          initialLogSinkEnabled: _logSinkEnabled,
        ),
      ),
    );

    if (result == null || !mounted) return;

    final (draft, logSinkEnabled) = result;

    setState(() => _logSinkEnabled = logSinkEnabled);

    try {
      MicRecorder.instance.initialize(
        MicRecorderConfig(
          sampleRate: draft.sampleRate,
          audioSession: draft.audioSession,
          androidForegroundService: draft.androidForegroundService,
          routeSwitchingEnabled: draft.routeSwitchingEnabled,
          amplitudeInterval: draft.amplitudeInterval,
          androidEchoCancel: draft.androidEchoCancel,
          androidNoiseSuppress: draft.androidNoiseSuppress,
          androidAutoGain: draft.androidAutoGain,
          maxDuration: draft.maxDuration,
          log: logSinkEnabled ? _onPluginLog : null,
        ),
      );

      // initialize() rebuilt the session/route controllers — their streams
      // are brand new, so re-subscribe the event log listeners.
      _subscribeEventStreams();

      if (!mounted) return;
      setState(() {
        _routeSwitchingEnabled = MicRecorder.instance.isRouteSwitchingEnabled;
      });

      _logAction('configuration applied (initialize)');
    } on StateError catch (e) {
      _logAction('initialize() rejected: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Stream & log plumbing
  // ---------------------------------------------------------------------------

  /// (Re-)subscribes the five recorder event streams. Safe to call again
  /// after a re-initialize; a no-op after dispose.
  void _subscribeEventStreams() {
    for (final subscription in _eventSubscriptions) {
      subscription.cancel();
    }
    _eventSubscriptions.clear();

    if (_disposed) return;

    _eventSubscriptions.addAll(<StreamSubscription<void>>[
      MicRecorder.instance.onStateChange.listen(_onRecorderState),
      MicRecorder.instance.onAudioInterruption.listen(_onAudioInterruption),
      MicRecorder.instance.onAudioSourceSwitched.listen(_onAudioSourceSwitched),
      MicRecorder.instance.onConversationSilence.listen(_onConversationSilence),
      MicRecorder.instance.onMicrophoneLost.listen(_onMicrophoneLost),
    ]);
  }

  void _onRecorderState(MicRecorderState state) {
    if (!mounted) return;

    final previous = _lastState;

    setState(() => _lastState = state);

    _appendEntry(
      _LogEntry(
        kind: _LogKind.state,
        title: 'state → ${state.name}',
        details: 'previous: ${previous.name}',
      ),
    );

    if (state == MicRecorderState.error) {
      setState(() => _permissionHint = true);
    }

    if (state == MicRecorderState.recording) {
      _pulse.repeat(reverse: true);
      if (previous == MicRecorderState.stopped ||
          previous == MicRecorderState.error) {
        // Fresh episode: reset the live meter.
        _levelDb.value = null;
        _peakDb.value = _meterFloorDb;
      }
      _lastMode = MicRecorder.instance.mode;
    } else {
      _pulse.stop();
      _pulse.value = 0;
    }

    if (state == MicRecorderState.stopped) {
      // stop() tears the RAM buffering subscription down as well.
      _bufferArmed = false;
      _drainedInEpisode = 0;
      _audioStats.value = const _AudioStats();
      _levelDb.value = null;
      _peakDb.value = _meterFloorDb;
      _amplitude.value = null;
      _amplitudeNow.value = null;

      // The episode clock freezes at the exact total (the final
      // onDurationChanged emission) and stays on display until the next
      // start resets it to zero.

      if (previous.isActive && !_manualStopRequested) {
        // No manual stop was requested — the episode hit
        // MicRecorderConfig.maxDuration and stopped itself.
        unawaited(_surfaceAutoStopResult());
      }
    }
  }

  void _onAudioInterruption(MicAudioInterruption event) {
    _appendEntry(
      _LogEntry(
        kind: _LogKind.interruption,
        title: 'audio interruption ${event.begin ? 'began' : 'ended'}',
        details: 'type: ${event.type.name}',
      ),
    );
  }

  void _onAudioSourceSwitched(MicAudioSourceSwitchedEvent event) {
    _appendEntry(
      _LogEntry(
        kind: _LogKind.sourceSwitched,
        title: 'audio source → ${event.sourceKind.name}',
        details:
            'previous: ${event.previousSourceKind?.name ?? '—'} · '
            'name: ${event.sourceName ?? '—'} · reason: ${event.reason} · '
            'switchingEnabled: ${event.switchingEnabled}',
      ),
    );
  }

  void _onConversationSilence(MicConversationSilenceEvent event) {
    _appendEntry(
      _LogEntry(
        kind: _LogKind.conversationSilence,
        title: 'conversation silence (${event.duration.inMinutes} min)',
        details:
            'startedAtUtc: ${event.startedAtUtc} · lastRms: '
            '${event.lastRms} · silenceThreshold: '
            '${event.silenceThreshold} · bytes: '
            '${event.bytesCapturedSinceStart} · buffers: '
            '${event.buffersCapturedSinceStart} · recoveryAttempts: '
            '${event.silenceRecoveryAttempts} · routeState: '
            '${event.routeState ?? '—'}',
      ),
    );
  }

  void _onMicrophoneLost(MicMicrophoneLostEvent event) {
    _appendEntry(
      _LogEntry(
        kind: _LogKind.microphoneLost,
        title: 'microphone lost',
        details: 'reason: ${event.reason}',
      ),
    );
  }

  /// The demo's [MicLogSink] — attached through [MicRecorderConfig.log] so
  /// plugin log lines surface in the event log from the very start.
  void _onPluginLog(
    MicLogLevel level,
    String message, [
    Map<String, Object?>? data,
  ]) {
    _appendEntry(
      _LogEntry(
        kind: _LogKind.log,
        title: message,
        details: _formatLogData(data),
        logLevel: level,
      ),
    );
  }

  /// Logs a demo-side action result (button presses etc.).
  void _logAction(String message) {
    _appendEntry(_LogEntry(kind: _LogKind.action, title: message));
  }

  void _appendEntry(_LogEntry entry) {
    if (!mounted) return;
    setState(() {
      _logEntries.add(entry);
      if (_logEntries.length > _maxLogEntries) {
        _logEntries.removeRange(0, _logEntries.length - _maxLogEntries);
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Live audio plumbing
  // ---------------------------------------------------------------------------

  /// Computes the RMS of a 16-bit little-endian mono PCM chunk (the same
  /// math the plugin uses for its silence detection).
  void _onAudioChunk(List<int> chunk) {
    final stats = _audioStats.value;
    final rms = _computeRms(chunk);

    _audioStats.value = _AudioStats(
      bytes: stats.bytes + chunk.length,
      chunks: stats.chunks + 1,
      lastRms: rms,
    );

    // The amplitude getter updates per chunk (no throttle) — fresher than
    // the onAmplitude stream whenever amplitudeInterval exceeds the chunk
    // period.
    _amplitudeNow.value = MicRecorder.instance.amplitude;

    final db = rms <= 0
        ? _meterFloorDb
        : math.max(_meterFloorDb, 20 * (math.log(rms) / math.ln10));

    _levelDb.value = db;
    _peakDb.value = math.max(db, _peakDb.value - _peakDecayDbPerChunk);
  }

  static double _computeRms(List<int> data) {
    final byteCount = data.length & ~1;
    if (byteCount == 0) return 0;

    var sumSquares = 0.0;

    for (var i = 0; i + 1 < byteCount; i += 2) {
      final sample = data[i] | (data[i + 1] << 8);
      final signedSample = sample >= 0x8000 ? sample - 0x10000 : sample;
      final normalized = signedSample / 32768.0;
      sumSquares += normalized * normalized;
    }

    return math.sqrt(sumSquares / (byteCount ~/ 2));
  }

  // ---------------------------------------------------------------------------
  // Misc helpers
  // ---------------------------------------------------------------------------

  static String _timestamp() {
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${now.year}${two(now.month)}${two(now.day)}'
        '_${two(now.hour)}${two(now.minute)}${two(now.second)}';
  }
}

// -----------------------------------------------------------------------------
// Configuration screen
// -----------------------------------------------------------------------------

/// Edits every [MicRecorderConfig] section and returns the draft (plus the
/// log-sink choice) to the home page, which applies it via
/// `MicRecorder.initialize`.
class _ConfigScreen extends StatefulWidget {
  const _ConfigScreen({
    required this.initialConfig,
    required this.initialLogSinkEnabled,
  });

  /// Configuration the form is seeded from (the recorder's active config).
  final MicRecorderConfig initialConfig;

  /// Whether the demo's log sink is currently attached.
  final bool initialLogSinkEnabled;

  @override
  State<_ConfigScreen> createState() => _ConfigScreenState();
}

class _ConfigScreenState extends State<_ConfigScreen> {
  static const List<int> _sampleRates = <int>[8000, 16000, 22050, 44100, 48000];

  /// amplitudeInterval choices (throttles onAmplitude).
  static const List<Duration> _amplitudeIntervals = <Duration>[
    Duration(milliseconds: 50),
    Duration(milliseconds: 100),
    Duration(milliseconds: 250),
    Duration(milliseconds: 500),
    Duration(seconds: 1),
  ];

  /// maxDuration choices: unlimited plus the auto-stop presets.
  static const List<(Duration?, String)> _maxDurationChoices =
      <(Duration?, String)>[
        (null, 'none'),
        (Duration(seconds: 10), '10 s'),
        (Duration(seconds: 30), '30 s'),
        (Duration(seconds: 60), '60 s'),
      ];

  late int _sampleRate;
  late Duration _amplitudeInterval;
  late Duration? _maxDuration;
  late bool _routeSwitchingEnabled;
  late bool _logSinkEnabled;

  late bool _androidEchoCancel;
  late bool _androidNoiseSuppress;
  late bool _androidAutoGain;

  late bool _allowBluetooth;
  late bool _defaultToSpeaker;
  late bool _notifyOthersOnDeactivation;
  late bool _androidWillPauseWhenDucked;

  late bool _fgsEnabled;

  late final TextEditingController _channelName;
  late final TextEditingController _channelDescription;
  late final TextEditingController _icon;
  late final TextEditingController _titleWhenRecording;
  late final TextEditingController _titleWhenListening;
  late final TextEditingController _titleWhenPaused;
  late final TextEditingController _titleWhenInterrupted;

  @override
  void initState() {
    super.initState();

    final config = widget.initialConfig;
    final session = config.audioSession;
    final fgs = config.androidForegroundService;

    _sampleRate = config.sampleRate;
    _amplitudeInterval = _amplitudeIntervals.contains(config.amplitudeInterval)
        ? config.amplitudeInterval
        : const Duration(milliseconds: 100);
    _maxDuration = config.maxDuration;
    _androidEchoCancel = config.androidEchoCancel;
    _androidNoiseSuppress = config.androidNoiseSuppress;
    _androidAutoGain = config.androidAutoGain;
    _routeSwitchingEnabled = config.routeSwitchingEnabled;
    _logSinkEnabled = widget.initialLogSinkEnabled;

    _allowBluetooth = session.allowBluetooth;
    _defaultToSpeaker = session.defaultToSpeaker;
    _notifyOthersOnDeactivation = session.notifyOthersOnDeactivation;
    _androidWillPauseWhenDucked = session.androidWillPauseWhenDucked;

    _fgsEnabled = fgs.enabled;
    _channelName = TextEditingController(text: fgs.channelName);
    _channelDescription = TextEditingController(text: fgs.channelDescription);
    _icon = TextEditingController(text: fgs.icon);
    _titleWhenRecording = TextEditingController(text: fgs.titleWhenRecording);
    _titleWhenListening = TextEditingController(text: fgs.titleWhenListening);
    _titleWhenPaused = TextEditingController(text: fgs.titleWhenPaused);
    _titleWhenInterrupted = TextEditingController(
      text: fgs.titleWhenInterrupted,
    );
  }

  @override
  void dispose() {
    _channelName.dispose();
    _channelDescription.dispose();
    _icon.dispose();
    _titleWhenRecording.dispose();
    _titleWhenListening.dispose();
    _titleWhenPaused.dispose();
    _titleWhenInterrupted.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // initialize() throws while a recording is active — the Apply button
    // is disabled in that case (and the apply path is guarded anyway).
    final recording = MicRecorder.instance.currentState.isActive;

    return Scaffold(
      appBar: AppBar(title: const Text('Configuration')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: <Widget>[
          _SectionCard(
            title: 'Capture',
            subtitle:
                'The sample rate is applied when the native recorder is '
                'created — i.e. on the next start(). amplitudeInterval '
                'throttles onAmplitude; maxDuration auto-stops the episode '
                'once that much ACTIVE time has elapsed (paused spans '
                'excluded).',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'sampleRate',
                    border: OutlineInputBorder(),
                  ),
                  child: DropdownButton<int>(
                    value: _sampleRate,
                    isDense: true,
                    isExpanded: true,
                    underline: SizedBox.shrink(),
                    items: <DropdownMenuItem<int>>[
                      for (final rate in _sampleRates)
                        DropdownMenuItem<int>(
                          value: rate,
                          child: Text(_sampleRateLabel(rate)),
                        ),
                    ],
                    onChanged: (rate) {
                      if (rate != null) {
                        setState(() => _sampleRate = rate);
                      }
                    },
                  ),
                ),
                const SizedBox(height: 8),
                InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'amplitudeInterval',
                    border: OutlineInputBorder(),
                  ),
                  child: DropdownButton<Duration>(
                    value: _amplitudeInterval,
                    isDense: true,
                    isExpanded: true,
                    underline: SizedBox.shrink(),
                    items: <DropdownMenuItem<Duration>>[
                      for (final interval in _amplitudeIntervals)
                        DropdownMenuItem<Duration>(
                          value: interval,
                          child: Text(_intervalLabel(interval)),
                        ),
                    ],
                    onChanged: (interval) {
                      if (interval != null) {
                        setState(() => _amplitudeInterval = interval);
                      }
                    },
                  ),
                ),
                const SizedBox(height: 12),
                InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'maxDuration',
                    border: OutlineInputBorder(),
                  ),
                  child: Wrap(
                    spacing: 8,
                    children: <Widget>[
                      for (final (value, label) in _maxDurationChoices)
                        ChoiceChip(
                          label: Text(label),
                          selected: _maxDuration == value,
                          onSelected: (selected) {
                            if (selected) {
                              setState(() => _maxDuration = value);
                            }
                          },
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          _SectionCard(
            title: 'Android capture effects',
            subtitle:
                'androidEchoCancel / androidNoiseSuppress / androidAutoGain '
                '— Android-only and best effort: they ask the platform for '
                'the effect when the device provides one, and are ignored '
                'on iOS. Applied on the next start().',
            child: Column(
              children: <Widget>[
                _flagSwitch(
                  title: 'androidEchoCancel',
                  subtitle: 'Platform echo canceler on the capture.',
                  value: _androidEchoCancel,
                  onChanged: (value) =>
                      setState(() => _androidEchoCancel = value ?? false),
                ),
                _flagSwitch(
                  title: 'androidNoiseSuppress',
                  subtitle: 'Platform noise suppressor on the capture.',
                  value: _androidNoiseSuppress,
                  onChanged: (value) =>
                      setState(() => _androidNoiseSuppress = value ?? false),
                ),
                _flagSwitch(
                  title: 'androidAutoGain',
                  subtitle: 'Platform automatic gain control on the capture.',
                  value: _androidAutoGain,
                  onChanged: (value) =>
                      setState(() => _androidAutoGain = value ?? false),
                ),
              ],
            ),
          ),
          _SectionCard(
            title: 'Routing',
            subtitle:
                'routeSwitchingEnabled — whether the USB/wired → Bluetooth '
                '→ built-in input priority ladder steers capture.',
            child: _flagSwitch(
              title: 'routeSwitchingEnabled',
              subtitle:
                  'setRouteSwitchingEnabled() toggles the same flag '
                  'mid-recording.',
              value: _routeSwitchingEnabled,
              onChanged: (value) =>
                  setState(() => _routeSwitchingEnabled = value ?? false),
            ),
          ),
          _SectionCard(
            title: 'Audio session (MicAudioSessionConfig)',
            subtitle: 'Applied on initialize(); mirrored natively.',
            child: Column(
              children: <Widget>[
                _flagSwitch(
                  title: 'allowBluetooth',
                  subtitle: 'Bluetooth HFP input allowed.',
                  value: _allowBluetooth,
                  onChanged: (value) =>
                      setState(() => _allowBluetooth = value ?? false),
                ),
                _flagSwitch(
                  title: 'defaultToSpeaker',
                  subtitle: 'Route output to the loudspeaker.',
                  value: _defaultToSpeaker,
                  onChanged: (value) =>
                      setState(() => _defaultToSpeaker = value ?? false),
                ),
                _flagSwitch(
                  title: 'notifyOthersOnDeactivation',
                  subtitle:
                      'Notify other audio apps when the session is '
                      'deactivated.',
                  value: _notifyOthersOnDeactivation,
                  onChanged: (value) => setState(
                    () => _notifyOthersOnDeactivation = value ?? false,
                  ),
                ),
                _flagSwitch(
                  title: 'androidWillPauseWhenDucked',
                  subtitle:
                      'Android: pause (true) or duck (false) when another '
                      'app requests transient focus.',
                  value: _androidWillPauseWhenDucked,
                  onChanged: (value) => setState(
                    () => _androidWillPauseWhenDucked = value ?? false,
                  ),
                ),
              ],
            ),
          ),
          _SectionCard(
            title: 'Android foreground service (MicForegroundServiceConfig)',
            subtitle:
                'The notification is configured here and shown/updated by '
                'the recorder itself — there is no separate notification '
                'method.',
            child: Column(
              children: <Widget>[
                _flagSwitch(
                  title: 'enabled',
                  subtitle:
                      'Android only; ignored on iOS. Starts with the '
                      'recording and stops with it.',
                  value: _fgsEnabled,
                  onChanged: (value) =>
                      setState(() => _fgsEnabled = value ?? false),
                ),
                _textField(
                  controller: _channelName,
                  label: 'channelName',
                  hint: 'Recording',
                ),
                _textField(
                  controller: _channelDescription,
                  label: 'channelDescription',
                  hint: 'Microphone recording status',
                ),
                _textField(
                  controller: _icon,
                  label: 'icon',
                  hint: 'ic_stat_mic (drawable resource name)',
                ),
                _textField(
                  controller: _titleWhenRecording,
                  label: 'titleWhenRecording',
                  hint: 'Recording conversation',
                ),
                _textField(
                  controller: _titleWhenListening,
                  label: 'titleWhenListening',
                  hint: 'Listening',
                ),
                _textField(
                  controller: _titleWhenPaused,
                  label: 'titleWhenPaused',
                  hint: 'Recording paused',
                ),
                _textField(
                  controller: _titleWhenInterrupted,
                  label: 'titleWhenInterrupted',
                  hint: 'Recording interrupted',
                ),
              ],
            ),
          ),
          _SectionCard(
            title: 'Logging',
            subtitle:
                'log — a custom MicLogSink (the event log screen) or '
                'defaultMicLog.',
            child: _flagSwitch(
              title: 'Route plugin logs into the event log',
              subtitle:
                  'Off → MicRecorderConfig.log is null and the plugin '
                  'falls back to defaultMicLog.',
              value: _logSinkEnabled,
              onChanged: (value) =>
                  setState(() => _logSinkEnabled = value ?? false),
            ),
          ),
          if (recording)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'A recording is active — stop it first: initialize() '
                'throws a StateError while the recorder is recording or '
                'paused.',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          FilledButton.icon(
            onPressed: recording ? null : _apply,
            icon: const Icon(Icons.check, size: 18),
            label: const Text('Apply configuration'),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  void _apply() {
    final draft = MicRecorderConfig(
      sampleRate: _sampleRate,
      audioSession: MicAudioSessionConfig(
        allowBluetooth: _allowBluetooth,
        defaultToSpeaker: _defaultToSpeaker,
        notifyOthersOnDeactivation: _notifyOthersOnDeactivation,
        androidWillPauseWhenDucked: _androidWillPauseWhenDucked,
      ),
      androidForegroundService: MicForegroundServiceConfig(
        enabled: _fgsEnabled,
        channelName: _channelName.text,
        channelDescription: _channelDescription.text,
        icon: _icon.text,
        titleWhenRecording: _titleWhenRecording.text,
        titleWhenListening: _titleWhenListening.text,
        titleWhenPaused: _titleWhenPaused.text,
        titleWhenInterrupted: _titleWhenInterrupted.text,
      ),
      routeSwitchingEnabled: _routeSwitchingEnabled,
      amplitudeInterval: _amplitudeInterval,
      androidEchoCancel: _androidEchoCancel,
      androidNoiseSuppress: _androidNoiseSuppress,
      androidAutoGain: _androidAutoGain,
      maxDuration: _maxDuration,
    );

    Navigator.of(context).pop((draft, _logSinkEnabled));
  }

  static String _sampleRateLabel(int rate) {
    if (rate == 22050) return '22.05 kHz';
    if (rate == 44100) return '44.1 kHz';
    return '${rate ~/ 1000} kHz';
  }

  static String _intervalLabel(Duration interval) =>
      '${interval.inMilliseconds} ms';

  Widget _flagSwitch({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool?> onChanged,
  }) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(title),
      subtitle: Text(subtitle),
      value: value,
      onChanged: onChanged,
    );
  }

  Widget _textField({
    required TextEditingController controller,
    required String label,
    String? hint,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextFormField(
        controller: controller,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Shared widgets
// -----------------------------------------------------------------------------

/// Card wrapper used by every demo section.
class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.child,
    this.subtitle,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(title, style: theme.textTheme.titleMedium),
                ),
                ?trailing,
              ],
            ),
            if (subtitle != null) ...<Widget>[
              const SizedBox(height: 4),
              Text(subtitle!, style: theme.textTheme.bodySmall),
            ],
            const SizedBox(height: 8),
            child,
          ],
        ),
      ),
    );
  }
}

/// Small label/value pill used for recorder stats.
class _StatPill extends StatelessWidget {
  const _StatPill({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(label, style: theme.textTheme.labelSmall),
          Text(
            value,
            style: theme.textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// Colored banner (permissions, error state, post-dispose notice).
class _Banner extends StatelessWidget {
  const _Banner({
    required this.icon,
    required this.color,
    required this.title,
    required this.body,
    this.onDismiss,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String body;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      color: color.withValues(alpha: 0.12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: color.withValues(alpha: 0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(icon, color: color),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(title, style: theme.textTheme.titleSmall),
                  const SizedBox(height: 4),
                  Text(body, style: theme.textTheme.bodySmall),
                ],
              ),
            ),
            if (onDismiss != null) ...<Widget>[
              const SizedBox(width: 4),
              IconButton(
                tooltip: 'Dismiss',
                icon: const Icon(Icons.close, size: 18),
                onPressed: onDismiss,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// State chip with per-state color.
class _StateChip extends StatelessWidget {
  const _StateChip({required this.state});

  final MicRecorderState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = _stateColor(state);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(_stateIcon(state), size: 16, color: color),
          const SizedBox(width: 6),
          Text(
            state.name,
            style: theme.textTheme.labelLarge?.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

/// Microphone dot pulsing while the recorder is active.
class _PulsingDot extends StatelessWidget {
  const _PulsingDot({required this.controller, required this.color});

  final AnimationController controller;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => Container(
        width: 14,
        height: 14,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color.withValues(alpha: 0.35 + 0.65 * controller.value),
          boxShadow: controller.isAnimating
              ? <BoxShadow>[
                  BoxShadow(
                    color: color.withValues(alpha: 0.5 * controller.value),
                    blurRadius: 4 + 8 * controller.value,
                  ),
                ]
              : null,
        ),
      ),
    );
  }
}

/// Live level meter driven by two ValueNotifiers (level + peak hold).
class _LevelMeter extends StatelessWidget {
  const _LevelMeter({
    required this.levelDb,
    required this.peakDb,
    required this.active,
  });

  final ValueNotifier<double?> levelDb;
  final ValueNotifier<double> peakDb;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[levelDb, peakDb]),
      builder: (context, _) {
        final level = levelDb.value;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SizedBox(
              height: 26,
              child: CustomPaint(
                painter: _LevelMeterPainter(
                  levelDb: active ? level : null,
                  peakDb: peakDb.value,
                  floorDb: _meterFloorDb,
                  trackColor: scheme.surfaceContainerHighest,
                  fillColor: scheme.primary,
                  peakColor: scheme.error,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              level == null
                  ? 'no audio received yet'
                  : '${level.toStringAsFixed(1)} dB · peak '
                        '${peakDb.value.toStringAsFixed(1)} dB',
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.end,
            ),
          ],
        );
      },
    );
  }
}

class _LevelMeterPainter extends CustomPainter {
  const _LevelMeterPainter({
    required this.levelDb,
    required this.peakDb,
    required this.floorDb,
    required this.trackColor,
    required this.fillColor,
    required this.peakColor,
  });

  final double? levelDb;
  final double peakDb;
  final double floorDb;
  final Color trackColor;
  final Color fillColor;
  final Color peakColor;

  double _fraction(double db) {
    final raw = (db - floorDb) / -floorDb;
    return raw.clamp(0.0, 1.0).toDouble();
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(6)),
      Paint()..color = trackColor,
    );

    final level = levelDb;
    if (level != null) {
      final fillWidth = size.width * _fraction(level);
      if (fillWidth > 0) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(0, 0, fillWidth, size.height),
            const Radius.circular(6),
          ),
          Paint()..color = fillColor,
        );
      }
    }

    final maxPeakX = math.max(0.0, size.width - 2);
    final peakX = math.min(
      math.max(0.0, size.width * _fraction(peakDb)),
      maxPeakX,
    );
    if (peakX > 0) {
      canvas.drawRect(
        Rect.fromLTWH(peakX, 0, 2, size.height),
        Paint()..color = peakColor,
      );
    }
  }

  @override
  bool shouldRepaint(_LevelMeterPainter oldDelegate) =>
      oldDelegate.levelDb != levelDb ||
      oldDelegate.peakDb != peakDb ||
      oldDelegate.floorDb != floorDb ||
      oldDelegate.trackColor != trackColor ||
      oldDelegate.fillColor != fillColor ||
      oldDelegate.peakColor != peakColor;
}

/// dBFS meter fed by [MicRecorder.onAmplitude]: current level as the
/// fill, peak as the marker, and the current / average / peak readings as
/// a caption.
class _DbfsMeter extends StatelessWidget {
  const _DbfsMeter({required this.amplitude, required this.active});

  final ValueNotifier<MicAmplitude?> amplitude;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return AnimatedBuilder(
      animation: amplitude,
      builder: (context, _) {
        final reading = amplitude.value;
        final current = reading?.currentDbfs;
        final peak = reading?.peakDbfs ?? MicAmplitude.silenceDbfs;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SizedBox(
              height: 26,
              child: CustomPaint(
                painter: _LevelMeterPainter(
                  levelDb: active ? current : null,
                  peakDb: peak,
                  floorDb: _meterFloorDb,
                  trackColor: scheme.surfaceContainerHighest,
                  fillColor: scheme.tertiary,
                  peakColor: scheme.error,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              reading == null
                  ? 'no amplitude reading yet'
                  : '${reading.currentDbfs.toStringAsFixed(1)} dBFS '
                        'current · avg '
                        '${reading.averageDbfs.toStringAsFixed(1)} · peak '
                        '${reading.peakDbfs.toStringAsFixed(1)}',
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.end,
            ),
          ],
        );
      },
    );
  }
}

/// Waveform renderer for extractAmplitudes results (60 bars).
class _WaveformPainter extends CustomPainter {
  const _WaveformPainter({required this.bars, required this.color});

  final List<double> bars;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final count = bars.length;
    if (count == 0) return;

    final paint = Paint()..color = color;
    final barWidth = size.width / count;

    for (var i = 0; i < count; i++) {
      final barHeight = math.min(
        math.max(2.0, size.height * bars[i]),
        size.height,
      );
      final rect = Rect.fromCenter(
        center: Offset((i + 0.5) * barWidth, size.height / 2),
        width: barWidth * 0.7,
        height: barHeight,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(2)),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter oldDelegate) =>
      oldDelegate.bars != bars || oldDelegate.color != color;
}

/// Label + (selectable) path row.
class _PathRow extends StatelessWidget {
  const _PathRow({required this.label, required this.path});

  final String label;
  final String path;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 140,
            child: Text(label, style: theme.textTheme.labelSmall),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SelectableText(path, style: theme.textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}

/// One timestamped event-log line.
class _LogEntryTile extends StatelessWidget {
  const _LogEntryTile({required this.entry});

  final _LogEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = _logEntryColor(entry);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 8,
            height: 8,
            margin: const EdgeInsets.only(top: 5),
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '${_clock(entry.time)}  ${entry.title}',
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (entry.details != null)
                  Text(entry.details!, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Event log model & helpers
// -----------------------------------------------------------------------------

/// Kinds of rows the event log distinguishes (color-coded).
enum _LogKind {
  state,
  interruption,
  sourceSwitched,
  conversationSilence,
  microphoneLost,
  log,
  action,
}

/// One event-log entry, stamped at creation time.
class _LogEntry {
  _LogEntry({
    required this.kind,
    required this.title,
    this.details,
    this.logLevel,
  }) : time = DateTime.now();

  /// When the entry was recorded.
  final DateTime time;
  final _LogKind kind;
  final String title;
  final String? details;
  final MicLogLevel? logLevel;
}

Color _logEntryColor(_LogEntry entry) {
  if (entry.kind == _LogKind.log) {
    final level = entry.logLevel;
    if (level == MicLogLevel.fatal) return Colors.red.shade900;
    if (level == MicLogLevel.error) return Colors.red.shade700;
    if (level == MicLogLevel.warn) return Colors.orange.shade800;
    if (level == MicLogLevel.debug) return Colors.blue.shade700;
    return Colors.blueGrey; // trace
  }
  if (entry.kind == _LogKind.interruption) {
    return Colors.deepOrange.shade700;
  }
  if (entry.kind == _LogKind.sourceSwitched) {
    return Colors.deepPurple.shade600;
  }
  if (entry.kind == _LogKind.conversationSilence) {
    return Colors.teal.shade700;
  }
  if (entry.kind == _LogKind.microphoneLost) return Colors.red.shade700;
  if (entry.kind == _LogKind.action) return Colors.brown.shade600;
  return Colors.indigo.shade600; // state
}

Color _stateColor(MicRecorderState state, [ColorScheme? scheme]) {
  if (state == MicRecorderState.recording) return Colors.green.shade600;
  if (state == MicRecorderState.paused) return Colors.orange.shade700;
  if (state == MicRecorderState.error) {
    return scheme?.error ?? Colors.red.shade700;
  }
  return Colors.blueGrey;
}

IconData _stateIcon(MicRecorderState state) {
  if (state == MicRecorderState.recording) {
    return Icons.fiber_manual_record;
  }
  if (state == MicRecorderState.paused) return Icons.pause_circle_outline;
  if (state == MicRecorderState.error) return Icons.error_outline;
  return Icons.stop_circle_outlined;
}

/// Live-audio counters (immutable snapshot pushed through a ValueNotifier).
class _AudioStats {
  const _AudioStats({this.bytes = 0, this.chunks = 0, this.lastRms = 0});

  final int bytes;
  final int chunks;
  final double lastRms;
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KiB';
  }
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
}

/// mm:ss clock for episode durations (null renders as a placeholder).
String _formatDurationClock(Duration? elapsed) {
  if (elapsed == null) return '--:--';
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(elapsed.inMinutes)}:${two(elapsed.inSeconds % 60)}';
}

String _formatBool(bool? value) => value == null ? '—' : '$value';

String _formatTimestamp(DateTime? utc) {
  if (utc == null) return '—';
  final local = utc.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
}

String _clock(DateTime time) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}'
      '.${time.millisecond.toString().padLeft(3, '0')}';
}

String? _formatLogData(Map<String, Object?>? data) {
  if (data == null || data.isEmpty) return null;
  return data.entries.map((entry) => '${entry.key}=${entry.value}').join(' · ');
}
