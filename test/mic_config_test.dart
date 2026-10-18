// Direct unit coverage for the configurations in lib/src/config/.
//
// MicRecorderConfig has no copyWith and no monolithic wire map of its own —
// the recorder decomposes it into the start verb's payload (sample rate and
// effect flags), the audio-session verb's config map and the
// foreground-notification verbs (those payloads are pinned in
// method_channel_mic_recorder_test.dart). This file pins the configs' own
// public surface — defaults, round-trips and diagnostics formatting — plus
// the wire maps the two sub-configs serialize into when forwarded the way
// the recorder forwards them.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mic_recorder/src/config/mic_audio_session_config.dart';
import 'package:mic_recorder/src/config/mic_foreground_service_config.dart';
import 'package:mic_recorder/src/config/mic_recorder_config.dart';
import 'package:mic_recorder/src/internal/mic_logger.dart';
import 'package:mic_recorder/src/platform/method_channel_mic_recorder.dart';

const MethodChannel _methodsChannel = MethodChannel(
  'com.bilalahmed24.mic_recorder/methods',
);

/// Records every method call sent to the methods channel; the wire tests
/// assert on the captured arguments.
final class MethodCallLog {
  final calls = <MethodCall>[];

  Future<Object?>? onCall(MethodCall call) {
    calls.add(call);
    return null;
  }

  MethodCall operator [](String method) =>
      calls.firstWhere((call) => call.method == method);
}

