import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:mic_recorder/src/config/mic_audio_session_config.dart';
import 'package:mic_recorder/src/config/mic_foreground_service_config.dart';
import 'package:mic_recorder/src/config/mic_recorder_config.dart';
import 'package:mic_recorder/src/internal/mic_platform.dart';
import 'package:mic_recorder/src/lifecycle/app_lifecycle_tracker.dart';
import 'package:mic_recorder/src/mic_recorder.dart';
import 'package:mic_recorder/src/models/mic_amplitude.dart';
import 'package:mic_recorder/src/models/mic_audio_device.dart';
import 'package:mic_recorder/src/models/mic_audio_encoder.dart';
import 'package:mic_recorder/src/models/mic_audio_interruption.dart';
import 'package:mic_recorder/src/models/mic_recorder_events.dart';
import 'package:mic_recorder/src/models/mic_recording_file_format.dart';
import 'package:mic_recorder/src/models/mic_recording_info.dart';
import 'package:mic_recorder/src/models/mic_recorder_state.dart';
import 'package:mic_recorder/src/models/mic_session_events.dart';
import 'package:mic_recorder/src/platform/mic_recorder_platform.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_mic_recorder_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final tracker = AppLifecycleTracker.instance;

  final MicRecorder recorder = MicRecorder.instance;

  late FakeMicRecorderPlatform fake;
  late Directory tempDir;

  late MicRecorderPlatform originalPlatform;

  setUpAll(() async {
    tracker.didChangeAppLifecycleState(AppLifecycleState.resumed);

    originalPlatform = MicRecorderPlatform.instance;

    tempDir = await Directory.systemTemp.createTemp('mic_recorder_test');
  });

  setUp(() {
    fake = FakeMicRecorderPlatform();

    MicRecorderPlatform.instance = fake;
  });

  tearDown(() async {
    micIsAndroid = false;
    micIsIOS = false;

    if (recorder.currentState.isActive) {
      await recorder.stop();
    }

    // The recorder is a singleton — never let one test's arming leak into
    // the next one's.
    if (recorder.encodedOutputFile != null) {
      await recorder.clearEncodedOutput();
    }

    if (recorder.outputFile != null) {
      await recorder.clearOutputFile();
    }

    await fake.dispose();
  });

  tearDownAll(() async {
    MicRecorderPlatform.instance = originalPlatform;

    try {
      await tempDir.delete(recursive: true);
    } on FileSystemException {
      // Already gone.
    }
  });

  Future<void> pump() => pumpEventQueue();

  // This group MUST stay the first one in the file: the recorder is a
  // shared singleton, so the start-before-initialize path is observable
  // only before any test has called initialize() in this process.
  group('MicRecorder lazy startup', () {
    test(
      'start before initialize builds the default configuration lazily',
      () async {
        expect(recorder.isInitialized, isFalse);
        expect(recorder.config, const MicRecorderConfig());

        final chunks = <List<int>>[];
        final subscription = recorder.audioStream.listen(chunks.add);

        expect(await recorder.start(), isTrue);

        // The lazy build arms the same controllers an explicit initialize()
        // would have — with the untouched default configuration.
        expect(recorder.isInitialized, isTrue);
        expect(recorder.currentState, MicRecorderState.recording);
        expect(fake.startRecordingCalls, [16000]);

        fake.emitAudioChunk(<int>[1, 2, 3, 4]);
        await pump();

        expect(chunks, [
          <int>[1, 2, 3, 4],
        ]);

        final info = await recorder.stop();

        expect(info, isNotNull);
        expect(info!.sampleRate, 16000);

        await subscription.cancel();
      },
    );
  });

  group('MicRecorder episode observability', () {
    test(
      'onDurationChanged emits zero on start, ticks and finishes exact',
      () async {
        recorder.initialize(
          MicRecorderConfig(amplitudeInterval: Duration.zero),
        );

        final durations = <Duration>[];
        final subscription = recorder.onDurationChanged.listen(durations.add);

        expect(await recorder.start(), isTrue);
        await pump();

        expect(durations.first, Duration.zero);

        fake.emitAudioChunk(<int>[1, 2, 3, 4, 5, 6, 7, 8]);
        fake.emitAudioChunk(<int>[1, 2, 3, 4, 5, 6, 7, 8]);
        await pump();

        expect(durations.length, greaterThanOrEqualTo(2));
        expect(
          durations,
          everyElement(lessThanOrEqualTo(const Duration(days: 1))),
        );

        final info = await recorder.stop();
        await pump();

        expect(info, isNotNull);
        expect(durations.last, info!.duration);

        await subscription.cancel();
      },
    );

    test('paused spans are excluded from the duration clock', () async {
      recorder.initialize(const MicRecorderConfig());

      expect(await recorder.start(), isTrue);
      await pump();

      fake.emitAudioChunk(<int>[1, 2, 3, 4]);
      await pump();

      await recorder.pause();
      await pump();

      final frozenWhilePaused = recorder.elapsedDuration;

      // A paused recorder receives no audio; the clock does not advance
      // (real time passes below without a chunk in sight).
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(
        recorder.elapsedDuration! - frozenWhilePaused!,
        lessThan(const Duration(milliseconds: 40)),
      );

      expect(await recorder.resume(), isTrue);
      fake.emitAudioChunk(<int>[1, 2, 3, 4]);
      await pump();

      final info = await recorder.stop();

      expect(info!.duration, greaterThan(Duration.zero));
      expect(recorder.lastRecordingInfo, same(info));
    });

    test('maxDuration auto-stops with the maxDurationReached reason', () async {
      recorder.initialize(
        const MicRecorderConfig(maxDuration: Duration(milliseconds: 200)),
      );

      final states = <MicRecorderState>[];
      final subscription = recorder.onStateChange.listen(states.add);

      expect(await recorder.start(), isTrue);
      await pump();

      // Let the active clock pass the cap, then deliver a chunk to check it.
      await Future<void>.delayed(const Duration(milliseconds: 300));

      fake.emitAudioChunk(<int>[1, 2, 3, 4]);
      await pump();

      expect(recorder.currentState, MicRecorderState.stopped);
      expect(
        recorder.lastRecordingInfo?.stopReason,
        MicRecordingStopReason.maxDurationReached,
      );
      expect(states.last, MicRecorderState.stopped);

      await subscription.cancel();
    });

    test('maxDuration never fires while paused (active time only)', () async {
      recorder.initialize(
        const MicRecorderConfig(maxDuration: Duration(milliseconds: 200)),
      );

      expect(await recorder.start(), isTrue);
      await pump();

      await recorder.pause();

      await Future<void>.delayed(const Duration(milliseconds: 350));

      // No chunk ever flowed while paused: no auto-stop, still paused.
      expect(recorder.currentState, MicRecorderState.paused);

      await recorder.stop();
    });

    test('a manual stop reports the manual reason', () async {
      recorder.initialize(const MicRecorderConfig());

      expect(await recorder.start(), isTrue);
      fake.emitAudioChunk(<int>[1, 2, 3, 4]);
      await pump();

      final info = await recorder.stop();

      expect(info!.stopReason, MicRecordingStopReason.manual);
      expect(info.sampleRate, 16000);
      expect(info.bitDepth, 16);
      expect(info.channels, 1);
      expect(info.sizeBytes, greaterThanOrEqualTo(4));
      expect(info.path, isNull);
      expect(info.encoder, isNull);
      expect(info.fileFormat, isNull);
    });
  });

  group('MicRecorder amplitude metering', () {
    test('onAmplitude reports current, average and peak dBFS', () async {
      recorder.initialize(MicRecorderConfig(amplitudeInterval: Duration.zero));

      final amplitudes = <MicAmplitude>[];
      final subscription = recorder.onAmplitude.listen(amplitudes.add);

      expect(await recorder.start(), isTrue);

      // A full-scale square wave: RMS 1.0 -> 0 dBFS.
      final loud = List<int>.generate(16, (i) => i.isEven ? 0xFF : 0x7F);
      fake.emitAudioChunk(loud);
      await pump();

      // Digital silence: RMS 0 -> the -120 dBFS floor.
      fake.emitAudioChunk(List<int>.filled(16, 0));
      await pump();

      expect(amplitudes, isNotEmpty);
      expect(amplitudes.first.currentDbfs, greaterThan(-1.0));
      expect(amplitudes.first.peakDbfs, greaterThan(-1.0));
      expect(amplitudes.last.currentDbfs, MicAmplitude.silenceDbfs);
      expect(amplitudes.last.peakDbfs, greaterThan(-1.0));
      expect(amplitudes.last.isSilent, isTrue);
      expect(recorder.amplitude, isNotNull);

      await recorder.stop();
      await subscription.cancel();
    });

    test('amplitudeInterval throttles the stream but not the getter', () async {
      recorder.initialize(
        const MicRecorderConfig(amplitudeInterval: Duration(seconds: 30)),
      );

      final amplitudes = <MicAmplitude>[];
      final subscription = recorder.onAmplitude.listen(amplitudes.add);

      expect(await recorder.start(), isTrue);

      // First reading always emits; the following chunks are throttled.
      fake.emitAudioChunk(List<int>.filled(16, 0x40));
      fake.emitAudioChunk(List<int>.filled(16, 0x40));
      fake.emitAudioChunk(List<int>.filled(16, 0x40));
      await pump();

      expect(amplitudes, hasLength(1));
      expect(recorder.amplitude, isNotNull);

      await recorder.stop();
      await subscription.cancel();
    });
  });

  group('MicRecorder WAV file output', () {
    test('writes a canonical 44-byte header and patches the sizes', () async {
      final path = '${tempDir.path}/wav_test.wav';

      recorder.initialize(const MicRecorderConfig());

      await recorder.setOutputFile(path, format: MicRecordingFileFormat.wav);

      expect(recorder.outputFile?.path, path);
      expect(recorder.outputFileFormat, MicRecordingFileFormat.wav);

      expect(await recorder.start(), isTrue);

      fake.emitAudioChunk(<int>[1, 0, 2, 0, 3, 0, 4, 0]);
      fake.emitAudioChunk(<int>[5, 0, 6, 0, 7, 0, 8, 0]);
      await pump();

      final info = await recorder.stop();

      expect(info!.path, path);
      expect(info.fileFormat, MicRecordingFileFormat.wav);
      expect(info.encoder, isNull);

      final bytes = await File(path).readAsBytes();

      expect(bytes.length, 44 + 16);

      final view = ByteData.sublistView(bytes);

      expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(bytes.sublist(8, 12)), 'WAVE');
      expect(String.fromCharCodes(bytes.sublist(12, 16)), 'fmt ');
      expect(String.fromCharCodes(bytes.sublist(36, 40)), 'data');
      expect(view.getUint32(4, Endian.little), 36 + 16);
      expect(view.getUint32(40, Endian.little), 16);
      expect(view.getUint16(20, Endian.little), 1); // PCM
      expect(view.getUint16(22, Endian.little), 1); // mono
      expect(view.getUint32(24, Endian.little), 16000);
      expect(view.getUint16(34, Endian.little), 16); // bits per sample

      expect(info.sizeBytes, 44 + 16);
    });

    test('raw pcm16 output stays headerless', () async {
      final path = '${tempDir.path}/raw_test.pcm';

      recorder.initialize(const MicRecorderConfig());

      await recorder.setOutputFile(path);

      expect(await recorder.start(), isTrue);

      fake.emitAudioChunk(<int>[9, 8, 7, 6]);
      await pump();

      final info = await recorder.stop();

      expect(info!.fileFormat, MicRecordingFileFormat.pcm16);

      final bytes = await File(path).readAsBytes();

      expect(bytes, <int>[9, 8, 7, 6]);
    });
  });

  group('MicRecorder encoded output', () {
    test(
      'arms the platform with path, encoder, bitRate and sampleRate',
      () async {
        recorder.initialize(const MicRecorderConfig());

        final file = await recorder.setEncodedOutput(
          '${tempDir.path}/enc.m4a',
          encoder: MicAudioEncoder.aacLc,
        );

        expect(file.path, '${tempDir.path}/enc.m4a');
        expect(recorder.encodedOutputFile?.path, '${tempDir.path}/enc.m4a');

        expect(fake.setEncodedOutputCalls, hasLength(1));

        final call = fake.setEncodedOutputCalls.single;

        expect(call.$1, '${tempDir.path}/enc.m4a');
        expect(call.$2, MicAudioEncoder.aacLc);
        // 128 kbps clamped to the AAC-LC ceiling: 6 × 16000 = 96000.
        expect(call.$3, 96000);
        expect(call.$4, 16000);

        await recorder.clearEncodedOutput();

        expect(fake.clearEncodedOutputCallCount, 1);
        expect(recorder.encodedOutputFile, isNull);

        // Clearing frees the slot for a fresh arming.
        await recorder.setEncodedOutput(
          '${tempDir.path}/enc2.m4a',
          encoder: MicAudioEncoder.aacLc,
          bitRate: 64000,
        );

        expect(fake.setEncodedOutputCalls.last, (
          '${tempDir.path}/enc2.m4a',
          MicAudioEncoder.aacLc,
          64000,
          16000,
        ));
      },
    );

    test('a second arming without clearing is a StateError', () async {
      recorder.initialize(const MicRecorderConfig());

      await recorder.setEncodedOutput(
        '${tempDir.path}/dup.m4a',
        encoder: MicAudioEncoder.aacLc,
      );

      await expectLater(
        recorder.setEncodedOutput(
          '${tempDir.path}/dup2.m4a',
          encoder: MicAudioEncoder.aacLc,
        ),
        throwsStateError,
      );

      await recorder.clearEncodedOutput();
    });

    test(
      'an encoder unavailable on this platform is an UnsupportedError',
      () async {
        recorder.initialize(const MicRecorderConfig());

        // The test platform is neither Android nor iOS-detected here; aacLc
        // passes as iOS-supported, while opus (Android-only) must not.
        micIsAndroid = false;

        await expectLater(
          recorder.setEncodedOutput(
            '${tempDir.path}/opus.ogg',
            encoder: MicAudioEncoder.opus,
          ),
          throwsUnsupportedError,
        );
      },
    );

    test(
      'a sample-rate-restricted encoder validates against the config',
      () async {
        micIsAndroid = true;

        recorder.initialize(const MicRecorderConfig());

        // amrNb requires 8000 Hz; the config says 16000 Hz.
        await expectLater(
          recorder.setEncodedOutput(
            '${tempDir.path}/nb.amr',
            encoder: MicAudioEncoder.amrNb,
          ),
          throwsStateError,
        );

        await expectLater(
          recorder.setEncodedOutput(
            '${tempDir.path}/wb.amr',
            encoder: MicAudioEncoder.amrWb,
          ),
          completes,
        );

        await recorder.clearEncodedOutput();
      },
    );

    test('stop reports the encoded output as the episode file', () async {
      recorder.initialize(const MicRecorderConfig());

      final encodedPath = '${tempDir.path}/episode.m4a';

      await recorder.setOutputFile(
        '${tempDir.path}/alongside.wav',
        format: MicRecordingFileFormat.wav,
      );
      await recorder.setEncodedOutput(
        encodedPath,
        encoder: MicAudioEncoder.aacLc,
      );

      expect(await recorder.start(), isTrue);

      fake.emitAudioChunk(List<int>.filled(32, 0x11));
      await pump();

      final info = await recorder.stop();

      expect(info!.path, encodedPath);
      expect(info.encoder, MicAudioEncoder.aacLc);
      expect(info.fileFormat, isNull);
      expect(fake.stopRecordingCallCount, 1);
    });

    test('cancel discards the outputs and reports nothing', () async {
      recorder.initialize(const MicRecorderConfig());

      final pcmPath = '${tempDir.path}/cancel_me.pcm';
      final encodedPath = '${tempDir.path}/cancel_me.m4a';

      await recorder.setOutputFile(pcmPath);
      await recorder.setEncodedOutput(
        encodedPath,
        encoder: MicAudioEncoder.aacLc,
      );

      expect(await recorder.start(), isTrue);

      fake.emitAudioChunk(List<int>.filled(32, 0x22));
      await pump();

      await recorder.cancel();

      expect(recorder.currentState, MicRecorderState.stopped);
      expect(await File(pcmPath).exists(), isFalse);
      expect(fake.clearEncodedOutputCallCount, 1);
      expect(recorder.encodedOutputFile, isNull);
      expect(recorder.outputFile, isNull);
    });

    test('a platform rejection surfaces as a StateError', () async {
      recorder.initialize(const MicRecorderConfig());

      fake.setEncodedOutputResult = false;

      await expectLater(
        recorder.setEncodedOutput(
          '${tempDir.path}/rejected.m4a',
          encoder: MicAudioEncoder.aacLc,
        ),
        throwsStateError,
      );
    });
  });

  group('MicRecorder permissions', () {
    test(
      'checkMicrophonePermission and requestMicrophonePermission pass through',
      () async {
        fake.checkMicPermissionResult = true;
        fake.requestMicPermissionResult = false;

        expect(await recorder.checkMicrophonePermission(), isTrue);
        expect(await recorder.requestMicrophonePermission(), isFalse);

        expect(fake.checkMicPermissionCallCount, 1);
        expect(fake.requestMicPermissionCallCount, 1);
      },
    );
  });

  group('MicRecorder start and state transitions', () {
    test(
      'start transitions to recording and forwards platform chunks verbatim',
      () async {
        recorder.initialize(
          const MicRecorderConfig(
            androidEchoCancel: true,
            androidNoiseSuppress: true,
            androidAutoGain: true,
          ),
        );

        expect(recorder.isInitialized, isTrue);
        expect(recorder.config.sampleRate, 16000);
        expect(recorder.sampleRate, 16000);
        expect(recorder.bitDepth, 16);

        final states = <MicRecorderState>[];
        final conversationSilenceEvents = <MicConversationSilenceEvent>[];
        final microphoneLostEvents = <MicMicrophoneLostEvent>[];

        final stateSubscription = recorder.onStateChange.listen(states.add);
        final conversationSilenceSubscription = recorder.onConversationSilence
            .listen(conversationSilenceEvents.add);
        final microphoneLostSubscription = recorder.onMicrophoneLost.listen(
          microphoneLostEvents.add,
        );

        final chunks = <List<int>>[];
        final audioSubscription = recorder.audioStream.listen(chunks.add);

        expect(await recorder.start(), isTrue);
        await pump();

        expect(recorder.currentState, MicRecorderState.recording);
        expect(states, [MicRecorderState.stopped, MicRecorderState.recording]);
        expect(recorder.mode, MicRecordingMode.conversation);
        expect(recorder.recordingStartedAt, isNotNull);

        expect(fake.startRecordingCalls, [16000]);
        expect(fake.startRecordingEffectCalls.single, (true, true, true));

        // Both chunks are loud (RMS above the silence threshold) and are
        // forwarded byte-for-byte.
        final loud = List<int>.generate(16, (i) => i.isEven ? 0xFF : 0x7F);
        fake.emitAudioChunk(<int>[1, 2, 3, 4]);
        fake.emitAudioChunk(loud);
        await pump();

        expect(chunks, [
          <int>[1, 2, 3, 4],
          loud,
        ]);

        final info = await recorder.stop();

        expect(info, isNotNull);
        expect(recorder.currentState, MicRecorderState.stopped);
        expect(states.last, MicRecorderState.stopped);
        // The episode anchor survives a stop (only cancel clears it).
        expect(recorder.recordingStartedAt, isNotNull);
        expect(conversationSilenceEvents, isEmpty);
        expect(microphoneLostEvents, isEmpty);

        await stateSubscription.cancel();
        await conversationSilenceSubscription.cancel();
        await microphoneLostSubscription.cancel();
        await audioSubscription.cancel();
      },
    );

    test('stop while idle is a safe no-op returning null', () async {
      recorder.initialize(const MicRecorderConfig());

      expect(await recorder.stop(), isNull);
      expect(recorder.currentState, MicRecorderState.stopped);
      expect(fake.stopRecordingCallCount, 1);

      expect(await recorder.start(), isTrue);
      await pump();

      expect(await recorder.stop(), isNotNull);

      // Stopping an already-stopped recorder tears nothing new down but
      // still returns null — there was no episode.
      expect(await recorder.stop(), isNull);
      expect(recorder.currentState, MicRecorderState.stopped);
      expect(fake.stopRecordingCallCount, 3);
    });

    test('a second start while the episode is active is a no-op', () async {
      recorder.initialize(const MicRecorderConfig());

      expect(await recorder.start(), isTrue);
      await pump();

      // Idempotent: reports success without touching the platform again.
      expect(await recorder.start(), isTrue);
      await pump();

      expect(fake.startRecordingCalls, hasLength(1));
      expect(recorder.currentState, MicRecorderState.recording);

      final chunks = <List<int>>[];
      final subscription = recorder.audioStream.listen(chunks.add);

      fake.emitAudioChunk(<int>[5, 6, 7, 8]);
      await pump();

      expect(chunks, [
        <int>[5, 6, 7, 8],
      ]);

      await recorder.stop();
      await subscription.cancel();
    });

    test('initialize while recording throws a StateError', () async {
      recorder.initialize(const MicRecorderConfig());

      expect(await recorder.start(), isTrue);

      expect(
        () => recorder.initialize(const MicRecorderConfig()),
        throwsStateError,
      );

      expect(recorder.currentState, MicRecorderState.recording);

      await recorder.stop();
    });

    test(
      're-initializing while stopped rebuilds with the new configuration',
      () async {
        recorder.initialize(const MicRecorderConfig(sampleRate: 22050));

        expect(recorder.config.sampleRate, 22050);
        expect(recorder.sampleRate, 22050);

        expect(await recorder.start(), isTrue);

        expect(fake.startRecordingCalls.single, 22050);

        await recorder.stop();

        recorder.initialize(const MicRecorderConfig());

        expect(recorder.config.sampleRate, 16000);
        expect(await recorder.start(), isTrue);

        expect(fake.startRecordingCalls, [22050, 16000]);

        await recorder.stop();
      },
    );

    test('cancel wipes the episode observability', () async {
      recorder.initialize(const MicRecorderConfig());

      expect(await recorder.start(), isTrue);

      fake.emitAudioChunk(<int>[1, 2, 3, 4]);
      await pump();

      expect(recorder.recordingStartedAt, isNotNull);
      expect(recorder.elapsedDuration, isNotNull);

      await recorder.cancel();

      expect(recorder.currentState, MicRecorderState.stopped);
      expect(recorder.recordingStartedAt, isNull);
      expect(recorder.elapsedDuration, isNull);
    });

    test(
      'stop sizes the episode from an encoded file that exists on disk',
      () async {
        final encodedPath = '${tempDir.path}/sized.m4a';

        recorder.initialize(const MicRecorderConfig());

        await recorder.setEncodedOutput(
          encodedPath,
          encoder: MicAudioEncoder.aacLc,
        );

        // The native encoder owns this file in production — plant a stand-in
        // payload to verify the size is read from disk.
        await File(encodedPath).writeAsBytes(<int>[1, 2, 3, 4, 5]);

        expect(await recorder.start(), isTrue);

        fake.emitAudioChunk(List<int>.filled(32, 0x33));
        await pump();

        final info = await recorder.stop();

        expect(info!.path, encodedPath);
        expect(info.sizeBytes, 5);
      },
    );
  });

  group('MicRecorder voice-command mode', () {
    test('conversation mode retains no voice-command tail', () async {
      recorder.initialize(const MicRecorderConfig());

      expect(await recorder.start(), isTrue);
      await pump();

      expect(recorder.mode, MicRecordingMode.conversation);

      fake.emitAudioChunk(<int>[1, 2, 3, 4]);
      await pump();

      expect(recorder.voiceCommandAudio, isEmpty);

      await recorder.stop();
    });

    test('retains at most the most recent ten seconds of audio', () async {
      recorder.initialize(const MicRecorderConfig());

      expect(await recorder.start(mode: MicRecordingMode.voiceCommand), isTrue);
      await pump();

      expect(recorder.mode, MicRecordingMode.voiceCommand);

      // Well under ten seconds: everything is kept.
      fake.emitAudioChunk(List<int>.filled(16, 1));
      await pump();

      expect(recorder.voiceCommandAudio, List<int>.filled(16, 1));

      // 16 kHz × 10 s × 2 bytes = 320 000 bytes crossed — only the tail
      // survives.
      fake.emitAudioChunk(List<int>.filled(320000 - 20, 0x7E));
      fake.emitAudioChunk(<int>[9, 9, 9, 9]);
      await pump();

      final tail = recorder.voiceCommandAudio;

      expect(tail.length, 320000);
      expect(tail.first, 1);
      expect(tail.sublist(tail.length - 4), <int>[9, 9, 9, 9]);

      // The tail only clears on emitInitialAudio (or its 5-minute trim) —
      // drain it here so the episode's RAM tail does not leak into later
      // tests.
      await recorder.emitInitialAudio();
      await pump();

      await recorder.stop();
    });
  });

  group('MicRecorder failed start', () {
    test(
      'a platform start failure parks the recorder in the error state',
      () async {
        recorder.initialize(const MicRecorderConfig());

        fake.startRecordingResult = false;

        expect(await recorder.start(), isFalse);

        expect(recorder.currentState, MicRecorderState.error);
        expect(fake.startRecordingCalls, hasLength(1));
      },
    );

    test('a retry after a failed start records', () async {
      recorder.initialize(const MicRecorderConfig());

      fake.startRecordingResult = false;

      expect(await recorder.start(), isFalse);
      expect(recorder.currentState, MicRecorderState.error);

      fake.startRecordingResult = true;

      expect(await recorder.start(), isTrue);

      expect(recorder.currentState, MicRecorderState.recording);

      fake.emitAudioChunk(<int>[1, 2, 3, 4]);
      await pump();

      final info = await recorder.stop();

      expect(info, isNotNull);
      expect(info!.sizeBytes, greaterThanOrEqualTo(4));
    });
  });

  group('MicRecorder pause and resume', () {
    test(
      'manual pause parks in paused and resume returns to recording',
      () async {
        recorder.initialize(const MicRecorderConfig());

        expect(await recorder.start(), isTrue);

        await recorder.pause();

        expect(recorder.currentState, MicRecorderState.paused);
        expect(fake.pauseRecordingCalls, [false]);

        expect(await recorder.resume(), isTrue);

        expect(recorder.currentState, MicRecorderState.recording);
        expect(fake.resumeRecordingCallCount, 1);

        fake.emitAudioChunk(<int>[1, 2, 3, 4]);
        await pump();

        expect(await recorder.stop(), isNotNull);
      },
    );

    test('a failed platform resume keeps the recorder paused', () async {
      recorder.initialize(const MicRecorderConfig());

      expect(await recorder.start(), isTrue);

      await recorder.pause();

      fake.resumeRecordingResult = false;

      expect(await recorder.resume(), isFalse);

      expect(recorder.currentState, MicRecorderState.paused);

      fake.resumeRecordingResult = true;

      expect(await recorder.resume(), isTrue);

      expect(recorder.currentState, MicRecorderState.recording);

      await recorder.stop();
    });

    test('pausing an idle recorder is a StateError', () async {
      recorder.initialize(const MicRecorderConfig());

      // A preceding cancelled episode zeroes the banked clock — the idle
      // pause is then attempted against a clean slate.
      expect(await recorder.start(), isTrue);
      fake.emitAudioChunk(<int>[1, 2, 3, 4]);
      await pump();
      await recorder.cancel();

      // Pausing while idle would park a phantom `paused` episode; the
      // guard rejects it before any platform verb runs.
      await expectLater(recorder.pause(), throwsA(isA<StateError>()));

      expect(recorder.currentState, MicRecorderState.stopped);
      expect(fake.pauseRecordingCalls, isEmpty);
    });
  });

  group('MicRecorder interruptions', () {
    test('an Android focus loss auto-pauses and a gain auto-resumes', () async {
      micIsAndroid = true;

      recorder.initialize(const MicRecorderConfig());

      // A begin event while the recorder is idle never reaches the capture
      // machinery.
      fake.emitAndroidFocus(MicAndroidAudioFocus.lossTransient);
      await pump();

      expect(recorder.currentState, MicRecorderState.stopped);

      expect(await recorder.start(), isTrue);
      await pump();

      fake.emitAndroidFocus(MicAndroidAudioFocus.lossTransient);
      await pump();

      expect(recorder.currentState, MicRecorderState.paused);
      expect(fake.pauseRecordingCalls, [true]);
      expect(
        fake.showForegroundNotificationCalls,
        contains('Recording interrupted'),
      );

      fake.emitAndroidFocus(MicAndroidAudioFocus.gain);
      await pump();

      expect(recorder.currentState, MicRecorderState.recording);
      expect(fake.resumeRecordingCallCount, 1);

      await recorder.stop();
    });

    test(
      'a call holding the microphone blocks resume and auto-resume',
      () async {
        micIsAndroid = true;

        recorder.initialize(const MicRecorderConfig());

        expect(await recorder.start(), isTrue);
        await pump();

        fake.emitAndroidFocus(MicAndroidAudioFocus.loss);
        await pump();

        expect(recorder.currentState, MicRecorderState.paused);

        // AudioManager.MODE_IN_CALL — a call owns the microphone.
        fake.audioModeResult = 2;

        expect(await recorder.resume(), isFalse);
        expect(recorder.currentState, MicRecorderState.paused);

        // The focus gain cannot auto-resume either while the call holds it.
        fake.emitAndroidFocus(MicAndroidAudioFocus.gain);
        await pump();

        expect(recorder.currentState, MicRecorderState.paused);

        fake.audioModeResult = 0;

        expect(await recorder.resume(), isTrue);
        expect(recorder.currentState, MicRecorderState.recording);

        await recorder.stop();
      },
    );

    test(
      'an iOS interruption auto-pauses and auto-resumes on its end',
      () async {
        micIsIOS = true;

        recorder.initialize(const MicRecorderConfig());

        final interruptions = <MicAudioInterruption>[];
        final interruptionSubscription = recorder.onAudioInterruption.listen(
          interruptions.add,
        );

        expect(await recorder.start(), isTrue);
        await pump();

        fake.emitIosInterruption(began: true, shouldResume: false);
        await pump();

        expect(recorder.currentState, MicRecorderState.paused);

        fake.emitIosInterruption(began: false, shouldResume: true);
        await pump();

        expect(recorder.currentState, MicRecorderState.recording);
        // The resumable end hard-resets the iOS audio stack on its way back.
        expect(fake.microphoneInterruptedCallCount, 1);
        expect(interruptions, isNotEmpty);
        expect(interruptions.first.begin, isTrue);
        expect(interruptions.last.begin, isFalse);

        await recorder.stop();
        await interruptionSubscription.cancel();
      },
    );

    test(
      'a failed auto-resume stays armed and live audio reconciles it',
      () async {
        micIsIOS = true;

        final logMessages = <String>[];

        recorder.initialize(
          MicRecorderConfig(
            log: (level, message, [data]) => logMessages.add(message),
          ),
        );

        expect(await recorder.start(), isTrue);
        await pump();

        fake.emitIosInterruption(began: true, shouldResume: false);
        await pump();

        expect(recorder.currentState, MicRecorderState.paused);

        fake.resumeRecordingResult = false;

        fake.emitIosInterruption(began: false, shouldResume: true);
        await pump();

        expect(recorder.currentState, MicRecorderState.paused);
        expect(logMessages, contains('audioRecorderResumeFailed'));

        // Native capture recovered on its own and audio flows again — the
        // live-audio reconcile closes the loop without another interruption
        // event.
        fake.resumeRecordingResult = true;

        fake.emitAudioChunk(<int>[1, 2, 3, 4]);
        await Future<void>.delayed(const Duration(milliseconds: 250));

        expect(recorder.currentState, MicRecorderState.recording);

        await recorder.stop();
      },
    );

    testWidgets(
      'native audio during an interruption pause reconciles back to recording (fake clock)',
      (tester) async {
        // Fake-async law: build the machinery inside the test body so the
        // reconcile timer advances on tester.pump. The platform flags stay
        // false for the whole episode: focus events are interpreted
        // regardless of them, but a "supported" platform would make the
        // route controller subscribe to the session's devicesStream — and
        // its stop() awaits that broadcast cancel, which never completes
        // under a fake event loop. The singleton's stop() must finish inside
        // this zone or every later test inherits a poisoned recorder.
        final localFake = FakeMicRecorderPlatform();
        MicRecorderPlatform.instance = localFake;

        final logMessages = <String>[];

        recorder.initialize(
          MicRecorderConfig(
            log: (level, message, [data]) => logMessages.add(message),
          ),
        );

        final started = recorder.start();
        await tester.pump();

        expect(await started, isTrue);
        expect(recorder.currentState, MicRecorderState.recording);

        localFake.emitAndroidFocus(MicAndroidAudioFocus.loss);
        await tester.pump();

        expect(recorder.currentState, MicRecorderState.paused);
        expect(localFake.pauseRecordingCalls, [true]);

        // Native audio recovered while Dart still thinks we are paused.
        localFake.emitAudioChunk(<int>[1, 2, 3, 4]);
        await tester.pump();

        // The live-audio reconcile delay (100 ms) elapses on the fake clock.
        await tester.pump(const Duration(milliseconds: 150));

        expect(recorder.currentState, MicRecorderState.recording);
        expect(localFake.resumeRecordingCallCount, 1);

        // A stale interruption flag over flowing audio resolves inline.
        localFake.emitAudioChunk(<int>[5, 6, 7, 8]);
        await tester.pump();

        // The 120-second audio-health heartbeat fires under the fake clock.
        await tester.pump(const Duration(seconds: 121));
        await tester.pump();

        expect(logMessages, contains('audioHealthHeartbeat'));

        // Tear the episode down inside the fake zone — testWidgets asserts
        // a clean timer slate, so the heartbeat timer must be cancelled
        // before the body ends. The stop's teardown futures drain on pump
        // turns; never bare-await them under fake async.
        unawaited(recorder.stop());
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 5));

        expect(recorder.currentState, MicRecorderState.stopped);
      },
    );

    testWidgets(
      'the interruption-end recovery retries on a timer until the session re-activates (fake clock)',
      (tester) async {
        // Fake-async law: build the machinery inside the test body so the
        // retry ladder's timers advance on tester.pump. iOS is emulated
        // only AFTER the episode is running for the same reason the
        // reconcile test above keeps both flags false: a "supported"
        // platform arms the route controller's device subscription, and
        // platform routing is irrelevant to the retry ladder under test.
        // (The subscription's teardown is unawaited — the fake-async-safe
        // pattern — but keeping the flags false avoids depending on that.)
        final localFake = FakeMicRecorderPlatform();
        MicRecorderPlatform.instance = localFake;

        final logMessages = <String>[];

        recorder.initialize(
          MicRecorderConfig(
            log: (level, message, [data]) => logMessages.add(message),
          ),
        );

        final started = recorder.start();
        await tester.pump();

        expect(await started, isTrue);
        expect(recorder.currentState, MicRecorderState.recording);

        // The retry ladder only arms on iOS while the app is resumed.
        micIsIOS = true;

        localFake.emitIosInterruption(began: true, shouldResume: false);
        await tester.pump();

        expect(recorder.currentState, MicRecorderState.paused);

        // The interruption ends, but the audio session cannot re-activate
        // yet — the recovery ladder retries every three seconds. (The
        // scripted replies are indexed by call: start already consumed
        // slot zero, so slot one is the first recovery attempt.)
        localFake.setAudioSessionActiveResponses.addAll(<bool>[true, false]);

        localFake.emitIosInterruption(began: false, shouldResume: false);
        await tester.pump();

        expect(recorder.currentState, MicRecorderState.paused);

        await tester.pump(const Duration(seconds: 4));
        await tester.pump();

        expect(recorder.currentState, MicRecorderState.recording);
        expect(localFake.resumeRecordingCallCount, 1);
        // The first recovery attempt failed (the scripted activation
        // refusal) and the ladder retried it on its timer.
        expect(logMessages, contains('audioSessionActivationFailed'));

        // Tear the episode down inside the fake zone (see the reconcile
        // test above for the fake-async teardown pattern).
        unawaited(recorder.stop());
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 5));

        expect(recorder.currentState, MicRecorderState.stopped);
      },
    );

    test('a failed interruption pause verb is logged, never fatal', () async {
      final logMessages = <String>[];

      recorder.initialize(
        MicRecorderConfig(
          log: (level, message, [data]) => logMessages.add(message),
        ),
      );

      expect(await recorder.start(), isTrue);
      await pump();

      fake.pauseRecordingResult = false;

      fake.emitAndroidFocus(MicAndroidAudioFocus.lossTransient);
      await pump();

      // The native pause verb refused — the Dart state still parks (the
      // capture stack is torn down regardless) and the failure is logged.
      expect(recorder.currentState, MicRecorderState.paused);
      expect(logMessages, contains('audioRecorderPauseFailed'));

      fake.pauseRecordingResult = true;

      fake.emitAndroidFocus(MicAndroidAudioFocus.gain);
      await pump();

      expect(recorder.currentState, MicRecorderState.recording);

      await recorder.stop();
    });

    test('the duration clock counts post-auto-resume audio', () async {
      // The interruption auto-resume goes through _transition (like the
      // manual resume), so the active-time clock re-arms at the resume
      // and every post-resume chunk is measured.
      recorder.initialize(const MicRecorderConfig());

      expect(await recorder.start(), isTrue);

      fake.emitAudioChunk(<int>[1, 2, 3, 4]);
      await pump();

      fake.emitAndroidFocus(MicAndroidAudioFocus.lossTransient);
      await pump();

      expect(recorder.currentState, MicRecorderState.paused);

      final bankedAtPause = recorder.elapsedDuration!;

      fake.emitAndroidFocus(MicAndroidAudioFocus.gain);
      await pump();

      expect(recorder.currentState, MicRecorderState.recording);

      // Live audio keeps flowing after the auto-resume — and the
      // re-armed clock counts it...
      fake.emitAudioChunk(List<int>.filled(32, 0x55));
      fake.emitAudioChunk(List<int>.filled(32, 0x55));
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await pump();

      expect(recorder.elapsedDuration!, greaterThan(bankedAtPause));

      // ...and the episode total reports the full span.
      final info = await recorder.stop();

      expect(info!.duration, greaterThan(bankedAtPause));
    });
  });

  group('MicRecorder fake-clock episode machinery', () {
    testWidgets(
      'the voice-command RAM tail is trimmed at the five-minute mark (fake clock)',
      (tester) async {
        // Platform flags stay false for the whole episode (see the
        // interruption fake-clock tests above): platform routing is
        // irrelevant to the RAM-tail machinery under test, and keeping
        // the flags false keeps the episode off the route controller's
        // device subscription entirely.
        final localFake = FakeMicRecorderPlatform();
        MicRecorderPlatform.instance = localFake;

        final logMessages = <String>[];

        recorder.initialize(
          MicRecorderConfig(
            log: (level, message, [data]) => logMessages.add(message),
          ),
        );

        final started = recorder.start(mode: MicRecordingMode.voiceCommand);
        await tester.pump();

        expect(await started, isTrue);
        expect(recorder.currentState, MicRecorderState.recording);

        // A silent chunk opens a silence period, a loud one closes it (the
        // short-silence reset), and a final silent one leaves an ongoing
        // silence for the heartbeat to measure.
        localFake.emitAudioChunk(<int>[0, 0, 0, 0]);
        localFake.emitAudioChunk(
          List<int>.generate(16, (i) => i.isEven ? 0xFF : 0x7F),
        );
        localFake.emitAudioChunk(<int>[0, 0, 0, 0]);
        await tester.pump();

        expect(recorder.voiceCommandAudio, isNotEmpty);

        // Five minutes of capture later, the periodic trim clears the RAM
        // tail — the getter cannot resurrect what was never kept. The
        // 120-second heartbeat fires along the way with an ongoing
        // silence to report.
        await tester.pump(const Duration(seconds: 121));
        await tester.pump(const Duration(seconds: 181));

        expect(recorder.voiceCommandAudio, isEmpty);
        expect(logMessages, contains('audioHealthHeartbeat'));

        // Tear the episode down inside the fake zone (the established
        // fake-async teardown pattern).
        unawaited(recorder.stop());
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 5));

        expect(recorder.currentState, MicRecorderState.stopped);
      },
    );
  });

  group('MicRecorder RAM buffering', () {
    test('startAudioBuffering captures in RAM until drained', () async {
      recorder.initialize(const MicRecorderConfig());

      expect(await recorder.startAudioBuffering(), isTrue);

      expect(recorder.bufferingStartedAt, isNotNull);
      expect(fake.startRecordingCalls, [16000]);

      fake.emitAudioChunk(<int>[1, 2, 3, 4]);
      fake.emitAudioChunk(<int>[5, 6, 7, 8]);
      await pump();

      expect(recorder.drainBufferedAudio(), <int>[1, 2, 3, 4, 5, 6, 7, 8]);
      expect(recorder.drainBufferedAudio(), isEmpty);

      // Draining never stopped the buffering subscription.
      fake.emitAudioChunk(<int>[9, 10]);
      await pump();

      final buffered = await recorder.stopAudioBuffering();

      expect(buffered, <int>[9, 10]);
      expect(recorder.bufferingStartedAt, isNull);

      // Stopping again returns nothing — the subscription is gone.
      expect(await recorder.stopAudioBuffering(), isEmpty);

      await recorder.stop();
    });

    test('startAudioBuffering while already buffering is idempotent', () async {
      recorder.initialize(const MicRecorderConfig());

      expect(await recorder.startAudioBuffering(), isTrue);

      fake.emitAudioChunk(<int>[1, 2]);
      await pump();

      expect(await recorder.startAudioBuffering(), isTrue);
      expect(fake.startRecordingCalls, hasLength(1));

      fake.emitAudioChunk(<int>[3, 4]);
      await pump();

      expect(await recorder.stopAudioBuffering(), <int>[1, 2, 3, 4]);

      await recorder.stop();
    });

    test(
      'emitInitialAudio replays the RAM buffer to late subscribers',
      () async {
        recorder.initialize(const MicRecorderConfig());

        expect(await recorder.startAudioBuffering(), isTrue);

        fake.emitAudioChunk(<int>[1, 2, 3, 4]);
        await pump();

        final replayed = <List<int>>[];
        final subscription = recorder.audioStream.listen(replayed.add);

        await recorder.emitInitialAudio();
        await pump();

        expect(replayed, [
          <int>[1, 2, 3, 4],
        ]);

        // The still-armed buffering subscription re-captured the replay.
        expect(recorder.drainBufferedAudio(), <int>[1, 2, 3, 4]);

        await recorder.stop();
        await subscription.cancel();
      },
    );

    test(
      'emitInitialAudio combines the voice-command tail with the RAM buffer',
      () async {
        recorder.initialize(const MicRecorderConfig());

        expect(
          await recorder.start(mode: MicRecordingMode.voiceCommand),
          isTrue,
        );

        expect(await recorder.startAudioBuffering(), isTrue);

        fake.emitAudioChunk(<int>[1, 2]);
        await pump();

        final replayed = <List<int>>[];
        final subscription = recorder.audioStream.listen(replayed.add);

        await recorder.emitInitialAudio();
        await pump();

        // Voice tail [1, 2] + drained RAM buffer [1, 2].
        expect(replayed, [
          <int>[1, 2, 1, 2],
        ]);
        expect(recorder.drainBufferedAudio(), <int>[1, 2, 1, 2]);
        expect(recorder.voiceCommandAudio, isEmpty);

        await recorder.stop();
        await subscription.cancel();
      },
    );

    test('emitInitialAudio without any audio is a no-op', () async {
      recorder.initialize(const MicRecorderConfig());

      expect(await recorder.start(), isTrue);

      final replayed = <List<int>>[];
      final subscription = recorder.audioStream.listen(replayed.add);

      await recorder.emitInitialAudio();

      expect(replayed, isEmpty);

      await recorder.stop();
      await subscription.cancel();
    });
  });

  group('MicRecorder PCM file output lifecycle', () {
    test('an existing file is replaced by default', () async {
      final path = '${tempDir.path}/replace.pcm';

      await File(path).writeAsBytes(<int>[7, 7, 7]);

      recorder.initialize(const MicRecorderConfig());

      await recorder.setOutputFile(path);

      expect(await recorder.start(), isTrue);

      fake.emitAudioChunk(<int>[1, 0]);
      await pump();

      final info = await recorder.stop();

      expect(await File(path).readAsBytes(), <int>[1, 0]);
      expect(info!.sizeBytes, 2);
    });

    test(
      'an existing file is appended to when deleteExistingFile is false',
      () async {
        final path = '${tempDir.path}/append.pcm';

        await File(path).writeAsBytes(<int>[9, 9]);

        recorder.initialize(const MicRecorderConfig());

        await recorder.setOutputFile(path, deleteExistingFile: false);

        expect(await recorder.start(), isTrue);

        fake.emitAudioChunk(<int>[1, 2, 3, 4]);
        await pump();

        await recorder.stop();

        expect(await File(path).readAsBytes(), <int>[9, 9, 1, 2, 3, 4]);
      },
    );

    test(
      'clearOutputFile finalizes mid-episode and the stream keeps flowing',
      () async {
        final path = '${tempDir.path}/midclear.wav';

        recorder.initialize(const MicRecorderConfig());

        await recorder.setOutputFile(path, format: MicRecordingFileFormat.wav);

        expect(await recorder.start(), isTrue);

        final chunks = <List<int>>[];
        final subscription = recorder.audioStream.listen(chunks.add);

        fake.emitAudioChunk(<int>[1, 2]);
        await pump();

        await recorder.clearOutputFile();

        expect(recorder.outputFile, isNull);
        expect(recorder.outputFileFormat, isNull);

        fake.emitAudioChunk(<int>[3, 4]);
        await pump();

        final info = await recorder.stop();

        expect(chunks, [
          <int>[1, 2],
          <int>[3, 4],
        ]);
        expect(info!.path, isNull);
        expect(info.fileFormat, isNull);

        final bytes = await File(path).readAsBytes();

        expect(bytes.length, 44 + 2);
        expect(bytes.sublist(44), <int>[1, 2]);

        await subscription.cancel();
      },
    );
  });

  group('MicRecorder Android foreground service', () {
    test('notification titles follow the recording state', () async {
      micIsAndroid = true;

      recorder.initialize(
        const MicRecorderConfig(
          androidForegroundService: MicForegroundServiceConfig(
            titleWhenRecording: 'Rec title',
            titleWhenListening: 'Listen title',
            titleWhenPaused: 'Pause title',
            titleWhenInterrupted: 'Interrupted title',
          ),
        ),
      );

      expect(await recorder.start(), isTrue);
      await pump();

      await recorder.pause();

      expect(await recorder.resume(), isTrue);

      await recorder.stop();

      expect(await recorder.start(mode: MicRecordingMode.voiceCommand), isTrue);
      await pump();

      fake.emitAndroidFocus(MicAndroidAudioFocus.lossTransient);
      await pump();

      expect(recorder.currentState, MicRecorderState.paused);

      fake.emitAndroidFocus(MicAndroidAudioFocus.gain);
      await pump();

      expect(recorder.currentState, MicRecorderState.recording);

      await recorder.stop();

      expect(fake.showForegroundNotificationCalls, [
        'Rec title',
        'Pause title',
        'Rec title',
        'Listen title',
        'Interrupted title',
        'Listen title',
      ]);
      expect(fake.removeForegroundNotificationCallCount, 2);
    });

    test('a failing foreground service never breaks the recording', () async {
      micIsAndroid = true;

      recorder.initialize(const MicRecorderConfig());

      fake.showForegroundNotificationResult = false;
      fake.removeForegroundNotificationResult = false;

      expect(await recorder.start(), isTrue);

      expect(recorder.currentState, MicRecorderState.recording);

      fake.emitAudioChunk(<int>[1, 2, 3, 4]);
      await pump();

      final info = await recorder.stop();

      expect(info, isNotNull);
      expect(recorder.currentState, MicRecorderState.stopped);
    });

    test('a throwing foreground service is contained', () async {
      micIsAndroid = true;

      final throwingFake = _ThrowingForegroundServicePlatform();
      MicRecorderPlatform.instance = throwingFake;

      recorder.initialize(const MicRecorderConfig());

      expect(await recorder.start(), isTrue);

      expect(recorder.currentState, MicRecorderState.recording);

      final info = await recorder.stop();

      expect(info, isNotNull);
      expect(recorder.currentState, MicRecorderState.stopped);
    });

    test(
      'a disabled foreground service issues no notification verbs',
      () async {
        micIsAndroid = true;

        recorder.initialize(
          const MicRecorderConfig(
            androidForegroundService: MicForegroundServiceConfig(
              enabled: false,
            ),
          ),
        );

        expect(await recorder.start(), isTrue);

        await recorder.pause();
        await recorder.resume();
        await recorder.stop();

        expect(fake.showForegroundNotificationCalls, isEmpty);
        expect(fake.removeForegroundNotificationCallCount, 0);
      },
    );
  });

  group('MicRecorder diagnostics', () {
    test(
      'getRouteState passes through on Android and is null elsewhere',
      () async {
        recorder.initialize(const MicRecorderConfig());

        // Neither Android nor iOS is emulated: the diagnostics verb stays
        // closed and answers null.
        expect(await recorder.getRouteState(), isNull);

        micIsAndroid = true;

        fake.getRouteStateResult = <String, Object?>{'sco': true};

        expect(await recorder.getRouteState(), <String, Object?>{'sco': true});

        expect(await recorder.isOtherAudioPlaying(), isFalse);

        // AudioManager.MODE_IN_COMMUNICATION — a call holds the microphone.
        fake.audioModeResult = 3;

        expect(await recorder.isAndroidMicHeldByCall(), isTrue);

        fake.audioModeResult = 0;

        final throwingFake = _ThrowingRouteStatePlatform();
        MicRecorderPlatform.instance = throwingFake;

        // A failing diagnostics call surfaces as null, never as a throw.
        expect(await recorder.getRouteState(), isNull);
      },
    );

    test('extractAmplitudes passes the file and bar count through', () async {
      recorder.initialize(const MicRecorderConfig());

      fake.extractAmplitudesResult = <double>[0.25, 0.5, 1.0];

      final bars = await recorder.extractAmplitudes(
        filePath: '${tempDir.path}/episode.wav',
        barCount: 3,
      );

      expect(bars, <double>[0.25, 0.5, 1.0]);
      expect(fake.callLog, contains('extractAmplitudes'));
    });
  });

  group('MicRecorder route switching', () {
    test(
      'the priority ladder can be toggled live during a recording',
      () async {
        micIsAndroid = true;

        recorder.initialize(
          const MicRecorderConfig(routeSwitchingEnabled: false),
        );

        expect(recorder.isRouteSwitchingEnabled, isFalse);

        recorder.initialize(const MicRecorderConfig());

        expect(recorder.isRouteSwitchingEnabled, isTrue);

        final sourceEvents = <MicAudioSourceSwitchedEvent>[];
        final subscription = recorder.onAudioSourceSwitched.listen(
          sourceEvents.add,
        );

        expect(await recorder.start(), isTrue);
        await pump();

        // An empty device list resolves to the system default input.
        expect(sourceEvents, isNotEmpty);
        expect(sourceEvents.first.sourceKind, MicAudioSourceKind.systemDefault);

        await recorder.setRouteSwitchingEnabled(false);

        expect(recorder.isRouteSwitchingEnabled, isFalse);
        // Standing down restores Android's normal Bluetooth behavior.
        expect(fake.setBluetoothStatusCalls, contains(true));

        await recorder.setRouteSwitchingEnabled(true);

        expect(recorder.isRouteSwitchingEnabled, isTrue);

        await recorder.stop();
        await subscription.cancel();
      },
    );
  });

  // KEEP LAST: dispose() is terminal for the singleton — its broadcast
  // controllers close permanently, so no test may run after this group.
  group('MicRecorder dispose', () {
    test('dispose stops an active recording first', () async {
      recorder.initialize(const MicRecorderConfig());

      expect(await recorder.start(), isTrue);

      fake.emitAudioChunk(<int>[1, 2, 3, 4]);
      await pump();

      await recorder.dispose();

      // The episode was torn down through the regular stop path before
      // the controllers closed.
      expect(recorder.currentState, MicRecorderState.stopped);
      expect(fake.stopRecordingCallCount, 1);
      expect(recorder.isInitialized, isFalse);
    });

    test(
      'dispose tears an idle recorder down and clears an armed encoded output',
      () async {
        recorder.initialize(const MicRecorderConfig());

        await recorder.setEncodedOutput(
          '${tempDir.path}/dispose.m4a',
          encoder: MicAudioEncoder.aacLc,
        );

        expect(recorder.encodedOutputFile, isNotNull);
        expect(recorder.isInitialized, isTrue);

        await recorder.dispose();

        expect(fake.clearEncodedOutputCallCount, 1);
        expect(recorder.encodedOutputFile, isNull);
        expect(recorder.isInitialized, isFalse);
        expect(recorder.currentState, MicRecorderState.stopped);
      },
    );
  });
}

