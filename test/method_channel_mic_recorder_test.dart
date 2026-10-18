import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mic_recorder/src/config/mic_audio_session_config.dart';
import 'package:mic_recorder/src/models/mic_audio_device.dart';
import 'package:mic_recorder/src/models/mic_audio_encoder.dart';
import 'package:mic_recorder/src/models/mic_session_events.dart';
import 'package:mic_recorder/src/platform/method_channel_mic_recorder.dart';
import 'package:mic_recorder/src/platform/mic_recorder_platform.dart';

import 'fake_mic_recorder_platform.dart';

const MethodChannel _methodsChannel = MethodChannel(
  'com.bilalahmed24.mic_recorder/methods',
);

const EventChannel _sessionEventsChannel = EventChannel(
  'com.bilalahmed24.mic_recorder/session_events',
);

const EventChannel _audioStreamChannel = EventChannel(
  'com.bilalahmed24.mic_recorder/audio_stream',
);

/// Records every method call sent to the methods channel and replies with
/// the scripted [replies] (falling back to a null reply).
final class MethodCallRecorder {
  final calls = <MethodCall>[];

  /// Scripted replies by method name.
  final Map<String, Object?> replies = {};

  /// Scripted errors by method name (thrown to the caller).
  final Map<String, Exception> errors = {};

  Future<Object?>? onCall(MethodCall call) {
    calls.add(call);

    final error = errors[call.method];
    if (error != null) throw error;

    return Future<Object?>.value(replies[call.method]);
  }

  List<String> get methodNames => <String>[
    for (final call in calls) call.method,
  ];

  MethodCall operator [](String method) =>
      calls.firstWhere((call) => call.method == method);
}

/// A [MicRecorderPlatform] with no overrides — used to exercise the
/// interface's default `UnimplementedError` guards.
final class BareMicRecorderPlatform extends MicRecorderPlatform {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger = TestWidgetsFlutterBinding.instance.defaultBinaryMessenger;

  late MethodCallRecorder recorder;

  setUp(() {
    recorder = MethodCallRecorder();
    messenger.setMockMethodCallHandler(_methodsChannel, recorder.onCall);
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(_methodsChannel, null);
  });

