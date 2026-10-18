/// Production-grade microphone recording for Flutter.
///
/// Raw 16-bit little-endian mono PCM capture with audio session handling,
/// interruption recovery and input device switching on Android and iOS —
/// plus native encoded file output (AAC/Opus/FLAC/AMR/Apple Lossless), a
/// built-in WAV container writer, live dBFS metering, permission
/// management and Android capture effects, with the entire audio-session
/// layer implemented natively inside the plugin (Android `AudioManager`
/// in Java, iOS `AVAudioSession` in Swift).
///
/// ```dart
/// final recorder = MicRecorder.instance;
///
/// recorder.initialize(
///   MicRecorderConfig(
///     androidForegroundService: MicForegroundServiceConfig(
///       titleWhenRecording: 'Recording conversation',
///     ),
///   ),
/// );
///
/// recorder.audioStream.listen((chunk) => print('${chunk.length} bytes'));
///
/// await recorder.requestMicrophonePermission();
///
/// await recorder.start();
/// ```
///
/// The library exports the recorder facade, its configuration types, the
/// models and (for advanced use) the controllers it is built from.
library;

export 'src/config/mic_audio_session_config.dart';
export 'src/config/mic_foreground_service_config.dart';
export 'src/config/mic_recorder_config.dart';
export 'src/internal/mic_logger.dart';
export 'src/lifecycle/app_lifecycle_tracker.dart';
export 'src/mic_recorder.dart';
export 'src/models/mic_amplitude.dart';
export 'src/models/mic_audio_device.dart';
export 'src/models/mic_audio_encoder.dart';
export 'src/models/mic_audio_interruption.dart';
export 'src/models/mic_recorder_events.dart';
export 'src/models/mic_recording_info.dart';
export 'src/models/mic_recorder_state.dart';
export 'src/models/mic_recording_file_format.dart';
export 'src/models/mic_session_events.dart';
export 'src/platform/mic_recorder_platform.dart';
export 'src/route/mic_route_controller.dart';
export 'src/session/mic_audio_session_controller.dart';

import 'src/platform/method_channel_mic_recorder.dart';
import 'src/platform/mic_recorder_platform.dart';

/// Installs the method-channel platform the first time this library is
/// imported — the production entry point's wiring.
///
/// `MicRecorderPlatform.instance` starts as an inert stub (so `src/`-level
/// unit tests can construct controllers without natives); importing the
/// public library swaps in the real implementation. Tests that import the
/// `src/` files directly never trigger this binding and stay in control of
/// the platform instance.
// ignore: unused_element
final _MicRecorderPlatformBinding _platformBinding =
    _MicRecorderPlatformBinding();

final class _MicRecorderPlatformBinding {
  _MicRecorderPlatformBinding() {
    if (MicRecorderPlatform.instance is! MethodChannelMicRecorder) {
      MicRecorderPlatform.instance = MethodChannelMicRecorder();
    }
  }
}
