import '../internal/mic_logger.dart';
import 'mic_audio_session_config.dart';
import 'mic_foreground_service_config.dart';

/// Everything the recorder needs to know before [MicRecorder.start].
///
/// The defaults are a production-hardened capture profile: 16 kHz mono
/// PCM, audio session with Bluetooth and speaker defaults, the Android
/// foreground-service notification enabled, the input priority ladder
/// armed and the built-in debug log sink.
final class MicRecorderConfig {
  /// Creates a recorder configuration.
  const MicRecorderConfig({
    this.sampleRate = 16000,
    this.audioSession = const MicAudioSessionConfig(),
    this.androidForegroundService = const MicForegroundServiceConfig(),
    this.routeSwitchingEnabled = true,
    this.amplitudeInterval = const Duration(milliseconds: 100),
    this.androidEchoCancel = false,
    this.androidNoiseSuppress = false,
    this.androidAutoGain = false,
    this.maxDuration,
    this.log,
  });

  /// Capture sample rate in Hz (audio is always 16-bit mono PCM).
  final int sampleRate;

  /// The audio-session configuration (see [MicAudioSessionConfig]).
  final MicAudioSessionConfig audioSession;

  /// The Android foreground-service notification configuration (see
  /// [MicForegroundServiceConfig]).
  final MicForegroundServiceConfig androidForegroundService;

  /// Whether the input priority ladder (USB/wired → Bluetooth → built-in)
  /// steers capture while recording.
  final bool routeSwitchingEnabled;

  /// Minimum spacing between [MicRecorder.onAmplitude] emissions
  /// (per-chunk readings still update [MicRecorder.amplitude]).
  final Duration amplitudeInterval;

  /// Enables the platform echo canceler for Android capture (when the
  /// device provides one — best effort, ignored on iOS).
  final bool androidEchoCancel;

  /// Enables the platform noise suppressor for Android capture (when the
  /// device provides one — best effort, ignored on iOS).
  final bool androidNoiseSuppress;

  /// Enables the platform automatic gain control for Android capture
  /// (when the device provides one — best effort, ignored on iOS).
  final bool androidAutoGain;

  /// Stops the recording automatically once this much ACTIVE capture
  /// time has elapsed (paused spans excluded). Null (the default) means
  /// unlimited. The resulting [MicRecorder.stop] info reports
  /// [MicRecordingStopReason.maxDurationReached].
  final Duration? maxDuration;

  /// A custom log sink, or null for [defaultMicLog].
  final MicLogSink? log;

  /// Whether this configuration asks Android for any capture effect.
  bool get wantsAndroidAudioEffects =>
      androidEchoCancel || androidNoiseSuppress || androidAutoGain;

  @override
  String toString() =>
      'MicRecorderConfig(sampleRate: $sampleRate, '
      'audioSession: $audioSession, '
      'androidForegroundService: $androidForegroundService, '
      'routeSwitchingEnabled: $routeSwitchingEnabled, '
      'amplitudeInterval: $amplitudeInterval, '
      'androidEchoCancel: $androidEchoCancel, '
      'androidNoiseSuppress: $androidNoiseSuppress, '
      'androidAutoGain: $androidAutoGain, '
      'maxDuration: $maxDuration, '
      'log: ${log == null ? 'defaultMicLog' : 'custom'})';
}
