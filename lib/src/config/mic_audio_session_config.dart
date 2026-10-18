/// The audio-session configuration applied at initialization.
///
/// Captures the recording-relevant slice of the platforms' audio-session
/// settings — the iOS category options and the Android audio-focus
/// request flags — applied natively by the plugin.
final class MicAudioSessionConfig {
  /// Creates an audio-session configuration.
  const MicAudioSessionConfig({
    this.allowBluetooth = true,
    this.defaultToSpeaker = true,
    this.notifyOthersOnDeactivation = true,
    this.androidWillPauseWhenDucked = true,
  });

  /// Whether Bluetooth HFP input may be used (iOS `allowBluetooth`, Android
  /// enables the SCO gate).
  final bool allowBluetooth;

  /// Whether audio defaults to the device speaker while recording (iOS
  /// `defaultToSpeaker`; ignored on Android).
  final bool defaultToSpeaker;

  /// Whether other apps are notified when this session deactivates (iOS
  /// `notifyOthersOnDeactivation`).
  final bool notifyOthersOnDeactivation;

  /// Whether a duckable focus loss pauses this recorder (`true`) or lets it
  /// keep recording at a ducked level (`false`). Android's
  /// `setWillPauseWhenDucked` flag.
  final bool androidWillPauseWhenDucked;

  @override
  String toString() =>
      'MicAudioSessionConfig(allowBluetooth: $allowBluetooth, '
      'defaultToSpeaker: $defaultToSpeaker, '
      'notifyOthersOnDeactivation: $notifyOthersOnDeactivation, '
      'androidWillPauseWhenDucked: $androidWillPauseWhenDucked)';
}
