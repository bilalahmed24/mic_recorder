/// API type gallery for the mic_recorder example.
///
/// The live demo flow only ever hands the app a handful of the exported
/// types (states, events, config objects). This screen showcases the rest:
/// the audio device model with its platform decoders, the input/route
/// models, the encoder / file-format / stop-reason enums with sample
/// recording results and metering readings, sample instances of every
/// event class, and value listings of the enums the plugin exposes.
library;

import 'package:flutter/material.dart';
import 'package:mic_recorder/mic_recorder.dart';

/// A simple scrollable catalog of the exported mic_recorder types.
class ApiTypeGallery extends StatelessWidget {
  /// Creates the gallery screen.
  const ApiTypeGallery({super.key});

  /// Android `AudioDeviceInfo` type codes fed through
  /// [MicAudioDeviceType.fromAndroidType].
  static const List<int> _androidTypeCodes = <int>[
    0,
    3,
    4,
    7,
    8,
    11,
    12,
    15,
    18,
    26,
  ];

  /// iOS `AVAudioSessionPort` strings fed through
  /// [MicAudioDeviceType.fromIosPortType].
  static const List<String> _iosPortTypes = <String>[
    'BuiltInMic',
    'HeadsetMic',
    'BluetoothHFP',
    'BluetoothLE',
    'USBAudio',
    'LineIn',
    'CarAudio',
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('API type gallery')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: <Widget>[
          _Section(
            title: 'MicAudioDeviceType.fromAndroidType(int)',
            children: _androidDecoderRows(),
          ),
          _Section(
            title:
                'MicAudioDeviceType.fromIosPortType(String, '
                '{headphonesInputAvailable})',
            children: _iosDecoderRows(),
          ),
          _Section(
            title: 'MicAudioDevice — ==, hashCode, toString',
            children: _audioDeviceRows(),
          ),
          _Section(title: 'MicAudioInput.type', children: _audioInputRows()),
          _Section(title: 'MicAudioRoute', children: _routeRows()),
          _Section(
            title: 'MicAudioEncoder (setEncodedOutput)',
            children: _encoderRows(),
          ),
          _Section(
            title: 'MicRecordingFileFormat (setOutputFile)',
            children: _fileFormatRows(),
          ),
          _Section(
            title: 'MicRecordingStopReason / MicRecordingInfo',
            children: _recordingInfoRows(),
          ),
          _Section(
            title: 'MicAmplitude (onAmplitude / amplitude)',
            children: _amplitudeRows(),
          ),
          _Section(title: 'Event samples', children: _eventSampleRows()),
          _Section(title: 'Value listings', children: _valueListingRows()),
        ],
      ),
    );
  }

  List<Widget> _androidDecoderRows() {
    return <Widget>[
      for (final code in _androidTypeCodes)
        _Row(
          label: 'fromAndroidType($code)',
          value: MicAudioDeviceType.fromAndroidType(code).name,
        ),
    ];
  }

  List<Widget> _iosDecoderRows() {
    return <Widget>[
      for (final portType in _iosPortTypes)
        _Row(
          label: "fromIosPortType('$portType')",
          value: MicAudioDeviceType.fromIosPortType(portType).name,
        ),
      // 'Headphones' is an OUTPUT port on iOS: whether it counts as a
      // wired-headset input depends on the caller's knowledge of the
      // headset wiring — that is exactly what the named parameter carries.
      _Row(
        label:
            "fromIosPortType('Headphones', "
            '{headphonesInputAvailable: false})',
        value: MicAudioDeviceType.fromIosPortType(
          'Headphones',
          headphonesInputAvailable: false,
        ).name,
      ),
      _Row(
        label:
            "fromIosPortType('Headphones', "
            '{headphonesInputAvailable: true})',
        value: MicAudioDeviceType.fromIosPortType(
          'Headphones',
          headphonesInputAvailable: true,
        ).name,
      ),
    ];
  }

  List<Widget> _audioDeviceRows() {
    const first = MicAudioDevice(
      id: 'bt',
      name: 'Pixel Buds',
      type: MicAudioDeviceType.bluetoothSco,
      isInput: true,
      isOutput: false,
    );
    const second = MicAudioDevice(
      id: 'bt',
      name: 'Pixel Buds',
      type: MicAudioDeviceType.bluetoothSco,
      isInput: true,
      isOutput: false,
    );
    const other = MicAudioDevice(
      id: 'usb',
      name: 'USB microphone',
      type: MicAudioDeviceType.usbAudio,
      isInput: true,
      isOutput: false,
    );

    return <Widget>[
      _Row(label: 'first == second', value: '${first == second}'),
      _Row(
        label: 'first.hashCode == second.hashCode',
        value: '${first.hashCode == second.hashCode}',
      ),
      _Row(label: 'first == other', value: '${first == other}'),
      _Row(label: 'first.toString()', value: '$first'),
      _Row(label: 'other.toString()', value: '$other'),
    ];
  }

  List<Widget> _audioInputRows() {
    const inputs = <MicAudioInput>[
      MicAudioInput(
        uid: 'in-builtin',
        portType: 'BuiltInMic',
        portName: 'iPhone Microphone',
      ),
      MicAudioInput(
        uid: 'in-wired',
        portType: 'HeadsetMic',
        portName: 'Wired headset',
      ),
      MicAudioInput(
        uid: 'in-bt',
        portType: 'BluetoothHFP',
        portName: 'Pixel Buds',
      ),
      MicAudioInput(
        uid: 'in-usb',
        portType: 'USBAudio',
        portName: 'USB microphone',
      ),
    ];

    return <Widget>[
      for (final input in inputs)
        _Row(
          label: "'${input.portName}' (${input.portType})",
          value: 'type: ${input.type.name}',
        ),
    ];
  }

  List<Widget> _routeRows() {
    final route = MicAudioRoute(
      inputs: const <MicAudioInput>[
        MicAudioInput(
          uid: 'in-wired',
          portType: 'HeadsetMic',
          portName: 'Wired headset',
        ),
        MicAudioInput(
          uid: 'in-builtin',
          portType: 'BuiltInMic',
          portName: 'iPhone Microphone',
        ),
      ],
      outputs: const <MicAudioInput>[
        MicAudioInput(
          uid: 'out-speaker',
          portType: 'BuiltInSpeaker',
          portName: 'iPhone Speaker',
        ),
      ],
    );

    return <Widget>[
      _Row(
        label: 'route.inputs',
        value:
            '${route.inputs.length} '
            "(${route.inputs.map((input) => input.portType).join(', ')})",
      ),
      _Row(
        label: 'route.outputs',
        value:
            '${route.outputs.length} '
            "(${route.outputs.map((output) => output.portType).join(', ')})",
      ),
    ];
  }

  List<Widget> _encoderRows() {
    return <Widget>[
      for (final encoder in MicAudioEncoder.values)
        _Row(
          label: '${encoder.name} (${encoder.fileExtension})',
          value:
              'wire: ${encoder.wireName} · '
              'defaultBitRate: ${encoder.defaultBitRate ?? '— (lossless)'} · '
              'requiredSampleRate: ${encoder.requiredSampleRate ?? 'any'} · '
              'android: ${encoder.android} · ios: ${encoder.ios}',
        ),
      const _Row(
        label: 'isSupportedOn(android:, ios:)',
        value: 'runtime gate the demo uses before arming an encoder',
      ),
    ];
  }

  List<Widget> _fileFormatRows() {
    return <Widget>[
      for (final format in MicRecordingFileFormat.values)
        _Row(label: format.name, value: 'wireName: ${format.wireName}'),
      const _Row(
        label: 'wav',
        value: 'RIFF container the plugin writes itself (44-byte header)',
      ),
    ];
  }

  List<Widget> _recordingInfoRows() {
    final encoded = MicRecordingInfo(
      startedAtUtc: DateTime.utc(2025, 6, 1, 12),
      duration: const Duration(minutes: 2, seconds: 5),
      sizeBytes: 2000000,
      sampleRate: 16000,
      bitDepth: 16,
      channels: 1,
      stopReason: MicRecordingStopReason.maxDurationReached,
      path: '/tmp/mic_recorder_demo_20250601_120000.m4a',
      encoder: MicAudioEncoder.aacLc,
    );

    final dartWritten = MicRecordingInfo(
      startedAtUtc: DateTime.utc(2025, 6, 1, 13),
      duration: const Duration(seconds: 90),
      sizeBytes: 2880044,
      sampleRate: 16000,
      bitDepth: 16,
      channels: 1,
      path: '/tmp/mic_recorder_demo_20250601_130000.wav',
      fileFormat: MicRecordingFileFormat.wav,
    );

    return <Widget>[
      const _SectionHeader('MicRecordingStopReason'),
      for (final reason in MicRecordingStopReason.values)
        _Row(label: reason.name, value: _stopReasonLabel(reason)),
      const _SectionHeader('MicRecordingInfo — encoded episode'),
      _Row(label: 'duration', value: '${encoded.duration}'),
      _Row(label: 'sizeBytes', value: '${encoded.sizeBytes}'),
      _Row(label: 'path', value: encoded.path ?? '—'),
      _Row(label: 'encoder', value: '${encoded.encoder}'),
      _Row(label: 'fileFormat', value: '${encoded.fileFormat}'),
      _Row(label: 'stopReason', value: encoded.stopReason.name),
      const _SectionHeader('MicRecordingInfo — Dart-written episode'),
      _Row(label: 'duration', value: '${dartWritten.duration}'),
      _Row(label: 'sizeBytes', value: '${dartWritten.sizeBytes}'),
      _Row(label: 'path', value: dartWritten.path ?? '—'),
      _Row(label: 'encoder', value: '${dartWritten.encoder}'),
      _Row(label: 'fileFormat', value: '${dartWritten.fileFormat}'),
      _Row(label: 'stopReason', value: dartWritten.stopReason.name),
    ];
  }

  String _stopReasonLabel(MicRecordingStopReason reason) {
    switch (reason) {
      case MicRecordingStopReason.manual:
        return 'stop() or cancel() was called';
      case MicRecordingStopReason.maxDurationReached:
        return 'MicRecorderConfig.maxDuration auto-stop';
    }
  }

  List<Widget> _amplitudeRows() {
    const reading = MicAmplitude(
      currentDbfs: -23.4,
      averageDbfs: -28.1,
      peakDbfs: -11.7,
    );

    return <Widget>[
      _Row(label: 'currentDbfs', value: '${reading.currentDbfs} dBFS'),
      _Row(label: 'averageDbfs', value: '${reading.averageDbfs} dBFS'),
      _Row(label: 'peakDbfs', value: '${reading.peakDbfs} dBFS'),
      _Row(label: 'silenceDbfs', value: '${MicAmplitude.silenceDbfs}'),
      _Row(label: 'isSilent', value: '${reading.isSilent}'),
      _Row(label: 'toString()', value: '$reading'),
    ];
  }

  List<Widget> _eventSampleRows() {
    final sourceSwitched = MicAudioSourceSwitchedEvent(
      sourceKind: MicAudioSourceKind.bluetooth,
      previousSourceKind: MicAudioSourceKind.defaultMicrophone,
      sourceName: 'Pixel Buds',
      reason: 'device-change',
      switchingEnabled: true,
    );

    final conversationSilence = MicConversationSilenceEvent(
      startedAtUtc: DateTime.utc(2025, 6, 1, 12),
      duration: const Duration(minutes: 5),
      lastRms: 0.0009,
      silenceThreshold: 0.004,
      bytesCapturedSinceStart: 9600000,
      buffersCapturedSinceStart: 469,
      silenceRecoveryAttempts: 0,
      routeState: const <String, Object?>{
        'scoConnected': false,
        'bluetoothHeadsetConnected': true,
      },
    );

    final microphoneLost = MicMicrophoneLostEvent(
      reason: 'unknown-interruption',
    );

    final interruption = MicAudioInterruption(
      begin: true,
      type: MicAudioInterruptionType.unknown,
    );

    return <Widget>[
      const _SectionHeader('MicAudioSourceSwitchedEvent'),
      _Row(label: 'sourceKind', value: sourceSwitched.sourceKind.name),
      _Row(
        label: 'previousSourceKind',
        value: sourceSwitched.previousSourceKind?.name ?? '—',
      ),
      _Row(label: 'sourceName', value: sourceSwitched.sourceName ?? '—'),
      _Row(label: 'reason', value: sourceSwitched.reason),
      _Row(
        label: 'switchingEnabled',
        value: '${sourceSwitched.switchingEnabled}',
      ),
      const _SectionHeader('MicConversationSilenceEvent'),
      _Row(label: 'startedAtUtc', value: '${conversationSilence.startedAtUtc}'),
      _Row(label: 'duration', value: '${conversationSilence.duration}'),
      _Row(label: 'lastRms', value: '${conversationSilence.lastRms}'),
      _Row(
        label: 'silenceThreshold',
        value: '${conversationSilence.silenceThreshold}',
      ),
      _Row(
        label: 'bytesCapturedSinceStart',
        value: '${conversationSilence.bytesCapturedSinceStart}',
      ),
      _Row(
        label: 'buffersCapturedSinceStart',
        value: '${conversationSilence.buffersCapturedSinceStart}',
      ),
      _Row(
        label: 'silenceRecoveryAttempts',
        value: '${conversationSilence.silenceRecoveryAttempts}',
      ),
      _Row(label: 'routeState', value: '${conversationSilence.routeState}'),
      const _SectionHeader('MicMicrophoneLostEvent'),
      _Row(label: 'reason', value: microphoneLost.reason),
      const _SectionHeader('MicAudioInterruption'),
      _Row(label: 'begin', value: '${interruption.begin}'),
      _Row(label: 'type', value: interruption.type.name),
    ];
  }

  List<Widget> _valueListingRows() {
    return <Widget>[
      const _SectionHeader('MicAudioSourceKind.wireName'),
      for (final kind in MicAudioSourceKind.values)
        _Row(label: kind.name, value: "'${kind.wireName}'"),
      const _SectionHeader('MicAudioInterruptionType'),
      for (final type in MicAudioInterruptionType.values)
        _Row(label: type.name, value: type.name),
      const _SectionHeader('MicLogLevel'),
      for (final level in MicLogLevel.values)
        _Row(label: level.name, value: level.name),
      const _SectionHeader('MicRecorderState (+flags)'),
      for (final state in MicRecorderState.values)
        _Row(
          label: state.name,
          value:
              'isActive: ${state.isActive} · '
              'isRecording: ${state.isRecording}',
        ),
      const _SectionHeader('MicRecordingMode'),
      for (final mode in MicRecordingMode.values)
        _Row(label: mode.name, value: mode.name),
      const _SectionHeader('MicLogSink'),
      const _Row(
        label: 'defaultMicLog',
        value: 'the sink used when MicRecorderConfig.log is null',
      ),
    ];
  }
}

/// Section card of the gallery.
class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

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
            Text(title, style: theme.textTheme.titleSmall),
            const SizedBox(height: 6),
            ...children,
          ],
        ),
      ),
    );
  }
}

/// In-section sub-header (used by the multi-class sections).
class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        label,
        style: Theme.of(
          context,
        ).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700),
      ),
    );
  }
}

/// Label/value row of the gallery.
class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(child: Text(label, style: theme.textTheme.bodySmall)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
              ),
              textAlign: TextAlign.end,
            ),
          ),
        ],
      ),
    );
  }
}