  group('MicRecorderPlatform', () {
    test('instance is a stable singleton by default', () {
      final first = MicRecorderPlatform.instance;
      final second = MicRecorderPlatform.instance;

      expect(second, same(first));
    });

    test('default implementation replies with benign values', () async {
      final platform = MicRecorderPlatform.instance;

      expect(await platform.startRecording(16000), isTrue);
      expect(await platform.pauseRecording(false), isTrue);
      expect(await platform.resumeRecording(), isTrue);
      expect(await platform.stopRecording(), isTrue);
      expect(await platform.microphoneInterrupted(), isTrue);
      expect(await platform.setAudioSessionActive(false), isTrue);
      expect(await platform.isOtherAudioPlaying(), isFalse);
      expect(await platform.isMusicActive(), isFalse);
      expect(await platform.getAudioMode(), 0);
      expect(
        await platform.setPreferredInput(
          const MicAudioInput(
            uid: 'u',
            portType: 'BuiltInMic',
            portName: 'Mic',
          ),
        ),
        isFalse,
      );
      expect(await platform.getRouteState(), isNull);
      expect(await platform.extractAmplitudes(filePath: '/none.pcm'), isNull);
      expect(await platform.getAudioDevices(), isEmpty);
      expect(await platform.getAvailableInputs(), isEmpty);

      final route = await platform.getCurrentRoute();
      expect(route.inputs, isEmpty);
      expect(route.outputs, isEmpty);

      await expectLater(platform.audioDataStream(), emitsDone);

      final sessionEvents = <MicSessionEvent>[];
      final subscription = platform.sessionEvents().listen(sessionEvents.add);
      await pumpEventQueue();

      expect(sessionEvents, isEmpty);

      await subscription.cancel();
    });

    test(
      'base class verbs throw UnimplementedError when not overridden',
      () async {
        final bare = BareMicRecorderPlatform();

        Future<void> expectUnimplemented(Object? Function() call) async {
          await expectLater(call, throwsA(isA<UnimplementedError>()));
        }

        await expectUnimplemented(() => bare.startRecording(16000));
        await expectUnimplemented(() => bare.pauseRecording(false));
        await expectUnimplemented(bare.resumeRecording);
        await expectUnimplemented(bare.stopRecording);
        await expectUnimplemented(bare.microphoneInterrupted);
        await expectUnimplemented(bare.audioDataStream);
        await expectUnimplemented(() => bare.setBluetoothStatus(true));
        await expectUnimplemented(bare.getRouteState);
        await expectUnimplemented(
          () => bare.extractAmplitudes(filePath: '/none.pcm'),
        );
        await expectUnimplemented(
          () => bare.configureAudioSession(const MicAudioSessionConfig()),
        );
        await expectUnimplemented(() => bare.setAudioSessionActive(false));
        await expectUnimplemented(bare.isOtherAudioPlaying);
        await expectUnimplemented(bare.isMusicActive);
        await expectUnimplemented(bare.getAudioMode);
        await expectUnimplemented(
          () => bare.setAllowHapticsAndSystemSoundsDuringRecording(false),
        );
        await expectUnimplemented(bare.getAudioDevices);
        await expectUnimplemented(bare.getAvailableInputs);
        await expectUnimplemented(bare.getCurrentRoute);
        await expectUnimplemented(
          () => bare.setPreferredInput(
            const MicAudioInput(
              uid: 'u',
              portType: 'BuiltInMic',
              portName: 'Mic',
            ),
          ),
        );
        await expectUnimplemented(bare.sessionEvents);
        await expectUnimplemented(() => bare.showForegroundNotification('T'));
        await expectUnimplemented(bare.removeForegroundNotification);
      },
    );

    test('instance swap routes calls to the fake and back', () async {
      final original = MicRecorderPlatform.instance;

      final fake = FakeMicRecorderPlatform();
      MicRecorderPlatform.instance = fake;

      expect(await MicRecorderPlatform.instance.startRecording(8000), isTrue);
      expect(fake.startRecordingCalls, <int>[8000]);

      MicRecorderPlatform.instance = original;

      expect(await MicRecorderPlatform.instance.startRecording(9000), isTrue);
      expect(fake.startRecordingCalls, <int>[8000]);

      await fake.dispose();
    });
  });

  group('MethodChannelMicRecorder capture verbs', () {
    test('startRecording sends the sample rate and effect toggles', () async {
      recorder.replies['startRecording'] = true;

      final platform = MethodChannelMicRecorder();

      expect(
        await platform.startRecording(
          44100,
          androidEchoCancel: true,
          androidNoiseSuppress: true,
          androidAutoGain: true,
        ),
        isTrue,
      );
      expect(recorder['startRecording'].arguments, <String, Object?>{
        'sampleRate': 44100,
        'echoCancel': true,
        'noiseSuppress': true,
        'autoGain': true,
      });
    });

    test('startRecording defaults the effect toggles to false', () async {
      final platform = MethodChannelMicRecorder();

      expect(await platform.startRecording(16000), isFalse);
      expect(recorder['startRecording'].arguments, <String, Object?>{
        'sampleRate': 16000,
        'echoCancel': false,
        'noiseSuppress': false,
        'autoGain': false,
      });
    });

    test('startRecording maps a null reply to false', () async {
      final platform = MethodChannelMicRecorder();

      expect(await platform.startRecording(16000), isFalse);
    });

    test('pauseRecording sends the interruption flag', () async {
      recorder.replies['pauseRecording'] = false;

      final platform = MethodChannelMicRecorder();

      expect(await platform.pauseRecording(true), isFalse);
      expect(recorder['pauseRecording'].arguments, <String, Object?>{
        'isPausedForInterruption': true,
      });
    });

    test('resume/stop/microphoneInterrupted take no arguments', () async {
      recorder.replies['resumeRecording'] = true;
      recorder.replies['stopRecording'] = true;
      recorder.replies['microphoneInterrupted'] = false;

      final platform = MethodChannelMicRecorder();

      expect(await platform.resumeRecording(), isTrue);
      expect(await platform.stopRecording(), isTrue);
      expect(await platform.microphoneInterrupted(), isFalse);

      expect(recorder['resumeRecording'].arguments, isNull);
      expect(recorder['stopRecording'].arguments, isNull);
      expect(recorder['microphoneInterrupted'].arguments, isNull);
      expect(recorder.methodNames, <String>[
        'resumeRecording',
        'stopRecording',
        'microphoneInterrupted',
      ]);
    });

    test('audioDataStream taps the audio_stream EventChannel', () async {
      MockStreamHandlerEventSink? sink;

      messenger.setMockStreamHandler(
        _audioStreamChannel,
        MockStreamHandler.inline(onListen: (_, events) => sink = events),
      );

      final platform = MethodChannelMicRecorder();

      final chunks = <List<int>>[];
      final subscription = platform.audioDataStream().listen(chunks.add);
      await pumpEventQueue();

      sink!.success(Uint8List.fromList(<int>[1, 2, 3]));
      await pumpEventQueue();

      expect(chunks, hasLength(1));
      expect(chunks.single, <int>[1, 2, 3]);

      await subscription.cancel();
      messenger.setMockStreamHandler(_audioStreamChannel, null);
    });
  });

