import 'package:flutter/foundation.dart';

/// Severity of a log entry produced by the recorder.
///
/// [trace] marks high-volume diagnostics, [debug] state transitions and
/// notable events, [warn] recoverable degradation, and [error]/[fatal]
/// failures.
enum MicLogLevel {
  /// High-volume diagnostic tracing.
  trace,

  /// State transitions and notable events.
  debug,

  /// Recoverable degradation; a retry or fallback is armed.
  warn,

  /// An operation failed.
  error,

  /// An unrecoverable failure.
  fatal,
}

/// Receives every diagnostic entry the recorder produces.
///
/// [level] classifies the entry, [message] is a stable identifier of the
/// log site (for example `audioSessionActivationFailed`) and the optional
/// [data] map carries structured context such as metrics, states or error
/// details.
typedef MicLogSink =
    void Function(
      MicLogLevel level,
      String message, [
      Map<String, Object?>? data,
    ]);

/// The default log sink, used when `MicRecorderConfig.log` is null.
///
/// Debug builds render every entry as a single tagged line on
/// [debugPrint]; release builds stay silent — install a custom sink
/// through `MicRecorderConfig.log` to ship logs anywhere else.
void defaultMicLog(
  MicLogLevel level,
  String message, [
  Map<String, Object?>? data,
]) {
  if (!kDebugMode) return;

  final line = StringBuffer('mic_recorder[${level.name}] $message');

  if (data != null && data.isNotEmpty) {
    line.write(' ');
    line.write(data);
  }

  debugPrint(line.toString());
}
