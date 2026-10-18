// Route-controller tests: the input priority ladder (USB/wired >
// Bluetooth > built-in), decision dedupe, iOS write gating, toggling,
// stop/episode-reset semantics and failure resilience.
//
// These are pure async/state tests. The fake-clock timer behavior (settle
// re-assert, foreground re-assert, route repay) lives in
// mic_route_controller_timers_test.dart.

import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:mic_recorder/src/config/mic_audio_session_config.dart';
import 'package:mic_recorder/src/internal/mic_logger.dart';
import 'package:mic_recorder/src/internal/mic_platform.dart';
import 'package:mic_recorder/src/lifecycle/app_lifecycle_tracker.dart';
import 'package:mic_recorder/src/models/mic_audio_device.dart';
import 'package:mic_recorder/src/models/mic_recorder_events.dart';
import 'package:mic_recorder/src/models/mic_session_events.dart';
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

/// An iOS Bluetooth HFP headset port (rung 2 of the ladder).
const MicAudioInput _hfpInput = MicAudioInput(
  uid: 'bt-hfp-1',
  portType: 'BluetoothHFP',
  portName: 'BT headset',
);

/// The iOS built-in microphone port (rung 3 of the ladder).
const MicAudioInput _builtinInput = MicAudioInput(
  uid: 'builtin-1',
  portType: 'BuiltInMic',
  portName: 'Built-in mic',
);

/// A wired headset microphone (rung 1 on Android).
final MicAudioDevice _wiredHeadset = makeDevice(
  MicAudioDeviceType.wiredHeadset,
  id: 'wired-1',
  name: 'Wired headset',
);

/// A Bluetooth SCO microphone (rung 2 on Android).
final MicAudioDevice _scoHeadset = makeDevice(
  MicAudioDeviceType.bluetoothSco,
  id: 'sco-1',
  name: 'BT headset',
);

/// A Bluetooth A2DP output — no microphone, but its presence signals a
/// connected headset.
final MicAudioDevice _a2dpHeadset = makeDevice(
  MicAudioDeviceType.bluetoothA2dp,
  id: 'a2dp-1',
  name: 'BT headphones',
  isInput: false,
  isOutput: true,
);

/// The device's own microphone (rung 3 on Android).
final MicAudioDevice _builtinMic = makeDevice(
  MicAudioDeviceType.builtInMic,
  id: 'builtin-1',
  name: 'Built-in mic',
);

/// The device's own speaker — an output with no input rung at all.
final MicAudioDevice _speaker = makeDevice(
  MicAudioDeviceType.builtInSpeaker,
  id: 'speaker-1',
  name: 'Speaker',
  isInput: false,
  isOutput: true,
);

/// A [MicRecorderPlatform] wrapping its own [FakeMicRecorderPlatform]
/// [delegate], with injectable failures on the routing verbs, so the
/// controller's error paths can be exercised. Everything the route
/// controller and the session's device seed touch forwards to the
/// delegate, whose scripted results and call logs stay readable.
final class _FaultyRoutingPlatform extends MicRecorderPlatform {
  _FaultyRoutingPlatform() : delegate = FakeMicRecorderPlatform();

  /// The wrapped fake: script its results and read its call logs here.
  final FakeMicRecorderPlatform delegate;

  /// When set, `setPreferredInput` throws this error.
  Object? setPreferredInputError;

  /// When set, `setBluetoothStatus` throws this error.
  Object? setBluetoothStatusError;

  /// When set, `getAvailableInputs` throws this error.
  Object? getAvailableInputsError;

  /// When set, `getCurrentRoute` throws this error.
  Object? getCurrentRouteError;

  /// `setPreferredInput` attempts in call order — recorded even when the
  /// call then fails (the wrapped fake only logs successful ones).
  final setPreferredInputAttempts = <MicAudioInput>[];

  /// `setBluetoothStatus` attempts in call order (see above).
  final setBluetoothStatusAttempts = <bool>[];

  @override
  Future<bool> setPreferredInput(MicAudioInput input) {
    setPreferredInputAttempts.add(input);

    final error = setPreferredInputError;

    if (error != null) throw error;

    return delegate.setPreferredInput(input);
  }

  @override
  Future<void> setBluetoothStatus(bool isAllowed) {
    setBluetoothStatusAttempts.add(isAllowed);

    final error = setBluetoothStatusError;

    if (error != null) throw error;

    return delegate.setBluetoothStatus(isAllowed);
  }

  @override
  Future<List<MicAudioInput>> getAvailableInputs() {
    final error = getAvailableInputsError;

    if (error != null) throw error;

    return delegate.getAvailableInputs();
  }