  group('MethodChannelMicRecorder encoded output and permissions', () {
    test(
      'setEncodedOutput sends path, encoder, bitRate and sampleRate',
      () async {
        recorder.replies['setEncodedOutput'] = true;

        final platform = MethodChannelMicRecorder();

        expect(
          await platform.setEncodedOutput(
            '/tmp/rec.m4a',
            MicAudioEncoder.aacLc,
            bitRate: 96000,
            sampleRate: 44100,
          ),
          isTrue,
        );
        expect(recorder['setEncodedOutput'].arguments, <String, Object?>{
          'path': '/tmp/rec.m4a',
          'encoder': 'aacLc',
          'bitRate': 96000,
          'sampleRate': 44100,
        });
      },
    );

    test(
      'setEncodedOutput omits null optionals and maps false replies',
      () async {
        recorder.replies['setEncodedOutput'] = false;

        final platform = MethodChannelMicRecorder();

        expect(
          await platform.setEncodedOutput('/tmp/rec.ogg', MicAudioEncoder.opus),
          isFalse,
        );
        expect(recorder['setEncodedOutput'].arguments, <String, Object?>{
          'path': '/tmp/rec.ogg',
          'encoder': 'opus',
        });
      },
    );

    test('clearEncodedOutput takes no arguments', () async {
      recorder.replies['clearEncodedOutput'] = true;

      final platform = MethodChannelMicRecorder();

      expect(await platform.clearEncodedOutput(), isTrue);
      expect(recorder['clearEncodedOutput'].arguments, isNull);
    });

    test('checkMicPermission decodes the grant', () async {
      recorder.replies['checkMicPermission'] = true;

      final platform = MethodChannelMicRecorder();

      expect(await platform.checkMicPermission(), isTrue);
      expect(recorder['checkMicPermission'].arguments, isNull);
    });

    test('requestMicPermission maps a null reply to false', () async {
      final platform = MethodChannelMicRecorder();

      expect(await platform.requestMicPermission(), isFalse);
    });
  });

