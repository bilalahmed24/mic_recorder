/// Encoded output formats [MicRecorder.setEncodedOutput] can record to.
///
/// Encoders run natively (Android: `MediaCodec` + `MediaMuxer`; iOS:
/// `AVAudioFile`) on the same capture pipeline as the raw PCM stream —
/// encoded files, the Dart file writer ([MicRecorder.setOutputFile]) and
/// the RAM buffer can all run from one recording.
///
/// | Encoder         | Container | Android | iOS | Notes                       |
/// |-----------------|-----------|---------|-----|-----------------------------|
/// | [aacLc]         | `.m4a`    | ✅      | ✅  | The portable default.       |
/// | [appleLossless] | `.m4a`    | ❌      | ✅  | iOS-only lossless.          |
/// | [opus]          | `.ogg`    | ✅      | ❌  | Android 10 (API 29)+.       |
/// | [flac]          | `.flac`   | ✅      | ❌  | Lossless.                   |
/// | [amrNb]         | `.amr`    | ✅      | ❌  | Requires 8 kHz capture.     |
/// | [amrWb]         | `.amr`    | ✅      | ❌  | Requires 16 kHz capture.    |
enum MicAudioEncoder {
  /// AAC-LC in an MPEG-4 (`.m4a`) container — plays everywhere.
  ///
  /// The bit rate (default or explicit) is clamped to `6 × sampleRate`
  /// bits/second — the codec's per-frame ceiling (6144 bits per
  /// 1024-sample frame); the default 128 kbps therefore materializes as
  /// 96 kbps at the default 16 kHz capture.
  aacLc('aacLc', '.m4a', 128000, null, android: true, ios: true),

  /// Apple Lossless in an MPEG-4 (`.m4a`) container. iOS only.
  appleLossless('appleLossless', '.m4a', null, null, android: false, ios: true),

  /// Opus in an Ogg (`.ogg`) container. Android only (Android 10+).
  opus('opus', '.ogg', 24000, null, android: true, ios: false),

  /// Free Lossless Audio Codec (`.flac`). Android only.
  flac('flac', '.flac', null, null, android: true, ios: false),

  /// AMR narrowband (`.amr`). Android only; the AMR-NB codec requires
  /// 8 kHz capture — arm it only with `MicRecorderConfig(sampleRate: 8000)`.
  amrNb('amrNb', '.amr', 12200, 8000, android: true, ios: false),

  /// AMR wideband (`.amr`). Android only; the AMR-WB codec requires
  /// 16 kHz capture — arm it only with `MicRecorderConfig(sampleRate: 16000)`.
  amrWb('amrWb', '.amr', 23850, 16000, android: true, ios: false);

  const MicAudioEncoder(
    this.wireName,
    this.fileExtension,
    this.defaultBitRate,
    this.requiredSampleRate, {
    required this.android,
    required this.ios,
  });

  /// The wire name used on the platform channel.
  final String wireName;

  /// The conventional file extension for this encoder's container.
  final String fileExtension;

  /// The default bit rate in bits/second, or null for lossless encoders
  /// (where the bit rate is a byproduct of the content).
  final int? defaultBitRate;

  /// The capture sample rate this encoder is restricted to, or null when
  /// any supported rate works.
  final int? requiredSampleRate;

  /// Whether this encoder is available on Android.
  final bool android;

  /// Whether this encoder is available on iOS.
  final bool ios;

  /// Whether this encoder is available on the given platform
  /// (pass the recorder's platform: `android: MicRecorderPlatform-host`).
  bool isSupportedOn({required bool android, required bool ios}) =>
      android ? this.android : this.ios;

  @override
  String toString() => 'MicAudioEncoder.$name ($wireName)';
}
