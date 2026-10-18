import 'dart:async';

import 'package:mic_recorder/src/config/mic_audio_session_config.dart';
import 'package:mic_recorder/src/models/mic_audio_device.dart';
import 'package:mic_recorder/src/models/mic_audio_encoder.dart';
import 'package:mic_recorder/src/models/mic_session_events.dart';
import 'package:mic_recorder/src/platform/mic_recorder_platform.dart';

/// A fully scriptable [MicRecorderPlatform] for tests.
///
/// Calls are recorded synchronously at invocation ([callLog] plus the
/// per-verb lists); every reply resolves one microtask later (like a real
/// platform channel hop, while still firing on a bare `tester.pump()`). The
/// session-event and audio-data streams are synchronous broadcast
/// controllers so `emit*` helpers drive the plugin deterministically.
final class FakeMicRecorderPlatform extends MicRecorderPlatform {
  /// Every method name in call order (including `sessionEvents`).
  final callLog = <String>[];

  /// `configureAudioSession` arguments in call order.
  final configureAudioSessionCalls = <MicAudioSessionConfig>[];

  /// `setAudioSessionActive` arguments in call order.
  final setAudioSessionActiveCalls = <bool>[];

  /// `startRecording` sample rates in call order.
  final startRecordingCalls = <int>[];

  /// `startRecording` Android effect toggles in call order.
  final startRecordingEffectCalls = <_FakeEffects>[];

  /// `setEncodedOutput` armings in call order — (path, encoder, bitRate,
  /// sampleRate).
  final setEncodedOutputCalls = <(String, MicAudioEncoder, int?, int?)>[];

  /// How many times `clearEncodedOutput` was called.
  int clearEncodedOutputCallCount = 0;

  /// How many times `checkMicPermission` was called.
  int checkMicPermissionCallCount = 0;

  /// How many times `requestMicPermission` was called.
  int requestMicPermissionCallCount = 0;

  /// Scripted `setEncodedOutput` reply (default `true`).
  bool setEncodedOutputResult = true;

  /// Scripted `checkMicPermission` reply (default `false`).
  bool checkMicPermissionResult = false;

  /// Scripted `requestMicPermission` reply (default `true`).
  bool requestMicPermissionResult = true;

  /// `pauseRecording` interruption flags in call order.
  final pauseRecordingCalls = <bool>[];

  /// `setAllowHaptics...` arguments in call order.
  final setAllowHapticsCalls = <bool>[];

  /// `setBluetoothStatus` arguments in call order.
  final setBluetoothStatusCalls = <bool>[];

  /// `setPreferredInput` arguments in call order.
  final setPreferredInputCalls = <MicAudioInput>[];

  /// `showForegroundNotification` titles in call order.
  final showForegroundNotificationCalls = <String>[];

  /// Scripted `setAudioSessionActive` replies, consumed in call order
  /// (default `true` once exhausted).
  final setAudioSessionActiveResponses = <bool>[];

  /// Scripted `startRecording` reply (default `true`).
  bool startRecordingResult = true;

  /// Scripted `pauseRecording` reply (default `true`).
  bool pauseRecordingResult = true;

  /// Scripted `resumeRecording` reply (default `true`).
  bool resumeRecordingResult = true;

  /// Scripted `stopRecording` reply (default `true`).
  bool stopRecordingResult = true;

  /// Scripted `setPreferredInput` reply (default `false`).
  bool setPreferredInputResult = false;

  /// Scripted `showForegroundNotification` reply (default `true`).
  bool showForegroundNotificationResult = true;

  /// Scripted `removeForegroundNotification` reply (default `true`).
  bool removeForegroundNotificationResult = true;

  /// Scripted `isOtherAudioPlaying` reply (default `false`).
  bool isOtherAudioPlayingResult = false;

  /// Scripted `isMusicActive` reply (default `false`).
  bool isMusicActiveResult = false;

  /// Scripted `getAudioMode` reply (default `0`).
  int audioModeResult = 0;

  /// Scripted `getAudioDevices` snapshot (default empty).
  Set<MicAudioDevice>? audioDevicesResult;

  /// When set, `getAudioDevices` throws this instead of replying.
  Object? getAudioDevicesError;

  /// Scripted `getRouteState` reply (default null).
  Map<String, Object?>? getRouteStateResult;

  /// Scripted `extractAmplitudes` reply (default null).
  List<double>? extractAmplitudesResult;

  /// Scripted `getAvailableInputs` reply (default empty).
  List<MicAudioInput>? getAvailableInputsResult;

