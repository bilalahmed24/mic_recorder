# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-10-18

Initial release.

### Added

- **Raw PCM capture** — 16-bit little-endian mono PCM on `MicRecorder.audioStream`
  at a configurable sample rate (default 16 kHz), on Android (Java
  `AudioRecord` engine) and iOS (Swift `AVAudioEngine` + `AVAudioConverter`).
- **In-plugin audio-session handling** — implemented natively in Java and
  Swift directly against the platform audio APIs (no Dart dependency):
  - Android: voice-communication audio focus request/abandon with
    auto-abandon on loss, focus-change events, `AudioDeviceCallback`
    device-diff events, `isMusicActive`, audio mode, input device listing.
  - iOS: `AVAudioSession` `playAndRecord`/`default` category with
    `.allowBluetoothHFP` + `.defaultToSpeaker`, activation with
    `.notifyOthersOnDeactivation`, `isOtherAudioPlaying`, the
    haptics-and-system-sounds option, and input/route introspection
    (`getAvailableInputs` / `getCurrentRoute` / `setPreferredInput`).
- **Interruption handling & recovery** — audio focus loss (Android) and
  AVAudioSession interruptions (iOS) auto-pause capture; an interruption end
  auto-resumes once the session is re-activated and the microphone is free
  (with retry/deferred recovery while backgrounded and live-audio
  reconciliation).
- **Microphone-lost detection** — `onMicrophoneLost` when the microphone
  becomes unavailable while backgrounded and only the user can fix it.
- **Priority-ladder input switching** — USB/wired → Bluetooth → built-in,
  applied before capture starts, re-evaluated on device changes, with settle
  and foreground re-asserts; runtime-toggleable (`routeSwitchingEnabled` /
  `setRouteSwitchingEnabled`), source-switch events included.
- **Voice-command mode** — continuous listening with a rolling voice-command
  buffer trimmed to the most recent 5 minutes and a `voiceCommandAudio`
  getter for the last 10 seconds (the pre-trigger tail for wake-word flows).
- **RAM buffering** — `startAudioBuffering` / `stopAudioBuffering` /
  `drainBufferedAudio` (atomic read-and-clear) / `emitInitialAudio`
  (re-emit the conversation-creation window for late subscribers) with
  `bufferingStartedAt` anchoring.
- **File output** — streaming raw PCM output to a file via `setOutputFile`
  (with roll-over and delete-existing control), `outputFile`, `clearOutputFile` —
  or a standards-compliant **WAV container** (`format: MicRecordingFileFormat.wav`)
  with the canonical 44-byte header written up-front and true RIFF/data sizes
  patched on close.
- **Native encoded file output** — `setEncodedOutput` arms a native encoder
  running alongside the raw stream from the same capture: AAC-LC (`.m4a`,
  Android + iOS), Apple Lossless (`.m4a`, iOS), Opus in Ogg (`.ogg`, Android
  10+), FLAC (`.flac`, Android) and AMR-NB/AMR-WB (`.amr`, Android — 8 kHz /
  16 kHz capture respectively). Pause/resume keeps one file (presentation
  timestamps span the gap); `stop` finalizes, `cancel` and
  `clearEncodedOutput` discard. Android: `MediaCodec` + `MediaMuxer`/raw
  writers fed from the capture tee; iOS: `AVAudioFile` writing from the tap.
- **Live dBFS metering** — `onAmplitude` (throttled to
  `MicRecorderConfig.amplitudeInterval`, 100 ms by default) and `amplitude`
  report current, average and peak dBFS computed from the same PCM chunks
  that feed the stream and files.
- **The recording clock** — `onDurationChanged` ticks the active capture
  duration (paused spans excluded): `Duration.zero` on `start`,
  chunk-arrival-driven ticks throttled to ~200 ms (no wall-clock timer — a
  frozen capture pipeline stops the clock instead of lying about it), and
  the episode's exact total as the final event on `stop`.
  `elapsedDuration` reads the always-current value and `recordingStartedAt`
  anchors the episode in UTC.
- **Recording results & cancellation** — `stop()` returns a `MicRecordingInfo`
  (start time, active duration with paused spans excluded, size, path,
  encoder/format, sample rate); `cancel()` stops and deletes every output
  file the episode produced. `recordingStartedAt` and `elapsedDuration`
  observe the live episode.
