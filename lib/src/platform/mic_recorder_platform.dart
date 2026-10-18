import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import '../config/mic_audio_session_config.dart';
import '../models/mic_audio_device.dart';
import '../models/mic_audio_encoder.dart';
import '../models/mic_session_events.dart';

/// The platform surface the recorder talks to.
///
/// Production code obtains the method-channel implementation automatically
/// when importing `package:mic_recorder/mic_recorder.dart`; tests inject a
/// fake through [instance] (the default instance is an inert, benign stub
/// so unit tests can construct controllers without natives).
abstract class MicRecorderPlatform extends PlatformInterface {
  /// Creates a platform implementation.
  MicRecorderPlatform() : super(token: _token);

  static final Object _token = Object();

  static MicRecorderPlatform _instance = _UnattachedMicRecorderPlatform();

  /// The active platform implementation.
  ///
  /// Tests (and the export library's bootstrap) replace it; the setter
  /// verifies the platform-interface token.
  static MicRecorderPlatform get instance => _instance;

  static set instance(MicRecorderPlatform value) {
    PlatformInterface.verifyToken(value, _token);

    _instance = value;
  }

  /// Starts native capture at [sampleRate] (16-bit mono PCM). The
  /// `android*` toggles request the platform audio effects when the device
  /// provides them (best effort; iOS ignores them).
  Future<bool> startRecording(
    int sampleRate, {
    bool androidEchoCancel = false,
    bool androidNoiseSuppress = false,
    bool androidAutoGain = false,
  }) => throw UnimplementedError('startRecording() has not been implemented.');

  /// Pauses capture. [isPausedForInterruption] distinguishes an
  /// interruption-caused pause (iOS keeps the session alive) from a manual
  /// one (full teardown).
  Future<bool> pauseRecording(bool isPausedForInterruption) =>
      throw UnimplementedError('pauseRecording() has not been implemented.');

  /// Resumes (or re-opens) native capture.
  Future<bool> resumeRecording() =>
      throw UnimplementedError('resumeRecording() has not been implemented.');

  /// Stops capture and releases the native recorder.
  Future<bool> stopRecording() =>
      throw UnimplementedError('stopRecording() has not been implemented.');

  /// Reports to iOS that the microphone was interrupted from the Dart side
  /// (a hard reset of the audio stack). iOS only.
  Future<bool> microphoneInterrupted() => throw UnimplementedError(
    'microphoneInterrupted() has not been implemented.',
  );

  /// Opens or closes the Bluetooth SCO capture gate. Android only.
  Future<void> setBluetoothStatus(bool isAllowed) => throw UnimplementedError(
    'setBluetoothStatus() has not been implemented.',
  );

  /// Native routing diagnostics (Android only; null elsewhere and on
  /// failure).
  Future<Map<String, Object?>?> getRouteState() =>
      throw UnimplementedError('getRouteState() has not been implemented.');

  /// Arms native encoded file output: audio captured from now on is
  /// encoded by [encoder] into [path] as well. Call before (or during) a
  /// recording; one encoded output at a time — [clearEncodedOutput]
  /// disarms it. [bitRate] defaults to the encoder's default, and
  /// [sampleRate] (the capture rate the encoder must be built for — pass
  /// the configured one) defaults to 16000.
  Future<bool> setEncodedOutput(
    String path,
    MicAudioEncoder encoder, {
    int? bitRate,
    int? sampleRate,
  }) =>
      throw UnimplementedError('setEncodedOutput() has not been implemented.');

  /// Disarms (and deletes the file of) the armed encoded output.
  Future<bool> clearEncodedOutput() => throw UnimplementedError(
    'clearEncodedOutput() has not been implemented.',
  );

  /// Whether the microphone permission is currently granted.
  Future<bool> checkMicPermission() => throw UnimplementedError(
    'checkMicPermission() has not been implemented.',
  );

  /// Requests the microphone permission (resolves with the grant).
  Future<bool> requestMicPermission() => throw UnimplementedError(
    'requestMicPermission() has not been implemented.',
  );

  /// Decodes [filePath] into [barCount] normalized (0.1–1.0) RMS bars for
  /// waveform rendering; null when the file cannot be decoded.
  Future<List<double>?> extractAmplitudes({
    required String filePath,
    int barCount = 60,
  }) =>
      throw UnimplementedError('extractAmplitudes() has not been implemented.');

  /// Applies the audio-session configuration (category options, focus
  /// flags).
  Future<void> configureAudioSession(MicAudioSessionConfig config) =>
      throw UnimplementedError(
        'configureAudioSession() has not been implemented.',
      );

  /// Activates (`true`) or deactivates the audio session.
  Future<bool> setAudioSessionActive(bool active) => throw UnimplementedError(
    'setAudioSessionActive() has not been implemented.',
  );

  /// Whether another app's audio is currently playing.
  Future<bool> isOtherAudioPlaying() => throw UnimplementedError(
    'isOtherAudioPlaying() has not been implemented.',
  );

  /// Whether any music is active. Android only.
  Future<bool> isMusicActive() =>
      throw UnimplementedError('isMusicActive() has not been implemented.');

