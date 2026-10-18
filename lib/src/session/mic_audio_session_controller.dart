import 'dart:async';

import 'package:flutter/widgets.dart';

import '../config/mic_audio_session_config.dart';
import '../internal/mic_logger.dart';
import '../internal/mic_platform.dart';
import '../internal/streams.dart';
import '../lifecycle/app_lifecycle_tracker.dart';
import '../models/mic_audio_device.dart';
import '../models/mic_audio_interruption.dart';
import '../models/mic_recorder_events.dart';
import '../models/mic_session_events.dart';
import '../platform/mic_recorder_platform.dart';

/// Owns the audio session: configuration, activation, interruption
/// recovery and the device snapshot.
///
/// The audio-session layer is implemented natively inside the plugin
/// (Android `AudioManager` audio focus in Java, iOS `AVAudioSession` in
/// Swift), wrapped here with production interruption-recovery machinery.
/// It maps the platforms' raw
/// notifications onto the shared [MicAudioInterruption] vocabulary:
///
/// * Android focus `loss` → unknown begin; `lossTransient` → pause begin;
///   `lossTransientCanDuck` → pause or duck begin depending on
///   [MicAudioSessionConfig.androidWillPauseWhenDucked]; `gain` → the
///   matching end.
/// * iOS interruption began (not suspended) → unknown begin; ended with
///   `shouldResume` → pause end; ended without it → unknown end (which
///   re-asserts the session).
///
/// Activation failures surface as an interruption (the orchestrator pauses
/// capture) and retry after [periodicDuration] × 5. An interruption end
/// re-activates the session, retrying every [periodicDuration] × 3 while
/// the interrupting app still holds the audio; iOS defers session writes
/// while backgrounded and pays the debt on the foreground return.
final class MicAudioSessionController {
  /// Creates a session controller.
  ///
  /// [platform] defaults to [MicRecorderPlatform.instance] so tests can
  /// inject a fake.
  MicAudioSessionController({
    required MicAudioSessionConfig config,
    required MicLogSink log,
    required AppLifecycleTracker lifecycle,
    MicRecorderPlatform? platform,
  }) : _config = config,
       _log = log,
       _lifecycle = lifecycle,
       _platform = platform ?? MicRecorderPlatform.instance {
    // The controller needs `this` in its onListen hook, so it is created
    // here rather than in a field initializer: a new listener seeds the
    // current device snapshot.
    _devicesController = StreamController<Set<MicAudioDevice>>.broadcast(
      onListen: () => unawaited(_seedDevices()),
    );
  }

  /// The session-watch tick — the controller's time unit.
  ///
  /// Activation retries wait `periodicDuration * 5`; interruption-end
  /// recovery retries every `periodicDuration * 3`; an iOS app suspended
  /// during an unknown interruption waits `periodicDuration * 2` before
  /// re-activating.
  static const Duration periodicDuration = Duration(seconds: 1);

  /// Retry budget for background interruption-end recovery attempts.
  static const int _maxBackgroundInterruptionEndRetries = 15;

  /// Android safety net while backgrounded: the focus-regain notification
  /// can be dropped (or the interrupting app keeps focus after pausing).
  static const Duration _backgroundInterruptionWatchInterval = Duration(
    seconds: 5,
  );

  final MicAudioSessionConfig _config;

  final MicLogSink _log;

  final AppLifecycleTracker _lifecycle;

  final MicRecorderPlatform _platform;

  bool _isInitiated = false;

  final SeededStream<bool> _audioInterruption$ = SeededStream<bool>(false);

  final StreamController<MicAudioInterruption> _interruptionController =
      StreamController<MicAudioInterruption>.broadcast();

  final StreamController<MicMicrophoneLostEvent> _microphoneLostController =
      StreamController<MicMicrophoneLostEvent>.broadcast();

  late final StreamController<Set<MicAudioDevice>> _devicesController;

  StreamSubscription<MicSessionEvent>? _sessionEventsSubscription;

  bool _microphoneLostNotified = false;

  bool? _unknownInterruptionBegan;