/// A platform that delegates every verb to an embedded fake — the base
/// for variants that sabotage exactly one of them. (The shared fake is
/// `final`, so it cannot be extended outside its library.)
class _DelegatingPlatform extends MicRecorderPlatform {
  _DelegatingPlatform(this._inner);

  final FakeMicRecorderPlatform _inner;

  @override
  Stream<MicSessionEvent> sessionEvents() => _inner.sessionEvents();

  @override
  Stream<List<int>> audioDataStream() => _inner.audioDataStream();

  @override
  Future<bool> startRecording(
    int sampleRate, {
    bool androidEchoCancel = false,
    bool androidNoiseSuppress = false,
    bool androidAutoGain = false,
  }) => _inner.startRecording(
    sampleRate,
    androidEchoCancel: androidEchoCancel,
    androidNoiseSuppress: androidNoiseSuppress,
    androidAutoGain: androidAutoGain,
  );

  @override
  Future<bool> pauseRecording(bool isPausedForInterruption) =>
      _inner.pauseRecording(isPausedForInterruption);

  @override
  Future<bool> resumeRecording() => _inner.resumeRecording();

  @override
  Future<bool> stopRecording() => _inner.stopRecording();

  @override
  Future<bool> setEncodedOutput(
    String path,
    MicAudioEncoder encoder, {
    int? bitRate,
    int? sampleRate,
  }) => _inner.setEncodedOutput(
    path,
    encoder,
    bitRate: bitRate,
    sampleRate: sampleRate,
  );

