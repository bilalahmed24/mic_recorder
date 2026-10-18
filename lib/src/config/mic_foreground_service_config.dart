/// The Android microphone foreground-service notification configuration.
///
/// Android requires ongoing background microphone capture to run as a
/// microphone-type foreground service with a user-visible notification
/// (see the README's "Android foreground service" section for the full
/// rationale). This configuration is passed through `MicRecorderConfig` —
/// there is deliberately NO separate `setForegroundNotification` method:
/// the notification's lifecycle is the recording session's lifecycle.
final class MicForegroundServiceConfig {
  /// Creates a foreground-service configuration.
  const MicForegroundServiceConfig({
    this.enabled = true,
    this.channelName = 'Recording',
    this.channelDescription = 'Microphone recording status',
    this.icon,
    this.titleWhenRecording = 'Recording conversation',
    this.titleWhenListening = 'Listening for voice command',
    this.titleWhenPaused = 'Recording paused',
    this.titleWhenInterrupted = 'Recording interrupted',
  });

  /// Whether the foreground service is used at all. Disabling it keeps the
  /// recording alive only while the app is foregrounded.
  final bool enabled;

  /// The notification channel's visible name.
  final String channelName;

  /// The notification channel's description.
  final String channelDescription;

  /// A drawable resource name for the notification's small icon (for
  /// example `ic_stat_mic`). When null or unresolvable, the plugin's bundled
  /// microphone icon is used; a missing app icon falls back to a system one
  /// — the notification never crashes on a bad name.
  final String? icon;

  /// Notification title while a conversation recording is running.
  final String titleWhenRecording;

  /// Notification title while a voice-command listening is running.
  final String titleWhenListening;

  /// Notification title while the recording is paused.
  final String titleWhenPaused;

  /// Notification title while the recording is interrupted (for example a
  /// call is in progress).
  final String titleWhenInterrupted;

  @override
  String toString() =>
      'MicForegroundServiceConfig(enabled: $enabled, '
      'channelName: $channelName, channelDescription: $channelDescription, '
      'icon: $icon, titleWhenRecording: $titleWhenRecording, '
      'titleWhenListening: $titleWhenListening, '
      'titleWhenPaused: $titleWhenPaused, '
      'titleWhenInterrupted: $titleWhenInterrupted)';
}
