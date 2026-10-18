/// Typed decodings of the native `session_events` EventChannel payloads.
///
/// The channel carries untyped maps; [MicSessionEvent] is their typed form
/// consumed by the audio-session controller. The families split cleanly by
/// platform: Android emits focus changes and device-list changes, iOS
/// emits interruption notifications and route changes.
library;

import 'mic_audio_device.dart';

/// Android `AudioManager` audio-focus change codes.
///
/// The values are the raw codes the native layer forwards; they are `int`
/// constants (not an enum) so unmapped codes can be logged verbatim.
abstract final class MicAndroidAudioFocus {
  /// `AUDIOFOCUS_GAIN` — focus was (re-)granted.
  static const int gain = 1;

  /// `AUDIOFOCUS_LOSS` — focus was lost (potentially long-term).
  static const int loss = -1;

  /// `AUDIOFOCUS_LOSS_TRANSIENT` — focus was lost temporarily.
  static const int lossTransient = -2;

  /// `AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK` — a duckable temporary loss.
  static const int lossTransientCanDuck = -3;
}

/// `AVAudioSession.RouteChangeReason` raw values.
///
/// Kept as `int` constants (not an enum) so unmapped reasons decode to `0`
/// (`unknown`) without losing information in logs.
abstract final class MicIosRouteChangeReason {
  /// The reason is not known.
  static const int unknown = 0;

  /// A new device became available.
  static const int newDeviceAvailable = 1;

  /// The old device is no longer available.
  static const int oldDeviceUnavailable = 2;

  /// The session category changed.
  static const int categoryChange = 3;

  /// The route was overridden.
  static const int override = 4;

  /// The device woke from sleep.
  static const int wakeFromSleep = 6;

  /// The route's configuration changed.
  static const int routeConfigurationChange = 7;
}

/// Base class of the typed session-event family.
sealed class MicSessionEvent {
  /// Creates a session event.
  const MicSessionEvent();
}

/// The Android audio focus changed.
final class MicAndroidAudioFocusChanged extends MicSessionEvent {
  /// Creates a focus-change event.
  const MicAndroidAudioFocusChanged({required this.focus});

  /// The raw `AudioManager` focus code (see [MicAndroidAudioFocus]).
  final int focus;

  @override
  String toString() => 'MicAndroidAudioFocusChanged(focus: $focus)';
}

/// The Android device list changed.
final class MicAndroidDevicesChanged extends MicSessionEvent {
  /// Creates a device-list change event.
  const MicAndroidDevicesChanged({required this.added, required this.removed});

  /// Devices that appeared.
  final List<MicAudioDevice> added;

  /// Devices that disappeared.
  final List<MicAudioDevice> removed;

  @override
  String toString() =>
      'MicAndroidDevicesChanged(added: $added, removed: $removed)';
}

/// An iOS interruption notification.
final class MicIosInterruptionNotification extends MicSessionEvent {
  /// Creates an interruption notification.
  const MicIosInterruptionNotification({
    required this.began,
    required this.shouldResume,
    this.wasSuspended,
  });

  /// Whether the interruption began (`true`) or ended (`false`).
  final bool began;

  /// Whether iOS hinted the app may resume its audio.
  final bool shouldResume;

  /// Whether the interruption began because the app itself was suspended
  /// (null when the OS did not report it). Began events with this flag are
  /// dropped by the session controller — they are not real interruptions.
  final bool? wasSuspended;

  @override
  String toString() =>
      'MicIosInterruptionNotification(began: $began, '
      'shouldResume: $shouldResume, wasSuspended: $wasSuspended)';
}

/// An iOS route change.
final class MicIosRouteChange extends MicSessionEvent {
  /// Creates a route-change event.
  const MicIosRouteChange({required this.reason});

  /// The raw `AVAudioSession.RouteChangeReason` value (see
  /// [MicIosRouteChangeReason]).
  final int reason;

  @override
  String toString() => 'MicIosRouteChange(reason: $reason)';
}
