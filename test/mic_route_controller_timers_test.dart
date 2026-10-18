// Route-controller timer tests: the three fake-clock re-assertion paths
// (settle, foreground-resume, deferred repay) and the Android SCO
// verification, all driven on testWidgets' fake event loop.
//
// Fake-async laws obeyed here (learned the hard way on this project):
// * controller instances are built INSIDE the test body — a setUp-created
//   instance's stream machinery does not advance on tester.pump (zone
//   mismatch);
// * teardown awaits that touch broadcast cancel/close futures are released
//   fire-and-forget (unawaited) and drained with a final pump.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:mic_recorder/src/config/mic_audio_session_config.dart';
import 'package:mic_recorder/src/internal/mic_logger.dart';
import 'package:mic_recorder/src/internal/mic_platform.dart';
import 'package:mic_recorder/src/lifecycle/app_lifecycle_tracker.dart';
import 'package:mic_recorder/src/models/mic_audio_device.dart';
import 'package:mic_recorder/src/models/mic_recorder_events.dart';
import 'package:mic_recorder/src/platform/mic_recorder_platform.dart';
import 'package:mic_recorder/src/route/mic_route_controller.dart';
import 'package:mic_recorder/src/session/mic_audio_session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_mic_recorder_platform.dart';

/// An iOS USB microphone port (rung 1 of the ladder).
const MicAudioInput _usbInput = MicAudioInput(
  uid: 'usb-1',
  portType: 'USBAudio',
  portName: 'USB mic',
);

/// The iOS built-in microphone port (rung 3 of the ladder).
const MicAudioInput _builtinInput = MicAudioInput(
  uid: 'builtin-1',
  portType: 'BuiltInMic',
  portName: 'Built-in mic',
);

/// A Bluetooth SCO microphone (rung 2 on Android).
final MicAudioDevice _scoHeadset = makeDevice(
  MicAudioDeviceType.bluetoothSco,
  id: 'sco-1',
  name: 'BT headset',
);

/// The device's own microphone (rung 3 on Android).
final MicAudioDevice _builtinMic = makeDevice(
  MicAudioDeviceType.builtInMic,
  id: 'builtin-1',
  name: 'Built-in mic',
);

/// A [MicRecorderPlatform] wrapping its own [FakeMicRecorderPlatform]
/// [delegate], with an injectable `getAvailableInputs` failure, so the
/// repay timer's error path can be exercised. Everything else the route
/// controller touches forwards to the delegate.
final class _FaultyRoutingPlatform extends MicRecorderPlatform {
  _FaultyRoutingPlatform() : delegate = FakeMicRecorderPlatform();

  /// The wrapped fake: script its results and read its call logs here.
  final FakeMicRecorderPlatform delegate;

  /// When set, `getAvailableInputs` throws this error.
  Object? getAvailableInputsError;

  @override
  Future<List<MicAudioInput>> getAvailableInputs() {
    final error = getAvailableInputsError;

    if (error != null) throw error;

    return delegate.getAvailableInputs();
  }

  @override
  Future<MicAudioRoute> getCurrentRoute() => delegate.getCurrentRoute();

  @override
  Future<bool> setPreferredInput(MicAudioInput input) =>
      delegate.setPreferredInput(input);

  @override
  Future<Map<String, Object?>?> getRouteState() => delegate.getRouteState();

  @override
  Future<Set<MicAudioDevice>> getAudioDevices() => delegate.getAudioDevices();
}

