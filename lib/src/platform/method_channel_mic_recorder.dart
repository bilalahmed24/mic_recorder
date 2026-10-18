import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../config/mic_audio_session_config.dart';
import '../models/mic_audio_device.dart';
import '../models/mic_audio_encoder.dart';
import '../models/mic_session_events.dart';
import 'mic_recorder_platform.dart';

/// The [MicRecorderPlatform] implementation over the plugin's channels.
///
/// * MethodChannel `com.bilalahmed24.mic_recorder/methods` — the wire
///   verbs (see `doc/ARCHITECTURE.md` §3 for the complete table).
/// * EventChannel `com.bilalahmed24.mic_recorder/audio_stream` — raw PCM
///   (16-bit little-endian mono) chunks.
/// * EventChannel `com.bilalahmed24.mic_recorder/session_events` — focus,
///   device, interruption and route notifications as maps.
final class MethodChannelMicRecorder extends MicRecorderPlatform {
  /// Creates the method-channel platform.
  MethodChannelMicRecorder();

  static const MethodChannel _methodsChannel = MethodChannel(
    'com.bilalahmed24.mic_recorder/methods',
  );

  static const EventChannel _audioStreamChannel = EventChannel(
    'com.bilalahmed24.mic_recorder/audio_stream',
  );

  static const EventChannel _sessionEventsChannel = EventChannel(
    'com.bilalahmed24.mic_recorder/session_events',
  );

  // ---------------------------------------------------------------------------
  // Capture
  // ---------------------------------------------------------------------------

  @override
  Future<bool> startRecording(
    int sampleRate, {
    bool androidEchoCancel = false,
    bool androidNoiseSuppress = false,
    bool androidAutoGain = false,
  }) async =>
      await _methodsChannel.invokeMethod<bool>('startRecording', {
        'sampleRate': sampleRate,
        'echoCancel': androidEchoCancel,
        'noiseSuppress': androidNoiseSuppress,
        'autoGain': androidAutoGain,
      }) ??
      false;

  @override
  Future<bool> pauseRecording(bool isPausedForInterruption) async =>
      await _methodsChannel.invokeMethod<bool>('pauseRecording', {
        'isPausedForInterruption': isPausedForInterruption,
      }) ??
      false;

  @override
  Future<bool> resumeRecording() async =>
      await _methodsChannel.invokeMethod<bool>('resumeRecording') ?? false;

  @override
  Future<bool> stopRecording() async =>
      await _methodsChannel.invokeMethod<bool>('stopRecording') ?? false;

  @override
  Future<bool> setEncodedOutput(
    String path,
    MicAudioEncoder encoder, {
    int? bitRate,
    int? sampleRate,
  }) async {
    final arguments = <String, Object?>{
      'path': path,
      'encoder': encoder.wireName,
    };

    if (bitRate != null) arguments['bitRate'] = bitRate;

    if (sampleRate != null) arguments['sampleRate'] = sampleRate;

    return await _methodsChannel.invokeMethod<bool>(
          'setEncodedOutput',
          arguments,
        ) ??
        false;
  }

  @override
  Future<bool> clearEncodedOutput() async =>
      await _methodsChannel.invokeMethod<bool>('clearEncodedOutput') ?? false;

  @override
  Future<bool> checkMicPermission() async =>
      await _methodsChannel.invokeMethod<bool>('checkMicPermission') ?? false;

  @override
  Future<bool> requestMicPermission() async =>
      await _methodsChannel.invokeMethod<bool>('requestMicPermission') ?? false;

  @override
  Future<bool> microphoneInterrupted() async =>
      await _methodsChannel.invokeMethod<bool>('microphoneInterrupted') ??
      false;

  // ---------------------------------------------------------------------------
  // Routing
  // ---------------------------------------------------------------------------

  @override
  Future<void> setBluetoothStatus(bool isAllowed) async {
    await _methodsChannel.invokeMethod<void>('setBluetoothStatus', {
      'isAllowed': isAllowed,
    });
  }

