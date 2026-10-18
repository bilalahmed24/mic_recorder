import 'dart:io';
import 'dart:typed_data';

/// The facade's file sink: appends captured PCM, then finalizes the file
/// (flush — and for WAV, patch the RIFF sizes) on close.
abstract interface class MicOutputFileWriter {
  /// Appends a PCM chunk.
  void add(List<int> pcm);

  /// Flushes and finalizes (the file is kept).
  Future<void> close();

  /// Flushes and deletes the file (a cancelled recording).
  Future<void> discard();
}

/// Raw headerless PCM — byte-for-byte what the stream delivers.
final class MicRawPcmFileWriter implements MicOutputFileWriter {
  MicRawPcmFileWriter._(this._sink, this.file);

  /// Opens [file] for appending (the documented pcm16 contract: with
  /// `deleteExistingFile: false` an existing file is appended to; the
  /// file is created when it does not exist).
  static Future<MicRawPcmFileWriter> create(
    File file, {
    required int sampleRate,
    required int channels,
    required int bitDepth,
  }) async {
    final sink = file.openWrite(mode: FileMode.writeOnlyAppend);

    return MicRawPcmFileWriter._(sink, file);
  }

  final IOSink _sink;
  final File file;

  @override
  void add(List<int> pcm) => _sink.add(pcm);

  @override
  Future<void> close() => _sink.close();

  @override
  Future<void> discard() async {
    await _sink.close();

    try {
      await file.delete();
    } on FileSystemException {
      // Already gone — a discard must never fail the stop flow.
    }
  }
}

/// A RIFF/WAVE container around the captured 16-bit PCM.
///
/// The canonical 44-byte header is written up-front with zero sizes and
/// patched to the true RIFF/data sizes on [close] — so even a hard
/// process death leaves a playable (if mis-sized) file on disk.
final class MicWavFileWriter implements MicOutputFileWriter {
  MicWavFileWriter._(this._sink, this.file, this._format);

  /// Creates (and truncates) [path] as a RIFF/WAVE file.
  static Future<MicWavFileWriter> create(
    File file, {
    required int sampleRate,
    required int channels,
    required int bitDepth,
  }) async {
    final sink = file.openWrite(mode: FileMode.writeOnly);

    final writer = MicWavFileWriter._(
      sink,
      file,
      _WavFormat(
        sampleRate: sampleRate,
        channels: channels,
        bitDepth: bitDepth,
      ),
    );

    sink.add(writer._headerBytes(dataSize: 0));

    return writer;
  }

  final IOSink _sink;
  final File file;
  final _WavFormat _format;

  int _dataBytes = 0;

  /// Bytes of PCM payload written (header excluded).
  int get dataBytes => _dataBytes;

  @override
  void add(List<int> pcm) {
    _sink.add(pcm);

    _dataBytes += pcm.length;
  }

  @override
  Future<void> close() async {
    await _sink.flush();
    await _sink.close();

    await _patchSizes();
  }

  @override
  Future<void> discard() async {
    await _sink.close();

    try {
      await file.delete();
    } on FileSystemException {
      // Already gone — a discard must never fail the stop flow.
    }
  }

  Future<void> _patchSizes() async {
    final riffSize = 36 + _dataBytes;

    final handle = await file.open(mode: FileMode.writeOnlyAppend);

    try {
      await handle.setPosition(4);
      await handle.writeFrom(_uint32(riffSize));
      await handle.setPosition(40);
      await handle.writeFrom(_uint32(_dataBytes));
    } finally {
      await handle.close();
    }
  }

  Uint8List _headerBytes({required int dataSize}) {
    final bytes = Uint8List(44);
    final view = ByteData.view(bytes.buffer);

    void ascii(int offset, String value) {
      for (var i = 0; i < value.length; i++) {
        bytes[offset + i] = value.codeUnitAt(i);
      }
    }

    ascii(0, 'RIFF');
    view.setUint32(4, 36 + dataSize, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    view.setUint32(16, 16, Endian.little); // fmt chunk size
    view.setUint16(20, 1, Endian.little); // PCM
    view.setUint16(22, _format.channels, Endian.little);
    view.setUint32(24, _format.sampleRate, Endian.little);
    view.setUint32(
      28,
      _format.sampleRate * _format.channels * _format.bitDepth ~/ 8,
      Endian.little,
    );
    view.setUint16(32, _format.channels * _format.bitDepth ~/ 8, Endian.little);
    view.setUint16(34, _format.bitDepth, Endian.little);
    ascii(36, 'data');
    view.setUint32(40, dataSize, Endian.little);

    return bytes;
  }

  static Uint8List _uint32(int value) {
    final bytes = Uint8List(4);

    ByteData.view(bytes.buffer).setUint32(0, value, Endian.little);

    return bytes;
  }
}

final class _WavFormat {
  const _WavFormat({
    required this.sampleRate,
    required this.channels,
    required this.bitDepth,
  });

  final int sampleRate;
  final int channels;
  final int bitDepth;
}