  int _activationRetryCount = 0;

  /// Retry timer for the interruption-end recovery. Frozen while iOS
  /// suspends the app; resumes on thaw.
  Timer? _interruptionEndRetryTimer;

  /// Background retries used by the interruption-end recovery.
  ///
  /// iOS stands down after one background attempt (AVAudioSession race);
  /// Android's `setActive` is a plain focus request and safe to retry — it
  /// must be, because `isMusicActive()` stays true for seconds after the
  /// interrupting app pauses.
  int _interruptionEndRetryAttempts = 0;

  /// Android safety net while the app is backgrounded (see
  /// [_backgroundInterruptionWatchInterval]).
  Timer? _backgroundInterruptionWatchTimer;

  /// True while interruption-end recovery retries are in flight — used to
  /// log the failure once per episode instead of on every retry, and by the
  /// route ladder's background-write gate.
  bool _isRecoveringFromInterruption = false;

  DateTime? _lastInterruptionEventAt;

  /// The type of the interruption currently in effect (used to type the
  /// Android gain-end: a gain after a duck ends the duck).
  MicAudioInterruptionType? _activeInterruptionType;

  /// Whether [init] has completed successfully since the last
  /// [resetService].
  bool get isInitiated => _isInitiated;

  /// Whether an interruption is currently in effect.
  ///
  /// Sticky: an unknown interruption stays active until an end event or
  /// [markInterruptionResolved] clears it — even after the pause/duck end
  /// that follows an Android focus loss.
  bool get isInterruptionActive =>
      _audioInterruption$.value || _unknownInterruptionBegan == true;

  /// Whether interruption-end recovery retries are currently in flight.
  bool get isRecoveringFromInterruption => _isRecoveringFromInterruption;

  /// When the last interruption notification was processed (the route
  /// ladder's quiet-period gate).
  DateTime? get lastInterruptionEventAt => _lastInterruptionEventAt;

  /// The distinct interruption state (true while an interruption is in
  /// effect), seeded with the current value.
  ///
  /// This is the orchestrator's capture pause/resume trigger.
  Stream<bool> get onAudioInterruption => _audioInterruption$.stream;

  /// Every mapped interruption event (the rich stream, see
  /// [MicAudioInterruption]).
  Stream<MicAudioInterruption> get interruptionStream =>
      _interruptionController.stream;

  /// The microphone became unavailable while the app was backgrounded —
  /// surface it through the app's own notification channel.
  Stream<MicMicrophoneLostEvent> get onMicrophoneLost =>
      _microphoneLostController.stream;