  @override
  Future<bool> clearEncodedOutput() => _inner.clearEncodedOutput();

  @override
  Future<bool> checkMicPermission() => _inner.checkMicPermission();

  @override
  Future<bool> requestMicPermission() => _inner.requestMicPermission();

  @override
  Future<bool> microphoneInterrupted() => _inner.microphoneInterrupted();

  @override
  Future<void> setBluetoothStatus(bool isAllowed) =>
      _inner.setBluetoothStatus(isAllowed);

  @override
  Future<Map<String, Object?>?> getRouteState() => _inner.getRouteState();

  @override
  Future<List<double>?> extractAmplitudes({
    required String filePath,
    int barCount = 60,
  }) => _inner.extractAmplitudes(filePath: filePath, barCount: barCount);

  @override
  Future<void> configureAudioSession(MicAudioSessionConfig config) =>
      _inner.configureAudioSession(config);

  @override
  Future<bool> setAudioSessionActive(bool active) =>
      _inner.setAudioSessionActive(active);

  @override
  Future<bool> isOtherAudioPlaying() => _inner.isOtherAudioPlaying();

  @override
  Future<bool> isMusicActive() => _inner.isMusicActive();

  @override
  Future<int> getAudioMode() => _inner.getAudioMode();

  @override
  Future<void> setAllowHapticsAndSystemSoundsDuringRecording(bool enabled) =>
      _inner.setAllowHapticsAndSystemSoundsDuringRecording(enabled);