  @override
  Future<Map<String, Object?>?> getRouteState() async {
    try {
      final reply = await _methodsChannel.invokeMethod<Map<Object?, Object?>>(
        'getRouteState',
      );

      return reply?.cast<String, Object?>();
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<List<double>?> extractAmplitudes({
    required String filePath,
    int barCount = 60,
  }) async {
    try {
      final reply = await _methodsChannel.invokeMethod<List<Object?>>(
        'extractAmplitudes',
        {'filePath': filePath, 'barCount': barCount},
      );

      if (reply == null) return null;

      return <double>[
        for (final amplitude in reply) (amplitude as num).toDouble(),
      ];
    } on PlatformException {
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Audio session
  // ---------------------------------------------------------------------------

  @override
  Future<void> configureAudioSession(MicAudioSessionConfig config) async {
    await _methodsChannel.invokeMethod<void>('configureAudioSession', {
      'config': <String, Object?>{
        'allowBluetooth': config.allowBluetooth,
        'defaultToSpeaker': config.defaultToSpeaker,
        'notifyOthersOnDeactivation': config.notifyOthersOnDeactivation,
        'willPauseWhenDucked': config.androidWillPauseWhenDucked,
      },
    });
  }

  @override
  Future<bool> setAudioSessionActive(bool active) async =>
      await _methodsChannel.invokeMethod<bool>('setAudioSessionActive', {
        'active': active,
      }) ??
      false;

  @override
  Future<bool> isOtherAudioPlaying() async =>
      await _methodsChannel.invokeMethod<bool>('isOtherAudioPlaying') ?? false;

  @override
  Future<bool> isMusicActive() async =>
      await _methodsChannel.invokeMethod<bool>('isMusicActive') ?? false;

  @override
  Future<int> getAudioMode() async =>
      await _methodsChannel.invokeMethod<int>('getAudioMode') ?? 0;

  @override
  Future<void> setAllowHapticsAndSystemSoundsDuringRecording(
    bool enabled,
  ) async {
    await _methodsChannel.invokeMethod<void>(
      'setAllowHapticsAndSystemSoundsDuringRecording',
      {'enabled': enabled},
    );
  }

  // ---------------------------------------------------------------------------
  // Devices and routes
  // ---------------------------------------------------------------------------

  @override
  Future<Set<MicAudioDevice>> getAudioDevices() async {
    // iOS composes the snapshot from the current route plus the available
    // inputs; Android replies null to the route probe, which selects the
    // Android device-list verb below.
    final routeReply = await _tryInvokeCurrentRoute();

    if (routeReply != null) {
      final inputs = await getAvailableInputs();

      return composeIosDevices(route: _decodeRoute(routeReply), inputs: inputs);
    }

    final listReply = await _methodsChannel.invokeMethod<List<Object?>>(
      'getAudioDevices',
    );

    return <MicAudioDevice>{
      for (final entry in listReply ?? const <Object?>[])
        _decodeAndroidDevice(
          (entry as Map<Object?, Object?>?)?.cast<String, Object?>() ??
              const <String, Object?>{},
        ),
    };
  }

  @override
  Future<List<MicAudioInput>> getAvailableInputs() async {
    final reply = await _methodsChannel.invokeMethod<List<Object?>>(
      'getAvailableInputs',
    );

    return <MicAudioInput>[
      for (final entry in reply ?? const <Object?>[])
        _decodePort(
          (entry as Map<Object?, Object?>?)?.cast<String, Object?>() ??
              const <String, Object?>{},
        ),
    ];
  }

  @override
  Future<MicAudioRoute> getCurrentRoute() async {
    final reply = await _tryInvokeCurrentRoute();

    if (reply == null) return const MicAudioRoute();

    return _decodeRoute(reply);
  }

  @override
  Future<bool> setPreferredInput(MicAudioInput input) async =>
      await _methodsChannel.invokeMethod<bool>('setPreferredInput', {
        'uid': input.uid,
      }) ??
      false;

  // ---------------------------------------------------------------------------
  // Foreground service (Android)
  // ---------------------------------------------------------------------------

  @override
  Future<bool> showForegroundNotification(
    String title, {
    String? channelName,
    String? channelDescription,
    String? icon,
  }) async {
    final arguments = <String, Object?>{'notificationTitle': title};

    // Null optional fields are omitted entirely (native defaults apply).
    if (channelName != null) arguments['channelName'] = channelName;
    if (channelDescription != null) {
      arguments['channelDescription'] = channelDescription;
    }
    if (icon != null) arguments['icon'] = icon;

    return await _methodsChannel.invokeMethod<bool>(
          'showForegroundNotification',
          arguments,
        ) ??
        false;
  }

  @override
  Future<bool> removeForegroundNotification() async =>
      await _methodsChannel.invokeMethod<bool>(
        'removeForegroundNotification',
      ) ??
      false;

  // ---------------------------------------------------------------------------
  // Streams
  // ---------------------------------------------------------------------------

  @override
  Stream<List<int>> audioDataStream() => _audioStreamChannel
      .receiveBroadcastStream()
      .map((chunk) => chunk as List<int>);

  @override
  Stream<MicSessionEvent> sessionEvents() =>
      _sessionEventsChannel.receiveBroadcastStream().map(decodeSessionEvent);

  // ---------------------------------------------------------------------------
  // Decoding
  // ---------------------------------------------------------------------------

  /// Decodes a raw `session_events` payload into its typed form.
  ///
  /// Unknown event names decode to a zero-reason [MicIosRouteChange] — a
  /// benign value that keeps the stream's element type stable.
  @visibleForTesting
  static MicSessionEvent decodeSessionEvent(Object? raw) {
    final map =
        (raw as Map<Object?, Object?>?)?.cast<String, Object?>() ??
        const <String, Object?>{};

    switch (map['event']) {
      case 'audioFocusChanged':
        return MicAndroidAudioFocusChanged(
          focus: (map['focus'] as num?)?.toInt() ?? 0,
        );
      case 'devicesChanged':
        return MicAndroidDevicesChanged(
          added: _decodeDeviceList(map['added']),
          removed: _decodeDeviceList(map['removed']),
        );
      case 'interruption':
        return MicIosInterruptionNotification(
          began: (map['type'] as num?)?.toInt() == 0,
          shouldResume: map['shouldResume'] == true,
          wasSuspended: map['wasSuspended'] as bool?,
        );
      case 'routeChange':
      default:
        return MicIosRouteChange(reason: (map['reason'] as num?)?.toInt() ?? 0);
    }
  }

  /// Composes the iOS device snapshot from the current route and the
  /// available inputs.
  ///
  /// Every available input is an input; a route output whose uid also
  /// belongs to an input marks that (shared) device as an output too — and
  /// upgrades `Headphones` to a wired headset, because the shared uid proves
  /// the attached accessory carries a microphone. Outputs without a matching
  /// input stay output-only.
  @visibleForTesting
  static Set<MicAudioDevice> composeIosDevices({
    required MicAudioRoute route,
    required List<MicAudioInput> inputs,
  }) {
    final devices = <String, MicAudioDevice>{
      for (final input in inputs)
        input.uid: MicAudioDevice(
          id: input.uid,
          name: input.portName,
          type: MicAudioDeviceType.fromIosPortType(input.portType),
          isInput: true,
          isOutput: false,
        ),
    };

    for (final output in route.outputs) {
      final existing = devices[output.uid];

      if (existing != null) {
        devices[output.uid] = MicAudioDevice(
          id: existing.id,
          name: existing.name,
          type: MicAudioDeviceType.fromIosPortType(
            output.portType,
            headphonesInputAvailable: true,
          ),
          isInput: true,
          isOutput: true,
        );

        continue;
      }

      devices[output.uid] = MicAudioDevice(
        id: output.uid,
        name: output.portName,
        type: MicAudioDeviceType.fromIosPortType(output.portType),
        isInput: false,
        isOutput: true,
      );
    }

    // The route's input is the one actually selected — keep it even when it
    // is not among the listed available inputs.
    for (final input in route.inputs) {
      devices.putIfAbsent(
        input.uid,
        () => MicAudioDevice(
          id: input.uid,
          name: input.portName,
          type: MicAudioDeviceType.fromIosPortType(input.portType),
          isInput: true,
          isOutput: false,
        ),
      );
    }

    return devices.values.toSet();
  }

  static Future<Map<String, Object?>?> _tryInvokeCurrentRoute() async {
    try {
      final reply = await _methodsChannel.invokeMethod<Map<Object?, Object?>>(
        'getCurrentRoute',
      );

      return reply?.cast<String, Object?>();
    } on PlatformException {
      return null;
    }
  }

  static List<MicAudioDevice> _decodeDeviceList(Object? raw) {
    return <MicAudioDevice>[
      for (final entry in (raw as List<Object?>?) ?? const <Object?>[])
        _decodeAndroidDevice(
          (entry as Map<Object?, Object?>?)?.cast<String, Object?>() ??
              const <String, Object?>{},
        ),
    ];
  }

  static MicAudioDevice _decodeAndroidDevice(Map<String, Object?> map) {
    return MicAudioDevice(
      id: '${map['id'] ?? ''}',
      name: map['name'] as String? ?? '',
      type: MicAudioDeviceType.fromAndroidType(
        (map['type'] as num?)?.toInt() ?? 0,
      ),
      isInput: map['isSource'] == true,
      isOutput: map['isSink'] == true,
    );
  }

  static MicAudioRoute _decodeRoute(Map<String, Object?> map) {
    return MicAudioRoute(
      inputs: _decodePorts(map['inputs']),
      outputs: _decodePorts(map['outputs']),
    );
  }

  static List<MicAudioInput> _decodePorts(Object? raw) {
    return <MicAudioInput>[
      for (final entry in (raw as List<Object?>?) ?? const <Object?>[])
        _decodePort(
          (entry as Map<Object?, Object?>?)?.cast<String, Object?>() ??
              const <String, Object?>{},
        ),
    ];
  }

  static MicAudioInput _decodePort(Map<String, Object?> map) {
    return MicAudioInput(
      uid: map['uid'] as String? ?? '',
      portType: map['portType'] as String? ?? '',
      portName: map['portName'] as String? ?? '',
    );
  }
}