  /// The device snapshot, seeded on listen and refreshed on device and
  /// route changes.
  Stream<Set<MicAudioDevice>> get devicesStream => _devicesController.stream;

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  /// Configures and activates the audio session.
  ///
  /// Idempotent while active. On failure the attempt surfaces as an
  /// interruption (so the orchestrator pauses capture), the session is torn
  /// back down, and the initialization retries after 5 × [periodicDuration].
  Future<void> init() async {
    if (_isInitiated) return;

    await _subscribeToSessionEvents();

    await _platform.configureAudioSession(_config);

    if (micIsIOS) {
      try {
        await _platform.setAllowHapticsAndSystemSoundsDuringRecording(true);
      } catch (e) {
        _log(MicLogLevel.warn, 'audioSessionHapticsFailed', {
          'error': e.toString(),
        });
      }
    }

    try {
      final isOtherPlaying = await isOtherAudioPlaying();

      if (micIsAndroid && isOtherPlaying) {
        throw StateError('other audio is playing');
      }

      if (micIsIOS) {
        // For unknown interruptions, wait a short grace period before
        // proceeding: activation can appear to succeed while the
        // microphone stays unavailable until the user returns to the app.
        if (_unknownInterruptionBegan == true) {
          await Future<void>.delayed(periodicDuration * 2);
        }

        final isAppNotActive =
            _lifecycle.currentState != AppLifecycleState.resumed;

        if (isAppNotActive &&
            (isOtherPlaying || _unknownInterruptionBegan == true)) {
          // The app replaced the original's local notification with this
          // event — the app decides how to surface it.
          if (!_microphoneLostNotified) {
            _microphoneLostController.add(
              const MicMicrophoneLostEvent(reason: 'unknown-interruption'),
            );

            _microphoneLostNotified = true;
          }

          throw StateError('microphone unavailable while backgrounded');
        }
      }

      final state = await _platform.setAudioSessionActive(true);

      _log(MicLogLevel.debug, 'audioSessionInitiated', {'active': state});

      if (!state) throw StateError('activation returned false');
    } catch (e) {
      _activationRetryCount++;

      _log(MicLogLevel.warn, 'audioSessionActivationFailed', {
        'attempt': _activationRetryCount,
        'platform': _platformName,
        'unknownInterruptionBegan': _unknownInterruptionBegan,
        'appLifecycleState': '${_lifecycle.currentState}',
        'error': e.toString(),
      });

      _emitInterruption(true);

      await resetService();

      await Future<void>.delayed(periodicDuration * 5);

      _log(MicLogLevel.debug, 'audioSessionInitiated', {'active': false});

      await init();

      return;
    }

    final activationRetries = _activationRetryCount;

    _activationRetryCount = 0;

    _microphoneLostNotified = false;

    _unknownInterruptionBegan = null;

    _emitInterruption(false);

    if (activationRetries > 0) {
      _log(MicLogLevel.debug, 'audioSessionInitiated', {
        'recoveredAfterAttempts': activationRetries,
      });
    }

    _isInitiated = true;
  }

  /// Deactivates the session and clears the initiated state.
  ///
  /// iOS never writes the session while the app is backgrounded — the
  /// system reclaims it on suspend — unless [isHardReset] is set, in which
  /// case the iOS audio stack is torn down through
  /// `microphoneInterrupted()` first.
  Future<void> resetService({bool isHardReset = false}) async {
    _interruptionEndRetryTimer?.cancel();
    _interruptionEndRetryTimer = null;

    _isRecoveringFromInterruption = false;

    _interruptionEndRetryAttempts = 0;

    _cancelBackgroundInterruptionWatch();

    final isBackgrounded = _lifecycle.currentState != AppLifecycleState.resumed;

    if (micIsAndroid || !isBackgrounded) {
      try {
        await _platform.setAudioSessionActive(false);
      } catch (e) {
        _log(MicLogLevel.warn, 'audioSessionDeactivationFailed', {
          'error': e.toString(),
        });
      }
    } else {
      _log(MicLogLevel.debug, 'audioSessionWriteDeferred', {
        'action': 'deactivation-skipped',
        'reason':
            'app backgrounded (no-background-session-writes rule '
            'for iOS)',
      });
    }

    if (micIsIOS && isHardReset) {
      try {
        await _platform.microphoneInterrupted();
      } catch (e) {
        _log(MicLogLevel.warn, 'microphoneInterruptedFailed', {
          'error': e.toString(),
        });
      }
    }

    _isInitiated = false;
  }

  /// Re-asserts the audio session (called right after a capture resume).
  ///
  /// iOS never writes the session while backgrounded; Android focus
  /// requests are always safe.
  Future<void> reassertActivation() async {
    if (micIsIOS && _lifecycle.currentState != AppLifecycleState.resumed) {
      return;
    }

    try {
      await _platform.setAudioSessionActive(true);
    } catch (e) {
      _log(MicLogLevel.warn, 'audioSessionReassertFailed', {
        'error': e.toString(),
      });
    }
  }

  /// Called after capture resumed: clears any stale interruption state so
  /// the error state cannot stick.
  void markInterruptionResolved() {
    _unknownInterruptionBegan = false;

    _microphoneLostNotified = false;

    _cancelBackgroundInterruptionWatch();

    _emitInterruption(false);
  }

