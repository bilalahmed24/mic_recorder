/// Why the audio session was interrupted (or resumed).
///
/// The vocabulary mirrors the mapping the plugin applies to the platforms'
/// native interruption notifications:
///
/// * Android focus loss → [unknown] begin; focus loss-transient → [pause]
///   begin; can-duck → [pause] or [duck] begin depending on
///   `MicAudioSessionConfig.androidWillPauseWhenDucked`; focus gain → the
///   matching end ([pause], or [duck] while a duck is active).
/// * iOS interruption began (not suspended) → [unknown] begin; ended with
///   `shouldResume` → [pause] end; ended without it → [unknown] end.
enum MicAudioInterruptionType {
  /// The cause is not identified (Android focus loss, iOS interruption
  /// began, iOS ended without `shouldResume`).
  unknown,

  /// The recording should pause (or is safe to resume).
  pause,

  /// Another app is ducking this app's audio (Android can-duck with
  /// `androidWillPauseWhenDucked` disabled).
  duck,
}

/// An interruption notification, already mapped to the shared vocabulary.
final class MicAudioInterruption {
  /// Creates an interruption event.
  const MicAudioInterruption({required this.begin, required this.type});

  /// Whether the interruption is starting (`true`) or over (`false`).
  final bool begin;

  /// The classified cause of the interruption.
  final MicAudioInterruptionType type;

  @override
  String toString() => 'MicAudioInterruption(begin: $begin, type: $type)';
}
