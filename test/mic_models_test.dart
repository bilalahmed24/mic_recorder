//
// The wire decoding of these models (method-channel maps into devices,
// routes and session events) lives in method_channel_mic_recorder_test.dart,
// and the episode machinery that builds them (amplitude metering, stop
// reasons, source switching) lives in mic_recorder_test.dart. This file
// pins the models' own public surface: constructors and defaults, the
// exhaustive enum mappings, equality/hashCode/toString and the dBFS range
// contract.
import 'package:flutter_test/flutter_test.dart';
import 'package:mic_recorder/src/models/mic_amplitude.dart';
import 'package:mic_recorder/src/models/mic_audio_device.dart';
import 'package:mic_recorder/src/models/mic_audio_encoder.dart';
import 'package:mic_recorder/src/models/mic_audio_interruption.dart';
import 'package:mic_recorder/src/models/mic_recorder_events.dart';
import 'package:mic_recorder/src/models/mic_recorder_state.dart';
import 'package:mic_recorder/src/models/mic_recording_file_format.dart';
import 'package:mic_recorder/src/models/mic_recording_info.dart';
import 'package:mic_recorder/src/models/mic_session_events.dart';

void main() {
  group('MicAmplitude', () {
    test('round-trips the full documented dBFS range', () {
      const loudest = MicAmplitude(
        currentDbfs: 0.0,
        averageDbfs: -3.0,
        peakDbfs: 0.0,
      );
      const silent = MicAmplitude(
        currentDbfs: -120.0,
        averageDbfs: -120.0,
        peakDbfs: -120.0,
      );

      expect(loudest.currentDbfs, 0.0);
      expect(loudest.averageDbfs, -3.0);
      expect(loudest.peakDbfs, 0.0);

      expect(silent.currentDbfs, -120.0);
      expect(silent.averageDbfs, -120.0);
      expect(silent.peakDbfs, -120.0);
    });

    test('pins the silence floor constant', () {
      expect(MicAmplitude.silenceDbfs, -120.0);
    });

    test('isSilent holds only at (or below) the silence floor', () {
      expect(
        const MicAmplitude(
          currentDbfs: -120.0,
          averageDbfs: -120.0,
          peakDbfs: -120.0,
        ).isSilent,
        isTrue,
      );
      expect(
        const MicAmplitude(
          currentDbfs: -119.9,
          averageDbfs: -120.0,
          peakDbfs: -120.0,
        ).isSilent,
        isFalse,
      );
      expect(
        const MicAmplitude(
          currentDbfs: 0.0,
          averageDbfs: 0.0,
          peakDbfs: 0.0,
        ).isSilent,
        isFalse,
      );
    });

    test('rejects readings outside the dBFS range (the clamp contract)', () {
      // Values are asserted into [-120.0, 0.0]: the metering pipeline clamps
      // before constructing a reading, so a raw out-of-range value is a bug.
      expect(
        () => MicAmplitude(currentDbfs: 0.1, averageDbfs: -1.0, peakDbfs: -1.0),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => MicAmplitude(
          currentDbfs: -120.1,
          averageDbfs: -1.0,
          peakDbfs: -1.0,
        ),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => MicAmplitude(currentDbfs: -1.0, averageDbfs: 0.1, peakDbfs: -1.0),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => MicAmplitude(
          currentDbfs: -1.0,
          averageDbfs: -120.1,
          peakDbfs: -1.0,
        ),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => MicAmplitude(currentDbfs: -1.0, averageDbfs: -1.0, peakDbfs: 0.1),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => MicAmplitude(
          currentDbfs: -1.0,
          averageDbfs: -1.0,
          peakDbfs: -120.1,
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('formats readings with one decimal place', () {
      const reading = MicAmplitude(
        currentDbfs: -6.0,
        averageDbfs: -12.3,
        peakDbfs: -3.4,
      );

      expect(
        reading.toString(),
        'MicAmplitude(current: -6.0 dBFS, average: -12.3 dBFS, '
        'peak: -3.4 dBFS)',
      );
    });
  });

  group('MicAudioDeviceType', () {
    test('decodes every mapped Android AudioDeviceInfo type code', () {
      const mappedCodes = <int, MicAudioDeviceType>{
        2: MicAudioDeviceType.builtInSpeaker, // TYPE_BUILTIN_SPEAKER
        3: MicAudioDeviceType.wiredHeadset, // TYPE_WIRED_HEADSET
        4: MicAudioDeviceType.headphones, // TYPE_WIRED_HEADPHONES
        7: MicAudioDeviceType.bluetoothSco, // TYPE_BLUETOOTH_SCO
        8: MicAudioDeviceType.bluetoothA2dp, // TYPE_BLUETOOTH_A2DP
        11: MicAudioDeviceType.usbAudio, // TYPE_USB_DEVICE
        12: MicAudioDeviceType.usbAudio, // TYPE_USB_ACCESSORY
        15: MicAudioDeviceType.builtInMic, // TYPE_BUILTIN_MIC
        19: MicAudioDeviceType.lineAnalog, // TYPE_LINE_ANALOG
        20: MicAudioDeviceType.lineDigital, // TYPE_LINE_DIGITAL
        22: MicAudioDeviceType.usbAudio, // TYPE_USB_HEADSET
        26: MicAudioDeviceType.bluetoothLe, // TYPE_BLE_HEADSET
      };

      for (final entry in mappedCodes.entries) {
        expect(
          MicAudioDeviceType.fromAndroidType(entry.key),
          entry.value,
          reason: 'Android type code ${entry.key}',
        );
      }
    });

    test('decodes unmapped Android type codes to unknown', () {
      const unmapped = <int>[0, 1, 5, 18, 25, 100, -1];

      for (final code in unmapped) {
        expect(
          MicAudioDeviceType.fromAndroidType(code),
          MicAudioDeviceType.unknown,
          reason: 'Android type code $code',
        );
      }
    });

    test('decodes every mapped iOS audio-session port type', () {
      const mappedPorts = <String, MicAudioDeviceType>{
        'BuiltInMic': MicAudioDeviceType.builtInMic,
        'BuiltInSpeaker': MicAudioDeviceType.builtInSpeaker,
        'HeadsetMic': MicAudioDeviceType.wiredHeadset,
        'Headphones': MicAudioDeviceType.headphones,
        'USBAudio': MicAudioDeviceType.usbAudio,
        'BluetoothHFP': MicAudioDeviceType.bluetoothSco,
        'BluetoothLE': MicAudioDeviceType.bluetoothLe,
        'LineIn': MicAudioDeviceType.lineAnalog,
        'HDMI': MicAudioDeviceType.lineDigital,
        'CarAudio': MicAudioDeviceType.carAudio,
      };

      for (final entry in mappedPorts.entries) {
        expect(
          MicAudioDeviceType.fromIosPortType(entry.key),
          entry.value,
          reason: 'iOS port type ${entry.key}',
        );
      }
    });

    test(
      'upgrades Headphones to a wired headset only when its input is listed',
      () {
        // A shared uid between the Headphones output and a listed input proves
        // the accessory carries a microphone.
        expect(
          MicAudioDeviceType.fromIosPortType('Headphones'),
          MicAudioDeviceType.headphones,
        );
        expect(
          MicAudioDeviceType.fromIosPortType(
            'Headphones',
            headphonesInputAvailable: true,
          ),
          MicAudioDeviceType.wiredHeadset,
        );

        // The flag is a no-op for every other port type.
        expect(
          MicAudioDeviceType.fromIosPortType(
            'BuiltInMic',
            headphonesInputAvailable: true,
          ),
          MicAudioDeviceType.builtInMic,
        );
      },
    );

    test('decodes unknown iOS port types to unknown', () {
      expect(
        MicAudioDeviceType.fromIosPortType('Thunderbolt'),
        MicAudioDeviceType.unknown,
      );
      expect(
        MicAudioDeviceType.fromIosPortType(''),
        MicAudioDeviceType.unknown,
      );
    });
  });

  group('MicAudioDevice', () {
    const device = MicAudioDevice(
      id: '15',
      name: 'Built-in mic',
      type: MicAudioDeviceType.builtInMic,
      isInput: true,
      isOutput: false,
    );

    test('round-trips its fields', () {
      expect(device.id, '15');
      expect(device.name, 'Built-in mic');
      expect(device.type, MicAudioDeviceType.builtInMic);
      expect(device.isInput, isTrue);
      expect(device.isOutput, isFalse);
    });

    test('equals devices with identical fields and hashes consistently', () {
      const twin = MicAudioDevice(
        id: '15',
        name: 'Built-in mic',
        type: MicAudioDeviceType.builtInMic,
        isInput: true,
        isOutput: false,
      );

      expect(device, twin);
      expect(twin, device);
      expect(device.hashCode, twin.hashCode);
    });

    test('distinguishes devices by any field', () {
      final others = <MicAudioDevice>[
        const MicAudioDevice(
          id: '7',
          name: 'Built-in mic',
          type: MicAudioDeviceType.builtInMic,
          isInput: true,
          isOutput: false,
        ),
        const MicAudioDevice(
          id: '15',
          name: 'Other mic',
          type: MicAudioDeviceType.builtInMic,
          isInput: true,
          isOutput: false,
        ),
        const MicAudioDevice(
          id: '15',
          name: 'Built-in mic',
          type: MicAudioDeviceType.usbAudio,
          isInput: true,
          isOutput: false,
        ),
        const MicAudioDevice(
          id: '15',
          name: 'Built-in mic',
          type: MicAudioDeviceType.builtInMic,
          isInput: false,
          isOutput: false,
        ),
        const MicAudioDevice(
          id: '15',
          name: 'Built-in mic',
          type: MicAudioDeviceType.builtInMic,
          isInput: true,
          isOutput: true,
        ),
      ];

      for (final other in others) {
        expect(device, isNot(other), reason: other.name);
      }
    });

    test('never equals a non-device', () {
      expect(device, isNot('15'));
    });

    test('formats itself for diagnostics', () {
      expect(
        device.toString(),
        'MicAudioDevice(id: 15, name: Built-in mic, '
        'type: MicAudioDeviceType.builtInMic, isInput: true, isOutput: false)',
      );
    });
  });

  group('MicAudioInput', () {
    const input = MicAudioInput(
      uid: 'input-0',
      portType: 'USBAudio',
      portName: 'USB mic',
    );

    test('round-trips its fields and derives its device type', () {
      expect(input.uid, 'input-0');
      expect(input.portType, 'USBAudio');
      expect(input.portName, 'USB mic');
      expect(input.type, MicAudioDeviceType.usbAudio);
    });

    test('equals inputs with identical fields and hashes consistently', () {
      const twin = MicAudioInput(
        uid: 'input-0',
        portType: 'USBAudio',
        portName: 'USB mic',
      );

      expect(input, twin);
      expect(input.hashCode, twin.hashCode);

      final others = <MicAudioInput>[
        const MicAudioInput(
          uid: 'input-1',
          portType: 'USBAudio',
          portName: 'USB mic',
        ),
        const MicAudioInput(
          uid: 'input-0',
          portType: 'BuiltInMic',
          portName: 'USB mic',
        ),
        const MicAudioInput(
          uid: 'input-0',
          portType: 'USBAudio',
          portName: 'Other mic',
        ),
      ];

      for (final other in others) {
        expect(input, isNot(other));
      }
    });

    test('formats itself for diagnostics', () {
      expect(
        input.toString(),
        'MicAudioInput(uid: input-0, portType: USBAudio, portName: USB mic)',
      );
    });
  });

  group('MicAudioRoute', () {
    const input = MicAudioInput(
      uid: 'u1',
      portType: 'BuiltInMic',
      portName: 'Mic',
    );

    test('defaults to the empty route (the OS decides)', () {
      const route = MicAudioRoute();

      expect(route.inputs, isEmpty);
      expect(route.outputs, isEmpty);
    });

    test('equals routes with identical port lists and hashes consistently', () {
      final route = MicAudioRoute(
        inputs: <MicAudioInput>[input],
        outputs: const <MicAudioInput>[],
      );
      final twin = MicAudioRoute(
        inputs: <MicAudioInput>[input],
        outputs: const <MicAudioInput>[],
      );

      expect(route, twin);
      expect(twin, route);
      expect(route.hashCode, twin.hashCode);

      expect(const MicAudioRoute(), const MicAudioRoute());
    });

    test('distinguishes routes by input or output ports', () {
      const speaker = MicAudioInput(
        uid: 'o1',
        portType: 'BuiltInSpeaker',
        portName: 'Speaker',
      );

      final route = MicAudioRoute(
        inputs: <MicAudioInput>[input],
        outputs: const <MicAudioInput>[],
      );

      // Different input list length.
      expect(route, isNot(const MicAudioRoute()));

      // Same length, a different element.
      expect(
        route,
        isNot(
          MicAudioRoute(
            inputs: const <MicAudioInput>[
              MicAudioInput(uid: 'u2', portType: 'BuiltInMic', portName: 'Mic'),
            ],
            outputs: const <MicAudioInput>[],
          ),
        ),
      );

      // Identical inputs, different outputs.
      expect(
        route,
        isNot(
          MicAudioRoute(
            inputs: <MicAudioInput>[input],
            outputs: <MicAudioInput>[speaker],
          ),
        ),
      );
    });

    test('formats itself for diagnostics', () {
      expect(
        const MicAudioRoute().toString(),
        'MicAudioRoute(inputs: [], outputs: [])',
      );
      expect(
        MicAudioRoute(
          inputs: <MicAudioInput>[input],
          outputs: const <MicAudioInput>[],
        ).toString(),
        'MicAudioRoute(inputs: '
        '[MicAudioInput(uid: u1, portType: BuiltInMic, portName: Mic)], '
        'outputs: [])',
      );
    });
  });

  group('MicAudioEncoder', () {
    test('pins every encoder wire name, container, bit rate and reach', () {
      // name → (container, default bit rate, required capture rate,
      // Android, iOS)
      const table = <String, (String, int?, int?, bool, bool)>{
        'aacLc': ('.m4a', 128000, null, true, true),
        'appleLossless': ('.m4a', null, null, false, true),
        'opus': ('.ogg', 24000, null, true, false),
        'flac': ('.flac', null, null, true, false),
        'amrNb': ('.amr', 12200, 8000, true, false),
        'amrWb': ('.amr', 23850, 16000, true, false),
      };

      // Exactly the six encoders exist — the table must not drift.
      expect(
        MicAudioEncoder.values.map((encoder) => encoder.name),
        unorderedEquals(table.keys),
      );

      for (final encoder in MicAudioEncoder.values) {
        final (extension, bitRate, requiredRate, onAndroid, onIos) =
            table[encoder.name]!;

        expect(
          encoder.wireName,
          encoder.name,
          reason: '${encoder.name} wire name',
        );
        expect(
          encoder.fileExtension,
          extension,
          reason: '${encoder.name} container',
        );
        expect(
          encoder.defaultBitRate,
          bitRate,
          reason: '${encoder.name} default bit rate',
        );
        expect(
          encoder.requiredSampleRate,
          requiredRate,
          reason: '${encoder.name} required capture rate',
        );
        expect(encoder.android, onAndroid, reason: '${encoder.name} Android');
        expect(encoder.ios, onIos, reason: '${encoder.name} iOS');
        expect(
          encoder.isSupportedOn(android: true, ios: false),
          onAndroid,
          reason: '${encoder.name} on Android',
        );
        expect(
          encoder.isSupportedOn(android: false, ios: true),
          onIos,
          reason: '${encoder.name} on iOS',
        );
      }

      // Wire names stay unique so the natives can decode them unambiguously.
      expect(
        MicAudioEncoder.values.map((encoder) => encoder.wireName).toSet(),
        hasLength(MicAudioEncoder.values.length),
      );
    });

    test('isSupportedOn defers to the iOS reach on an unknown platform', () {
      // Neither flag set: it is not Android, so the iOS availability decides.
      expect(
        MicAudioEncoder.aacLc.isSupportedOn(android: false, ios: false),
        isTrue,
      );
      expect(
        MicAudioEncoder.opus.isSupportedOn(android: false, ios: false),
        isFalse,
      );
    });

    test('round-trips enum names', () {
      for (final encoder in MicAudioEncoder.values) {
        expect(MicAudioEncoder.values.byName(encoder.name), same(encoder));
      }
    });

    test('formats as a documented enum tag', () {
      expect(MicAudioEncoder.aacLc.toString(), 'MicAudioEncoder.aacLc (aacLc)');
    });
  });

  group('MicAudioInterruption', () {
    test('enumerates the classified causes', () {
      expect(MicAudioInterruptionType.values, <MicAudioInterruptionType>[
        MicAudioInterruptionType.unknown,
        MicAudioInterruptionType.pause,
        MicAudioInterruptionType.duck,
      ]);
    });

    test('round-trips begin and type', () {
      const interruption = MicAudioInterruption(
        begin: true,
        type: MicAudioInterruptionType.duck,
      );

      expect(interruption.begin, isTrue);
      expect(interruption.type, MicAudioInterruptionType.duck);
    });

    test('formats itself for diagnostics', () {
      expect(
        const MicAudioInterruption(
          begin: false,
          type: MicAudioInterruptionType.pause,
        ).toString(),
        'MicAudioInterruption(begin: false, type: '
        'MicAudioInterruptionType.pause)',
      );
    });
  });

  group('MicRecorderState', () {
    test('enumerates the four states in order', () {
      expect(MicRecorderState.values, <MicRecorderState>[
        MicRecorderState.recording,
        MicRecorderState.paused,
        MicRecorderState.stopped,
        MicRecorderState.error,
      ]);
    });

    test('isActive only while an episode is in progress', () {
      expect(MicRecorderState.recording.isActive, isTrue);
      expect(MicRecorderState.paused.isActive, isTrue);
      expect(MicRecorderState.stopped.isActive, isFalse);
      expect(MicRecorderState.error.isActive, isFalse);
    });

    test('isRecording and isPaused are exclusive per state', () {
      for (final state in MicRecorderState.values) {
        expect(
          state.isRecording,
          state == MicRecorderState.recording,
          reason: state.name,
        );
        expect(
          state.isPaused,
          state == MicRecorderState.paused,
          reason: state.name,
        );
        expect(
          state.isRecording && state.isPaused,
          isFalse,
          reason: state.name,
        );
      }
    });
  });

  group('MicRecordingFileFormat', () {
    test('enumerates the raw and container formats', () {
      expect(MicRecordingFileFormat.values, <MicRecordingFileFormat>[
        MicRecordingFileFormat.pcm16,
        MicRecordingFileFormat.wav,
      ]);
    });

    test('uses its enum name as the wire name', () {
      expect(MicRecordingFileFormat.pcm16.wireName, 'pcm16');
      expect(MicRecordingFileFormat.wav.wireName, 'wav');
    });
  });

  group('MicRecordingInfo', () {
    test('round-trips every episode field', () {
      final startedAt = DateTime.utc(2024, 1, 2, 3, 4, 5);

      final info = MicRecordingInfo(
        startedAtUtc: startedAt,
        duration: const Duration(seconds: 10),
        sizeBytes: 320000,
        sampleRate: 16000,
        bitDepth: 16,
        channels: 1,
        stopReason: MicRecordingStopReason.maxDurationReached,
        path: '/tmp/episode.m4a',
        encoder: MicAudioEncoder.aacLc,
        fileFormat: MicRecordingFileFormat.wav,
      );

      expect(info.startedAtUtc, startedAt);
      expect(info.duration, const Duration(seconds: 10));
      expect(info.sizeBytes, 320000);
      expect(info.sampleRate, 16000);
      expect(info.bitDepth, 16);
      expect(info.channels, 1);
      expect(info.stopReason, MicRecordingStopReason.maxDurationReached);
      expect(info.path, '/tmp/episode.m4a');
      expect(info.encoder, MicAudioEncoder.aacLc);
      expect(info.fileFormat, MicRecordingFileFormat.wav);
    });

    test('defaults to a manual stop with no file artifacts', () {
      final info = MicRecordingInfo(
        startedAtUtc: DateTime.utc(2024, 1, 2),
        duration: Duration.zero,
        sizeBytes: 0,
        sampleRate: 16000,
        bitDepth: 16,
        channels: 1,
      );

      expect(info.stopReason, MicRecordingStopReason.manual);
      expect(info.path, isNull);
      expect(info.encoder, isNull);
      expect(info.fileFormat, isNull);
    });

    test('formats every field into its toString', () {
      final streamOnly = MicRecordingInfo(
        startedAtUtc: DateTime.utc(2024, 1, 2, 3, 4, 5),
        duration: const Duration(seconds: 10),
        sizeBytes: 320000,
        sampleRate: 16000,
        bitDepth: 16,
        channels: 1,
      );

      expect(
        streamOnly.toString(),
        'MicRecordingInfo(startedAtUtc: 2024-01-02 03:04:05.000Z, '
        'duration: 0:00:10.000000, sizeBytes: 320000, path: null, '
        'encoder: null, fileFormat: null, '
        'stopReason: MicRecordingStopReason.manual, sampleRate: 16000, '
        'bitDepth: 16, channels: 1)',
      );

      final encoded = MicRecordingInfo(
        startedAtUtc: DateTime.utc(2024, 1, 2, 3, 4, 5),
        duration: const Duration(seconds: 10),
        sizeBytes: 160000,
        sampleRate: 16000,
        bitDepth: 16,
        channels: 1,
        stopReason: MicRecordingStopReason.maxDurationReached,
        path: '/tmp/episode.wav',
        encoder: MicAudioEncoder.aacLc,
        fileFormat: MicRecordingFileFormat.wav,
      );

      expect(
        encoded.toString(),
        'MicRecordingInfo(startedAtUtc: 2024-01-02 03:04:05.000Z, '
        'duration: 0:00:10.000000, sizeBytes: 160000, '
        'path: /tmp/episode.wav, encoder: MicAudioEncoder.aacLc (aacLc), '
        'fileFormat: MicRecordingFileFormat.wav, '
        'stopReason: MicRecordingStopReason.maxDurationReached, '
        'sampleRate: 16000, bitDepth: 16, channels: 1)',
      );
    });
  });

  group('MicRecordingMode', () {
    test('enumerates conversation and voiceCommand', () {
      expect(MicRecordingMode.values, <MicRecordingMode>[
        MicRecordingMode.conversation,
        MicRecordingMode.voiceCommand,
      ]);
    });
  });

  group('MicAudioSourceKind', () {
    test('pins the wire name of every source kind', () {
      const wireNames = <MicAudioSourceKind, String>{
        MicAudioSourceKind.usbWired: 'usb-wired',
        MicAudioSourceKind.bluetooth: 'bluetooth',
        MicAudioSourceKind.defaultMicrophone: 'default-microphone',
        MicAudioSourceKind.systemDefault: 'system-default',
      };

      expect(wireNames.keys.toSet(), MicAudioSourceKind.values.toSet());

      for (final entry in wireNames.entries) {
        expect(entry.key.wireName, entry.value, reason: entry.key.name);
      }

      // Wire names stay unique so consecutive routing decisions compare
      // cleanly in logs.
      expect(
        MicAudioSourceKind.values.map((kind) => kind.wireName).toSet(),
        hasLength(MicAudioSourceKind.values.length),
      );
    });
  });

  group('MicAudioSourceSwitchedEvent', () {
    test('round-trips every field', () {
      const event = MicAudioSourceSwitchedEvent(
        sourceKind: MicAudioSourceKind.bluetooth,
        previousSourceKind: MicAudioSourceKind.defaultMicrophone,
        sourceName: 'Pixel Buds',
        reason: 'device-change',
        switchingEnabled: true,
      );

      expect(event.sourceKind, MicAudioSourceKind.bluetooth);
      expect(event.previousSourceKind, MicAudioSourceKind.defaultMicrophone);
      expect(event.sourceName, 'Pixel Buds');
      expect(event.reason, 'device-change');
      expect(event.switchingEnabled, isTrue);
    });

    test('defaults previousSourceKind and sourceName to null', () {
      const event = MicAudioSourceSwitchedEvent(
        sourceKind: MicAudioSourceKind.usbWired,
        reason: 'prepare',
        switchingEnabled: false,
      );

      expect(event.previousSourceKind, isNull);
      expect(event.sourceName, isNull);
    });

    test('formats every field into its toString', () {
      const event = MicAudioSourceSwitchedEvent(
        sourceKind: MicAudioSourceKind.usbWired,
        reason: 'prepare',
        switchingEnabled: false,
      );

      expect(
        event.toString(),
        'MicAudioSourceSwitchedEvent(sourceKind: '
        'MicAudioSourceKind.usbWired, previousSourceKind: null, '
        'sourceName: null, reason: prepare, switchingEnabled: false)',
      );
    });
  });

  group('MicConversationSilenceEvent', () {
    test('round-trips every field including the optional route state', () {
      final startedAt = DateTime.utc(2024, 6, 1, 12);

      final event = MicConversationSilenceEvent(
        startedAtUtc: startedAt,
        duration: const Duration(minutes: 5),
        lastRms: 0.0025,
        silenceThreshold: 0.01,
        bytesCapturedSinceStart: 9600000,
        buffersCapturedSinceStart: 3000,
        silenceRecoveryAttempts: 2,
        routeState: const <String, Object?>{'usb': 'wired'},
      );

      expect(event.startedAtUtc, startedAt);
      expect(event.duration, const Duration(minutes: 5));
      expect(event.lastRms, 0.0025);
      expect(event.silenceThreshold, 0.01);
      expect(event.bytesCapturedSinceStart, 9600000);
      expect(event.buffersCapturedSinceStart, 3000);
      expect(event.silenceRecoveryAttempts, 2);
      expect(event.routeState, const <String, Object?>{'usb': 'wired'});
    });

    test('defaults the route state to null', () {
      final event = MicConversationSilenceEvent(
        startedAtUtc: DateTime.utc(2024, 6, 1, 12),
        duration: const Duration(minutes: 5),
        lastRms: 0.0025,
        silenceThreshold: 0.01,
        bytesCapturedSinceStart: 9600000,
        buffersCapturedSinceStart: 3000,
        silenceRecoveryAttempts: 2,
      );

      expect(event.routeState, isNull);
    });

    test('formats every field into its toString', () {
      final event = MicConversationSilenceEvent(
        startedAtUtc: DateTime.utc(2024, 6, 1, 12),
        duration: const Duration(minutes: 5),
        lastRms: 0.0025,
        silenceThreshold: 0.01,
        bytesCapturedSinceStart: 9600000,
        buffersCapturedSinceStart: 3000,
        silenceRecoveryAttempts: 2,
      );

      expect(
        event.toString(),
        'MicConversationSilenceEvent(startedAtUtc: 2024-06-01 12:00:00.000Z, '
        'duration: 0:05:00.000000, lastRms: 0.0025, silenceThreshold: 0.01, '
        'bytesCapturedSinceStart: 9600000, buffersCapturedSinceStart: 3000, '
        'silenceRecoveryAttempts: 2, routeState: null)',
      );
    });
  });

  group('MicMicrophoneLostEvent', () {
    test('round-trips reason and detection time', () {
      final occurredAt = DateTime.utc(2024, 6, 1, 12);

      final event = MicMicrophoneLostEvent(
        reason: 'unknown-interruption',
        occurredAtUtc: occurredAt,
      );

      expect(event.reason, 'unknown-interruption');
      expect(event.occurredAtUtc, occurredAt);
    });

    test('defaults the detection time to null', () {
      const event = MicMicrophoneLostEvent(reason: 'unknown-interruption');

      expect(event.occurredAtUtc, isNull);
    });

    test('formats itself for diagnostics', () {
      expect(
        const MicMicrophoneLostEvent(reason: 'unknown-interruption').toString(),
        'MicMicrophoneLostEvent(reason: unknown-interruption, '
        'occurredAtUtc: null)',
      );
    });
  });

  group('MicAndroidAudioFocus', () {
    test('pins the raw AudioManager focus codes', () {
      expect(MicAndroidAudioFocus.gain, 1);
      expect(MicAndroidAudioFocus.loss, -1);
      expect(MicAndroidAudioFocus.lossTransient, -2);
      expect(MicAndroidAudioFocus.lossTransientCanDuck, -3);
    });
  });

  group('MicIosRouteChangeReason', () {
    test('pins the raw AVAudioSession route-change reasons', () {
      // Reason 5 has no constant here — unmapped raw codes stay lossless ints.
      expect(MicIosRouteChangeReason.unknown, 0);
      expect(MicIosRouteChangeReason.newDeviceAvailable, 1);
      expect(MicIosRouteChangeReason.oldDeviceUnavailable, 2);
      expect(MicIosRouteChangeReason.categoryChange, 3);
      expect(MicIosRouteChangeReason.override, 4);
      expect(MicIosRouteChangeReason.wakeFromSleep, 6);
      expect(MicIosRouteChangeReason.routeConfigurationChange, 7);
    });
  });

  group('MicSessionEvent family', () {
    test('MicAndroidAudioFocusChanged carries the raw focus code', () {
      const event = MicAndroidAudioFocusChanged(
        focus: MicAndroidAudioFocus.lossTransient,
      );

      expect(event, isA<MicSessionEvent>());
      expect(event.focus, -2);
      expect(event.toString(), 'MicAndroidAudioFocusChanged(focus: -2)');
    });

    test('MicAndroidDevicesChanged carries added and removed devices', () {
      const device = MicAudioDevice(
        id: '11',
        name: 'USB mic',
        type: MicAudioDeviceType.usbAudio,
        isInput: true,
        isOutput: false,
      );

      const event = MicAndroidDevicesChanged(
        added: <MicAudioDevice>[device],
        removed: <MicAudioDevice>[],
      );

      expect(event, isA<MicSessionEvent>());
      expect(event.added, <MicAudioDevice>[device]);
      expect(event.removed, isEmpty);
      expect(
        event.toString(),
        'MicAndroidDevicesChanged(added: '
        '[MicAudioDevice(id: 11, name: USB mic, '
        'type: MicAudioDeviceType.usbAudio, isInput: true, isOutput: false)], '
        'removed: [])',
      );
    });

    test('MicIosInterruptionNotification carries the interruption details', () {
      const began = MicIosInterruptionNotification(
        began: true,
        shouldResume: false,
        wasSuspended: false,
      );

      expect(began, isA<MicSessionEvent>());
      expect(began.began, isTrue);
      expect(began.shouldResume, isFalse);
      expect(began.wasSuspended, isFalse);

      const ended = MicIosInterruptionNotification(
        began: false,
        shouldResume: true,
      );

      expect(ended.wasSuspended, isNull);
      expect(
        ended.toString(),
        'MicIosInterruptionNotification(began: false, shouldResume: true, '
        'wasSuspended: null)',
      );
    });

    test('MicIosRouteChange carries the raw reason code', () {
      const event = MicIosRouteChange(
        reason: MicIosRouteChangeReason.oldDeviceUnavailable,
      );

      expect(event, isA<MicSessionEvent>());
      expect(event.reason, 2);
      expect(event.toString(), 'MicIosRouteChange(reason: 2)');
    });
  });
}