- **Max-duration auto-stop** — `MicRecorderConfig.maxDuration` stops the
  episode once that much ACTIVE capture time has elapsed (paused spans
  excluded, so a paused recording never burns its budget): the stop runs
  with `MicRecordingStopReason.maxDurationReached`, surfaced in
  `MicRecordingInfo.stopReason`, `lastRecordingInfo` and `onStateChange`. A
  one-shot scheduling guard plus a finishing re-entry guard keep the
  automatic stop, a manual stop and a dispose-triggered stop from racing.
- **Microphone permissions** — `checkMicrophonePermission` /
  `requestMicrophonePermission` implemented natively (Android
  `ActivityCompat` + result listener, iOS `AVAudioSession
  .requestRecordPermission`); capture itself never requests implicitly.
- **Android capture effects** — `MicRecorderConfig.androidEchoCancel` /
  `androidNoiseSuppress` / `androidAutoGain` attach the platform echo
  canceler, noise suppressor and automatic gain control to the capture
  session (best effort, re-armed across route rebuilds; no iOS equivalents —
  the session mode governs them there).
- **Amplitude extraction** — `extractAmplitudes` decodes a containered audio
  file into normalized (0.1–1.0) RMS bars for waveform rendering
  (Android `MediaCodec`, iOS `AVAssetReader`).
- **Android microphone foreground service** — ongoing background capture runs
  as a microphone-type foreground service (Android 8+ background execution
  limits; Android 14 `FOREGROUND_SERVICE_MICROPHONE` while-in-use start)
  with per-state notification titles configured through
  `MicForegroundServiceConfig` on `initialize` (no separate notification
  method, by design); recording continues safely when the Android 13+
  notification grant is absent.
- **Self-healing capture** — native watchdogs rebuild the capture stack on
  digital silence (15 s threshold, up to 4 quick rebuilds then one per 60 s),
  route transitions (budget 8), read stalls (budget 4), routed-input
  vanishing, and iOS engine/tap failures (route watchdog 2 s, recreation
  retry 0.7 s, foreground recreation 0.4 s, silent-buffer zombie detection).
- **Silence & health telemetry** — 30 s silence alarms with 60 s-paced
  foreground capture-stack recovery, one `onConversationSilence` event per
  completed 5-minute quiet window, and a 2-minute audio-health heartbeat.
- **Diagnostics** — `getRouteState()` (Android route/silence diagnostics),
  `isOtherAudioPlaying()`, `isAndroidMicHeldByCall()`.
- **Opt-in logging** — a `MicLogSink` can be attached via
  `MicRecorderConfig.log`.
- **Example app** — a full demo exercising every public API member: the
  permissions gate, the encoded-output card, the WAV selector, the dBFS
  meter, the duration timer, the maxDuration chips and the stop-result
  card, plus RAM buffering, voice-command flows, route diagnostics, the
  event log and the configuration screen.
- **CI/CD** — GitHub Actions: analyze/format/test with coverage, `pana`,
  Android debug APK build, iOS no-codesign build, and OIDC-tagged automated
  publishing (after the one-time manual first publish and publisher
  transfer; see `doc/PUBLISHING.md`).

### Engineering notes

- Zero Dart dependencies beyond `flutter` and `plugin_platform_interface`.
- The wire protocol counts 24 verbs on
  `com.bilalahmed24.mic_recorder/methods` (with the
  `com.bilalahmed24.mic_recorder/audio_stream` and
  `…/session_events` event channels alongside). `startRecording` carries
  the three Android effect toggles; `setEncodedOutput` carries
  `{path, encoder, bitRate?, sampleRate?}` — Dart always sends the
  configured capture rate, so arming an encoder BEFORE the first start
  works at non-default rates (the natives fall back to their tracked
  last-started rate only for foreign callers, and Android drops — loudly,
  never pitch-shifted — an armed encoder that mismatches a later start).
- Android implementation in Java, iOS in Swift with both Swift Package Manager
  and CocoaPods support.
- MIT licensed.

[Unreleased]: https://github.com/bilalahmed24/mic_recorder/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/bilalahmed24/mic_recorder/releases/tag/v0.1.0
