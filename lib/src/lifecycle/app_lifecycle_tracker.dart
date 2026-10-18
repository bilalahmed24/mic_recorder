import 'dart:async';

import 'package:flutter/widgets.dart';

import '../internal/streams.dart';

/// Tracks the app's lifecycle state for the recorder.
///
/// The plugin's controllers need to know whether the app is foregrounded
/// before performing session writes (iOS forbids audio-session writes from
/// the background; Android's focus requests race the launch). This tracker
/// owns a single `WidgetsBindingObserver` registration so the recorder does
/// not need one per controller.
///
/// Deterministic under tests: a one-shot 100 ms "assume resumed" fallback
/// primes [currentState] until the first real observation arrives, and that
/// fallback timer is cancelled by any real observation — whether it arrives
/// through the binding (a real app) or through a direct
/// [didChangeAppLifecycleState] call (tests).
final class AppLifecycleTracker with WidgetsBindingObserver {
  AppLifecycleTracker._() {
    _registerWithBindingIfAvailable();

    _assumeResumedTimer = Timer(_assumeResumedDelay, () {
      if (!_hasRealObservation) {
        _state$.add(AppLifecycleState.resumed);
      }
    });
  }

  /// The shared tracker instance.
  static final AppLifecycleTracker instance = AppLifecycleTracker._();

  /// How long to wait for the first real observation before assuming the
  /// app is resumed.
  static const Duration _assumeResumedDelay = Duration(milliseconds: 100);

  final SeededStream<AppLifecycleState> _state$ =
      SeededStream<AppLifecycleState>(AppLifecycleState.resumed);

  Timer? _assumeResumedTimer;

  bool _hasRealObservation = false;

  /// The current lifecycle state.
  ///
  /// Resumed until the first real observation says otherwise — matching both
  /// normal app launches and headless test environments.
  AppLifecycleState get currentState => _state$.value;

  /// Every lifecycle state change, seeded with [currentState].
  ///
  /// New listeners immediately receive the current state, then updates as
  /// they happen — a listener can therefore rely on receiving one state
  /// without waiting for the app to actually transition.
  Stream<AppLifecycleState> get onStateChange => _state$.stream;

  /// Observes a lifecycle state change.
  ///
  /// Called by the binding for real observations; tests dispatch states
  /// through this method directly. Any real observation cancels the
  /// assume-resumed priming.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _assumeResumedTimer?.cancel();
    _assumeResumedTimer = null;

    _hasRealObservation = true;

    _state$.add(state);
  }

  /// Cancels the priming timer without recording an observation.
  ///
  /// Useful for test teardowns that want a clean timer slate without
  /// asserting a state transition happened.
  void cancelAssumeResumedTimer() {
    _assumeResumedTimer?.cancel();
    _assumeResumedTimer = null;
  }

  void _registerWithBindingIfAvailable() {
    // A binding always exists in a running app and in `testWidgets`; a
    // binding-less plain `test()` dispatches states manually instead, so a
    // missing registration is fine there.
    try {
      WidgetsBinding.instance.addObserver(this);
    } catch (_) {
      // No binding — manual dispatch only.
    }
  }
}
