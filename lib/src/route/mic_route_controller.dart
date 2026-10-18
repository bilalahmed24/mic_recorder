import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

import '../internal/mic_logger.dart';
import '../internal/mic_platform.dart';
import '../lifecycle/app_lifecycle_tracker.dart';
import '../models/mic_audio_device.dart';
import '../models/mic_recorder_events.dart';
import '../platform/mic_recorder_platform.dart';
import '../session/mic_audio_session_controller.dart';

/// Selects the preferred microphone during recording.
///
/// Priority: USB/wired → Bluetooth → built-in microphone. Works on iOS and
/// Android and re-evaluates when available inputs change. The policy can be
/// disabled to leave routing entirely to the OS.
final class MicRouteController with WidgetsBindingObserver {
  /// Creates a route controller bound to its collaborators.
  ///
  /// The [platform] is injectable for tests; it defaults to the shared
  /// [MicRecorderPlatform.instance]. Callers wire the [log], [lifecycle]
  /// and [session] owned by the surrounding recorder.
  MicRouteController({
    required bool enabled,
    required MicLogSink log,
    required AppLifecycleTracker lifecycle,
    required MicAudioSessionController session,
    MicRecorderPlatform? platform,
  }) : _isEnabled = enabled,
       _log = log,
       _lifecycle = lifecycle,
       _session = session,
       _platform = platform ?? MicRecorderPlatform.instance;

  /// Whether priority routing is enabled by default.
  static const bool defaultEnabled = true;

  /// Delay before re-checking inputs after recording starts.
  static const Duration settleReassertDelay = Duration(milliseconds: 3000);

  /// Delay before re-applying the preferred input after the app resumes.
  static const Duration foregroundReassertDelay = Duration(milliseconds: 300);

  /// Minimum delay after an interruption before changing the iOS input
  /// while the app is in the background.
  static const Duration interruptionWriteCooldown = Duration(seconds: 5);

  /// Retry delay when routing is temporarily deferred because there is no
  /// current input route.
  static const Duration routeRepayDelay = Duration(seconds: 2);

  // Input types are grouped into the three priority levels below.

  /// Input device types treated as "USB / wired external" microphones —
  /// rung 1 of the ladder.
  static const Set<MicAudioDeviceType> usbWiredInputTypes = {
    MicAudioDeviceType.usbAudio,
    MicAudioDeviceType.wiredHeadset,
    MicAudioDeviceType.lineAnalog,
    MicAudioDeviceType.lineDigital,
    MicAudioDeviceType.carAudio,
  };

  /// Input device types treated as Bluetooth microphones — rung 2.
  static const Set<MicAudioDeviceType> bluetoothInputTypes = {
    MicAudioDeviceType.bluetoothSco,
    MicAudioDeviceType.bluetoothLe,
  };

  /// Any Bluetooth audio device (input OR output). An A2DP output appears
  /// in the device set the moment a headset connects — before (and
  /// regardless of) the SCO input listing — so it doubles as a
  /// headset-connected signal.
  static const Set<MicAudioDeviceType> bluetoothDeviceTypes = {
    MicAudioDeviceType.bluetoothSco,
    MicAudioDeviceType.bluetoothLe,
    MicAudioDeviceType.bluetoothA2dp,
  };

  /// Input device types treated as the device's own microphone — rung 3.
  static const Set<MicAudioDeviceType> defaultInputTypes = {
    MicAudioDeviceType.builtInMic,
  };

  /// iOS port types treated as "USB / wired external" microphones — rung 1.
  static const Set<String> usbWiredPortTypes = {
    'USBAudio',
    'HeadsetMic',
    'LineIn',
    'CarAudio',
  };

  /// iOS port types treated as Bluetooth microphones — rung 2.
  static const Set<String> bluetoothPortTypes = {'BluetoothHFP', 'BluetoothLE'};

  /// iOS port type of the device's built-in (default) microphone — rung 3.
  static const String builtinMicPortType = 'BuiltInMic';

  final MicLogSink _log;
  final AppLifecycleTracker _lifecycle;
  final MicAudioSessionController _session;
  final MicRecorderPlatform _platform;

  /// Whether the Dart-side priority policy is active.
  bool _isEnabled;

  bool _isStarted = false;
  bool _isStandDownLogged = false;

  /// Last headset-connected signal seen by the ladder; flips are logged.
  bool? _lastHeadsetConnectedSignal;
  bool _ownsRouting = false;

