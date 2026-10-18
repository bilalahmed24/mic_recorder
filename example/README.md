# mic_recorder example

A single-screen Material 3 demo that exercises **every public member** of
the [`mic_recorder`](https://pub.dev/packages/mic_recorder) plugin — raw PCM
recording with audio session handling, interruption recovery and audio input
device switching, plus the v0.2 additions: a built-in WAV container writer,
native encoded output (AAC-LC / Apple Lossless / Opus / FLAC / AMR-NB /
AMR-WB), dBFS metering, a live episode clock with max-duration auto-stop,
permission management and Android capture effects.

The example depends on nothing but Flutter and the plugin itself (path
dependency): no path provider, no permission handler, no state management
library.

## What the demo shows

| Area | API members exercised |
| --- | --- |
| Lifecycle | `MicRecorder.instance`, `initialize(MicRecorderConfig)`, `start(mode:)` (conversation + voice command), `pause()`, `resume()`, `stop()` (returns the `MicRecordingInfo` shown in the stop-result card), `cancel()` (behind a confirmation dialog — it discards every output file), `dispose()` (behind a confirmation dialog — the singleton teardown is terminal) |
| Permissions (pre-flight gate) | `checkMicrophonePermission()` (status row), `requestMicrophonePermission()` (button) — shown before the first start; the plugin never requests permissions itself, so a failed start re-opens the gate |
| State & events | `onStateChange`, `onAudioInterruption`, `onAudioSourceSwitched`, `onConversationSilence`, `onMicrophoneLost` (timestamped, color-coded event log capped at 300 entries) |
| Metering | `onAmplitude` (dBFS bar with current / average / peak caption, fed through a `ValueNotifier`) and the unthrottled `amplitude` getter (per-chunk freshness), next to the demo's own per-chunk RMS meter from `audioStream`; throttling is set by `MicRecorderConfig.amplitudeInterval` |
| Episode clock | `onDurationChanged` (live mm:ss display in the status card; zero on start, exact total on stop, paused spans excluded), `elapsedDuration`, `recordingStartedAt` |
| RAM buffering | `startAudioBuffering()`, `stopAudioBuffering()`, `drainBufferedAudio()`, `voiceCommandAudio`, `emitInitialAudio()`, `bufferingStartedAt` (live in-buffer / harvested / last-harvest / voice-tail counters derived from byte accounting) |
| File output | `setOutputFile(path, format:)` with a `MicRecordingFileFormat` pcm16/wav selector — the plugin's writer builds the container itself (the canonical 44-byte WAV header, sizes patched on close; the old demo-side header workaround is gone), `outputFile`, `outputFileFormat`, `clearOutputFile()`, `extractAmplitudes(filePath, barCount: 60)` rendered as a 60-bar waveform |
| Encoded output | `setEncodedOutput(path, encoder:, bitRate:)`, `clearEncodedOutput()`, `encodedOutputFile` — encoder dropdown over all six `MicAudioEncoder` values (gated by `isSupportedOn` + `defaultTargetPlatform`, so unsupported entries are disabled), a bitRate field (encoder default when empty; disabled for lossless), file names suggested via `MicAudioEncoder.fileExtension`, and an explicit block reason when AMR-NB / AMR-WB is picked without the `requiredSampleRate` (8 kHz / 16 kHz) configured |
| Stop result | the `MicRecordingInfo` `stop()` returned — `duration`, `sizeBytes`, `path`, `encoder`, `fileFormat`, `stopReason`, `startedAtUtc`, `sampleRate` / `bitDepth` / `channels`; after a `maxDuration` auto-stop the card flags `lastRecordingInfo?.stopReason == MicRecordingStopReason.maxDurationReached` (the demo polls the getter briefly because the recorder assigns it behind the state event) |
| Routing & diagnostics | `isRouteSwitchingEnabled`, `setRouteSwitchingEnabled()`, `getRouteState()` (raw map, sorted; Android-only), `isOtherAudioPlaying()`, `isAndroidMicHeldByCall()` (Android-only) |
| Status | `isInitialized`, `sampleRate`, `bitDepth`, `mode`, `currentState`, `recordingStartedAt`, `elapsedDuration`, `bufferingStartedAt`, `config` summary (incl. `amplitudeInterval`, the Android effect flags and `maxDuration`) |
| Configuration screen | `MicRecorderConfig` — `sampleRate` (8/16/22.05/44.1/48 kHz), `amplitudeInterval` (50 ms – 1 s), `maxDuration` chips (none / 10 s / 30 s / 60 s → auto-stop), the three Android capture-effect switches (`androidEchoCancel` / `androidNoiseSuppress` / `androidAutoGain`), `routeSwitchingEnabled`, every `MicAudioSessionConfig` flag, every `MicForegroundServiceConfig` field, and the `log` sink (custom `MicLogSink` vs `defaultMicLog`) |
| API type gallery | `MicAudioDeviceType.fromAndroidType` / `fromIosPortType` (incl. `headphonesInputAvailable`), `MicAudioDevice` `==` / `hashCode` / `toString`, `MicAudioInput.type`, `MicAudioRoute`, all six `MicAudioEncoder` values (`wireName`, `fileExtension`, `defaultBitRate`, `requiredSampleRate`, `android` / `ios` flags), `MicRecordingFileFormat`, `MicRecordingStopReason`, sample `MicRecordingInfo` instances (an encoded episode and a Dart-written WAV episode), a sample `MicAmplitude` (`silenceDbfs`, `isSilent`), sample instances of every event class, and value listings of `MicAudioSourceKind.wireName`, `MicAudioInterruptionType`, `MicLogLevel`, `MicRecorderState` (+ flags), `MicRecordingMode` |

## Running the app

### 1. Generate the platform folders (first run only)

This rebuild ships the Dart code only; the `android/` and `ios/` runner
folders are generated separately. If they are missing, generate them once
from inside `example/`:

```sh
flutter create . --platforms=android,ios
```

### 2. Add the permissions

The plugin deliberately does **not** request permissions itself — the host
app must declare them (the demo then drives
`requestMicrophonePermission()` through the pre-flight gate card).

**Android** — add inside `<manifest>`, before `<application>`, in
`android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.RECORD_AUDIO"/>
<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
```

> `RECORD_AUDIO` must also be **granted at runtime** (the demo's gate card
> runs `checkMicrophonePermission()` / `requestMicrophonePermission()`; the
> plugin's `start()` itself never prompts); `POST_NOTIFICATIONS` is needed
> from Android 13+ for the recording foreground-service notification.

**iOS** — add to `ios/Runner/Info.plist`:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>Recording demo requires microphone access</string>
<key>UIBackgroundModes</key>
<array>
    <string>audio</string>
</array>
```

### 3. Run

```sh
flutter pub get
flutter run
```

## Permission matrix

| Platform | Permission | Why |
| --- | --- | --- |
| Android | `RECORD_AUDIO` | `AudioRecord` capture |
| Android 13+ | `POST_NOTIFICATIONS` | microphone foreground-service notification |
| Android 14+ | (implicit) `FOREGROUND_SERVICE_MICROPHONE` | merged in by the plugin's manifest |
| iOS | `NSMicrophoneUsageDescription` | `AVAudioSession` microphone input |
| iOS | `UIBackgroundModes` → `audio` | keep capturing while backgrounded |

## Files

- `lib/main.dart` — the demo itself (permission gate, status with the
  mm:ss clock, controls, stop-result card, live meters, RAM buffering, file
  output with the pcm16/wav selector, encoded output, routing &
  diagnostics, event log, configuration screen, theme-mode menu).
- `lib/api_gallery.dart` — catalog of the exported types the live flow does
  not hand over (incl. the encoder / file-format / stop-reason enums and
  sample `MicRecordingInfo` / `MicAmplitude` instances).
- `test/widget_test.dart` — smoke test (title + the recorder's one-shot
  lifecycle priming timer).
