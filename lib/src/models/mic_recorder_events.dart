/// What a recording episode is optimized for.
///
/// The mode decides how silence is interpreted and how much audio is
/// retained in RAM — it never changes the wire format (16-bit little-endian
/// mono PCM either way).
enum MicRecordingMode {
  /// A conversation is being recorded: silence detection is armed (a
  /// sustained quiet window surfaces once per completed five-minute span)
  /// and silence recovery may restart the capture stack.
  conversation,

  /// The recorder listens for a wake-word style voice command: silence is
  /// expected (no silence alarms, no silence recovery) and only the most
  /// recent audio tail is retained.
  voiceCommand,
}

/// The effective microphone source, in the vocabulary shared by the input
/// priority ladder and the source-switch events.
enum MicAudioSourceKind {
  /// A USB or wired external microphone (rung 1 of the ladder).
  usbWired('usb-wired'),

  /// A Bluetooth microphone (rung 2 of the ladder).
  bluetooth('bluetooth'),

  /// The device's own microphone (rung 3 of the ladder).
  defaultMicrophone('default-microphone'),

  /// Whatever the OS picked — no ladder decision applies.
  systemDefault('system-default');

  const MicAudioSourceKind(this.wireName);

  /// The stable wire identifier of the kind (used in logs and to compare
  /// consecutive routing decisions).
  final String wireName;
}

/// The effective microphone source changed.
///
/// Emitted on the recording-start resolution, on every ladder decision that
/// changes the effective source and — while the priority policy is disabled
/// — whenever the OS re-routes on its own.
final class MicAudioSourceSwitchedEvent {
  /// Creates a source-switched event.
  const MicAudioSourceSwitchedEvent({
    required this.sourceKind,
    this.previousSourceKind,
    this.sourceName,
    required this.reason,
    required this.switchingEnabled,
  });

  /// The source now in effect.
  final MicAudioSourceKind sourceKind;

  /// The source that was in effect before (null on the first resolution of
  /// a recording episode).
  final MicAudioSourceKind? previousSourceKind;

  /// A human-readable name of the chosen input, when one is known.
  final String? sourceName;

  /// Why the source was (re-)evaluated: `prepare`, `start`,
  /// `device-change`, `toggle-off`, `settle-reassert`,
  /// `foreground-resume`, `deferred-repay`, ...
  final String reason;

  /// Whether the Dart-side priority ladder was steering when the change
  /// happened (false means the OS re-routed on its own).
  final bool switchingEnabled;

  @override
  String toString() =>
      'MicAudioSourceSwitchedEvent(sourceKind: $sourceKind, '
      'previousSourceKind: $previousSourceKind, sourceName: $sourceName, '
      'reason: $reason, switchingEnabled: $switchingEnabled)';
}

/// A five-minute window of continuous conversational silence completed.
///
/// Quiet-but-flowing audio tiles these events back-to-back
/// (T0, T0+5m, T0+10m, ...); recorder transitions reset the window because
/// a paused recorder is *missing* audio, not silent.
final class MicConversationSilenceEvent {
  /// Creates a conversation-silence event.
  const MicConversationSilenceEvent({
    required this.startedAtUtc,
    required this.duration,
    required this.lastRms,
    required this.silenceThreshold,
    required this.bytesCapturedSinceStart,
    required this.buffersCapturedSinceStart,
    required this.silenceRecoveryAttempts,
    this.routeState,
  });

  /// UTC instant the completed silence window began.
  final DateTime startedAtUtc;

  /// How long the completed window lasted.
  final Duration duration;

  /// RMS of the most recent quiet buffer.
  final double lastRms;

  /// RMS level at or below which audio counts as silence.
  final double silenceThreshold;

  /// Bytes captured since the recording started.
  final int bytesCapturedSinceStart;

  /// Buffers captured since the recording started.
  final int buffersCapturedSinceStart;

  /// Silence-recovery attempts made so far this episode.
  final int silenceRecoveryAttempts;

  /// Native route diagnostics at emission time (Android only; null
  /// elsewhere and on failure).
  final Map<String, Object?>? routeState;

  @override
  String toString() =>
      'MicConversationSilenceEvent(startedAtUtc: $startedAtUtc, '
      'duration: $duration, lastRms: $lastRms, '
      'silenceThreshold: $silenceThreshold, '
      'bytesCapturedSinceStart: $bytesCapturedSinceStart, '
      'buffersCapturedSinceStart: $buffersCapturedSinceStart, '
      'silenceRecoveryAttempts: $silenceRecoveryAttempts, '
      'routeState: $routeState)';
}

/// The microphone became unavailable while the app was backgrounded and
/// needs the user to return to the app.
///
/// Surface it through the app's own notification channel — the plugin
/// deliberately owns no user-facing notification for this (the Android
/// foreground-service notification it does own is configured separately).
final class MicMicrophoneLostEvent {
  /// Creates a microphone-lost event.
  const MicMicrophoneLostEvent({required this.reason, this.occurredAtUtc});

  /// Why the microphone was lost, for example `unknown-interruption`.
  final String reason;

  /// When the loss was detected (null when unknown).
  final DateTime? occurredAtUtc;

  @override
  String toString() =>
      'MicMicrophoneLostEvent(reason: $reason, occurredAtUtc: '
      '$occurredAtUtc)';
}