  /// The current Android audio mode (raw `AudioManager` mode). Android only.
  Future<int> getAudioMode() =>
      throw UnimplementedError('getAudioMode() has not been implemented.');

  /// Whether haptics and system sounds may play during recording. iOS only.
  Future<void> setAllowHapticsAndSystemSoundsDuringRecording(bool enabled) =>
      throw UnimplementedError(
        'setAllowHapticsAndSystemSoundsDuringRecording()'
        ' has not been implemented.',
      );

  /// The current audio device snapshot.
  ///
  /// Composed from the iOS route + inputs on iOS; the Android device list
  /// on Android.
  Future<Set<MicAudioDevice>> getAudioDevices() =>
      throw UnimplementedError('getAudioDevices() has not been implemented.');

  /// The available input ports. iOS only.
  Future<List<MicAudioInput>> getAvailableInputs() => throw UnimplementedError(
    'getAvailableInputs() has not been implemented.',
  );

  /// The current audio route. iOS only (an empty route elsewhere).
  Future<MicAudioRoute> getCurrentRoute() =>
      throw UnimplementedError('getCurrentRoute() has not been implemented.');

  /// Selects [input] as the session's preferred input. iOS only.
  Future<bool> setPreferredInput(MicAudioInput input) =>
      throw UnimplementedError('setPreferredInput() has not been implemented.');

  /// Shows (or updates) the recording's foreground-service notification
  /// with [title]. Android only.
  Future<bool> showForegroundNotification(
    String title, {
    String? channelName,
    String? channelDescription,
    String? icon,
  }) => throw UnimplementedError(
    'showForegroundNotification() has not been implemented.',
  );

  /// Removes the foreground-service notification (and stops the service).
  /// Android only.
  Future<bool> removeForegroundNotification() => throw UnimplementedError(
    'removeForegroundNotification() has not been implemented.',
  );

  /// The raw PCM audio stream (16-bit little-endian mono chunks).
  Stream<List<int>> audioDataStream() =>
      throw UnimplementedError('audioDataStream() has not been implemented.');

  /// The typed session-event stream (focus, device, interruption and route
  /// changes).
  Stream<MicSessionEvent> sessionEvents() =>
      throw UnimplementedError('sessionEvents() has not been implemented.');
}

/// The inert default platform.
///
/// Capture verbs report success without doing anything (a recorder used
/// before the natives attached keeps its state machine coherent), queries
/// report empty/false, and both streams are empty. The export library's
/// bootstrap replaces it with the real method channel in production; tests
/// replace it with fakes.
final class _UnattachedMicRecorderPlatform extends MicRecorderPlatform {
  @override
  Future<bool> startRecording(
    int sampleRate, {
    bool androidEchoCancel = false,
    bool androidNoiseSuppress = false,
    bool androidAutoGain = false,
  }) async => true;

  @override
  Future<bool> pauseRecording(bool isPausedForInterruption) async => true;

  @override
  Future<bool> resumeRecording() async => true;

  @override
  Future<bool> stopRecording() async => true;

  @override
  Future<bool> setEncodedOutput(
    String path,
    MicAudioEncoder encoder, {
    int? bitRate,
    int? sampleRate,
  }) async => true;

  @override
  Future<bool> clearEncodedOutput() async => true;

  @override
  Future<bool> checkMicPermission() async => false;

  @override
  Future<bool> requestMicPermission() async => false;

  @override
  Future<bool> microphoneInterrupted() async => true;

  @override
  Future<void> setBluetoothStatus(bool isAllowed) async {}

  @override
  Future<Map<String, Object?>?> getRouteState() async => null;

  @override
  Future<List<double>?> extractAmplitudes({
    required String filePath,
    int barCount = 60,
  }) async => null;

  @override
  Future<void> configureAudioSession(MicAudioSessionConfig config) async {}

  @override
  Future<bool> setAudioSessionActive(bool active) async => true;

  @override
  Future<bool> isOtherAudioPlaying() async => false;

  @override
  Future<bool> isMusicActive() async => false;

  @override
  Future<int> getAudioMode() async => 0;

  @override
  Future<void> setAllowHapticsAndSystemSoundsDuringRecording(
    bool enabled,
  ) async {}

  @override
  Future<Set<MicAudioDevice>> getAudioDevices() async => <MicAudioDevice>{};

  @override
  Future<List<MicAudioInput>> getAvailableInputs() async => <MicAudioInput>[];

  @override
  Future<MicAudioRoute> getCurrentRoute() async => const MicAudioRoute();

  @override
  Future<bool> setPreferredInput(MicAudioInput input) async => false;

  @override
  Future<bool> showForegroundNotification(
    String title, {
    String? channelName,
    String? channelDescription,
    String? icon,
  }) async => false;

  @override
  Future<bool> removeForegroundNotification() async => false;

  @override
  Stream<Uint8List> audioDataStream() => const Stream<Uint8List>.empty();

  @override
  Stream<MicSessionEvent> sessionEvents() =>
      const Stream<MicSessionEvent>.empty();
}