  StreamSubscription<Set<MicAudioDevice>>? _deviceChangeSubscription;

  /// Last routing decision. Used to avoid repeating the same Android
  /// routing operation.
  String? _lastAppliedDecision;

  /// Last source kind emitted. Dedupes emissions: the event fires only
  /// when the EFFECTIVE source kind changes. Reset in [stop] so every
  /// recording episode re-emits its initial resolution.
  MicAudioSourceKind? _lastEmittedSourceKind;

  /// Ensures device changes are evaluated one at a time.
  bool _isEvaluating = false;
  bool _hasPendingEvaluation = false;
  Set<MicAudioDevice>? _pendingDevices;

  /// Re-checks the preferred input shortly after recording starts.
  Timer? _settleReassertTimer;

  /// Re-checks the preferred input after the app resumes.
  Timer? _foregroundReassertTimer;

  /// Re-tries an input change that was temporarily deferred.
  Timer? _routeRepayTimer;

  final StreamController<MicAudioSourceSwitchedEvent>
  _sourceSwitchedController =
      StreamController<MicAudioSourceSwitchedEvent>.broadcast();

  /// Whether priority routing is enabled.
  bool get isEnabled => _isEnabled;

  /// Whether this controller is currently responsible for routing.
  bool get ownsInputRouting => _ownsRouting;

  /// Effective source change events (deduped per recording episode).
  Stream<MicAudioSourceSwitchedEvent> get onAudioSourceSwitched =>
      _sourceSwitchedController.stream;

  /// Applies the input priority BEFORE the native recorder starts.
  ///
  /// Called after the audio session is activated: on iOS the preferred
  /// input is set while no capture engine is running yet, and on Android
  /// the native Bluetooth gate is already positioned when `AudioRecord`
  /// is created — so the first captured buffer comes from the priority
  /// input instead of briefly capturing Bluetooth and switching. Safe to
  /// skip: [start] applies the same policy again if this never ran.
  Future<void> prepare() async {
    if (_isStarted) return;

    if (!_isEnabled) {
      _log(MicLogLevel.trace, 'audioInputsSnapshot', {
        'reason': 'prepare',
        'switchingEnabled': false,
        'note': 'Dart-side priority routing disabled; OS defaults apply',
      });

      return;
    }

    if (!_isSupportedPlatform()) return;

    try {
      _ownsRouting = true;

      await _apply(reason: 'prepare');
    } catch (e) {
      // The routing policy must never break recording startup: if the
      // native layer is unavailable for any reason, stand down quietly.
      _ownsRouting = false;

      _log(MicLogLevel.error, 'audioInputsSnapshot', {
        'policyPrepareError': e.toString(),
      });
    }
  }

  /// Keeps the input priority applied for the duration of a recording:
  /// subscribes to device changes and re-applies the ladder on every
  /// event. Idempotent; call [stop] when recording ends.
  ///
  /// The subscription is installed even while the policy is disabled —
  /// device changes stay visible in logs (observe-only), and a mid-flight
  /// [setEnabled] takes effect immediately without re-subscribing.
  Future<void> start() async {
    if (_isStarted) return;

    _isStarted = true;

    if (!_isSupportedPlatform()) return;

    try {
      _deviceChangeSubscription = _session.devicesStream.listen(
        _onDevicesChanged,
        onError: (Object error, StackTrace _) {
          _log(MicLogLevel.error, 'audioRouteChanged', {
            'deviceStreamError': error.toString(),
          });
        },
      );

      WidgetsBinding.instance.addObserver(this);

      if (!_isEnabled) {
        _ownsRouting = false;

        _log(MicLogLevel.trace, 'audioInputsSnapshot', {
          'reason': 'start',
          'switchingEnabled': false,
          'note': 'Dart-side priority routing disabled; observing only',
        });

        await _emitObservedSourceKind(reason: 'start');

        return;
      }

      _ownsRouting = true;

      // Apply once more in case prepare() did not set the route.
      await _apply(reason: 'start');

      // Some devices appear shortly after recording starts, so check again.
      _scheduleSettleReassert();
    } catch (e) {
      _ownsRouting = false;

      _log(MicLogLevel.error, 'audioInputsSnapshot', {
        'policyStartError': e.toString(),
      });
    }
  }