  /// Releases the controller's resources.
  Future<void> dispose() async {
    _interruptionEndRetryTimer?.cancel();
    _interruptionEndRetryTimer = null;

    _cancelBackgroundInterruptionWatch();

    final subscription = _sessionEventsSubscription;

    _sessionEventsSubscription = null;

    if (subscription != null) {
      unawaited(subscription.cancel());
    }

    unawaited(_interruptionController.close());

    unawaited(_microphoneLostController.close());

    unawaited(_devicesController.close());

    _audioInterruption$.close();

    _isInitiated = false;
  }

  // ---------------------------------------------------------------------------
  // Queries
  // ---------------------------------------------------------------------------

  /// The current audio device snapshot (empty on failure).
  Future<Set<MicAudioDevice>> getDevices() async {
    try {
      return await _platform.getAudioDevices();
    } catch (e) {
      _log(MicLogLevel.error, 'getDevicesError', {'error': e.toString()});

      return <MicAudioDevice>{};
    }
  }

  /// Whether another app's audio is currently playing (music, or a call
  /// holding the microphone on Android).
  Future<bool> isOtherAudioPlaying() async {
    if (micIsAndroid) {
      if (await _platform.isMusicActive()) return true;

      return isAndroidMicHeldByCall();
    }

    return _platform.isOtherAudioPlaying();
  }

  /// Whether a call (POTS or VoIP) currently holds the microphone. Android
  /// only — always false elsewhere, without touching the platform.
  Future<bool> isAndroidMicHeldByCall() async {
    if (!micIsAndroid) return false;

    // MODE_IN_CALL / MODE_IN_COMMUNICATION — the raw codes the native
    // layer reports (AudioManager.getMode()).
    final mode = await _platform.getAudioMode();

    return mode == 2 || mode == 3;
  }

  // ---------------------------------------------------------------------------
  // Session events
  // ---------------------------------------------------------------------------

  Future<void> _subscribeToSessionEvents() async {
    if (_sessionEventsSubscription != null) return;

    _sessionEventsSubscription = _platform.sessionEvents().listen(
      (event) => unawaited(_onSessionEvent(event)),
      onError: (Object error, StackTrace _) {
        _log(MicLogLevel.warn, 'audioSessionEventError', {
          'error': error.toString(),
        });
      },
    );
  }

  Future<void> _onSessionEvent(MicSessionEvent event) async {
    try {
      switch (event) {
        case MicAndroidAudioFocusChanged():
          _onAndroidFocusChanged(event.focus);
        case MicAndroidDevicesChanged():
          await _refreshDevicesSnapshot();
        case MicIosInterruptionNotification():
          if (event.began && event.wasSuspended == true) {
            // The app itself was suspended — not a real interruption.
            return;
          }

          await _handleInterruption(
            MicAudioInterruption(
              begin: event.began,
              type: event.began
                  ? MicAudioInterruptionType.unknown
                  : (event.shouldResume
                        ? MicAudioInterruptionType.pause
                        : MicAudioInterruptionType.unknown),
            ),
          );
        case MicIosRouteChange():
          if (event.reason == MicIosRouteChangeReason.newDeviceAvailable ||
              event.reason == MicIosRouteChangeReason.oldDeviceUnavailable) {
            await _refreshDevicesSnapshot();
          }
      }
    } catch (e) {
      _log(MicLogLevel.error, 'audioSessionEventHandlerError', {
        'error': e.toString(),
      });
    }
  }

  void _onAndroidFocusChanged(int focus) {
    switch (focus) {
      case MicAndroidAudioFocus.loss:
        _handleInterruption(
          const MicAudioInterruption(
            begin: true,
            type: MicAudioInterruptionType.unknown,
          ),
        );
      case MicAndroidAudioFocus.lossTransient:
        _handleInterruption(
          const MicAudioInterruption(
            begin: true,
            type: MicAudioInterruptionType.pause,
          ),
        );
      case MicAndroidAudioFocus.lossTransientCanDuck:
        _handleInterruption(
          MicAudioInterruption(
            begin: true,
            type: _config.androidWillPauseWhenDucked
                ? MicAudioInterruptionType.pause
                : MicAudioInterruptionType.duck,
          ),
        );
      case MicAndroidAudioFocus.gain:
        _handleInterruption(
          MicAudioInterruption(
            begin: false,
            type: _activeInterruptionType == MicAudioInterruptionType.duck
                ? MicAudioInterruptionType.duck
                : MicAudioInterruptionType.pause,
          ),
        );
      default:
        _log(MicLogLevel.warn, 'unmappedFocusChange', {'focus': focus});
    }
  }