  /// Scripted `getCurrentRoute` reply (default an empty route).
  MicAudioRoute getCurrentRouteResult = const MicAudioRoute();

  /// How many times `microphoneInterrupted` was called.
  int microphoneInterruptedCallCount = 0;

  /// How many times `getAudioDevices` was called.
  int getAudioDevicesCallCount = 0;

  /// How many times `resumeRecording` was called.
  int resumeRecordingCallCount = 0;

  /// How many times `stopRecording` was called.
  int stopRecordingCallCount = 0;

  /// How many times `removeForegroundNotification` was called.
  int removeForegroundNotificationCallCount = 0;

  int _setAudioSessionActiveReplyIndex = 0;

  final StreamController<MicSessionEvent> _sessionEventsController =
      StreamController<MicSessionEvent>.broadcast(sync: true);

  final StreamController<List<int>> _audioDataController =
      StreamController<List<int>>.broadcast(sync: true);

  bool _isDisposed = false;

  /// Emits an Android audio-focus change into the session-event stream.
  void emitAndroidFocus(int focus) {
    _sessionEventsController.add(MicAndroidAudioFocusChanged(focus: focus));
  }

  /// Emits an iOS interruption notification into the session-event stream.
  void emitIosInterruption({
    required bool began,
    required bool shouldResume,
    bool? wasSuspended,
  }) {
    _sessionEventsController.add(
      MicIosInterruptionNotification(
        began: began,
        shouldResume: shouldResume,
        wasSuspended: wasSuspended,
      ),
    );
  }

  /// Emits an Android device-list change into the session-event stream.
  void emitDevicesChanged({
    List<MicAudioDevice> added = const <MicAudioDevice>[],
    List<MicAudioDevice> removed = const <MicAudioDevice>[],
  }) {
    _sessionEventsController.add(
      MicAndroidDevicesChanged(added: added, removed: removed),
    );
  }

  /// Emits an iOS route change into the session-event stream.
  void emitIosRouteChange(int reason) {
    _sessionEventsController.add(MicIosRouteChange(reason: reason));
  }

  /// Emits a PCM chunk into the audio-data stream.
  void emitAudioChunk(List<int> chunk) {
    _audioDataController.add(chunk);
  }

  @override
  Stream<MicSessionEvent> sessionEvents() {
    callLog.add('sessionEvents');

    return _sessionEventsController.stream;
  }

  @override
  Stream<List<int>> audioDataStream() {
    callLog.add('audioDataStream');

    return _audioDataController.stream;
  }

  @override
  Future<bool> startRecording(
    int sampleRate, {
    bool androidEchoCancel = false,
    bool androidNoiseSuppress = false,
    bool androidAutoGain = false,
  }) {
    callLog.add('startRecording');

    startRecordingCalls.add(sampleRate);

    startRecordingEffectCalls.add((
      androidEchoCancel,
      androidNoiseSuppress,
      androidAutoGain,
    ));

    return Future<bool>.value(startRecordingResult);
  }

  @override
  Future<bool> pauseRecording(bool isPausedForInterruption) {
    callLog.add('pauseRecording');

    pauseRecordingCalls.add(isPausedForInterruption);

    return Future<bool>.value(pauseRecordingResult);
  }

  @override
  Future<bool> resumeRecording() {
    callLog.add('resumeRecording');

    resumeRecordingCallCount++;

    return Future<bool>.value(resumeRecordingResult);
  }

  @override
  Future<bool> stopRecording() {
    callLog.add('stopRecording');

    stopRecordingCallCount++;

    return Future<bool>.value(stopRecordingResult);
  }

  @override
  Future<bool> setEncodedOutput(
    String path,
    MicAudioEncoder encoder, {
    int? bitRate,
    int? sampleRate,
  }) {
    callLog.add('setEncodedOutput');

    setEncodedOutputCalls.add((path, encoder, bitRate, sampleRate));

    return Future<bool>.value(setEncodedOutputResult);
  }

  @override
  Future<bool> clearEncodedOutput() {
    callLog.add('clearEncodedOutput');

    clearEncodedOutputCallCount++;

    return Future<bool>.value(true);
  }

  @override
  Future<bool> checkMicPermission() {
    callLog.add('checkMicPermission');

    checkMicPermissionCallCount++;

    return Future<bool>.value(checkMicPermissionResult);
  }

  @override
  Future<bool> requestMicPermission() {
    callLog.add('requestMicPermission');

    requestMicPermissionCallCount++;

    return Future<bool>.value(requestMicPermissionResult);
  }