  group('MethodChannelMicRecorder routing verbs', () {
    test('setBluetoothStatus sends the isAllowed flag', () async {
      final platform = MethodChannelMicRecorder();

      await platform.setBluetoothStatus(false);

      expect(recorder['setBluetoothStatus'].arguments, <String, Object?>{
        'isAllowed': false,
      });
    });

    test('getRouteState decodes the native map', () async {
      recorder.replies['getRouteState'] = <String, Object?>{
        'scoConnected': true,
        'bluetoothHeadsetConnected': false,
      };

      final platform = MethodChannelMicRecorder();

      expect(await platform.getRouteState(), <String, Object?>{
        'scoConnected': true,
        'bluetoothHeadsetConnected': false,
      });
      expect(recorder['getRouteState'].arguments, isNull);
    });

    test('getRouteState maps a PlatformException to null', () async {
      recorder.errors['getRouteState'] = PlatformException(
        code: 'mic_recorder_error',
        message: 'route state unavailable',
      );

      final platform = MethodChannelMicRecorder();

      expect(await platform.getRouteState(), isNull);
    });

    test('getRouteState maps a null reply to null', () async {
      final platform = MethodChannelMicRecorder();

      expect(await platform.getRouteState(), isNull);
    });

    test('extractAmplitudes sends path and bar count', () async {
      recorder.replies['extractAmplitudes'] = <num>[0.1, 0.5, 1.0];

      final platform = MethodChannelMicRecorder();

      expect(
        await platform.extractAmplitudes(filePath: '/audio.pcm', barCount: 30),
        <double>[0.1, 0.5, 1.0],
      );
      expect(recorder['extractAmplitudes'].arguments, <String, Object?>{
        'filePath': '/audio.pcm',
        'barCount': 30,
      });
    });

    test('extractAmplitudes defaults to 60 bars and null replies', () async {
      final platform = MethodChannelMicRecorder();

      expect(await platform.extractAmplitudes(filePath: '/audio.pcm'), isNull);
      expect(recorder['extractAmplitudes'].arguments, <String, Object?>{
        'filePath': '/audio.pcm',
        'barCount': 60,
      });
    });

    test('extractAmplitudes maps a PlatformException to null', () async {
      recorder.errors['extractAmplitudes'] = PlatformException(
        code: 'EXTRACTION_FAILED',
      );

      final platform = MethodChannelMicRecorder();

      expect(await platform.extractAmplitudes(filePath: '/audio.pcm'), isNull);
    });
  });

  group('MethodChannelMicRecorder session verbs', () {
    test('configureAudioSession sends the config map', () async {
      final platform = MethodChannelMicRecorder();

      await platform.configureAudioSession(
        const MicAudioSessionConfig(
          allowBluetooth: false,
          defaultToSpeaker: false,
          notifyOthersOnDeactivation: false,
          androidWillPauseWhenDucked: false,
        ),
      );

      expect(recorder['configureAudioSession'].arguments, <String, Object?>{
        'config': <String, Object?>{
          'allowBluetooth': false,
          'defaultToSpeaker': false,
          'notifyOthersOnDeactivation': false,
          'willPauseWhenDucked': false,
        },
      });
    });

    test('setAudioSessionActive sends the active flag', () async {
      recorder.replies['setAudioSessionActive'] = false;

      final platform = MethodChannelMicRecorder();

      expect(await platform.setAudioSessionActive(false), isFalse);
      expect(recorder['setAudioSessionActive'].arguments, <String, Object?>{
        'active': false,
      });
    });

    test('isOtherAudioPlaying and isMusicActive decode bools', () async {
      recorder.replies['isOtherAudioPlaying'] = true;
      recorder.replies['isMusicActive'] = true;

      final platform = MethodChannelMicRecorder();

      expect(await platform.isOtherAudioPlaying(), isTrue);
      expect(await platform.isMusicActive(), isTrue);

      recorder.replies.clear();

      expect(await platform.isOtherAudioPlaying(), isFalse);
      expect(await platform.isMusicActive(), isFalse);
    });

    test('getAudioMode decodes ints and defaults to 0', () async {
      recorder.replies['getAudioMode'] = 2;

      final platform = MethodChannelMicRecorder();

      expect(await platform.getAudioMode(), 2);

      recorder.replies.clear();

      expect(await platform.getAudioMode(), 0);
    });

    test('setAllowHaptics sends the enabled flag', () async {
      final platform = MethodChannelMicRecorder();

      await platform.setAllowHapticsAndSystemSoundsDuringRecording(false);

      expect(
        recorder['setAllowHapticsAndSystemSoundsDuringRecording'].arguments,
        <String, Object?>{'enabled': false},
      );
    });
  });