  @override
  Future<MicAudioRoute> getCurrentRoute() {
    final error = getCurrentRouteError;

    if (error != null) throw error;

    return delegate.getCurrentRoute();
  }

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

/// A [MicRecorderPlatform] wrapping its own [FakeMicRecorderPlatform]
/// [delegate], whose `getRouteState` can be parked mid-flight, so a
/// device-change evaluation can be held at a known point while further
/// device changes arrive — pinning the serialization of concurrent
/// evaluations (only the latest device set is re-evaluated). Everything
/// else the route controller touches forwards to the delegate.
final class _GatedRouteStatePlatform extends MicRecorderPlatform {
  _GatedRouteStatePlatform() : delegate = FakeMicRecorderPlatform();

  /// The wrapped fake: script its results and read its call logs here.
  final FakeMicRecorderPlatform delegate;

  Completer<Map<String, Object?>?>? _routeStateGate;

  /// The next `getRouteState` call blocks until [releaseGatedRouteState].
  void parkNextGetRouteState() {
    _routeStateGate = Completer<Map<String, Object?>>();
  }

  /// Unblocks the parked call, answering it with [state].
  void releaseGatedRouteState(Map<String, Object?> state) {
    _routeStateGate?.complete(state);
    _routeStateGate = null;
  }

  @override
  Future<Map<String, Object?>?> getRouteState() {
    final gate = _routeStateGate;

    if (gate != null) return gate.future;

    return delegate.getRouteState();
  }

  @override
  Future<void> setBluetoothStatus(bool isAllowed) =>
      delegate.setBluetoothStatus(isAllowed);

  @override
  Future<List<MicAudioInput>> getAvailableInputs() =>
      delegate.getAvailableInputs();

  @override
  Future<MicAudioRoute> getCurrentRoute() => delegate.getCurrentRoute();

  @override
  Future<bool> setPreferredInput(MicAudioInput input) =>
      delegate.setPreferredInput(input);