/// The structured data of every [message] log entry, in order.
List<Map<String, Object?>> _logData(
  List<(MicLogLevel, String, Map<String, Object?>?)> entries,
  String message,
) => [
  for (final entry in entries)
    if (entry.$2 == message && entry.$3 != null) entry.$3!,
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final tracker = AppLifecycleTracker.instance;

  setUpAll(() {
    // Prime the tracker outside any fake-async zone (it is a per-isolate
    // singleton) so its 100 ms assume-resumed fallback never leaks into
    // the fake clocks below.
    tracker.didChangeAppLifecycleState(AppLifecycleState.resumed);
  });

  tearDown(() {
    micIsAndroid = false;
    micIsIOS = false;

    tracker.didChangeAppLifecycleState(AppLifecycleState.resumed);
  });

  group('settle re-assert', () {
    testWidgets('re-applies the preferred input exactly at the settle delay', (
      tester,
    ) async {
      micIsIOS = true;

      final fake = FakeMicRecorderPlatform();
      final logs = <(MicLogLevel, String, Map<String, Object?>?)>[];

      fake.getAvailableInputsResult = [_usbInput, _builtinInput];
      fake.getCurrentRouteResult = MicAudioRoute(inputs: [_usbInput]);

      // Fake-async law: build locally, inside the test body.
      final session = MicAudioSessionController(
        config: const MicAudioSessionConfig(),
        log:
            (MicLogLevel level, String message, [Map<String, Object?>? data]) =>
                logs.add((level, message, data)),
        lifecycle: tracker,
        platform: fake,
      );

      final controller = MicRouteController(
        enabled: true,
        log:
            (MicLogLevel level, String message, [Map<String, Object?>? data]) =>
                logs.add((level, message, data)),
        lifecycle: tracker,
        session: session,
        platform: fake,
      );

      final events = <MicAudioSourceSwitchedEvent>[];
      final subscription = controller.onAudioSourceSwitched.listen(events.add);

      final started = controller.start();
      await tester.pump();
      await started;

      // Already routed at start-up: the initial resolution emitted
      // without a platform write.
      expect(fake.setPreferredInputCalls, isEmpty);
      expect(events.single.sourceKind, MicAudioSourceKind.usbWired);

      // The OS reverts to the built-in mic (a late engine-start glitch).
      fake.getCurrentRouteResult = MicAudioRoute(inputs: [_builtinInput]);

      await tester.pump(
        MicRouteController.settleReassertDelay -
            const Duration(milliseconds: 1),
      );

      // Not yet: the settle window has not elapsed.
      expect(fake.setPreferredInputCalls, isEmpty);

      await tester.pump(const Duration(milliseconds: 1));

      expect(fake.setPreferredInputCalls, [_usbInput]);

      expect(
        _logData(logs, 'audioInputSourceChanged'),
        contains(
          allOf(
            containsPair('action', 'switched'),
            containsPair('reason', 'settle-reassert'),
          ),
        ),
      );

      // Same source kind: the re-assert does not duplicate the event.
      expect(events, hasLength(1));

      unawaited(subscription.cancel());
      unawaited(controller.dispose());
      unawaited(session.dispose());
      unawaited(fake.dispose());
      await tester.pump();
    });

    testWidgets('stands down while the policy is disabled', (tester) async {
      micIsIOS = true;

      final fake = FakeMicRecorderPlatform();
      final logs = <(MicLogLevel, String, Map<String, Object?>?)>[];

      fake.getAvailableInputsResult = [_usbInput, _builtinInput];
      fake.getCurrentRouteResult = MicAudioRoute(inputs: [_usbInput]);

      final session = MicAudioSessionController(
        config: const MicAudioSessionConfig(),
        log:
            (MicLogLevel level, String message, [Map<String, Object?>? data]) =>
                logs.add((level, message, data)),
        lifecycle: tracker,
        platform: fake,
      );

      final controller = MicRouteController(
        enabled: true,
        log:
            (MicLogLevel level, String message, [Map<String, Object?>? data]) =>
                logs.add((level, message, data)),
        lifecycle: tracker,
        session: session,
        platform: fake,
      );

      final started = controller.start();
      await tester.pump();
      await started;

      expect(fake.setPreferredInputCalls, isEmpty);

      final disabled = controller.setEnabled(false);
      await tester.pump();
      await disabled;

      // The OS reverts the route, but the policy no longer owns routing.
      fake.getCurrentRouteResult = MicAudioRoute(inputs: [_builtinInput]);

      // Well past the settle delay: the timer fired into its guard.
      await tester.pump(MicRouteController.settleReassertDelay * 2);

      expect(fake.setPreferredInputCalls, isEmpty);

      unawaited(controller.dispose());
      unawaited(session.dispose());
      unawaited(fake.dispose());
      await tester.pump();
    });

    testWidgets(
      'a failing settle re-assert is logged, never thrown into the timer zone',
      (tester) async {
        micIsIOS = true;

        final faulty = _FaultyRoutingPlatform();
        final logs = <(MicLogLevel, String, Map<String, Object?>?)>[];

        faulty.delegate.getAvailableInputsResult = [_usbInput];
        faulty.delegate.getCurrentRouteResult = MicAudioRoute(
          inputs: [_usbInput],
        );

        final session = MicAudioSessionController(
          config: const MicAudioSessionConfig(),
          log:
              (
                MicLogLevel level,
                String message, [
                Map<String, Object?>? data,
              ]) => logs.add((level, message, data)),
          lifecycle: tracker,
          platform: faulty.delegate,
        );

        final controller = MicRouteController(
          enabled: true,
          log:
              (
                MicLogLevel level,
                String message, [
                Map<String, Object?>? data,
              ]) => logs.add((level, message, data)),
          lifecycle: tracker,
          session: session,
          platform: faulty,
        );

        final started = controller.start();
        await tester.pump();
        await started;

        // Already routed at start-up: no write happened yet.
        expect(faulty.delegate.setPreferredInputCalls, isEmpty);

        // The inputs query starts failing before the settle re-assert
        // fires: its error must be caught and logged, not thrown out of
        // the timer callback.
        faulty.getAvailableInputsError = StateError('inputs gone');

        await tester.pump(MicRouteController.settleReassertDelay);

        expect(faulty.delegate.setPreferredInputCalls, isEmpty);
        expect(
          logs,
          contains(
            predicate<(MicLogLevel, String, Map<String, Object?>?)>(
              (entry) =>
                  entry.$1 == MicLogLevel.error &&
                  entry.$2 == 'audioRouteChanged' &&
                  entry.$3?['settleReassertError'] != null,
              'a settleReassertError entry',
            ),
          ),
        );

        unawaited(controller.dispose());
        unawaited(session.dispose());
        unawaited(faulty.delegate.dispose());
        await tester.pump();
      },
    );
  });

  group('foreground re-assert', () {
    testWidgets('re-applies the preferred input exactly at the resume delay', (
      tester,
    ) async {
      micIsIOS = true;

      final fake = FakeMicRecorderPlatform();
      final logs = <(MicLogLevel, String, Map<String, Object?>?)>[];

      fake.getAvailableInputsResult = [_usbInput, _builtinInput];
      fake.getCurrentRouteResult = MicAudioRoute(inputs: [_usbInput]);

      final session = MicAudioSessionController(
        config: const MicAudioSessionConfig(),
        log:
            (MicLogLevel level, String message, [Map<String, Object?>? data]) =>
                logs.add((level, message, data)),
        lifecycle: tracker,
        platform: fake,
      );

      final controller = MicRouteController(
        enabled: true,
        log:
            (MicLogLevel level, String message, [Map<String, Object?>? data]) =>
                logs.add((level, message, data)),
        lifecycle: tracker,
        session: session,
        platform: fake,
      );

      final events = <MicAudioSourceSwitchedEvent>[];
      final subscription = controller.onAudioSourceSwitched.listen(events.add);

      final started = controller.start();
      await tester.pump();
      await started;

      expect(fake.setPreferredInputCalls, isEmpty);
      expect(events.single.sourceKind, MicAudioSourceKind.usbWired);

      // The OS reverts to the built-in mic while the app is away.
      fake.getCurrentRouteResult = MicAudioRoute(inputs: [_builtinInput]);

      // Dispatch the lifecycle transitions through the binding so every
      // WidgetsBindingObserver — this controller included — is notified.
      // (The AppLifecycleTracker call does NOT dispatch to observers.)
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

      await tester.pump(
        MicRouteController.foregroundReassertDelay -
            const Duration(milliseconds: 1),
      );

      // Not yet: the resume grace window has not elapsed.
      expect(fake.setPreferredInputCalls, isEmpty);

      await tester.pump(const Duration(milliseconds: 1));

      expect(fake.setPreferredInputCalls, [_usbInput]);

      expect(
        _logData(logs, 'audioInputSourceChanged'),
        contains(
          allOf(
            containsPair('action', 'switched'),
            containsPair('reason', 'foreground-resume'),
          ),
        ),
      );

      expect(events, hasLength(1));

      unawaited(subscription.cancel());
      unawaited(controller.dispose());
      unawaited(session.dispose());
      unawaited(fake.dispose());
      await tester.pump();
    });

    testWidgets(
      'a failing foreground re-assert is logged, never thrown into the timer zone',
      (tester) async {
        micIsIOS = true;

        final faulty = _FaultyRoutingPlatform();
        final logs = <(MicLogLevel, String, Map<String, Object?>?)>[];

        faulty.delegate.getAvailableInputsResult = [_usbInput];
        faulty.delegate.getCurrentRouteResult = MicAudioRoute(
          inputs: [_usbInput],
        );

        final session = MicAudioSessionController(
          config: const MicAudioSessionConfig(),
          log:
              (
                MicLogLevel level,
                String message, [
                Map<String, Object?>? data,
              ]) => logs.add((level, message, data)),
          lifecycle: tracker,
          platform: faulty.delegate,
        );

        final controller = MicRouteController(
          enabled: true,
          log:
              (
                MicLogLevel level,
                String message, [
                Map<String, Object?>? data,
              ]) => logs.add((level, message, data)),
          lifecycle: tracker,
          session: session,
          platform: faulty,
        );

        final started = controller.start();
        await tester.pump();
        await started;

        expect(faulty.delegate.setPreferredInputCalls, isEmpty);

        // The inputs query starts failing before the resume re-assert
        // fires: its error must be caught and logged, not thrown out of
        // the timer callback.
        faulty.getAvailableInputsError = StateError('inputs gone');

        // Dispatch through the binding so every WidgetsBindingObserver —
        // this controller included — is notified of the resume.
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );

        await tester.pump(MicRouteController.foregroundReassertDelay);

        expect(faulty.delegate.setPreferredInputCalls, isEmpty);
        expect(
          logs,
          contains(
            predicate<(MicLogLevel, String, Map<String, Object?>?)>(
              (entry) =>
                  entry.$1 == MicLogLevel.error &&
                  entry.$2 == 'audioRouteChanged' &&
                  entry.$3?['foregroundReassertError'] != null,
              'a foregroundReassertError entry',
            ),
          ),
        );

        unawaited(controller.dispose());
        unawaited(session.dispose());
        unawaited(faulty.delegate.dispose());
        await tester.pump();
      },
    );
  });

  group('route repay', () {
    testWidgets(
      'a decision deferred by a torn-down route is repaid after the delay',
      (tester) async {
        micIsIOS = true;

        final fake = FakeMicRecorderPlatform();
        final logs = <(MicLogLevel, String, Map<String, Object?>?)>[];

        fake.getAvailableInputsResult = [_usbInput, _builtinInput];

        // An empty route: the session has no input selected, so writing
        // the preferred input now would race the OS re-establishing one.
        fake.getCurrentRouteResult = MicAudioRoute();

        final session = MicAudioSessionController(
          config: const MicAudioSessionConfig(),
          log:
              (
                MicLogLevel level,
                String message, [
                Map<String, Object?>? data,
              ]) => logs.add((level, message, data)),
          lifecycle: tracker,
          platform: fake,
        );

        final controller = MicRouteController(
          enabled: true,
          log:
              (
                MicLogLevel level,
                String message, [
                Map<String, Object?>? data,
              ]) => logs.add((level, message, data)),
          lifecycle: tracker,
          session: session,
          platform: fake,
        );

        final events = <MicAudioSourceSwitchedEvent>[];
        final subscription = controller.onAudioSourceSwitched.listen(
          events.add,
        );

        final started = controller.start();
        await tester.pump();
        await started;

        // Deferred, not dropped: no write, no source event yet.
        expect(fake.setPreferredInputCalls, isEmpty);
        expect(events, isEmpty);

        expect(
          _logData(logs, 'audioSessionWriteDeferred'),
          contains(
            allOf(
              containsPair('action', 'preferred-input-deferred'),
              containsPair(
                'repayArmedMs',
                MicRouteController.routeRepayDelay.inMilliseconds,
              ),
              containsPair('currentRouteHasInput', false),
            ),
          ),
        );

        // The OS re-establishes the default input on the route.
        fake.getCurrentRouteResult = MicAudioRoute(inputs: [_builtinInput]);

        await tester.pump(
          MicRouteController.routeRepayDelay - const Duration(milliseconds: 1),
        );

        // Not yet: the repay window has not elapsed.
        expect(fake.setPreferredInputCalls, isEmpty);

        await tester.pump(const Duration(milliseconds: 1));

        expect(fake.setPreferredInputCalls, [_usbInput]);
        expect(events.single.sourceKind, MicAudioSourceKind.usbWired);
        expect(events.single.previousSourceKind, isNull);
        expect(events.single.reason, 'deferred-repay');

        unawaited(subscription.cancel());
        unawaited(controller.dispose());
        unawaited(session.dispose());
        unawaited(fake.dispose());
        await tester.pump();
      },
    );

    testWidgets('a failing repay is logged, never thrown into the timer zone', (
      tester,
    ) async {
      micIsIOS = true;

      final faulty = _FaultyRoutingPlatform();
      final logs = <(MicLogLevel, String, Map<String, Object?>?)>[];

      faulty.delegate.getAvailableInputsResult = [_usbInput];

      final session = MicAudioSessionController(
        config: const MicAudioSessionConfig(),
        log:
            (MicLogLevel level, String message, [Map<String, Object?>? data]) =>
                logs.add((level, message, data)),
        lifecycle: tracker,
        platform: faulty.delegate,
      );

      final controller = MicRouteController(
        enabled: true,
        log:
            (MicLogLevel level, String message, [Map<String, Object?>? data]) =>
                logs.add((level, message, data)),
        lifecycle: tracker,
        session: session,
        platform: faulty,
      );

      final started = controller.start();
      await tester.pump();
      await started;

      expect(_logData(logs, 'audioSessionWriteDeferred'), isNotEmpty);

      // The inputs query starts failing before the repay fires.
      faulty.getAvailableInputsError = StateError('inputs gone');

      // The repay fires: its error must be caught and logged, not thrown
      // out of the timer callback.
      await tester.pump(MicRouteController.routeRepayDelay);

      expect(faulty.delegate.setPreferredInputCalls, isEmpty);
      expect(
        logs,
        contains(
          predicate<(MicLogLevel, String, Map<String, Object?>?)>(
            (entry) =>
                entry.$1 == MicLogLevel.error &&
                entry.$2 == 'audioRouteChanged' &&
                entry.$3?['routeRepayError'] != null,
            'a routeRepayError entry',
          ),
        ),
      );

      unawaited(controller.dispose());
      unawaited(session.dispose());
      unawaited(faulty.delegate.dispose());
      await tester.pump();
    });

    testWidgets(
      'a repayment landing inside an active interruption defers again',
      (tester) async {
        micIsIOS = true;

        final fake = FakeMicRecorderPlatform();
        final logs = <(MicLogLevel, String, Map<String, Object?>?)>[];

        final session = MicAudioSessionController(
          config: const MicAudioSessionConfig(),
          log:
              (
                MicLogLevel level,
                String message, [
                Map<String, Object?>? data,
              ]) => logs.add((level, message, data)),
          lifecycle: tracker,
          platform: fake,
        );

        final sessionInit = session.init();
        await tester.pump();
        await sessionInit;

        // The app goes to the background and a call interruption begins.
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        fake.emitIosInterruption(began: true, shouldResume: false);
        await tester.pump();

        fake.getAvailableInputsResult = [_usbInput, _builtinInput];
        fake.getCurrentRouteResult = MicAudioRoute(inputs: [_builtinInput]);

        final controller = MicRouteController(
          enabled: true,
          log:
              (
                MicLogLevel level,
                String message, [
                Map<String, Object?>? data,
              ]) => logs.add((level, message, data)),
          lifecycle: tracker,
          session: session,
          platform: fake,
        );

        final started = controller.start();
        await tester.pump();
        await started;

        // The route has an input, but the interruption window is closed:
        // the write is deferred with the interruption cooldown, not the
        // plain route delay.
        expect(fake.setPreferredInputCalls, isEmpty);
        expect(
          _logData(logs, 'audioSessionWriteDeferred'),
          contains(
            allOf(
              containsPair('action', 'preferred-input-deferred'),
              containsPair(
                'repayArmedMs',
                MicRouteController.interruptionWriteCooldown.inMilliseconds,
              ),
              containsPair('currentRouteHasInput', true),
            ),
          ),
        );

        final deferralsBefore = _logData(
          logs,
          'audioSessionWriteDeferred',
        ).length;

        // First let the settle re-assert fire (it re-checks the gates too
        // and re-arms the repay with the same cooldown).
        await tester.pump(MicRouteController.settleReassertDelay);

        final deferralsAfterSettle = _logData(
          logs,
          'audioSessionWriteDeferred',
        );
        expect(deferralsAfterSettle, hasLength(deferralsBefore + 1));
        expect(deferralsAfterSettle.last['reason'], 'settle-reassert');

        // The cooldown elapses with the interruption still active: the
        // repay re-checks the gates, finds them still closed and re-arms —
        // the decision is delayed again, never dropped and never written
        // onto a torn-down session.
        await tester.pump(MicRouteController.interruptionWriteCooldown);

        final deferrals = _logData(logs, 'audioSessionWriteDeferred');

        expect(fake.setPreferredInputCalls, isEmpty);
        expect(deferrals, hasLength(deferralsAfterSettle.length + 1));
        expect(deferrals.last['reason'], 'deferred-repay');

        unawaited(controller.dispose());
        unawaited(session.dispose());
        unawaited(fake.dispose());
        await tester.pump();
      },
    );
  });

  group('Android SCO verification', () {
    testWidgets(
      'a repeated Bluetooth decision verifies SCO and re-applies when it dropped',
      (tester) async {
        micIsAndroid = true;

        final fake = FakeMicRecorderPlatform();
        final logs = <(MicLogLevel, String, Map<String, Object?>?)>[];

        fake.audioDevicesResult = {_scoHeadset, _builtinMic};

        final session = MicAudioSessionController(
          config: const MicAudioSessionConfig(),
          log:
              (
                MicLogLevel level,
                String message, [
                Map<String, Object?>? data,
              ]) => logs.add((level, message, data)),
          lifecycle: tracker,
          platform: fake,
        );

        final controller = MicRouteController(
          enabled: true,
          log:
              (
                MicLogLevel level,
                String message, [
                Map<String, Object?>? data,
              ]) => logs.add((level, message, data)),
          lifecycle: tracker,
          session: session,
          platform: fake,
        );

        final events = <MicAudioSourceSwitchedEvent>[];
        final subscription = controller.onAudioSourceSwitched.listen(
          events.add,
        );

        final sessionInit = session.init();
        await tester.pump();
        await sessionInit;

        final started = controller.start();
        await tester.pump();
        await started;

        // The Bluetooth decision engaged the gate; the standing decision
        // is Bluetooth.
        expect(fake.setBluetoothStatusCalls, everyElement(isTrue));
        expect(fake.setBluetoothStatusCalls, isNotEmpty);

        // The SCO link silently dropped (a start that failed in the
        // background): the device-change re-check must re-apply it.
        fake.getRouteStateResult = {'scoConnected': false};
        fake.emitDevicesChanged();
        await tester.pump();

        expect(
          _logData(logs, 'audioInputSourceChanged'),
          contains(
            allOf(
              containsPair('action', 're-apply'),
              containsPair('scoConnected', false),
            ),
          ),
        );

        final reappliedCount = fake.setBluetoothStatusCalls.length;

        // SCO is live again: the standing decision holds, no re-apply.
        fake.getRouteStateResult = {'scoConnected': true};
        fake.emitDevicesChanged();
        await tester.pump();

        expect(fake.setBluetoothStatusCalls, hasLength(reappliedCount));

        // The native layer deliberately stood the SCO request down: that
        // is not a mismatch — no re-apply either.
        fake.getRouteStateResult = {
          'scoConnected': false,
          'scoRequestStoodDown': true,
        };
        fake.emitDevicesChanged();
        await tester.pump();

        expect(fake.setBluetoothStatusCalls, hasLength(reappliedCount));

        expect(
          _logData(logs, 'audioInputSourceChanged'),
          contains(containsPair('scoRequestStoodDown', true)),
        );

        // Bluetooth was the effective source throughout: one event.
        expect(events, hasLength(1));
        expect(events.single.sourceKind, MicAudioSourceKind.bluetooth);

        unawaited(subscription.cancel());
        unawaited(controller.dispose());
        unawaited(session.dispose());
        unawaited(fake.dispose());
        await tester.pump();
      },
    );
  });
}