  group('MethodChannelMicRecorder foreground service verbs', () {
    test('showForegroundNotification omits null optional fields', () async {
      recorder.replies['showForegroundNotification'] = true;

      final platform = MethodChannelMicRecorder();

      expect(await platform.showForegroundNotification('Recording...'), isTrue);

      expect(
        recorder['showForegroundNotification'].arguments,
        <String, Object?>{'notificationTitle': 'Recording...'},
      );
    });

    test('showForegroundNotification sends every configured field', () async {
      recorder.replies['showForegroundNotification'] = true;

      final platform = MethodChannelMicRecorder();

      expect(
        await platform.showForegroundNotification(
          'Listening...',
          channelName: 'My channel',
          channelDescription: 'My description',
          icon: 'ic_stat_mic',
        ),
        isTrue,
      );

      expect(
        recorder['showForegroundNotification'].arguments,
        <String, Object?>{
          'notificationTitle': 'Listening...',
          'channelName': 'My channel',
          'channelDescription': 'My description',
          'icon': 'ic_stat_mic',
        },
      );
    });

    test('showForegroundNotification maps a failed start to false', () async {
      final platform = MethodChannelMicRecorder();

      expect(await platform.showForegroundNotification('T'), isFalse);
    });

    test('removeForegroundNotification takes no arguments', () async {
      recorder.replies['removeForegroundNotification'] = false;

      final platform = MethodChannelMicRecorder();

      expect(await platform.removeForegroundNotification(), isFalse);
      expect(recorder['removeForegroundNotification'].arguments, isNull);
    });
  });