  /// The interruption state machine's shared entry point.
  Future<void> _handleInterruption(MicAudioInterruption interruption) async {
    _lastInterruptionEventAt = DateTime.now();

    _log(MicLogLevel.trace, 'microphoneInterruptionOccurred', {
      'type': interruption.type.name,
      'isBegin': interruption.begin,
    });

    _interruptionController.add(interruption);

    if (interruption.begin) {
      _activeInterruptionType = interruption.type;

      if (interruption.type == MicAudioInterruptionType.unknown) {
        _unknownInterruptionBegan = true;

        _scheduleBackgroundInterruptionWatch();

        if (micIsIOS &&
            _lifecycle.currentState != AppLifecycleState.resumed &&
            !_microphoneLostNotified) {
          _microphoneLostController.add(
            const MicMicrophoneLostEvent(reason: 'unknown-interruption'),
          );

          _microphoneLostNotified = true;

          _log(MicLogLevel.warn, 'microphoneLost', {
            'reason': 'unknown-interruption',
          });
        }
      }

      _emitInterruption(true);

      return;
    }

    // End events.
    if (interruption.type == MicAudioInterruptionType.unknown) {
      // An unknown end: the interruption is over but the session must be
      // re-asserted explicitly (the system does not hand it back by
      // itself).
      _unknownInterruptionBegan = false;

      _activeInterruptionType = null;

      await _recoverAfterInterruptionEnd();

      return;
    }

    // A pause/duck end while an unknown interruption was pending.
    if (_unknownInterruptionBegan == true) {
      _unknownInterruptionBegan = false;

      _activeInterruptionType = null;

      if (micIsIOS) {
        if (_lifecycle.currentState != AppLifecycleState.resumed) {
          // Backgrounded: never write the session — the debt is paid on the
          // foreground return (the recovery timer keeps trying).
          await _recoverAfterInterruptionEnd();
        } else {
          // A resumable end while an unknown interruption was pending: hard
          // reset the audio stack, then re-initialize.
          await resetService(isHardReset: true);

          await init();
        }

        return;
      }

      // Android: the system auto-regrants focus on gain; nothing to
      // re-assert.
      _emitInterruption(false);

      return;
    }

    _activeInterruptionType = null;

    _emitInterruption(false);
  }