  /// Stops routing and clears the current routing state.
  Future<void> stop() async {
    _settleReassertTimer?.cancel();
    _settleReassertTimer = null;

    _foregroundReassertTimer?.cancel();
    _foregroundReassertTimer = null;

    _routeRepayTimer?.cancel();
    _routeRepayTimer = null;

    WidgetsBinding.instance.removeObserver(this);

    // Fake-async law (see worklog Task 6-10): a broadcast subscription's
    // cancel() future never completes under a fake event loop — teardown
    // paths must not await it.
    unawaited(_deviceChangeSubscription?.cancel() ?? Future<void>.value());
    _deviceChangeSubscription = null;

    _ownsRouting = false;
    _lastAppliedDecision = null;

    // The recording episode ended — its source-kind episode ends with it,
    // so the NEXT recording re-emits its own initial resolution.
    _lastEmittedSourceKind = null;

    _hasPendingEvaluation = false;
    _pendingDevices = null;

    _isStarted = false;
  }

  /// Enables or disables priority routing (persisting the setting is the
  /// app's job).
  Future<void> setEnabled(bool value) async {
    _isEnabled = value;

    _log(MicLogLevel.trace, 'audioRouteChanged', {
      'config': 'audio-route-switching',
      'switchingEnabled': value,
    });

    if (!_isStarted) {
      _ownsRouting = false;

      return;
    }

    if (value) {
      _ownsRouting = true;

      try {
        await _apply(reason: 'toggle-on');
      } catch (e) {
        _log(MicLogLevel.error, 'audioRouteChanged', {
          'toggleOnError': e.toString(),
        });
      }

      return;
    }

    _ownsRouting = false;
    _lastAppliedDecision = null;

    if (micIsAndroid) {
      // Restore the normal Android Bluetooth behavior.
      try {
        await _platform.setBluetoothStatus(true);
      } catch (_) {}
    }

    _log(MicLogLevel.trace, 'audioInputSourceChanged', {
      'action': 'stand-down',
      'reason': 'toggle-off',
      'note': 'Dart-side priority routing disabled; OS defaults apply',
    });

    // The OS takes over routing — the observed source (which may differ
    // from the ladder's last choice) becomes the effective source.
    await _emitObservedSourceKind(reason: 'toggle-off');
  }

  /// Re-checks the preferred input shortly after recording starts.
  void _scheduleSettleReassert() {
    _settleReassertTimer?.cancel();

    _settleReassertTimer = Timer(settleReassertDelay, () {
      if (!_isStarted || !_ownsRouting) return;

      () async {
        try {
          await _apply(reason: 'settle-reassert');
        } catch (e) {
          _log(MicLogLevel.error, 'audioRouteChanged', {
            'settleReassertError': e.toString(),
          });
        }
      }();
    });
  }

  /// Re-applies the preferred input after the app returns to the
  /// foreground.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;