/// A custom log sink (top-level, so the tear-off is a stable value).
void _customLogSink(
  MicLogLevel level,
  String message, [
  Map<String, Object?>? data,
]) {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger = TestWidgetsFlutterBinding.instance.defaultBinaryMessenger;

  late MethodCallLog calls;

  setUp(() {
    calls = MethodCallLog();
    messenger.setMockMethodCallHandler(_methodsChannel, calls.onCall);
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(_methodsChannel, null);
  });

  group('MicRecorderConfig', () {
    test('defaults to the production capture profile', () {
      const config = MicRecorderConfig();

      expect(config.sampleRate, 16000);
      expect(config.routeSwitchingEnabled, isTrue);
      expect(config.amplitudeInterval, const Duration(milliseconds: 100));
      expect(config.androidEchoCancel, isFalse);
      expect(config.androidNoiseSuppress, isFalse);
      expect(config.androidAutoGain, isFalse);
      expect(config.wantsAndroidAudioEffects, isFalse);
      expect(config.maxDuration, isNull);
      expect(config.log, isNull);

      // The embedded audio-session defaults.
      expect(config.audioSession.allowBluetooth, isTrue);
      expect(config.audioSession.defaultToSpeaker, isTrue);
      expect(config.audioSession.notifyOthersOnDeactivation, isTrue);
      expect(config.audioSession.androidWillPauseWhenDucked, isTrue);

      // The embedded foreground-service defaults.
      expect(config.androidForegroundService.enabled, isTrue);
      expect(config.androidForegroundService.channelName, 'Recording');
      expect(
        config.androidForegroundService.channelDescription,
        'Microphone recording status',
      );
      expect(config.androidForegroundService.icon, isNull);
      expect(
        config.androidForegroundService.titleWhenRecording,
        'Recording conversation',
      );
      expect(
        config.androidForegroundService.titleWhenListening,
        'Listening for voice command',
      );
      expect(
        config.androidForegroundService.titleWhenPaused,
        'Recording paused',
      );
      expect(
        config.androidForegroundService.titleWhenInterrupted,
        'Recording interrupted',
      );
    });

    test('round-trips every configured value', () {
      final config = MicRecorderConfig(
        sampleRate: 8000,
        audioSession: const MicAudioSessionConfig(
          allowBluetooth: false,
          defaultToSpeaker: false,
          notifyOthersOnDeactivation: false,
          androidWillPauseWhenDucked: false,
        ),
        androidForegroundService: const MicForegroundServiceConfig(
          enabled: false,
          channelName: 'Custom channel',
          channelDescription: 'Custom description',
          icon: 'ic_stat_mic',
          titleWhenRecording: 'Custom recording',
          titleWhenListening: 'Custom listening',
          titleWhenPaused: 'Custom paused',
          titleWhenInterrupted: 'Custom interrupted',
        ),
        routeSwitchingEnabled: false,
        amplitudeInterval: const Duration(milliseconds: 250),
        androidEchoCancel: true,
        androidNoiseSuppress: true,
        androidAutoGain: true,
        maxDuration: const Duration(minutes: 5),
        log: _customLogSink,
      );

      expect(config.sampleRate, 8000);
      expect(config.audioSession.allowBluetooth, isFalse);
      expect(config.audioSession.defaultToSpeaker, isFalse);
      expect(config.audioSession.notifyOthersOnDeactivation, isFalse);
      expect(config.audioSession.androidWillPauseWhenDucked, isFalse);
      expect(config.androidForegroundService.enabled, isFalse);
      expect(config.androidForegroundService.channelName, 'Custom channel');
      expect(
        config.androidForegroundService.channelDescription,
        'Custom description',
      );
      expect(config.androidForegroundService.icon, 'ic_stat_mic');
      expect(
        config.androidForegroundService.titleWhenRecording,
        'Custom recording',
      );
      expect(
        config.androidForegroundService.titleWhenListening,
        'Custom listening',
      );
      expect(config.androidForegroundService.titleWhenPaused, 'Custom paused');
      expect(
        config.androidForegroundService.titleWhenInterrupted,
        'Custom interrupted',
      );
      expect(config.routeSwitchingEnabled, isFalse);
      expect(config.amplitudeInterval, const Duration(milliseconds: 250));
      expect(config.androidEchoCancel, isTrue);
      expect(config.androidNoiseSuppress, isTrue);
      expect(config.androidAutoGain, isTrue);
      expect(config.wantsAndroidAudioEffects, isTrue);
      expect(config.maxDuration, const Duration(minutes: 5));
      expect(config.log, isNotNull);
    });

    test('wantsAndroidAudioEffects is on for any Android effect flag', () {
      expect(const MicRecorderConfig().wantsAndroidAudioEffects, isFalse);
      expect(
        const MicRecorderConfig(
          androidEchoCancel: true,
        ).wantsAndroidAudioEffects,
        isTrue,
      );
      expect(
        const MicRecorderConfig(
          androidNoiseSuppress: true,
        ).wantsAndroidAudioEffects,
        isTrue,
      );
      expect(
        const MicRecorderConfig(androidAutoGain: true).wantsAndroidAudioEffects,
        isTrue,
      );
    });

    test('formats itself for diagnostics', () {
      expect(
        const MicRecorderConfig().toString(),
        'MicRecorderConfig(sampleRate: 16000, '
        'audioSession: MicAudioSessionConfig(allowBluetooth: true, '
        'defaultToSpeaker: true, notifyOthersOnDeactivation: true, '
        'androidWillPauseWhenDucked: true), '
        'androidForegroundService: MicForegroundServiceConfig(enabled: true, '
        'channelName: Recording, '
        'channelDescription: Microphone recording status, icon: null, '
        'titleWhenRecording: Recording conversation, '
        'titleWhenListening: Listening for voice command, '
        'titleWhenPaused: Recording paused, '
        'titleWhenInterrupted: Recording interrupted), '
        'routeSwitchingEnabled: true, amplitudeInterval: 0:00:00.100000, '
        'androidEchoCancel: false, androidNoiseSuppress: false, '
        'androidAutoGain: false, maxDuration: null, log: defaultMicLog)',
      );

      final custom = MicRecorderConfig(
        maxDuration: const Duration(minutes: 5),
        log: _customLogSink,
      );

      expect(custom.toString(), contains('maxDuration: 0:05:00.000000'));
      expect(custom.toString(), contains('log: custom'));
    });
  });

  group('MicAudioSessionConfig', () {
    test('defaults every option to true', () {
      const config = MicAudioSessionConfig();

      expect(config.allowBluetooth, isTrue);
      expect(config.defaultToSpeaker, isTrue);
      expect(config.notifyOthersOnDeactivation, isTrue);
      expect(config.androidWillPauseWhenDucked, isTrue);
    });

    test('round-trips every option', () {
      const config = MicAudioSessionConfig(
        allowBluetooth: false,
        defaultToSpeaker: false,
        notifyOthersOnDeactivation: false,
        androidWillPauseWhenDucked: false,
      );

      expect(config.allowBluetooth, isFalse);
      expect(config.defaultToSpeaker, isFalse);
      expect(config.notifyOthersOnDeactivation, isFalse);
      expect(config.androidWillPauseWhenDucked, isFalse);
    });

    test('formats itself for diagnostics', () {
      expect(
        const MicAudioSessionConfig().toString(),
        'MicAudioSessionConfig(allowBluetooth: true, defaultToSpeaker: true, '
        'notifyOthersOnDeactivation: true, androidWillPauseWhenDucked: true)',
      );
    });

    test('serializes onto the wire with the documented keys', () async {
      final platform = MethodChannelMicRecorder();

      await platform.configureAudioSession(const MicAudioSessionConfig());

      // The defaults flow to the natives as the all-true focus profile.
      expect(calls['configureAudioSession'].arguments, <String, Object?>{
        'config': <String, Object?>{
          'allowBluetooth': true,
          'defaultToSpeaker': true,
          'notifyOthersOnDeactivation': true,
          'willPauseWhenDucked': true,
        },
      });

      const ducked = MicAudioSessionConfig(
        allowBluetooth: false,
        defaultToSpeaker: false,
        notifyOthersOnDeactivation: false,
        androidWillPauseWhenDucked: false,
      );

      await platform.configureAudioSession(ducked);

      expect(calls.calls.last.arguments, <String, Object?>{
        'config': <String, Object?>{
          'allowBluetooth': false,
          'defaultToSpeaker': false,
          'notifyOthersOnDeactivation': false,
          'willPauseWhenDucked': false,
        },
      });
    });
  });

  group('MicForegroundServiceConfig', () {
    test('defaults to the recording-status notification', () {
      const config = MicForegroundServiceConfig();

      expect(config.enabled, isTrue);
      expect(config.channelName, 'Recording');
      expect(config.channelDescription, 'Microphone recording status');
      expect(config.icon, isNull);
      expect(config.titleWhenRecording, 'Recording conversation');
      expect(config.titleWhenListening, 'Listening for voice command');
      expect(config.titleWhenPaused, 'Recording paused');
      expect(config.titleWhenInterrupted, 'Recording interrupted');
    });

    test('round-trips every field', () {
      const config = MicForegroundServiceConfig(
        enabled: false,
        channelName: 'Custom channel',
        channelDescription: 'Custom description',
        icon: 'ic_stat_mic',
        titleWhenRecording: 'Custom recording',
        titleWhenListening: 'Custom listening',
        titleWhenPaused: 'Custom paused',
        titleWhenInterrupted: 'Custom interrupted',
      );

      expect(config.enabled, isFalse);
      expect(config.channelName, 'Custom channel');
      expect(config.channelDescription, 'Custom description');
      expect(config.icon, 'ic_stat_mic');
      expect(config.titleWhenRecording, 'Custom recording');
      expect(config.titleWhenListening, 'Custom listening');
      expect(config.titleWhenPaused, 'Custom paused');
      expect(config.titleWhenInterrupted, 'Custom interrupted');
    });

    test('formats itself for diagnostics', () {
      expect(
        const MicForegroundServiceConfig().toString(),
        'MicForegroundServiceConfig(enabled: true, channelName: Recording, '
        'channelDescription: Microphone recording status, icon: null, '
        'titleWhenRecording: Recording conversation, '
        'titleWhenListening: Listening for voice command, '
        'titleWhenPaused: Recording paused, '
        'titleWhenInterrupted: Recording interrupted)',
      );
    });

    test(
      'feeds the foreground-notification wire map as the recorder forwards it',
      () async {
        final platform = MethodChannelMicRecorder();
        const config = MicForegroundServiceConfig();

        // The recorder forwards the config fields to the verb verbatim (see
        // MicRecorder._showForegroundNotification).
        await platform.showForegroundNotification(
          config.titleWhenRecording,
          channelName: config.channelName,
          channelDescription: config.channelDescription,
          icon: config.icon,
        );

        // A null icon is omitted — the bundled microphone icon applies natively.
        expect(calls['showForegroundNotification'].arguments, <String, Object?>{
          'notificationTitle': 'Recording conversation',
          'channelName': 'Recording',
          'channelDescription': 'Microphone recording status',
        });

        const withIcon = MicForegroundServiceConfig(icon: 'ic_stat_mic');

        await platform.showForegroundNotification(
          withIcon.titleWhenListening,
          channelName: withIcon.channelName,
          channelDescription: withIcon.channelDescription,
          icon: withIcon.icon,
        );

        expect(calls.calls.last.arguments, <String, Object?>{
          'notificationTitle': 'Listening for voice command',
          'channelName': 'Recording',
          'channelDescription': 'Microphone recording status',
          'icon': 'ic_stat_mic',
        });
      },
    );
  });
}