  /// Re-activates the audio session after an interruption ended.
  ///
  /// Runs entirely in the background when the app holds the audio
  /// background mode — the user does not have to return to the app after a
  /// phone call / YouTube / Siri interruption. If re-activation fails (the
  /// interrupting app still holds audio focus) it retries every
  /// [periodicDuration] × 3; the timer freezes while iOS suspends the app
  /// and continues on thaw.
  Future<void> _recoverAfterInterruptionEnd() async {
    _interruptionEndRetryTimer?.cancel();
    _interruptionEndRetryTimer = null;

    try {
      if (micIsIOS && _lifecycle.currentState != AppLifecycleState.resumed) {
        _log(MicLogLevel.debug, 'audioSessionWriteDeferred', {
          'recovery': 'interruption-end-deferred',
          'appLifecycleState': '${_lifecycle.currentState}',
          'note': 'app backgrounded; the foreground return pays the debt',
        });

        throw StateError('iOS backgrounded; foreground return pays the debt');
      }

      final isOtherPlaying = await isOtherAudioPlaying();

      if (isOtherPlaying) throw StateError('other audio still playing');

      // Explicit activation BEFORE resuming the native recorder: the
      // engine's implicit activation can "succeed" while the microphone
      // stays unavailable.
      final state = await _platform.setAudioSessionActive(true);

      if (!state) throw StateError('activation returned false');

      _isRecoveringFromInterruption = false;

      _microphoneLostNotified = false;

      _unknownInterruptionBegan = false;

      _interruptionEndRetryAttempts = 0;

      _cancelBackgroundInterruptionWatch();

      _emitInterruption(false);
    } catch (e) {
      if (!_isRecoveringFromInterruption) {
        _isRecoveringFromInterruption = true;

        _log(MicLogLevel.warn, 'audioSessionActivationFailed', {
          'recovery': 'interruption-end-retry',
          'appLifecycleState': '${_lifecycle.currentState}',
          'error': e.toString(),
        });
      }

      final lifecycleState = _lifecycle.currentState;

      final isBackgrounded = lifecycleState != AppLifecycleState.resumed;

      final isResumed = lifecycleState == AppLifecycleState.resumed;

      if ((isBackgrounded && micIsAndroid) || (isResumed && micIsIOS)) {
        _interruptionEndRetryAttempts++;

        if (_interruptionEndRetryAttempts >
            _maxBackgroundInterruptionEndRetries) {
          _isRecoveringFromInterruption = false;

          _log(MicLogLevel.warn, 'audioSessionWriteDeferred', {
            'recovery': 'interruption-end-deferred',
            'appLifecycleState': '$lifecycleState',
            'error': e.toString(),
            'note':
                'background retry budget exhausted; the foreground '
                'return pays the debt',
          });

          return;
        }

        _log(MicLogLevel.debug, 'audioSessionWriteDeferred', {
          'recovery': 'interruption-end-retry',
          'appLifecycleState': '$lifecycleState',
          'attempt': _interruptionEndRetryAttempts,
          'error': e.toString(),
        });
      }

      _interruptionEndRetryTimer = Timer.periodic(
        periodicDuration * 3,
        (_) => unawaited(_recoverAfterInterruptionEnd()),
      );
    }
  }

  /// Android safety net while the app is backgrounded: polls whether the
  /// interrupting audio actually stopped and drives the recovery when it
  /// has.
  void _scheduleBackgroundInterruptionWatch() {
    if (!micIsAndroid) return;

    _cancelBackgroundInterruptionWatch();

    _backgroundInterruptionWatchTimer = Timer.periodic(
      _backgroundInterruptionWatchInterval,
      (_) => unawaited(() async {
        if (!isInterruptionActive) {
          _cancelBackgroundInterruptionWatch();

          return;
        }

        if (_isRecoveringFromInterruption ||
            _interruptionEndRetryTimer != null) {
          return;
        }

        try {
          if (!await isOtherAudioPlaying()) {
            await _recoverAfterInterruptionEnd();
          }
        } catch (_) {
          // The watch must never throw into the timer zone.
        }
      }()),
    );
  }

  void _cancelBackgroundInterruptionWatch() {
    _backgroundInterruptionWatchTimer?.cancel();
    _backgroundInterruptionWatchTimer = null;
  }

  void _emitInterruption(bool value) {
    // Distinct by construction (the original used a distinct() stream):
    // a repeated value adds nothing and would only churn listeners.
    if (_audioInterruption$.value == value) return;

    _audioInterruption$.add(value);
  }

  // ---------------------------------------------------------------------------
  // Devices
  // ---------------------------------------------------------------------------

  /// Delivers the current device snapshot to a fresh listener (the
  /// devicesStream's onListen hook).
  Future<void> _seedDevices() async {
    try {
      _devicesController.add(await getDevices());
    } catch (_) {
      // Seeding must never disturb a new listener.
    }
  }

  Future<void> _refreshDevicesSnapshot() async {
    if (!_devicesController.hasListener) return;

    try {
      final devices = await getDevices();

      if (_devicesController.hasListener) {
        _devicesController.add(devices);
      }
    } catch (e) {
      _log(MicLogLevel.error, 'devicesSnapshotError', {'error': e.toString()});
    }
  }

  String get _platformName => micIsAndroid
      ? 'android'
      : micIsIOS
      ? 'ios'
      : 'other';
}