  group('MethodChannelMicRecorder iOS inputs and routes', () {
    test('getAvailableInputs decodes port descriptions', () async {
      recorder.replies['getAvailableInputs'] = <Object?>[
        <String, Object?>{
          'uid': 'input-0',
          'portType': 'BuiltInMic',
          'portName': 'iPhone Microphone',
        },
        <String, Object?>{
          'uid': 'input-1',
          'portType': 'BluetoothHFP',
          'portName': 'Pixel Buds',
        },
      ];

      final platform = MethodChannelMicRecorder();

      expect(await platform.getAvailableInputs(), <MicAudioInput>[
        const MicAudioInput(
          uid: 'input-0',
          portType: 'BuiltInMic',
          portName: 'iPhone Microphone',
        ),
        const MicAudioInput(
          uid: 'input-1',
          portType: 'BluetoothHFP',
          portName: 'Pixel Buds',
        ),
      ]);
    });

    test('getAvailableInputs decodes a null reply to an empty list', () async {
      final platform = MethodChannelMicRecorder();

      expect(await platform.getAvailableInputs(), isEmpty);
    });

    test('getCurrentRoute decodes inputs and outputs', () async {
      recorder.replies['getCurrentRoute'] = <String, Object?>{
        'inputs': <Object?>[
          <String, Object?>{
            'uid': 'in-1',
            'portType': 'HeadsetMic',
            'portName': 'Wired headset',
          },
        ],
        'outputs': <Object?>[
          <String, Object?>{
            'uid': 'out-1',
            'portType': 'Headphones',
            'portName': 'Wired headphones',
          },
        ],
      };

      final platform = MethodChannelMicRecorder();

      final route = await platform.getCurrentRoute();

      expect(route.inputs.single.uid, 'in-1');
      expect(route.inputs.single.portType, 'HeadsetMic');
      expect(route.outputs.single.portName, 'Wired headphones');
      expect(recorder['getCurrentRoute'].arguments, isNull);
    });

    test('getCurrentRoute decodes a null reply to an empty route', () async {
      final platform = MethodChannelMicRecorder();

      final route = await platform.getCurrentRoute();

      expect(route.inputs, isEmpty);
      expect(route.outputs, isEmpty);
    });

    test('setPreferredInput sends the uid', () async {
      recorder.replies['setPreferredInput'] = true;

      final platform = MethodChannelMicRecorder();

      expect(
        await platform.setPreferredInput(
          const MicAudioInput(
            uid: 'input-1',
            portType: 'USBAudio',
            portName: 'USB mic',
          ),
        ),
        isTrue,
      );

      expect(recorder['setPreferredInput'].arguments, <String, Object?>{
        'uid': 'input-1',
      });
    });

    test(
      'getAudioDevices composes the iOS snapshot from route + inputs',
      () async {
        recorder.replies['getCurrentRoute'] = <String, Object?>{
          'inputs': <Object?>[
            <String, Object?>{
              'uid': 'wired',
              'portType': 'HeadsetMic',
              'portName': 'Wired headset',
            },
          ],
          'outputs': <Object?>[
            <String, Object?>{
              'uid': 'wired',
              'portType': 'Headphones',
              'portName': 'Wired headphones',
            },
            <String, Object?>{
              'uid': 'speaker',
              'portType': 'BuiltInSpeaker',
              'portName': 'iPhone Speaker',
            },
          ],
        };
        recorder.replies['getAvailableInputs'] = <Object?>[
          <String, Object?>{
            'uid': 'wired',
            'portType': 'HeadsetMic',
            'portName': 'Wired headset',
          },
          <String, Object?>{
            'uid': 'builtin',
            'portType': 'BuiltInMic',
            'portName': 'iPhone Microphone',
          },
        ];

        final platform = MethodChannelMicRecorder();

        expect(await platform.getAudioDevices(), <MicAudioDevice>{
          // Available inputs are inputs; the headset doubles as an output
          // (its uid appears in the route outputs) — hence input/output, and
          // the Headphones OUTPUT upgrades to wiredHeadset because its uid is
          // also an input uid.
          const MicAudioDevice(
            id: 'wired',
            name: 'Wired headset',
            type: MicAudioDeviceType.wiredHeadset,
            isInput: true,
            isOutput: true,
          ),
          const MicAudioDevice(
            id: 'builtin',
            name: 'iPhone Microphone',
            type: MicAudioDeviceType.builtInMic,
            isInput: true,
            isOutput: false,
          ),
          const MicAudioDevice(
            id: 'speaker',
            name: 'iPhone Speaker',
            type: MicAudioDeviceType.builtInSpeaker,
            isInput: false,
            isOutput: true,
          ),
        });

        // The iOS path composes route + inputs; it never touches the
        // Android getAudioDevices verb.
        expect(recorder.methodNames, <String>[
          'getCurrentRoute',
          'getAvailableInputs',
        ]);
      },
    );

    test('getAudioDevices falls back to the Android device list', () async {
      recorder.replies['getAudioDevices'] = <Object?>[
        <String, Object?>{
          'id': 3,
          'name': 'Pixel Buds',
          'type': 7,
          'isSource': true,
          'isSink': false,
        },
        <String, Object?>{
          'id': 15,
          'name': 'Built-in mic',
          'type': 15,
          'isSource': true,
          'isSink': true,
        },
      ];

      final platform = MethodChannelMicRecorder();

      expect(await platform.getAudioDevices(), <MicAudioDevice>{
        const MicAudioDevice(
          id: '3',
          name: 'Pixel Buds',
          type: MicAudioDeviceType.bluetoothSco,
          isInput: true,
          isOutput: false,
        ),
        const MicAudioDevice(
          id: '15',
          name: 'Built-in mic',
          type: MicAudioDeviceType.builtInMic,
          isInput: true,
          isOutput: true,
        ),
      });

      // A null getCurrentRoute reply drives the Android fallback.
      expect(recorder.methodNames, <String>[
        'getCurrentRoute',
        'getAudioDevices',
      ]);
    });

    test('getAudioDevices handles an empty Android list', () async {
      recorder.replies['getAudioDevices'] = <Object?>[];

      final platform = MethodChannelMicRecorder();

      expect(await platform.getAudioDevices(), isEmpty);
    });

    test(
      'getAudioDevices decodes missing Android fields defensively',
      () async {
        recorder.replies['getAudioDevices'] = <Object?>[<String, Object?>{}];

        final platform = MethodChannelMicRecorder();

        expect(await platform.getAudioDevices(), <MicAudioDevice>{
          const MicAudioDevice(
            id: '',
            name: '',
            type: MicAudioDeviceType.unknown,
            isInput: false,
            isOutput: false,
          ),
        });
      },
    );
  });