  @override
  Future<bool> microphoneInterrupted() {
    callLog.add('microphoneInterrupted');

    microphoneInterruptedCallCount++;

    return Future<bool>.value(true);
  }

  @override
  Future<void> setBluetoothStatus(bool isAllowed) {
    callLog.add('setBluetoothStatus');

    setBluetoothStatusCalls.add(isAllowed);

    return Future<void>.value();
  }

  @override
  Future<Map<String, Object?>?> getRouteState() {
    callLog.add('getRouteState');

    return Future<Map<String, Object?>?>.value(getRouteStateResult);
  }

  @override
  Future<List<double>?> extractAmplitudes({
    required String filePath,
    int barCount = 60,
  }) {
    callLog.add('extractAmplitudes');

    return Future<List<double>?>.value(extractAmplitudesResult);
  }

  @override
  Future<void> configureAudioSession(MicAudioSessionConfig config) {
    callLog.add('configureAudioSession');

    configureAudioSessionCalls.add(config);

    return Future<void>.value();
  }

  @override
  Future<bool> setAudioSessionActive(bool active) {
    callLog.add('setAudioSessionActive');

    setAudioSessionActiveCalls.add(active);

    final index = _setAudioSessionActiveReplyIndex++;

    final reply = index < setAudioSessionActiveResponses.length
        ? setAudioSessionActiveResponses[index]
        : true;

    return Future<bool>.value(reply);
  }

  @override
  Future<bool> isOtherAudioPlaying() {
    callLog.add('isOtherAudioPlaying');

    return Future<bool>.value(isOtherAudioPlayingResult);
  }

  @override
  Future<bool> isMusicActive() {
    callLog.add('isMusicActive');

    return Future<bool>.value(isMusicActiveResult);
  }

  @override
  Future<int> getAudioMode() {
    callLog.add('getAudioMode');

    return Future<int>.value(audioModeResult);
  }

  @override
  Future<void> setAllowHapticsAndSystemSoundsDuringRecording(bool enabled) {
    callLog.add('setAllowHapticsAndSystemSoundsDuringRecording');

    setAllowHapticsCalls.add(enabled);

    return Future<void>.value();
  }

  @override
  Future<Set<MicAudioDevice>> getAudioDevices() async {
    callLog.add('getAudioDevices');

    getAudioDevicesCallCount++;

    final error = getAudioDevicesError;

    if (error != null) throw error;

    return audioDevicesResult ?? <MicAudioDevice>{};
  }

  @override
  Future<List<MicAudioInput>> getAvailableInputs() {
    callLog.add('getAvailableInputs');

    return Future<List<MicAudioInput>>.value(
      getAvailableInputsResult ?? <MicAudioInput>[],
    );
  }

  @override
  Future<MicAudioRoute> getCurrentRoute() {
    callLog.add('getCurrentRoute');

    return Future<MicAudioRoute>.value(getCurrentRouteResult);
  }

  @override
  Future<bool> setPreferredInput(MicAudioInput input) {
    callLog.add('setPreferredInput');

    setPreferredInputCalls.add(input);

    return Future<bool>.value(setPreferredInputResult);
  }

  @override
  Future<bool> showForegroundNotification(
    String title, {
    String? channelName,
    String? channelDescription,
    String? icon,
  }) {
    callLog.add('showForegroundNotification');

    showForegroundNotificationCalls.add(title);

    return Future<bool>.value(showForegroundNotificationResult);
  }

  @override
  Future<bool> removeForegroundNotification() {
    callLog.add('removeForegroundNotification');

    removeForegroundNotificationCallCount++;

    return Future<bool>.value(removeForegroundNotificationResult);
  }

  /// Closes the underlying controllers (fire-and-forget — awaiting a
  /// broadcast close never completes under fake async).
  Future<void> dispose() async {
    if (_isDisposed) return;

    _isDisposed = true;

    unawaited(_sessionEventsController.close());

    unawaited(_audioDataController.close());
  }
}

/// Creates a [MicAudioDevice] with input defaults — the test helper used by
/// device-snapshot assertions.
MicAudioDevice makeDevice(
  MicAudioDeviceType type, {
  String id = '',
  String name = '',
  bool isInput = true,
  bool isOutput = false,
}) {
  return MicAudioDevice(
    id: id,
    name: name,
    type: type,
    isInput: isInput,
    isOutput: isOutput,
  );
}

/// The Android effect toggles a `startRecording` call carried
typedef _FakeEffects = (bool, bool, bool);
