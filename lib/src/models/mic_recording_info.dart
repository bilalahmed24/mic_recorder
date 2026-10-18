import 'mic_audio_encoder.dart';
import 'mic_recording_file_format.dart';

/// Why a recording episode ended.
enum MicRecordingStopReason {
  /// [MicRecorder.stop] (or [MicRecorder.cancel]) was called.
  manual,

  /// The episode reached [MicRecorderConfig.maxDuration] and was
  /// stopped automatically.
  maxDurationReached,
}

/// The result [MicRecorder.stop] returns for a completed episode.
///
/// `duration` counts only the spans where capture was actually running —
/// paused gaps are excluded.
final class MicRecordingInfo {
  /// Creates a recording result.
  const MicRecordingInfo({
    required this.startedAtUtc,
    required this.duration,
    required this.sizeBytes,
    required this.sampleRate,
    required this.bitDepth,
    required this.channels,
    this.stopReason = MicRecordingStopReason.manual,
    this.path,
    this.encoder,
    this.fileFormat,
  });

  /// When the episode started (UTC).
  final DateTime startedAtUtc;

  /// How long capture was live (paused spans excluded).
  final Duration duration;

  /// Bytes written to the output file; when no file was armed, the bytes
  /// captured on the stream instead.
  final int sizeBytes;

  /// The capture sample rate in Hz.
  final int sampleRate;

  /// The capture bit depth (always 16).
  final int bitDepth;

  /// The channel count (always 1 — mono).
  final int channels;

  /// Why the episode ended.
  final MicRecordingStopReason stopReason;

  /// The output file this episode wrote (the encoded output when armed,
  /// else the Dart-written file), or null when recording to stream only.
  final String? path;

  /// The native encoder that produced [path], or null when the file was
  /// written by the Dart writer (see [fileFormat]) or no file was armed.
  final MicAudioEncoder? encoder;

  /// The format of a Dart-written [path] (see [MicRecorder.setOutputFile]),
  /// or null for encoded output / no file.
  final MicRecordingFileFormat? fileFormat;

  @override
  String toString() =>
      'MicRecordingInfo(startedAtUtc: $startedAtUtc, '
      'duration: $duration, sizeBytes: $sizeBytes, path: $path, '
      'encoder: $encoder, fileFormat: $fileFormat, '
      'stopReason: $stopReason, '
      'sampleRate: $sampleRate, bitDepth: $bitDepth, channels: $channels)';
}