  @override
  Future<Set<MicAudioDevice>> getAudioDevices() => _inner.getAudioDevices();

  @override
  Future<List<MicAudioInput>> getAvailableInputs() =>
      _inner.getAvailableInputs();

  @override
  Future<MicAudioRoute> getCurrentRoute() => _inner.getCurrentRoute();

  @override
  Future<bool> setPreferredInput(MicAudioInput input) =>
      _inner.setPreferredInput(input);

  @override
  Future<bool> showForegroundNotification(
    String title, {
    String? channelName,
    String? channelDescription,
    String? icon,
  }) => _inner.showForegroundNotification(
    title,
    channelName: channelName,
    channelDescription: channelDescription,
    icon: icon,
  );

  @override
  Future<bool> removeForegroundNotification() =>
      _inner.removeForegroundNotification();
}

/// A platform whose foreground-service verbs throw — pins the containment
/// guards around the orchestrator's notification paths.
final class _ThrowingForegroundServicePlatform extends _DelegatingPlatform {
  _ThrowingForegroundServicePlatform() : super(FakeMicRecorderPlatform());

  @override
  Future<bool> showForegroundNotification(
    String title, {
    String? channelName,
    String? channelDescription,
    String? icon,
  }) async => throw StateError('notification channel unavailable');

  @override
  Future<bool> removeForegroundNotification() async =>
      throw StateError('notification channel unavailable');
}

/// A platform whose route-state diagnostics throw — the passthrough must
/// surface null, never the error.
final class _ThrowingRouteStatePlatform extends _DelegatingPlatform {
  _ThrowingRouteStatePlatform() : super(FakeMicRecorderPlatform());

  @override
  Future<Map<String, Object?>?> getRouteState() async =>
      throw StateError('route state unavailable');
}