  @override
  Future<Set<MicAudioDevice>> getAudioDevices() => delegate.getAudioDevices();
}

/// Whether an error-level [message] entry mentioning [key] was logged.
bool _loggedError(
  List<(MicLogLevel, String, Map<String, Object?>?)> entries,
  String message,
  String key,
) => entries.any(
  (entry) => entry.$1 == MicLogLevel.error && entry.$3?[key] != null,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final tracker = AppLifecycleTracker.instance;

  late FakeMicRecorderPlatform fake;
  late List<(MicLogLevel, String, Map<String, Object?>?)> logs;
  late MicAudioSessionController session;

  MicRouteController? controller;

  final events = <MicAudioSourceSwitchedEvent>[];
  StreamSubscription<MicAudioSourceSwitchedEvent>? eventsSubscription;

  /// Builds a controller wired to this test's collaborators and starts
  /// collecting its source-switch events.
  MicRouteController buildController({
    bool enabled = true,
    MicRecorderPlatform? platform,
  }) {
    final built = MicRouteController(
      enabled: enabled,
      log: (MicLogLevel level, String message, [Map<String, Object?>? data]) =>
          logs.add((level, message, data)),
      lifecycle: tracker,
      session: session,
      platform: platform ?? fake,
    );

    controller = built;

    eventsSubscription = built.onAudioSourceSwitched.listen(events.add);

    return built;
  }

  setUpAll(() {
    // Deterministic foreground start (the tracker is a per-isolate
    // singleton shared by every test in this file).
    tracker.didChangeAppLifecycleState(AppLifecycleState.resumed);
  });

  setUp(() {
    fake = FakeMicRecorderPlatform();

    logs = <(MicLogLevel, String, Map<String, Object?>?)>[];

    session = MicAudioSessionController(
      config: const MicAudioSessionConfig(),
      log: (MicLogLevel level, String message, [Map<String, Object?>? data]) =>
          logs.add((level, message, data)),
      lifecycle: tracker,
      platform: fake,
    );

    events.clear();
  });

  tearDown(() async {
    micIsAndroid = false;
    micIsIOS = false;

    tracker.didChangeAppLifecycleState(AppLifecycleState.resumed);

    await eventsSubscription?.cancel();

    eventsSubscription = null;

    await controller?.dispose();

    controller = null;

    await session.dispose();

    await fake.dispose();
  });

  Future<void> pump() => pumpEventQueue();

  group('construction', () {
    test('omitting the platform falls back to the shared singleton', () async {
      micIsIOS = true;

      // No platform injected: the controller talks to the shared instance —
      // the inert stub until the export library's bootstrap installs the
      // method channel in production. It offers no selectable input, so
      // the ladder leaves the route at the OS default.
      final bare = MicRouteController(
        enabled: true,
        log:
            (MicLogLevel level, String message, [Map<String, Object?>? data]) =>
                logs.add((level, message, data)),
        lifecycle: tracker,
        session: session,
      );

      controller = bare;

      final localEvents = <MicAudioSourceSwitchedEvent>[];
      final subscription = bare.onAudioSourceSwitched.listen(localEvents.add);

      await bare.prepare();

      expect(bare.ownsInputRouting, isTrue);
      expect(fake.setPreferredInputCalls, isEmpty);
      expect(localEvents.single.sourceKind, MicAudioSourceKind.systemDefault);

      await subscription.cancel();
    });
  });

  group('iOS input ladder', () {
    test(
      'prefers a USB input over Bluetooth and the built-in microphone',
      () async {
        buildController();
        micIsIOS = true;

        fake.getAvailableInputsResult = [_hfpInput, _builtinInput, _usbInput];
        fake.getCurrentRouteResult = MicAudioRoute(inputs: [_builtinInput]);

        // prepare() applies the ladder exactly once (no device subscription
        // yet), so the rung choice is observable without interleaving.
        await controller!.prepare();

        expect(controller!.ownsInputRouting, isTrue);
        expect(fake.setPreferredInputCalls, [_usbInput]);

        expect(events, hasLength(1));
        expect(events.single.sourceKind, MicAudioSourceKind.usbWired);
        expect(events.single.previousSourceKind, isNull);
        expect(events.single.sourceName, 'USB mic');
        expect(events.single.reason, 'prepare');
        expect(events.single.switchingEnabled, isTrue);
      },
    );

    test('prefers Bluetooth when no USB/wired input exists', () async {
      buildController();
      micIsIOS = true;

      fake.getAvailableInputsResult = [_hfpInput, _builtinInput];
      fake.getCurrentRouteResult = MicAudioRoute(inputs: [_builtinInput]);

      await controller!.prepare();

      expect(fake.setPreferredInputCalls, [_hfpInput]);
      expect(events.single.sourceKind, MicAudioSourceKind.bluetooth);
      expect(events.single.sourceName, 'BT headset');
    });

    test('falls back to the built-in microphone', () async {
      buildController();
      micIsIOS = true;

      // The Bluetooth route is stale (the headset vanished from the input
      // list); only the built-in microphone remains selectable.
      fake.getAvailableInputsResult = [_builtinInput];
      fake.getCurrentRouteResult = MicAudioRoute(inputs: [_hfpInput]);

      await controller!.prepare();

      expect(fake.setPreferredInputCalls, [_builtinInput]);
      expect(events.single.sourceKind, MicAudioSourceKind.defaultMicrophone);
      expect(events.single.sourceName, 'Built-in mic');
    });

    test('leaves the route to the OS when no input is offered', () async {
      buildController();
      micIsIOS = true;

      fake.getAvailableInputsResult = [];
      fake.getCurrentRouteResult = MicAudioRoute(inputs: [_builtinInput]);

      await controller!.prepare();

      // No input to select: the OS default stays in charge.
      expect(fake.setPreferredInputCalls, isEmpty);

      expect(events.single.sourceKind, MicAudioSourceKind.systemDefault);
      expect(events.single.sourceName, isNull);

      expect(
        _logData(logs, 'audioInputSourceChanged'),
        contains(containsPair('action', 'none')),
      );
    });
  });

  group('iOS route stability', () {
    test('an unchanged decision never re-issues the platform call', () async {
      buildController();
      micIsIOS = true;

      await session.init();

      fake.getAvailableInputsResult = [_usbInput, _builtinInput];
      fake.getCurrentRouteResult = MicAudioRoute(inputs: [_usbInput]);

      await controller!.start();
      await pump();

      // The current route already IS the target: no write may happen, but
      // the first resolution of the episode still emits.
      expect(fake.setPreferredInputCalls, isEmpty);
      expect(events.single.sourceKind, MicAudioSourceKind.usbWired);
      expect(
        _logData(logs, 'audioInputSourceChanged'),
        contains(containsPair('action', 'already-routed')),
      );

      // A route-change notification re-evaluates, but the decision is
      // still unchanged — still no write, no redundant event.
      fake.emitIosRouteChange(MicIosRouteChangeReason.newDeviceAvailable);
      await pump();

      expect(fake.setPreferredInputCalls, isEmpty);
      expect(events, hasLength(1));
    });
  });

  group('iOS device-change reactivity', () {
    test('a new-device route change re-ranks the ladder', () async {
      buildController();
      micIsIOS = true;

      await session.init();

      fake.getAvailableInputsResult = [_hfpInput, _builtinInput];
      fake.getCurrentRouteResult = MicAudioRoute(inputs: [_builtinInput]);

      await controller!.prepare();

      expect(fake.setPreferredInputCalls, [_hfpInput]);

      // The OS accepted the headset; now start the recording episode.
      fake.getCurrentRouteResult = MicAudioRoute(inputs: [_hfpInput]);

      await controller!.start();
      await pump();

      expect(fake.setPreferredInputCalls, [_hfpInput]);

      // A USB microphone appears mid-recording: it outranks the headset.
      fake.getAvailableInputsResult = [_usbInput, _hfpInput, _builtinInput];
      fake.emitIosRouteChange(MicIosRouteChangeReason.newDeviceAvailable);
      await pump();

      expect(fake.setPreferredInputCalls, [_hfpInput, _usbInput]);

      expect(events.last.sourceKind, MicAudioSourceKind.usbWired);
      expect(events.last.previousSourceKind, MicAudioSourceKind.bluetooth);
      expect(events.last.sourceName, 'USB mic');

      // Route changes that are not device arrivals/departures (a category
      // change, say) never re-evaluate the ladder.
      fake.emitIosRouteChange(MicIosRouteChangeReason.categoryChange);
      await pump();

      expect(fake.setPreferredInputCalls, hasLength(2));
    });
  });

  group('iOS write gating', () {
    test(
      'defers the input write while backgrounded in an interruption',
      () async {
        buildController();
        micIsIOS = true;

        await session.init();

        tracker.didChangeAppLifecycleState(AppLifecycleState.paused);

        fake.emitIosInterruption(began: true, shouldResume: false);
        await pump();

        fake.getAvailableInputsResult = [_usbInput, _builtinInput];
        fake.getCurrentRouteResult = MicAudioRoute(inputs: [_builtinInput]);

        await controller!.prepare();

        // The route has an input, but the app is backgrounded inside an
        // active interruption: the write is deferred (armed for the repay
        // timer), never dropped onto a torn-down session.
        expect(fake.setPreferredInputCalls, isEmpty);
        expect(events, isEmpty);

        expect(
          _logData(logs, 'audioSessionWriteDeferred'),
          contains(
            allOf(
              containsPair('action', 'preferred-input-deferred'),
              containsPair('repayArmedMs', 5000),
              containsPair('currentRouteHasInput', true),
            ),
          ),
        );
      },
    );
  });

  group('Android input ladder', () {
    test('a wired headset outranks Bluetooth (gate disengaged)', () async {
      buildController();
      micIsAndroid = true;

      fake.audioDevicesResult = {_wiredHeadset, _scoHeadset, _builtinMic};

      await controller!.prepare();

      // The wired headset wins rung 1, so the Bluetooth gate is disengaged.
      expect(fake.setBluetoothStatusCalls, [false]);
      expect(events.single.sourceKind, MicAudioSourceKind.usbWired);
      expect(events.single.sourceName, 'Wired headset');
    });

    test('Bluetooth engages when no wired/USB microphone exists', () async {
      buildController();
      micIsAndroid = true;

      fake.audioDevicesResult = {_scoHeadset, _builtinMic};

      await controller!.prepare();

      expect(fake.setBluetoothStatusCalls, [true]);
      expect(events.single.sourceKind, MicAudioSourceKind.bluetooth);
      expect(events.single.sourceName, 'BT headset');
    });

    test('an A2DP headset upgrades the built-in mic to Bluetooth', () async {
      buildController();
      micIsAndroid = true;

      // The A2DP output carries no microphone, but it proves a headset is
      // connected — the SCO input is listed once the gate engages.
      fake.audioDevicesResult = {_builtinMic, _a2dpHeadset};

      await controller!.prepare();

      expect(fake.setBluetoothStatusCalls, [true]);
      expect(events.single.sourceKind, MicAudioSourceKind.bluetooth);

      // No SCO input was listed yet, so the event carries no source name.
      expect(events.single.sourceName, isNull);

      expect(
        _logData(logs, 'audioInputsSnapshot'),
        contains(
          allOf(
            containsPair('reason', 'headset-signal'),
            containsPair('bluetoothHeadsetConnected', true),
            containsPair('listedBluetoothDevice', true),
          ),
        ),
      );
    });

    test('the native headset flag alone upgrades the built-in mic', () async {
      buildController();
      micIsAndroid = true;

      fake.audioDevicesResult = {_builtinMic};
      fake.getRouteStateResult = {'bluetoothHeadsetConnected': true};

      await controller!.prepare();

      expect(fake.setBluetoothStatusCalls, [true]);
      expect(events.single.sourceKind, MicAudioSourceKind.bluetooth);

      expect(
        _logData(logs, 'audioInputsSnapshot'),
        contains(
          allOf(
            containsPair('reason', 'headset-signal'),
            containsPair('nativeFlag', true),
            containsPair('listedBluetoothDevice', false),
          ),
        ),
      );
    });

    test('the default microphone wins with no headset signals', () async {
      buildController();
      micIsAndroid = true;

      fake.audioDevicesResult = {_builtinMic};

      // A route state without the headset key is stale — it must not be
      // mistaken for a "not connected" answer either way.
      fake.getRouteStateResult = {'scoConnected': false};

      await controller!.prepare();

      expect(fake.setBluetoothStatusCalls, [false]);
      expect(events.single.sourceKind, MicAudioSourceKind.defaultMicrophone);
      expect(events.single.sourceName, 'Built-in mic');

      expect(
        _logData(logs, 'audioInputsSnapshot'),
        contains(
          allOf(
            containsPair('reason', 'headset-signal'),
            containsPair('bluetoothHeadsetConnected', false),
            containsPair('nativeRouteStateStale', true),
          ),
        ),
      );
    });

    test('no input devices at all leaves the route to the OS', () async {
      buildController();
      micIsAndroid = true;

      fake.audioDevicesResult = {_speaker};

      await controller!.prepare();

      expect(fake.setBluetoothStatusCalls, isEmpty);
      expect(events.single.sourceKind, MicAudioSourceKind.systemDefault);

      expect(
        _logData(logs, 'audioInputSourceChanged'),
        contains(containsPair('action', 'none')),
      );
    });
  });

  group('Android decision dedupe', () {
    test('a repeated decision never re-issues the gate call', () async {
      buildController();
      micIsAndroid = true;

      await session.init();

      fake.audioDevicesResult = {_wiredHeadset, _builtinMic};

      await controller!.prepare();

      expect(fake.setBluetoothStatusCalls, [false]);

      await controller!.start();
      await pump();

      // The start re-apply and the seeded device-change evaluation both
      // re-check the standing decision — neither re-issues the call.
      expect(fake.setBluetoothStatusCalls, [false]);

      fake.emitDevicesChanged(added: [_wiredHeadset, _builtinMic]);
      await pump();

      expect(fake.setBluetoothStatusCalls, [false]);
      expect(events, hasLength(1));

      // Only a Bluetooth decision needs native verification.
      expect(fake.callLog, isNot(contains('getRouteState')));
    });
  });

  group('toggling the priority policy', () {
    test(
      'prepare while disabled stands down without touching the platform',
      () async {
        buildController(enabled: false);
        micIsIOS = true;

        await controller!.prepare();

        expect(controller!.ownsInputRouting, isFalse);
        expect(fake.callLog, isEmpty);
        expect(events, isEmpty);

        expect(
          _logData(logs, 'audioInputsSnapshot'),
          contains(
            allOf(
              containsPair('reason', 'prepare'),
              containsPair('switchingEnabled', false),
            ),
          ),
        );
      },
    );

    test('a disabled controller observes but never steers', () async {
      micIsAndroid = true;

      await session.init();

      fake.audioDevicesResult = {_wiredHeadset, _builtinMic};

      buildController(enabled: false);

      await controller!.start();
      await pump();

      expect(fake.setBluetoothStatusCalls, isEmpty);
      expect(controller!.ownsInputRouting, isFalse);

      // The OS-picked source is still reported — flagged as unsteered.
      expect(events.single.sourceKind, MicAudioSourceKind.usbWired);
      expect(events.single.switchingEnabled, isFalse);
    });

    test(
      'a disabled controller reports the OS-chosen source on changes',
      () async {
        micIsAndroid = true;

        await session.init();

        fake.audioDevicesResult = {_scoHeadset};

        buildController(enabled: false);

        await controller!.start();
        await pump();

        expect(events.single.sourceKind, MicAudioSourceKind.bluetooth);

        // The headset disconnects and only the speaker remains.
        fake.audioDevicesResult = {_speaker};
        fake.emitDevicesChanged(removed: [_scoHeadset]);
        await pump();

        expect(events.last.sourceKind, MicAudioSourceKind.systemDefault);
        expect(events.last.switchingEnabled, isFalse);
        expect(fake.setBluetoothStatusCalls, isEmpty);
      },
    );

    test('enabling mid-flight applies the ladder', () async {
      micIsAndroid = true;

      fake.audioDevicesResult = {_wiredHeadset, _builtinMic};

      buildController(enabled: false);

      await controller!.start();
      await pump();

      expect(fake.setBluetoothStatusCalls, isEmpty);

      await controller!.setEnabled(true);
      await pump();

      expect(controller!.ownsInputRouting, isTrue);
      expect(fake.setBluetoothStatusCalls, [false]);

      expect(
        _logData(logs, 'audioInputsSnapshot'),
        contains(containsPair('reason', 'toggle-on')),
      );

      // The effective kind did not change, so no second event.
      expect(events, hasLength(1));
    });

    test(
      'disabling restores the Android Bluetooth gate and stands down',
      () async {
        buildController();
        micIsAndroid = true;

        await session.init();

        fake.audioDevicesResult = {_builtinMic};

        await controller!.prepare();

        expect(fake.setBluetoothStatusCalls, [false]);

        await controller!.start();
        await pump();

        expect(fake.setBluetoothStatusCalls, [false]);

        await controller!.setEnabled(false);
        await pump();

        expect(controller!.ownsInputRouting, isFalse);

        // The normal Android Bluetooth behavior is restored.
        expect(fake.setBluetoothStatusCalls, [false, true]);

        expect(
          _logData(logs, 'audioInputSourceChanged'),
          contains(containsPair('action', 'stand-down')),
        );

        // A device change while disabled is observed, never steered.
        fake.audioDevicesResult = {_wiredHeadset, _builtinMic};
        fake.emitDevicesChanged(added: [_wiredHeadset]);
        await pump();

        expect(fake.setBluetoothStatusCalls, [false, true]);
        expect(events.last.sourceKind, MicAudioSourceKind.usbWired);
        expect(events.last.switchingEnabled, isFalse);
        expect(events.last.reason, 'device-change');
      },
    );

    test(
      'disabling on iOS stands down without touching the Bluetooth gate',
      () async {
        buildController();
        micIsIOS = true;

        fake.getAvailableInputsResult = [_usbInput, _builtinInput];
        fake.getCurrentRouteResult = MicAudioRoute(inputs: [_usbInput]);

        await controller!.start();
        await pump();

        expect(events.single.sourceKind, MicAudioSourceKind.usbWired);

        await controller!.setEnabled(false);
        await pump();

        expect(controller!.ownsInputRouting, isFalse);

        // The Bluetooth gate is an Android-only lever.
        expect(fake.setBluetoothStatusCalls, isEmpty);

        expect(
          _logData(logs, 'audioInputSourceChanged'),
          contains(containsPair('action', 'stand-down')),
        );
      },
    );

    test(
      'a disabled iOS controller reports the OS route as the effective source',
      () async {
        buildController(enabled: false);
        micIsIOS = true;

        await session.init();

        // The OS routed to the Bluetooth headset on its own.
        fake.getCurrentRouteResult = MicAudioRoute(inputs: [_hfpInput]);

        await controller!.start();
        await pump();

        expect(events.single.sourceKind, MicAudioSourceKind.bluetooth);
        expect(events.single.switchingEnabled, isFalse);
        expect(events.single.sourceName, 'BT headset');

        // The OS re-routes to the built-in mic mid-recording: still reported
        // (it is the effective source), still never steered.
        fake.getCurrentRouteResult = MicAudioRoute(inputs: [_builtinInput]);
        fake.emitIosRouteChange(MicIosRouteChangeReason.newDeviceAvailable);
        await pump();

        expect(events.last.sourceKind, MicAudioSourceKind.defaultMicrophone);
        expect(events.last.switchingEnabled, isFalse);
        expect(fake.setPreferredInputCalls, isEmpty);
      },
    );

    test('setEnabled while not started only flips the flag', () async {
      buildController();
      expect(MicRouteController.defaultEnabled, isTrue);

      await controller!.setEnabled(false);
      expect(controller!.isEnabled, isFalse);

      await controller!.setEnabled(true);
      expect(controller!.isEnabled, isTrue);

      // Nothing is driven before a recording episode starts.
      expect(controller!.ownsInputRouting, isFalse);
      expect(fake.callLog, isEmpty);
    });
  });

  group('device-change serialization', () {
    test(
      'changes arriving mid-evaluation are held; the latest snapshot wins',
      () async {
        micIsAndroid = true;

        await session.init();

        final gated = _GatedRouteStatePlatform();

        buildController(platform: gated);

        fake.audioDevicesResult = {_scoHeadset, _builtinMic};

        await controller!.prepare();
        await controller!.start();
        await pump();

        // The standing decision is Bluetooth (engaged by prepare; the start
        // re-check and the seeded device snapshot only verify it).
        final baseline = gated.delegate.setBluetoothStatusCalls.length;
        expect(baseline, greaterThan(0));
        expect(gated.delegate.setBluetoothStatusCalls, everyElement(isTrue));

        // Park the next native route-state query: the evaluation of the next
        // device change blocks inside its headset consult.
        gated.parkNextGetRouteState();

        // The headset vanishes — with only the built-in mic left, the
        // evaluation must consult the native headset signal (parked).
        fake.audioDevicesResult = {_builtinMic};
        fake.emitDevicesChanged(removed: [_scoHeadset]);
        await pump();

        // A second change lands while the first evaluation is still in
        // flight: it must be held — neither dropped nor run concurrently.
        fake.audioDevicesResult = {_scoHeadset, _builtinMic};
        fake.emitDevicesChanged(added: [_scoHeadset]);
        await pump();

        expect(gated.delegate.setBluetoothStatusCalls, hasLength(baseline));

        // The parked evaluation completes with its own answer (no headset):
        // the built-in mic decision is applied...
        gated.releaseGatedRouteState(const <String, Object?>{});
        await pump();

        // ...then the HELD change is evaluated with the LATEST snapshot, so
        // Bluetooth is re-engaged — exactly one application each, in order.
        expect(gated.delegate.setBluetoothStatusCalls.sublist(baseline), [
          false,
          true,
        ]);

        expect(events.map((event) => event.sourceKind), <MicAudioSourceKind>[
          MicAudioSourceKind.bluetooth,
          MicAudioSourceKind.defaultMicrophone,
          MicAudioSourceKind.bluetooth,
        ]);
      },
    );
  });

  group('stop and episode reset', () {
    test('stop clears routing ownership and device reactivity', () async {
      buildController();
      micIsAndroid = true;

      await session.init();

      fake.audioDevicesResult = {_wiredHeadset, _builtinMic};

      await controller!.prepare();

      await controller!.start();
      await pump();

      expect(fake.setBluetoothStatusCalls, [false]);

      await controller!.stop();

      expect(controller!.ownsInputRouting, isFalse);

      // The device subscription is gone: later changes never steer.
      fake.emitDevicesChanged(removed: [_wiredHeadset]);
      await pump();

      expect(fake.setBluetoothStatusCalls, [false]);
      expect(events, hasLength(1));
    });

    test(
      'a restarted episode re-applies and re-emits its resolution',
      () async {
        buildController();
        micIsAndroid = true;

        fake.audioDevicesResult = {_scoHeadset, _builtinMic};

        await controller!.prepare();
        await controller!.start();
        await pump();

        expect(events.single.sourceKind, MicAudioSourceKind.bluetooth);
        expect(events.single.previousSourceKind, isNull);

        await controller!.stop();

        await controller!.start();
        await pump();

        expect(controller!.ownsInputRouting, isTrue);

        // The decision was re-applied for the new episode...
        expect(fake.setBluetoothStatusCalls, everyElement(isTrue));
        expect(fake.setBluetoothStatusCalls.length, greaterThan(1));

        // ...and its initial resolution re-emitted with a clean slate.
        expect(events, hasLength(2));
        expect(events.last.sourceKind, MicAudioSourceKind.bluetooth);
        expect(events.last.previousSourceKind, isNull);
      },
    );

    test('dispose ends the source-switched stream', () async {
      buildController();
      await controller!.dispose();

      // A closed broadcast stream immediately delivers done to new
      // listeners — the second dispose in tearDown stays a no-op.
      await expectLater(
        controller!.onAudioSourceSwitched.drain<void>(),
        completes,
      );
    });
  });

  group('failure resilience', () {
    test('a failed iOS input switch logs and keeps the route', () async {
      micIsIOS = true;

      final faulty = _FaultyRoutingPlatform();

      buildController(platform: faulty);

      faulty.delegate.getAvailableInputsResult = [_usbInput, _builtinInput];
      faulty.delegate.getCurrentRouteResult = MicAudioRoute(
        inputs: [_builtinInput],
      );
      faulty.setPreferredInputError = StateError('preferred input rejected');

      await controller!.prepare();

      expect(faulty.setPreferredInputAttempts, [_usbInput]);

      // The switch failed: no source event claims the target.
      expect(events, isEmpty);

      expect(
        _logData(logs, 'audioInputSourceChanged'),
        contains(containsPair('action', 'switch-failed')),
      );
    });

    test('a failed Android gate switch logs and keeps the route', () async {
      micIsAndroid = true;

      final faulty = _FaultyRoutingPlatform();

      buildController(platform: faulty);

      // The Android ladder reads the device snapshot through the session,
      // which is wired to the plain fake — script the devices there; only
      // the gate call needs to travel through the faulty platform.
      fake.audioDevicesResult = {_scoHeadset, _builtinMic};
      faulty.setBluetoothStatusError = StateError('gate rejected');

      await controller!.prepare();

      expect(faulty.setBluetoothStatusAttempts, [true]);
      expect(events, isEmpty);

      expect(
        _logData(logs, 'audioInputSourceChanged'),
        contains(containsPair('action', 'switch-failed')),
      );
    });

    test('a routing failure during prepare stands the policy down', () async {
      micIsIOS = true;

      final faulty = _FaultyRoutingPlatform();

      buildController(platform: faulty);

      faulty.getAvailableInputsError = StateError('inputs unavailable');

      // The routing policy must never break recording startup.
      await controller!.prepare();

      expect(controller!.ownsInputRouting, isFalse);
      expect(controller!.isEnabled, isTrue);
      expect(events, isEmpty);

      expect(
        _loggedError(logs, 'audioInputsSnapshot', 'policyPrepareError'),
        isTrue,
      );
    });

    test('a routing failure during start stands the policy down', () async {
      micIsIOS = true;

      final faulty = _FaultyRoutingPlatform();

      buildController(platform: faulty);

      faulty.getAvailableInputsError = StateError('inputs unavailable');

      // The routing policy must never break recording startup.
      await controller!.start();
      await pump();

      expect(controller!.ownsInputRouting, isFalse);

      expect(
        _loggedError(logs, 'audioInputsSnapshot', 'policyStartError'),
        isTrue,
      );

      // A later enable attempt retries the ladder (and reports its own
      // failure — the toggle must never throw either).
      await controller!.setEnabled(true);
      await pump();

      expect(_loggedError(logs, 'audioRouteChanged', 'toggleOnError'), isTrue);
    });

    test(
      'a failing evaluation while routing is logged, never thrown',
      () async {
        micIsIOS = true;

        await session.init();

        final faulty = _FaultyRoutingPlatform();

        buildController(platform: faulty);

        faulty.delegate.getAvailableInputsResult = [_usbInput, _builtinInput];
        faulty.delegate.getCurrentRouteResult = MicAudioRoute(
          inputs: [_usbInput],
        );

        await controller!.start();
        await pump();

        expect(faulty.delegate.setPreferredInputCalls, isEmpty);

        // The inputs query starts failing: a device-change evaluation must
        // log the error and keep the policy standing — never rethrow.
        faulty.getAvailableInputsError = StateError('inputs gone');

        fake.emitIosRouteChange(MicIosRouteChangeReason.newDeviceAvailable);
        await pump();

        expect(controller!.ownsInputRouting, isTrue);
        expect(faulty.delegate.setPreferredInputCalls, isEmpty);

        expect(
          _loggedError(logs, 'audioRouteChanged', 'evaluationError'),
          isTrue,
        );
      },
    );

    test(
      'a failing observation while disabled never disturbs the pipeline',
      () async {
        micIsIOS = true;

        final faulty = _FaultyRoutingPlatform();

        buildController(enabled: false, platform: faulty);

        faulty.getCurrentRouteError = StateError('route unavailable');

        await controller!.start();
        await pump();

        expect(controller!.ownsInputRouting, isFalse);
        expect(events, isEmpty);
      },
    );
  });

  group('unsupported platforms', () {
    test('routing is left to the OS outside iOS and Android', () async {
      buildController();
      // The host test platform is neither iOS nor Android.
      await controller!.prepare();
      await controller!.start();
      await pump();

      expect(controller!.ownsInputRouting, isFalse);
      expect(fake.callLog, isEmpty);

      // The stand-down log names the host the suite runs on (macos,
      // linux, …) because the controller reads Platform.operatingSystem,
      // so the expectation must follow it too — a hard-coded name would
      // tie the suite to one developer machine.
      expect(
        _logData(logs, 'audioInputsSnapshot'),
        contains(containsPair('policyPlatform', Platform.operatingSystem)),
      );
    });
  });
}
