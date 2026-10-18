/// A live loudness reading, in dBFS (decibels relative to full scale:
/// `0.0` is the loudest 16-bit PCM can be, `-120.0` is digital silence).
///
/// Emitted on [MicRecorder.onAmplitude] while audio flows; see
/// [MicRecorder.amplitude] for the latest value.
final class MicAmplitude {
  /// Creates a reading. Values are clamped to the range -120.0 to 0.0;
  /// total silence reads as -120.0.
  const MicAmplitude({
    required this.currentDbfs,
    required this.averageDbfs,
    required this.peakDbfs,
  }) : assert(currentDbfs <= 0 && currentDbfs >= -120.0),
       assert(averageDbfs <= 0 && averageDbfs >= -120.0),
       assert(peakDbfs <= 0 && peakDbfs >= -120.0);

  /// The floor reported for digital silence.
  static const double silenceDbfs = -120.0;

  /// The loudness of the most recent chunk.
  final double currentDbfs;

  /// The mean loudness since the recording started.
  final double averageDbfs;

  /// The loudest reading since the recording started.
  final double peakDbfs;

  /// Whether no sound above the silence floor has been captured yet.
  bool get isSilent => currentDbfs <= silenceDbfs;

  @override
  String toString() =>
      'MicAmplitude(current: ${currentDbfs.toStringAsFixed(1)} dBFS, '
      'average: ${averageDbfs.toStringAsFixed(1)} dBFS, '
      'peak: ${peakDbfs.toStringAsFixed(1)} dBFS)';
}
