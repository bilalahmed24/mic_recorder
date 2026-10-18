/// The recording state of a recorder episode.
///
/// * [recording] — capture is running and audio is flowing.
/// * [paused] — capture is torn down but the episode continues (a manual
///   pause, or one caused by an interruption waiting to resume).
/// * [stopped] — no episode; the recorder is idle.
/// * [error] — the last start attempt failed.
enum MicRecorderState {
  /// Capture is running.
  recording,

  /// The episode continues, but capture is currently torn down.
  paused,

  /// No recording episode is running.
  stopped,

  /// The last start attempt failed.
  error;

  /// Whether an episode is in progress (recording or paused).
  bool get isActive => this == MicRecorderState.recording || this == paused;

  /// Whether capture is currently running.
  bool get isRecording => this == MicRecorderState.recording;

  /// Whether the episode is paused.
  bool get isPaused => this == paused;
}
