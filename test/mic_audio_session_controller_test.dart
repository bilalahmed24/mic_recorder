import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:mic_recorder/src/config/mic_audio_session_config.dart';
import 'package:mic_recorder/src/internal/mic_logger.dart';
import 'package:mic_recorder/src/internal/mic_platform.dart';
import 'package:mic_recorder/src/lifecycle/app_lifecycle_tracker.dart';
import 'package:mic_recorder/src/models/mic_audio_device.dart';
import 'package:mic_recorder/src/models/mic_audio_interruption.dart';
import 'package:mic_recorder/src/models/mic_recorder_events.dart';
import 'package:mic_recorder/src/models/mic_session_events.dart';
import 'package:mic_recorder/src/session/mic_audio_session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_mic_recorder_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final tracker = AppLifecycleTracker.instance;

  late FakeMicRecorderPlatform fake;
  late List<(MicLogLevel, String)> logs;
  late MicAudioSessionController controller;

  setUpAll(() {
    // Deterministic foreground start (the tracker is a per-isolate
    // singleton shared by every test in this file).
    tracker.didChangeAppLifecycleState(AppLifecycleState.resumed);
  });

  setUp(() {
    fake = FakeMicRecorderPlatform();
    logs = <(MicLogLevel, String)>[];

    controller = MicAudioSessionController(
      config: const MicAudioSessionConfig(),
      log: (MicLogLevel level, String message, [Map<String, Object?>? data]) =>
          logs.add((level, message)),
      lifecycle: tracker,
      platform: fake,
    );
  });

  tearDown(() async {
    micIsAndroid = false;
    micIsIOS = false;
    tracker.didChangeAppLifecycleState(AppLifecycleState.resumed);

    await controller.dispose();
    await fake.dispose();
  });

  group('init', () {
    test('happy path configures then activates the session', () async {
      const config = MicAudioSessionConfig(androidWillPauseWhenDucked: false);
      final local = FakeMicRecorderPlatform();

      final localController = MicAudioSessionController(
        config: config,
        log: (_, _, [_]) {},
        lifecycle: tracker,
        platform: local,
      );

      await localController.init();

      expect(local.configureAudioSessionCalls, <MicAudioSessionConfig>[config]);
      expect(local.setAudioSessionActiveCalls, <bool>[true]);
      expect(local.callLog, <String>[
        'sessionEvents',
        'configureAudioSession',
        'isOtherAudioPlaying',
        'setAudioSessionActive',
      ]);
      expect(localController.isInitiated, isTrue);

      await localController.dispose();
      await local.dispose();
    });

    test('init is idempotent once activated', () async {
      await controller.init();
      await controller.init();

      expect(fake.configureAudioSessionCalls, hasLength(1));
      expect(fake.setAudioSessionActiveCalls, <bool>[true]);
      expect(controller.isInitiated, isTrue);
    });

    testWidgets('activation failure interrupts, resets and retries', (
      tester,
    ) async {
      // Fake-async law: instances built in setUp carry real-zone stream
      // machinery that never advances on tester.pump — build locally.
      final localFake = FakeMicRecorderPlatform();
      localFake.setAudioSessionActiveResponses.addAll(<bool>[false, true]);

      final local = MicAudioSessionController(
        config: const MicAudioSessionConfig(),
        log: (_, _, [_]) {},
        lifecycle: tracker,
        platform: localFake,
      );

      // Activation failures surface on the distinct bool stream (the
      // orchestrator's trigger); the rich event stream stays quiet until
      // the interruption handler is installed by a successful init.
      final states = <bool>[];
      final subscription = local.onAudioInterruption.listen(states.add);

      // Never bare-await init() — the retry ladder is timer-driven and
      // only advances on pumps.
      final done = local.init();
      await tester.pump();
      await tester.pump();

      // First attempt failed: an interruption began, the session was torn
      // down (deactivation), and a retry is scheduled after 5 seconds.
      expect(states, <bool>[false, true]);
      expect(localFake.setAudioSessionActiveCalls, <bool>[true, false]);
      expect(local.isInitiated, isFalse);

      await tester.pump(const Duration(seconds: 5));
      await done;

      // The retry reconfigured and finally activated the session.
      expect(localFake.setAudioSessionActiveCalls, <bool>[true, false, true]);
      expect(localFake.configureAudioSessionCalls, hasLength(2));
      expect(local.isInitiated, isTrue);
      expect(states.last, isFalse);

      // Trailing awaits never drain without a pump — release fire-and-
      // forget and drain the queue.
      unawaited(subscription.cancel());
      unawaited(local.dispose());
      unawaited(localFake.dispose());
      await tester.pump();
    });

    testWidgets('other audio playing on Android blocks activation', (
      tester,
    ) async {
      micIsAndroid = true;

      // Fake-async law: build locally (see the test above).
      final localFake = FakeMicRecorderPlatform();
      localFake.isMusicActiveResult = true;

      final local = MicAudioSessionController(
        config: const MicAudioSessionConfig(),
        log: (_, _, [_]) {},
        lifecycle: tracker,
        platform: localFake,
      );

      final states = <bool>[];
      final subscription = local.onAudioInterruption.listen(states.add);

      final done = local.init();
      await tester.pump();
      await tester.pump();

      // Android isOtherAudioPlaying consults isMusicActive + audio mode.
      expect(localFake.callLog, contains('isMusicActive'));
      // Activation never happened; the failure path tore the (never
      // activated) request back down.
      expect(localFake.setAudioSessionActiveCalls, <bool>[false]);
      expect(states, <bool>[false, true]);

      // The interrupting music stops; the 5s retry activates.
      localFake.isMusicActiveResult = false;
      await tester.pump(const Duration(seconds: 5));
      await done;

      expect(local.isInitiated, isTrue);
      expect(localFake.setAudioSessionActiveCalls, <bool>[false, true]);

      unawaited(subscription.cancel());
      unawaited(local.dispose());
      unawaited(localFake.dispose());
      await tester.pump();
    });

    test('iOS haptics are enabled on init', () async {
      micIsIOS = true;

      await controller.init();

      expect(fake.setAllowHapticsCalls, <bool>[true]);
      expect(controller.isInitiated, isTrue);
    });
  });

  group('Android focus mapping', () {
    Future<List<MicAudioInterruption>> collectDuring(
      Future<void> Function() action,
    ) async {
      final events = <MicAudioInterruption>[];
      final subscription = controller.interruptionStream.listen(events.add);

      await action();

      await pumpEventQueue();
      await subscription.cancel();

      return events;
    }

    test('loss begins an unknown interruption; gain ends it', () async {
      await controller.init();

      final events = await collectDuring(() async {
        fake.emitAndroidFocus(MicAndroidAudioFocus.loss);
        fake.emitAndroidFocus(MicAndroidAudioFocus.gain);
      });

      expect(events, hasLength(2));

      final begin = events[0];

      expect(begin.begin, isTrue);
      expect(begin.type, MicAudioInterruptionType.unknown);

      final end = events[1];

      expect(end.begin, isFalse);
      expect(end.type, MicAudioInterruptionType.pause);
    });

    test('lossTransient is a pause interruption', () async {
      await controller.init();

      final events = await collectDuring(
        () async => fake.emitAndroidFocus(MicAndroidAudioFocus.lossTransient),
      );

      expect(events.single.begin, isTrue);
      expect(events.single.type, MicAudioInterruptionType.pause);
    });

    test('can-duck pauses when willPauseWhenDucked is set', () async {
      await controller.init();

      final events = await collectDuring(
        () async =>
            fake.emitAndroidFocus(MicAndroidAudioFocus.lossTransientCanDuck),
      );

      expect(events.single.begin, isTrue);
      expect(events.single.type, MicAudioInterruptionType.pause);
    });

    test('can-duck ducks (and gain ends the duck) when configured', () async {
      final ducking = FakeMicRecorderPlatform();

      final duckingController = MicAudioSessionController(
        config: const MicAudioSessionConfig(androidWillPauseWhenDucked: false),
        log: (_, _, [_]) {},
        lifecycle: tracker,
        platform: ducking,
      );
      await duckingController.init();

      final events = <MicAudioInterruption>[];
      final subscription = duckingController.interruptionStream.listen(
        events.add,
      );

      ducking.emitAndroidFocus(MicAndroidAudioFocus.lossTransientCanDuck);
      await pumpEventQueue();
      ducking.emitAndroidFocus(MicAndroidAudioFocus.gain);
      await pumpEventQueue();

      expect(events, hasLength(2));
      expect(events[0].begin, isTrue);
      expect(events[0].type, MicAudioInterruptionType.duck);
      expect(events[1].begin, isFalse);
      expect(events[1].type, MicAudioInterruptionType.duck);

      await subscription.cancel();
      await duckingController.dispose();
      await ducking.dispose();
    });

    test('unmapped focus codes produce no interruption', () async {
      await controller.init();

      final events = await collectDuring(() async => fake.emitAndroidFocus(42));

      expect(events, isEmpty);
      expect(
        logs,
        contains(
          predicate<(MicLogLevel, String)>(
            (entry) =>
                entry.$1 == MicLogLevel.warn &&
                entry.$2 == 'unmappedFocusChange',
          ),
        ),
      );
    });

    test('onAudioInterruption exposes the distinct bool stream', () async {
      await controller.init();

      final states = <bool>[];
      final subscription = controller.onAudioInterruption.listen(states.add);
      await pumpEventQueue();

      // A new listener first receives the current (not interrupted) value.
      expect(states, <bool>[false]);

      fake.emitAndroidFocus(MicAndroidAudioFocus.loss);
      await pumpEventQueue();

      expect(states, <bool>[false, true]);
      expect(controller.isInterruptionActive, isTrue);

      fake.emitAndroidFocus(MicAndroidAudioFocus.gain);
      await pumpEventQueue();

      expect(states, <bool>[false, true, false]);
      expect(controller.isInterruptionActive, isFalse);
      expect(controller.lastInterruptionEventAt, isNotNull);

      await subscription.cancel();
    });

    test('an unknown-interruption end re-activates the session', () async {
      // Android focus GAIN maps to a pause-end and leaves the session
      // alone (the system auto-regrants focus); only an unknown END
      // (iOS interruption ended without shouldResume) re-asserts it.
      micIsIOS = true;

      await controller.init();
      fake.setAudioSessionActiveCalls.clear();

      final states = <bool>[];
      final subscription = controller.onAudioInterruption.listen(states.add);
      await pumpEventQueue();

      fake.emitIosInterruption(
        began: true,
        shouldResume: false,
        wasSuspended: false,
      );
      await pumpEventQueue();

      expect(states, <bool>[false, true]);

      fake.emitIosInterruption(began: false, shouldResume: false);
      await pumpEventQueue();

      // Interruption-end recovery explicitly re-asserts activation.
      expect(fake.setAudioSessionActiveCalls, <bool>[true]);
      expect(controller.isInterruptionActive, isFalse);

      await subscription.cancel();
    });
  });

  group('iOS interruption mapping', () {
    test('began (not suspended) is an unknown interruption', () async {
      await controller.init();

      final events = <MicAudioInterruption>[];
      final subscription = controller.interruptionStream.listen(events.add);

      fake.emitIosInterruption(
        began: true,
        shouldResume: false,
        wasSuspended: false,
      );
      await pumpEventQueue();

      expect(events.single.begin, isTrue);
      expect(events.single.type, MicAudioInterruptionType.unknown);

      await subscription.cancel();
    });

    test('a wasSuspended began event is dropped', () async {
      await controller.init();

      final events = <MicAudioInterruption>[];
      final subscription = controller.interruptionStream.listen(events.add);

      fake.emitIosInterruption(
        began: true,
        shouldResume: false,
        wasSuspended: true,
      );
      await pumpEventQueue();

      expect(events, isEmpty);

      await subscription.cancel();
    });

    test('ended with shouldResume is a pause end', () async {
      await controller.init();

      final events = <MicAudioInterruption>[];
      final subscription = controller.interruptionStream.listen(events.add);

      fake.emitIosInterruption(began: false, shouldResume: true);
      await pumpEventQueue();

      expect(events.single.begin, isFalse);
      expect(events.single.type, MicAudioInterruptionType.pause);

      await subscription.cancel();
    });

    test('ended without shouldResume is an unknown end', () async {
      await controller.init();

      final events = <MicAudioInterruption>[];
      final subscription = controller.interruptionStream.listen(events.add);

      fake.emitIosInterruption(began: false, shouldResume: false);
      await pumpEventQueue();

      expect(events.single.begin, isFalse);
      expect(events.single.type, MicAudioInterruptionType.unknown);

      await subscription.cancel();
    });

    test('an unknown-interruption end after a pause-end hard resets', () async {
      micIsIOS = true;

      await controller.init();
      fake.microphoneInterruptedCallCount = 0;

      final events = <MicAudioInterruption>[];
      final subscription = controller.interruptionStream.listen(events.add);

      // Unknown interruption begins...
      fake.emitIosInterruption(
        began: true,
        shouldResume: false,
        wasSuspended: false,
      );
      await pumpEventQueue();

      expect(fake.microphoneInterruptedCallCount, 0);

      // ...and a resumable end while an unknown interruption is pending
      // triggers the hard reset path.
      fake.emitIosInterruption(began: false, shouldResume: true);
      await pumpEventQueue();

      expect(fake.microphoneInterruptedCallCount, 1);
      expect(fake.setAudioSessionActiveCalls, contains(false));

      await subscription.cancel();
    });

    test('mic-lost fires for a backgrounded unknown interruption', () async {
      micIsIOS = true;
      tracker.didChangeAppLifecycleState(AppLifecycleState.paused);

      await controller.init();

      final lost = <MicMicrophoneLostEvent>[];
      final subscription = controller.onMicrophoneLost.listen(lost.add);

      fake.emitIosInterruption(
        began: true,
        shouldResume: false,
        wasSuspended: false,
      );
      await pumpEventQueue();

      expect(lost, hasLength(1));
      expect(lost.single.reason, 'unknown-interruption');

      await subscription.cancel();
    });
  });

  group('interruption-end recovery', () {
    testWidgets('retries while another app holds audio, then recovers', (
      tester,
    ) async {
      micIsIOS = true;

      // Fake-async law: local instances only (timer-driven retries).
      final localFake = FakeMicRecorderPlatform();
      localFake.isOtherAudioPlayingResult = false;

      final local = MicAudioSessionController(
        config: const MicAudioSessionConfig(),
        log: (_, _, [_]) {},
        lifecycle: tracker,
        platform: localFake,
      );

      final initDone = local.init();
      await tester.pump();
      await initDone;
      localFake.setAudioSessionActiveCalls.clear();

      final states = <bool>[];
      final subscription = local.onAudioInterruption.listen(states.add);
      await tester.pump();

      localFake.emitIosInterruption(
        began: true,
        shouldResume: false,
        wasSuspended: false,
      );
      await tester.pump();
      await tester.pump();

      expect(states, <bool>[false, true]);

      // The interrupting app is still playing when the interruption ends.
      localFake.isOtherAudioPlayingResult = true;

      localFake.emitIosInterruption(began: false, shouldResume: false);
      await tester.pump();
      await tester.pump();

      // Recovery failed (other audio still playing) — a retry is scheduled.
      expect(states, <bool>[false, true]);
      expect(local.isRecoveringFromInterruption, isTrue);
      expect(localFake.setAudioSessionActiveCalls, isEmpty);

      // The interrupting app stopped.
      localFake.isOtherAudioPlayingResult = false;
      await tester.pump(const Duration(seconds: 3));

      expect(states, <bool>[false, true, false]);
      expect(localFake.setAudioSessionActiveCalls, <bool>[true]);
      expect(local.isRecoveringFromInterruption, isFalse);

      unawaited(subscription.cancel());
      unawaited(local.dispose());
      unawaited(localFake.dispose());
      await tester.pump();
    });

    testWidgets('iOS defers the session write while backgrounded', (
      tester,
    ) async {
      micIsIOS = true;

      // Fake-async law: local instances only (timer-driven retries).
      final localFake = FakeMicRecorderPlatform();
      localFake.isOtherAudioPlayingResult = false;

      final local = MicAudioSessionController(
        config: const MicAudioSessionConfig(),
        log: (_, _, [_]) {},
        lifecycle: tracker,
        platform: localFake,
      );

      final initDone = local.init();
      await tester.pump();
      await initDone;
      localFake.setAudioSessionActiveCalls.clear();

      final states = <bool>[];
      final subscription = local.onAudioInterruption.listen(states.add);

      tracker.didChangeAppLifecycleState(AppLifecycleState.paused);

      localFake.emitIosInterruption(
        began: true,
        shouldResume: false,
        wasSuspended: false,
      );
      await tester.pump();

      localFake.emitIosInterruption(began: false, shouldResume: true);
      await tester.pump();

      // Backgrounded iOS never writes the session — the debt is paid on
      // the foreground return.
      expect(localFake.setAudioSessionActiveCalls, isEmpty);
      expect(states, <bool>[true]);

      tracker.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pump(const Duration(seconds: 3));

      expect(localFake.setAudioSessionActiveCalls, <bool>[true]);
      expect(states, <bool>[true, false]);

      unawaited(subscription.cancel());
      unawaited(local.dispose());
      unawaited(localFake.dispose());
      await tester.pump();
    });

    test('Android polls the interrupting audio while backgrounded', () async {
      micIsAndroid = true;

      await controller.init();
      fake.setAudioSessionActiveCalls.clear();
      fake.isMusicActiveResult = false;
      fake.isOtherAudioPlayingResult = false;

      final states = <bool>[];
      final subscription = controller.onAudioInterruption.listen(states.add);

      fake.emitAndroidFocus(MicAndroidAudioFocus.loss);
      await pumpEventQueue();

      // Background watch is armed; recovery happens immediately on gain.
      fake.emitAndroidFocus(MicAndroidAudioFocus.gain);
      await pumpEventQueue();

      expect(states, <bool>[true, false]);

      await subscription.cancel();
    });

    test('markInterruptionResolved clears the interruption state', () async {
      await controller.init();

      final states = <bool>[];
      final subscription = controller.onAudioInterruption.listen(states.add);

      fake.emitAndroidFocus(MicAndroidAudioFocus.loss);
      await pumpEventQueue();

      expect(controller.isInterruptionActive, isTrue);

      controller.markInterruptionResolved();
      await pumpEventQueue();

      expect(controller.isInterruptionActive, isFalse);
      expect(states.last, isFalse);

      await subscription.cancel();
    });
  });

  group('devices', () {
    test('getDevices returns the platform snapshot', () async {
      fake.audioDevicesResult = <MicAudioDevice>{
        makeDevice(MicAudioDeviceType.usbAudio, id: 'usb', name: 'USB mic'),
      };

      expect(await controller.getDevices(), fake.audioDevicesResult);
      expect(fake.callLog, contains('getAudioDevices'));
    });

    test('getDevices maps platform failures to an empty set', () async {
      fake.getAudioDevicesError = Exception('device service down');

      expect(await controller.getDevices(), isEmpty);
      expect(
        logs,
        contains(
          predicate<(MicLogLevel, String)>(
            (entry) =>
                entry.$1 == MicLogLevel.error && entry.$2 == 'getDevicesError',
          ),
        ),
      );
    });

    test('devicesStream seeds the snapshot and follows changes', () async {
      await controller.init();

      final first = <MicAudioDevice>{
        makeDevice(MicAudioDeviceType.builtInMic, id: 'mic', name: 'Mic'),
      };
      final second = <MicAudioDevice>{
        makeDevice(MicAudioDeviceType.usbAudio, id: 'usb', name: 'USB'),
      };

      fake.audioDevicesResult = first;

      final snapshots = <Set<MicAudioDevice>>[];
      final subscription = controller.devicesStream.listen(snapshots.add);
      await pumpEventQueue();

      // Listening primes the current snapshot.
      expect(snapshots, <Set<MicAudioDevice>>[first]);

      fake.audioDevicesResult = second;

      fake.emitDevicesChanged(added: second.toList());
      await pumpEventQueue();

      expect(snapshots, hasLength(2));
      expect(snapshots[1], second);

      await subscription.cancel();
    });

    test('iOS route changes refresh the device snapshot', () async {
      await controller.init();

      final first = <MicAudioDevice>{
        makeDevice(MicAudioDeviceType.builtInMic, id: 'mic', name: 'Mic'),
      };

      fake.audioDevicesResult = first;

      final snapshots = <Set<MicAudioDevice>>[];
      final subscription = controller.devicesStream.listen(snapshots.add);
      await pumpEventQueue();

      fake.getAudioDevicesCallCount = 0;

      // A category change alone does not recompute the set.
      fake.emitIosRouteChange(MicIosRouteChangeReason.categoryChange);
      await pumpEventQueue();

      expect(fake.getAudioDevicesCallCount, 0);

      // Device (un)availability does.
      fake.emitIosRouteChange(MicIosRouteChangeReason.newDeviceAvailable);
      await pumpEventQueue();

      fake.emitIosRouteChange(MicIosRouteChangeReason.oldDeviceUnavailable);
      await pumpEventQueue();

      expect(fake.getAudioDevicesCallCount, 2);
      expect(snapshots, hasLength(3));

      await subscription.cancel();
    });

    test('device refreshes without listeners skip the platform call', () async {
      fake.emitDevicesChanged(
        added: <MicAudioDevice>[
          makeDevice(MicAudioDeviceType.bluetoothSco, id: 'bt', name: 'BT'),
        ],
      );
      await pumpEventQueue();

      expect(fake.callLog, isNot(contains('getAudioDevices')));
    });
  });

  group('isOtherAudioPlaying / mic-held-by-call', () {
    test('delegates to the platform on other platforms', () async {
      fake.isOtherAudioPlayingResult = true;

      expect(await controller.isOtherAudioPlaying(), isTrue);
      expect(fake.callLog, contains('isOtherAudioPlaying'));
    });

    test('Android combines isMusicActive with the call mode', () async {
      micIsAndroid = true;

      fake.isMusicActiveResult = true;

      expect(await controller.isOtherAudioPlaying(), isTrue);
      expect(fake.callLog, contains('isMusicActive'));

      // Music inactive but a call holds the microphone.
      final second = FakeMicRecorderPlatform();
      final secondController = MicAudioSessionController(
        config: const MicAudioSessionConfig(),
        log: (_, _, [_]) {},
        lifecycle: tracker,
        platform: second,
      );

      second.isMusicActiveResult = false;
      second.audioModeResult = 3;

      expect(await secondController.isOtherAudioPlaying(), isTrue);
      expect(second.callLog, contains('getAudioMode'));

      second.audioModeResult = 0;

      expect(await secondController.isOtherAudioPlaying(), isFalse);

      await secondController.dispose();
      await second.dispose();
    });

    test('isAndroidMicHeldByCall is Android-only', () async {
      // Not Android: no mode query, always false.
      expect(await controller.isAndroidMicHeldByCall(), isFalse);
      expect(fake.callLog, isNot(contains('getAudioMode')));

      micIsAndroid = true;
      fake.audioModeResult = 2;

      expect(await controller.isAndroidMicHeldByCall(), isTrue);

      fake.audioModeResult = 3;

      expect(await controller.isAndroidMicHeldByCall(), isTrue);

      fake.audioModeResult = 0;

      expect(await controller.isAndroidMicHeldByCall(), isFalse);
    });
  });

  group('resetService', () {
    test('deactivates the session while foregrounded', () async {
      await controller.init();

      await controller.resetService();

      expect(fake.setAudioSessionActiveCalls, <bool>[true, false]);
      expect(controller.isInitiated, isFalse);
    });

    test('Android deactivates even while backgrounded', () async {
      micIsAndroid = true;

      await controller.init();

      tracker.didChangeAppLifecycleState(AppLifecycleState.paused);

      await controller.resetService();

      expect(fake.setAudioSessionActiveCalls, <bool>[true, false]);
    });

    test('iOS skips deactivation while backgrounded but hard-resets', () async {
      micIsIOS = true;

      await controller.init();
      fake.setAudioSessionActiveCalls.clear();

      tracker.didChangeAppLifecycleState(AppLifecycleState.paused);

      await controller.resetService(isHardReset: true);

      expect(fake.setAudioSessionActiveCalls, isEmpty);
      expect(fake.microphoneInterruptedCallCount, 1);
      expect(controller.isInitiated, isFalse);
    });
  });

  group('reassertActivation', () {
    test('re-asserts the audio session', () async {
      await controller.init();
      fake.setAudioSessionActiveCalls.clear();

      await controller.reassertActivation();

      expect(fake.setAudioSessionActiveCalls, <bool>[true]);
    });

    test('iOS never writes the session while backgrounded', () async {
      micIsIOS = true;

      tracker.didChangeAppLifecycleState(AppLifecycleState.paused);

      await controller.reassertActivation();

      expect(fake.setAudioSessionActiveCalls, isEmpty);
    });
  });

  group('dispose', () {
    test('stops consuming session events and closes streams', () async {
      await controller.init();

      final events = <MicAudioInterruption>[];
      final subscription = controller.interruptionStream.listen(events.add);

      await controller.dispose();

      // Closed stream: the listener is done.
      await pumpEventQueue();

      // Events after dispose are ignored (no crash, no event).
      fake.emitAndroidFocus(MicAndroidAudioFocus.loss);
      await pumpEventQueue();

      expect(events, isEmpty);

      await subscription.cancel();
    });
  });
}