  group('session_events EventChannel decoding', () {
    late MockStreamHandlerEventSink sink;

    setUp(() {
      messenger.setMockStreamHandler(
        _sessionEventsChannel,
        MockStreamHandler.inline(onListen: (_, events) => sink = events),
      );
    });

    tearDown(() {
      messenger.setMockStreamHandler(_sessionEventsChannel, null);
    });

    MethodChannelMicRecorder platform() => MethodChannelMicRecorder();

    test('decodes audioFocusChanged', () async {
      final events = <MicSessionEvent>[];

      final subscription = platform().sessionEvents().listen(events.add);
      await pumpEventQueue();

      sink.success(<String, Object?>{
        'event': 'audioFocusChanged',
        'focus': -2,
      });
      await pumpEventQueue();

      expect(events, hasLength(1));

      final event = events.single as MicAndroidAudioFocusChanged;

      expect(event.focus, -2);

      await subscription.cancel();
    });

    test('decodes devicesChanged with typed device lists', () async {
      final events = <MicSessionEvent>[];

      final subscription = platform().sessionEvents().listen(events.add);
      await pumpEventQueue();

      sink.success(<String, Object?>{
        'event': 'devicesChanged',
        'added': <Object?>[
          <String, Object?>{
            'id': 11,
            'name': 'USB mic',
            'type': 11,
            'isSource': true,
            'isSink': false,
          },
        ],
        'removed': <Object?>[
          <String, Object?>{
            'id': 7,
            'name': 'BT SCO',
            'type': 7,
            'isSource': true,
            'isSink': false,
          },
        ],
      });
      await pumpEventQueue();

      final event = events.single as MicAndroidDevicesChanged;

      expect(event.added.single.id, '11');
      expect(event.added.single.type, MicAudioDeviceType.usbAudio);
      expect(event.removed.single.type, MicAudioDeviceType.bluetoothSco);

      await subscription.cancel();
    });

    test('decodes iOS interruptions (began and ended)', () async {
      final events = <MicSessionEvent>[];

      final subscription = platform().sessionEvents().listen(events.add);
      await pumpEventQueue();

      sink.success(<String, Object?>{
        'event': 'interruption',
        'type': 0,
        'shouldResume': false,
        'wasSuspended': false,
      });
      sink.success(<String, Object?>{
        'event': 'interruption',
        'type': 1,
        'shouldResume': true,
      });
      await pumpEventQueue();

      final began = events[0] as MicIosInterruptionNotification;

      expect(began.began, isTrue);
      expect(began.shouldResume, isFalse);
      expect(began.wasSuspended, isFalse);

      final ended = events[1] as MicIosInterruptionNotification;

      expect(ended.began, isFalse);
      expect(ended.shouldResume, isTrue);
      expect(ended.wasSuspended, isNull);

      await subscription.cancel();
    });

    test('decodes route changes', () async {
      final events = <MicSessionEvent>[];

      final subscription = platform().sessionEvents().listen(events.add);
      await pumpEventQueue();

      sink.success(<String, Object?>{
        'event': 'routeChange',
        'reason': MicIosRouteChangeReason.oldDeviceUnavailable,
      });
      await pumpEventQueue();

      expect(
        (events.single as MicIosRouteChange).reason,
        MicIosRouteChangeReason.oldDeviceUnavailable,
      );

      await subscription.cancel();
    });

    test('unknown event names fall back to a zero route change', () async {
      final events = <MicSessionEvent>[];

      final subscription = platform().sessionEvents().listen(events.add);
      await pumpEventQueue();

      sink.success(<String, Object?>{'event': 'mystery'});
      await pumpEventQueue();

      expect((events.single as MicIosRouteChange).reason, 0);

      await subscription.cancel();
    });

    test('missing optional fields decode defensively', () async {
      final events = <MicSessionEvent>[];

      final subscription = platform().sessionEvents().listen(events.add);
      await pumpEventQueue();

      // No focus key -> 0; no added/removed keys -> empty lists.
      sink.success(<String, Object?>{'event': 'audioFocusChanged'});
      sink.success(<String, Object?>{'event': 'devicesChanged'});
      await pumpEventQueue();

      expect((events[0] as MicAndroidAudioFocusChanged).focus, 0);
      expect(events[1], isA<MicAndroidDevicesChanged>());

      final devices = events[1] as MicAndroidDevicesChanged;

      expect(devices.added, isEmpty);
      expect(devices.removed, isEmpty);

      await subscription.cancel();
    });

    test('stream errors surface on the session event stream', () async {
      final errors = <Object>[];

      final subscription = platform().sessionEvents().listen(
        (_) {},
        onError: (Object e, StackTrace _) => errors.add(e),
      );
      await pumpEventQueue();

      sink.error(code: 'mic_recorder_error', message: 'session events broke');
      await pumpEventQueue();

      expect(errors, hasLength(1));
      expect(errors.single, isA<PlatformException>());

      await subscription.cancel();
    });
  });
}