    _scheduleForegroundReassert();
  }

  /// Schedules a one-time routing check after resume.
  void _scheduleForegroundReassert() {
    _foregroundReassertTimer?.cancel();

    _foregroundReassertTimer = Timer(foregroundReassertDelay, () {
      if (!_isStarted || !_ownsRouting) return;

      () async {
        try {
          await _apply(reason: 'foreground-resume');
        } catch (e) {
          _log(MicLogLevel.error, 'audioRouteChanged', {
            'foregroundReassertError': e.toString(),
          });
        }
      }();
    });
  }

  /// Re-checks a routing decision that was temporarily deferred.
  void _scheduleRouteRepay({required Duration delay}) {
    _routeRepayTimer?.cancel();

    _routeRepayTimer = Timer(delay, () {
      if (!_isStarted || !_ownsRouting) return;

      () async {
        try {
          await _apply(reason: 'deferred-repay');
        } catch (e) {
          _log(MicLogLevel.error, 'audioRouteChanged', {
            'routeRepayError': e.toString(),
          });
        }
      }();
    });
  }

  /// Only iOS and Android have explicit routing support here.
  bool _isSupportedPlatform() {
    if (micIsIOS || micIsAndroid) return true;

    if (!_isStandDownLogged) {
      _isStandDownLogged = true;

      _log(MicLogLevel.trace, 'audioInputsSnapshot', {
        'policyPlatform': Platform.operatingSystem,
        'note': 'unsupported platform; input routing left to the OS',
      });
    }

    return false;
  }

  /// Serializes device-change handling. If several events arrive while one
  /// evaluation is running, only the latest device set is evaluated next.
  void _onDevicesChanged(Set<MicAudioDevice> devices) {
    if (_isEvaluating) {
      _hasPendingEvaluation = true;
      _pendingDevices = devices;
      return;
    }

    _isEvaluating = true;

    () async {
      try {
        await _evaluate(devices);

        while (_hasPendingEvaluation) {
          _hasPendingEvaluation = false;

          await _evaluate(_pendingDevices!);
        }
      } finally {
        _isEvaluating = false;
        _pendingDevices = null;
      }
    }();
  }

  Future<void> _evaluate(Set<MicAudioDevice> devices) async {
    try {
      await _evaluateUnsafe(devices);
    } catch (e) {
      _log(MicLogLevel.error, 'audioRouteChanged', {
        'evaluationError': e.toString(),
      });
    }
  }

  Future<void> _evaluateUnsafe(Set<MicAudioDevice> devices) async {
    if (!_ownsRouting) {
      // Policy is disabled: observe and log device changes, but don't
      // steer.
      _log(MicLogLevel.trace, 'audioInputsSnapshot', {
        'reason': 'device-change',
        'switchingEnabled': false,
        'inputs': _describeDevices(devices.where((d) => d.isInput)),
      });

      // Observe-only: the OS re-routed on its own — still a source change
      // worth an event.
      await _emitObservedSourceKind(reason: 'device-change', devices: devices);

      return;
    }

    if (micIsIOS) {
      await _evaluateIOS(reason: 'device-change');
    } else {
      await _evaluateAndroid(devices, reason: 'device-change');
    }
  }

  /// Applies the current priority using a fresh device snapshot.
  Future<void> _apply({required String reason}) async {
    if (!_ownsRouting) return;

    if (micIsIOS) {
      await _evaluateIOS(reason: reason);
    } else {
      await _evaluateAndroid(await _session.getDevices(), reason: reason);
    }
  }

  // iOS selects the preferred input on the shared audio session.
  Future<void> _evaluateIOS({required String reason}) async {
    final inputs = await _platform.getAvailableInputs();

    final current = _currentInputOf(await _platform.getCurrentRoute());

    // Prefer USB/wired, then Bluetooth, then the built-in microphone.
    var target = inputs
        .where((input) => usbWiredPortTypes.contains(input.portType))
        .firstOrNull;

    var targetKind = MicAudioSourceKind.usbWired;

    if (target == null) {
      target = inputs
          .where((input) => bluetoothPortTypes.contains(input.portType))
          .firstOrNull;

      targetKind = MicAudioSourceKind.bluetooth;
    }

    if (target == null) {
      target = inputs
          .where((input) => input.portType == builtinMicPortType)
          .firstOrNull;

      targetKind = MicAudioSourceKind.defaultMicrophone;
    }

    _log(MicLogLevel.trace, 'audioInputsSnapshot', {
      'reason': reason,
      'switchingEnabled': _isEnabled,
      'current': _describeIosInput(current),
      'inputs': [for (final input in inputs) _describeIosInput(input)],
      'decision': target == null
          ? MicAudioSourceKind.systemDefault.wireName
          : targetKind.wireName,
    });

    if (target == null) {
      _log(MicLogLevel.trace, 'audioInputSourceChanged', {
        'action': 'none',
        'reason': reason,
        'note': 'no selectable input offered; leaving route to the OS',
      });

      // No selectable input: the OS default is the effective source.
      await _emitSourceKindChanged(
        sourceKind: MicAudioSourceKind.systemDefault,
        reason: reason,
      );

      return;
    }

    // Already using the preferred input, so no change is needed.
    if (target.uid == current?.uid) {
      _lastAppliedDecision = targetKind.wireName;

      _log(MicLogLevel.trace, 'audioInputSourceChanged', {
        'action': 'already-routed',
        'to': _describeIosInput(target),
        'targetKind': targetKind.wireName,
        'reason': reason,
      });

      // Effective source is already the target: emit the kind (deduped —
      // the FIRST evaluation of a recording episode is the
      // recording-start resolution).
      await _emitSourceKindChanged(
        sourceKind: targetKind,
        sourceName: target.portName,
        reason: reason,
      );

      return;
    }

    final lifecycleState = _lifecycle.currentState;

    final isForegrounded = lifecycleState == AppLifecycleState.resumed;

    final routeHasInput = current != null;

    final interruptionActive =
        _session.isInterruptionActive || _session.isRecoveringFromInterruption;

    final lastInterruptionAt = _session.lastInterruptionEventAt;

    final msSinceInterruption = lastInterruptionAt == null
        ? null
        : DateTime.now().difference(lastInterruptionAt).inMilliseconds;

    final quietPeriodElapsed =
        msSinceInterruption == null ||
        msSinceInterruption >= interruptionWriteCooldown.inMilliseconds;

    final writeAllowed =
        routeHasInput &&
        (isForegrounded || (!interruptionActive && quietPeriodElapsed));

    if (!writeAllowed) {
      // Delay the decision rather than dropping it; conditions are checked
      // again when the timer fires.
      _scheduleRouteRepay(
        delay: routeHasInput ? interruptionWriteCooldown : routeRepayDelay,
      );

      _log(MicLogLevel.trace, 'audioSessionWriteDeferred', {
        'action': 'preferred-input-deferred',
        'to': _describeIosInput(target),
        'targetKind': targetKind.wireName,
        'reason': reason,
        'appLifecycleState': '$lifecycleState',
        'currentRouteHasInput': routeHasInput,
        'interruptionActive': interruptionActive,
        'msSinceLastInterruption': msSinceInterruption,
        'repayArmedMs':
            (routeHasInput ? interruptionWriteCooldown : routeRepayDelay)
                .inMilliseconds,
        'note':
            'session write deferred (route torn down or interruption '
            'window); the repay timer or the foreground re-assertion '
            'applies it once the gates clear',
      });

      return;
    }

    try {
      await _platform.setPreferredInput(target);
    } catch (e) {
      _log(MicLogLevel.error, 'audioInputSourceChanged', {
        'action': 'switch-failed',
        'to': _describeIosInput(target),
        'targetKind': targetKind.wireName,
        'reason': reason,
        'error': e.toString(),
      });

      return;
    }

    _lastAppliedDecision = targetKind.wireName;

    _log(MicLogLevel.trace, 'audioInputSourceChanged', {
      'action': 'switched',
      'from': _describeIosInput(current),
      'to': _describeIosInput(target),
      'targetKind': targetKind.wireName,
      'reason': reason,
      'appLifecycleState': '$lifecycleState',
    });

    await _emitSourceKindChanged(
      sourceKind: targetKind,
      sourceName: target.portName,
      reason: reason,
    );
  }

  // Android uses Bluetooth only when no USB/wired microphone is available.
  Future<void> _evaluateAndroid(
    Set<MicAudioDevice> devices, {
    required String reason,
  }) async {
    final inputs = devices.where((device) => device.isInput).toList();

    MicAudioSourceKind decision;

    if (inputs.any((device) => usbWiredInputTypes.contains(device.type))) {
      decision = MicAudioSourceKind.usbWired;
    } else if (inputs.any(
      (device) => bluetoothInputTypes.contains(device.type),
    )) {
      decision = MicAudioSourceKind.bluetooth;
    } else if (inputs.any(
      (device) => defaultInputTypes.contains(device.type),
    )) {
      // A connected headset is still routable — consult the native/A2DP
      // signals before falling back.
      decision = await _isBluetoothHeadsetConnected(devices)
          ? MicAudioSourceKind.bluetooth
          : MicAudioSourceKind.defaultMicrophone;
    } else {
      decision = MicAudioSourceKind.systemDefault;
    }

    _log(MicLogLevel.trace, 'audioInputsSnapshot', {
      'reason': reason,
      'switchingEnabled': _isEnabled,
      'inputs': _describeDevices(inputs),
      'decision': decision.wireName,
      'lastApplied': _lastAppliedDecision,
    });

    if (decision == MicAudioSourceKind.systemDefault) {
      _log(MicLogLevel.trace, 'audioInputSourceChanged', {
        'action': 'none',
        'reason': reason,
        'note': 'no selectable input offered; leaving route to the OS',
      });

      // No selectable input: the OS default is the effective source.
      await _emitSourceKindChanged(
        sourceKind: MicAudioSourceKind.systemDefault,
        reason: reason,
      );

      return;
    }

    // If this decision was already applied, there is nothing to do —
    // unless the native route disagrees, in which case it is applied
    // again.
    if (decision.wireName == _lastAppliedDecision) {
      // An SCO link that lingers after leaving Bluetooth is cleaned up by
      // the native layer (bounded); it is not a routing mismatch, so only
      // a Bluetooth decision needs native verification — a start that
      // silently failed in the background must be re-requested.
      if (decision != MicAudioSourceKind.bluetooth) {
        _log(MicLogLevel.trace, 'audioInputSourceChanged', {
          'action': 'already-routed',
          'targetKind': decision.wireName,
          'reason': reason,
        });

        // Effective source is the standing decision: emit the kind
        // (deduped — the FIRST evaluation of a recording episode is the
        // recording-start resolution).
        await _emitSourceKindChanged(
          sourceKind: decision,
          sourceName: _androidSourceName(inputs, decision),
          reason: reason,
        );

        return;
      }

      final routeState = await _platform.getRouteState();

      final scoConnected = routeState == null
          ? null
          : routeState['scoConnected'] == true;

      final scoRequestStoodDown = routeState == null
          ? null
          : routeState['scoRequestStoodDown'] == true;

      if (scoConnected == null || scoConnected || scoRequestStoodDown == true) {
        _log(MicLogLevel.trace, 'audioInputSourceChanged', {
          'action': 'already-routed',
          'targetKind': decision.wireName,
          'reason': reason,
          if (scoRequestStoodDown == true) 'scoRequestStoodDown': true,
        });

        // SCO is live (or was deliberately stood down): Bluetooth is the
        // standing effective source.
        await _emitSourceKindChanged(
          sourceKind: MicAudioSourceKind.bluetooth,
          sourceName: _androidSourceName(inputs, MicAudioSourceKind.bluetooth),
          reason: reason,
        );

        return;
      }

      _log(MicLogLevel.trace, 'audioInputSourceChanged', {
        'action': 're-apply',
        'targetKind': decision.wireName,
        'reason': reason,
        'scoConnected': scoConnected,
      });
    }

    try {
      if (decision == MicAudioSourceKind.bluetooth) {
        // Route capture through Bluetooth.
        await _platform.setBluetoothStatus(true);
      } else {
        // Stop Bluetooth routing so Android uses its normal input.
        await _platform.setBluetoothStatus(false);
      }
    } catch (e) {
      _log(MicLogLevel.error, 'audioInputSourceChanged', {
        'action': 'switch-failed',
        'targetKind': decision.wireName,
        'reason': reason,
        'error': e.toString(),
      });

      return;
    }

    _lastAppliedDecision = decision.wireName;

    _log(MicLogLevel.trace, 'audioInputSourceChanged', {
      'action': 'switched',
      'targetKind': decision.wireName,
      'bluetoothGate': decision == MicAudioSourceKind.bluetooth,
      'reason': reason,
    });

    // The gate change succeeded — the effective source just changed.
    await _emitSourceKindChanged(
      sourceKind: decision,
      sourceName: _androidSourceName(inputs, decision),
      reason: reason,
    );
  }

  /// Emits a source switch when [sourceKind] differs from the last emitted
  /// one (see [_lastEmittedSourceKind]).
  Future<void> _emitSourceKindChanged({
    required MicAudioSourceKind sourceKind,
    String? sourceName,
    required String reason,
  }) async {
    if (sourceKind == _lastEmittedSourceKind) return;

    final previousSourceKind = _lastEmittedSourceKind;

    _lastEmittedSourceKind = sourceKind;

    _sourceSwitchedController.add(
      MicAudioSourceSwitchedEvent(
        sourceKind: sourceKind,
        previousSourceKind: previousSourceKind,
        sourceName: sourceName,
        reason: reason,
        switchingEnabled: _isEnabled,
      ),
    );
  }

  /// Emits the OBSERVED effective source kind (no ladder steering): used
  /// while the priority policy is disabled — the OS's own routing is then
  /// the source in effect, and it can still change mid-recording.
  Future<void> _emitObservedSourceKind({
    required String reason,
    Set<MicAudioDevice>? devices,
  }) async {
    try {
      if (micIsIOS) {
        final current = _currentInputOf(await _platform.getCurrentRoute());

        await _emitSourceKindChanged(
          sourceKind: _classifyIOSInput(current),
          sourceName: current?.portName,
          reason: reason,
        );

        return;
      }

      final androidDevices = devices ?? await _session.getDevices();

      final inputs = androidDevices.where((device) => device.isInput).toList();

      final kind = _classifyAndroidInputs(inputs);

      await _emitSourceKindChanged(
        sourceKind: kind,
        sourceName: _androidSourceName(inputs, kind),
        reason: reason,
      );
    } catch (_) {
      // Observation must never disturb the recording pipeline.
    }
  }

  /// Classifies an iOS current-route input into the source-kind vocabulary
  /// shared with the ladder decisions.
  static MicAudioSourceKind _classifyIOSInput(MicAudioInput? input) {
    if (input == null) return MicAudioSourceKind.systemDefault;
    if (usbWiredPortTypes.contains(input.portType)) {
      return MicAudioSourceKind.usbWired;
    }
    if (bluetoothPortTypes.contains(input.portType)) {
      return MicAudioSourceKind.bluetooth;
    }
    if (input.portType == builtinMicPortType) {
      return MicAudioSourceKind.defaultMicrophone;
    }

    return MicAudioSourceKind.systemDefault;
  }

  /// Classifies an Android input-device snapshot into the source-kind
  /// vocabulary shared with the ladder decisions.
  static MicAudioSourceKind _classifyAndroidInputs(
    List<MicAudioDevice> inputs,
  ) {
    if (inputs.any((device) => usbWiredInputTypes.contains(device.type))) {
      return MicAudioSourceKind.usbWired;
    }

    if (inputs.any((device) => bluetoothInputTypes.contains(device.type))) {
      return MicAudioSourceKind.bluetooth;
    }

    if (inputs.any((device) => defaultInputTypes.contains(device.type))) {
      return MicAudioSourceKind.defaultMicrophone;
    }

    return MicAudioSourceKind.systemDefault;
  }

  /// Display name of the first input device matching [sourceKind] (null
  /// for system-default / when no name is available).
  static String? _androidSourceName(
    List<MicAudioDevice> inputs,
    MicAudioSourceKind sourceKind,
  ) {
    if (sourceKind == MicAudioSourceKind.usbWired) {
      return inputs
          .where((device) => usbWiredInputTypes.contains(device.type))
          .firstOrNull
          ?.name;
    }

    if (sourceKind == MicAudioSourceKind.bluetooth) {
      return inputs
          .where((device) => bluetoothInputTypes.contains(device.type))
          .firstOrNull
          ?.name;
    }

    if (sourceKind == MicAudioSourceKind.defaultMicrophone) {
      return inputs
          .where((device) => defaultInputTypes.contains(device.type))
          .firstOrNull
          ?.name;
    }

    return null;
  }

  static MicAudioInput? _currentInputOf(MicAudioRoute route) =>
      route.inputs.isEmpty ? null : route.inputs.first;

  /// Whether an HFP-capable Bluetooth headset is connected, combining the
  /// native layer's profile state (selection-independent) with the presence
  /// of any Bluetooth device in the snapshot — either one unlocks the
  /// bluetooth decision even when the SCO input itself is not listed.
  Future<bool> _isBluetoothHeadsetConnected(Set<MicAudioDevice> devices) async {
    bool? nativeFlag;
    var nativeRouteStateStale = false;

    try {
      final state = await _platform.getRouteState();

      nativeFlag = state?['bluetoothHeadsetConnected'] == true;

      nativeRouteStateStale =
          state != null && !state.containsKey('bluetoothHeadsetConnected');
    } catch (_) {}

    final listedBluetooth = devices.any(
      (device) => bluetoothDeviceTypes.contains(device.type),
    );

    final connected = nativeFlag == true || listedBluetooth;

    if (_lastHeadsetConnectedSignal != connected) {
      _lastHeadsetConnectedSignal = connected;

      _log(MicLogLevel.trace, 'audioInputsSnapshot', {
        'reason': 'headset-signal',
        'bluetoothHeadsetConnected': connected,
        'nativeFlag': nativeFlag,
        'listedBluetoothDevice': listedBluetooth,
        if (nativeRouteStateStale) 'nativeRouteStateStale': true,
      });
    }

    return connected;
  }

  static String? _describeIosInput(MicAudioInput? input) =>
      input == null ? null : "${input.portType}('${input.portName}')";

  static List<String> _describeDevices(Iterable<MicAudioDevice> devices) =>
      devices.map((device) => device.toString()).toList();

  /// Releases resources (engine teardown).
  Future<void> dispose() async {
    await stop();

    await _sourceSwitchedController.close();
  }
}
