/// File container formats for [MicRecorder.setOutputFile].
///
/// Both formats capture the same raw PCM the [MicRecorder.audioStream]
/// delivers — they only differ in what lands on disk.
enum MicRecordingFileFormat {
  /// Headerless 16-bit little-endian mono PCM — byte-for-byte the stream.
  pcm16,

  /// A standards-compliant RIFF/WAVE container (44-byte canonical header,
  /// patched sizes) around the same 16-bit PCM. Files are directly
  /// playable and loadable by [MicRecorder.extractAmplitudes].
  wav;

  /// The wire name used on the platform channel and log payloads.
  String get wireName => name;
}
