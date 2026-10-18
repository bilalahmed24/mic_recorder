# mic_recorder

[![pub package](https://img.shields.io/pub/v/mic_recorder.svg)](https://pub.dev/packages/mic_recorder)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Platforms](https://img.shields.io/badge/platforms-Android%20%7C%20iOS-44cc11.svg)](https://pub.dev/packages/mic_recorder)

Microphone recording for Flutter with audio-session handling, interruption
recovery and audio input device switching, for Android and iOS.

Audio is delivered as a **16-bit little-endian mono PCM stream** — you get
the bytes (stream them to a transcriber, meter them, buffer them in RAM for
wake-word style flows) — and when you want files, the plugin writes them
itself: a built-in WAV container, or natively encoded AAC-LC, Apple
Lossless, Opus, FLAC and AMR files, with live dBFS metering and a duration
clock included. No recorder, container, permission, metering or encoder
package needed.

The plugin was built for production voice recording, and the parts that
are hard to get right — audio focus, AVAudioSession, interruptions,
Bluetooth SCO, route watchdogs — are exactly the parts it keeps
battle-tested.

## Contents

- [Features](#features)
- [Capabilities](#capabilities)
- [Requirements](#requirements)
- [Installation](#installation)
- [Permissions](#permissions)
- [Quick start](#quick-start)
- [File output: WAV and encoded formats](#file-output-wav-and-encoded-formats)
- [The Android foreground service rationale](#the-android-foreground-service-rationale)
- [Interruption handling](#interruption-handling)
- [Input switching (priority ladder)](#input-switching-priority-ladder)
- [Metering, duration and auto-stop](#metering-duration-and-auto-stop)
- [Limitations & scope](#limitations--scope)
- [API reference](#api-reference)
- [Example app](#example-app)
- [Troubleshooting / FAQ](#troubleshooting--faq)
- [License](#license)

## Features

- **Raw PCM capture** — 16-bit little-endian mono chunks on `audioStream`,
  at a configurable sample rate (default 16 kHz).
- **File output built in** — stream the same PCM to a file with
  `setOutputFile`: raw headerless PCM, or a standards-compliant **WAV
  container** (canonical 44-byte header, sizes patched on close).
- **Native encoded output** — `setEncodedOutput` arms a native encoder that
  runs alongside the raw stream from the same capture: **AAC-LC (`.m4a`)**
  on Android and iOS, **Apple Lossless (`.m4a`)** on iOS, **Opus (`.ogg`,
  Android 10+)**, **FLAC (`.flac`)** and **AMR-NB/AMR-WB (`.amr`)** on
  Android.
- **Live dBFS metering** — `onAmplitude` (throttled by
  `amplitudeInterval`, 100 ms by default) and the always-fresh `amplitude`
  getter report current, average and peak dBFS.
- **The recording clock** — `onDurationChanged` ticks the active capture
  duration (paused spans excluded; ticks ride the audio, so a frozen
  pipeline stops the clock instead of lying), and `stop()` finishes with
  the exact total. `elapsedDuration` reads it at any time.
- **Auto-stop** — `MicRecorderConfig.maxDuration` stops the episode after
  that much **active** capture time, with the reason reported in
  `MicRecordingInfo.stopReason`.
- **Stop results & cancellation** — `stop()` returns a `MicRecordingInfo`
  (start time, duration, size, path, encoder/format, stop reason);
  `lastRecordingInfo` keeps the most recent one; `cancel()` throws the
  recording away and deletes its files.
- **Microphone permissions** — `checkMicrophonePermission` /
  `requestMicrophonePermission` implemented natively; capture itself never
  requests implicitly.
- **Android capture effects** — optional echo canceler, noise suppressor
  and automatic gain control on the capture session (best effort; on iOS
  the session mode governs these).
- **Audio session handling built in natively** — Android
  `AudioManager` audio focus (Java) and iOS `AVAudioSession` (Swift)
  implemented inside the plugin: zero Dart dependencies beyond Flutter and
  `plugin_platform_interface`.
- **Interruption detection & recovery** — audio focus loss (Android) and
  session interruptions (iOS) auto-pause capture; recording auto-resumes when
  the interruption ends and the session is live again. Includes
  microphone-lost detection while backgrounded.
- **Priority-ladder input switching** — USB/wired → Bluetooth → built-in
  microphone, re-evaluated whenever the available inputs change. Can be
  disabled to leave routing to the OS.
- **Voice-command mode** — continuous listening that retains only the most
  recent audio: `voiceCommandAudio` hands you the last 10 seconds at any time.
- **RAM buffering** — buffer everything in memory, drain it atomically, and
  re-emit the conversation-creation window onto the stream for late
  subscribers.
- **Amplitude extraction** — decode a recorded file into normalized RMS bars
  for waveform rendering.
- **Android microphone foreground service** — the ongoing background capture
  runs as a microphone-type foreground service with a user-visible
  notification whose per-state titles you configure (see
  [the rationale](#the-android-foreground-service-rationale)).
- **Self-healing capture** — silence/route/stall watchdogs rebuild the native
  capture stack when the audio path dies (unplugged headsets, zombie SCO
  links, framework stalls) instead of silently recording zeros.
- **Diagnostics & opt-in logging** — `getRouteState()`,
  `isOtherAudioPlaying()`, `isAndroidMicHeldByCall()`, and an opt-in
  `MicLogSink` for verbose tracing.

## Capabilities

The whole recording stack in one package — no `record`,
`permission_handler` or encoder package to add:

| Capability | mic_recorder |
|---|---|
| Streaming PCM capture | yes — `audioStream` (16-bit LE mono, configurable rate) |
| File output — WAV | yes — `setOutputFile(format: MicRecordingFileFormat.wav)` |
| File output — AAC-LC (`.m4a`) | yes — `setEncodedOutput(MicAudioEncoder.aacLc)` (Android + iOS) |
| File output — Apple Lossless (`.m4a`) | yes — iOS |
| File output — Opus (`.ogg`) | yes — Android 10+ |
| File output — FLAC (`.flac`) | yes — Android |
| File output — AMR-NB (8 kHz) / AMR-WB (16 kHz) (`.amr`) | yes — Android |
| Metering | yes — live dBFS on `onAmplitude` / `amplitude` |
| Recording clock | yes — `onDurationChanged` / `elapsedDuration` |
| Auto-stop | yes — `MicRecorderConfig.maxDuration` |
| Permissions | yes — `checkMicrophonePermission` / `requestMicrophonePermission` |
| Interruption recovery | yes — auto-pause/auto-resume, both platforms |
| Audio session handling | yes — implemented natively in the plugin (Java/Swift) |
| Input switching | yes — USB/wired → Bluetooth → built-in priority ladder |
| Background recording | yes — Android microphone foreground service; iOS background audio mode |
| Pause / resume | yes |
| Stereo / multi-channel | no — mono by design (see [Limitations & scope](#limitations--scope)) |

## Requirements

| | Minimum |
|---|---|
| Flutter | ≥ 3.35.0 (Dart ≥ 3.8.0) |
| Android | `minSdk 24` (Android 7.0), `compileSdk 36` |
| iOS | 15.0 |
| Platforms | Android (Java) and iOS (Swift). No web / desktop support. |

## Installation

From pub.dev:

```bash
flutter pub add mic_recorder
```

or in `pubspec.yaml`:

```yaml
dependencies:
  mic_recorder: ^0.1.0
```

While developing against a local checkout (path dependency):

```yaml
dependencies:
  mic_recorder:
    path: ../mic_recorder
```

## Permissions

The plugin provides `checkMicrophonePermission()` and
`requestMicrophonePermission()` natively — Android shows the system dialog
through the host activity, iOS asks via
`AVAudioSession.requestRecordPermission`. **Capture itself never requests
the permission implicitly**: gate `start()` on an explicit request (or your
own flow) so a deliberate user journey precedes the first recording.

The declarations remain the host app's job — the native request only shows
the dialog; the manifest/plist keys must already exist:

### Android (host app manifest)

```xml
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<!-- Android 13+: runtime grant; only needed so the foreground-service
     notification is visible. Recording continues without it. -->
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
```

The plugin's own manifest declares (merged into your app automatically):

```xml
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_MICROPHONE" />
```

- `RECORD_AUDIO` is **required** and must be granted before `start()`.
- `POST_NOTIFICATIONS` (Android 13+) only affects **visibility** of the
  recording notification. If it is not granted, recording still runs safely
  in the background — the user just does not see the notification.
- `FOREGROUND_SERVICE` / `FOREGROUND_SERVICE_MICROPHONE` are normal
  (install-time) permissions and are satisfied automatically.

### iOS (host app `Info.plist`)

```xml
<key>NSMicrophoneUsageDescription</key>
<string>We need the microphone to record your voice.</string>

<!-- Only if recording must continue while backgrounded: -->
<key>UIBackgroundModes</key>
<array>
  <string>audio</string>
</array>
```

## Quick start

A complete, runnable flow:

```dart
import 'package:mic_recorder/mic_recorder.dart';

Future<void> main() async {
  final recorder = MicRecorder.instance;

  // 1. Ask for the microphone up front — capture never requests it
  //    implicitly, so an explicit user journey precedes the first
  //    recording. (checkMicrophonePermission() reads the current state.)
  if (!await recorder.requestMicrophonePermission()) {
    return; // declined — surface your own UI here
  }

  // 2. Configure once, before the first start.
  //    Calling initialize() again while stopped reconfigures; it throws a
  //    StateError while a recording is active.
  recorder.initialize(
    const MicRecorderConfig(
      sampleRate: 16000,
      routeSwitchingEnabled: true,
      amplitudeInterval: Duration(milliseconds: 100),
      // maxDuration: Duration(minutes: 10), // optional auto-stop
      audioSession: MicAudioSessionConfig(
        allowBluetooth: true,
        defaultToSpeaker: true,
        notifyOthersOnDeactivation: true,
        androidWillPauseWhenDucked: true,
      ),
      androidForegroundService: MicForegroundServiceConfig(
        enabled: true,
        channelName: 'Recording',
        channelDescription: 'Microphone recording status',
        titleWhenRecording: 'Recording conversation',
        titleWhenPaused: 'Recording paused',
        titleWhenInterrupted: 'Recording interrupted',
        titleWhenListening: 'Listening for voice commands',
      ),
    ),
  );

  // 3. Observe the recorder.
  recorder.onStateChange.listen((state) {
    // stopped | recording | paused | error
    print('Recorder state: ${state.name}');
  });

  recorder.onAudioInterruption.listen((interruption) {
    print(
      'Interruption ${interruption.begin ? 'began' : 'ended'} '
      '(${interruption.type.name})',
    );
    // Capture auto-pauses on begin and auto-resumes on end — you usually
    // only need this for UI bookkeeping.
  });

  recorder.onAudioSourceSwitched.listen((event) {
    print('Mic source: ${event.sourceKind.name} (${event.reason})');
  });

  recorder.onConversationSilence.listen((event) {
    print('Quiet for ${event.duration.inMinutes} minute(s)');
  });

  // The mic went away while the app was backgrounded — surface your own
  // notification so the user returns to the app.
  recorder.onMicrophoneLost.listen((event) {
    print('Microphone lost (${event.reason})');
  });

  // 4. Watch the meters: loudness in dBFS and the active duration
  //    (paused spans excluded). Both ride the audio — no timers to
  //    manage, and a frozen pipeline stops the clock instead of lying.
  recorder.onAmplitude.listen((reading) {
    print('Now ${reading.currentDbfs.toStringAsFixed(1)} dBFS');
  });

  recorder.onDurationChanged.listen((elapsed) {
    print('Recording for $elapsed');
  });

  // 5. Consume the raw PCM stream (16-bit little-endian mono).
  final subscription = recorder.audioStream.listen((chunk) {
    // chunk is a List<int> of raw PCM bytes at 16 kHz.
  });

  // 6. Start recording — conversation mode.
  final started = await recorder.start();
  if (!started) {
    // State is MicRecorderState.error — most commonly the permission
    // was never granted, or another app holds the microphone.
    await subscription.cancel();

    return;
  }

  // Optional: buffer everything in RAM for a later hand-off…
  await recorder.startAudioBuffering();

  // …and/or write files — a WAV container (or raw PCM) from the Dart
  // writer, and/or a natively encoded file from the same capture:
  await recorder.setOutputFile(
    '/path/to/recording.wav',
    format: MicRecordingFileFormat.wav,
  );

  // await recorder.setEncodedOutput(
  //   '/path/to/recording.m4a',
  //   encoder: MicAudioEncoder.aacLc,
  // );

  // 7. Voice-command flows use the same stream with a rolling tail:
  //
  //   await recorder.start(mode: MicRecordingMode.voiceCommand);
  //   ...
  //   final tail = recorder.voiceCommandAudio; // last <= 10 s of PCM
  //
  // and hand the conversation-creation window to late subscribers:
  //
  //   await recorder.emitInitialAudio();

  // 8. Harvest the RAM buffer BEFORE stopping (stop() stops buffering and
  //    flushes the file writer itself).
  final buffered = recorder.drainBufferedAudio();

  // 9. Stop — returns what the episode produced. A maxDuration
  //    auto-stop lands here too, with stopReason: maxDurationReached.
  final info = await recorder.stop();
  print('${info?.path}: ${info?.duration} / ${info?.sizeBytes} bytes '
      '(${info?.stopReason.name})');

  // Or throw the recording away — cancel() stops AND deletes every
  // output file the episode produced:
  //
  //   await recorder.cancel();

  await subscription.cancel();
}
```

Notes on the pieces:

- **RAM buffering** — `startAudioBuffering()` records every chunk in memory
  (it implicitly starts the recorder if needed). `drainBufferedAudio()`
  atomically reads-and-clears the buffer on Dart's single-threaded event loop,
  so exactly one consumer harvests any segment. `stopAudioBuffering()` stops
  buffering and returns what was held. `bufferingStartedAt` anchors gap
  attribution when no explicit disconnect timestamp exists.
- **Voice-command mode** — silence is expected there: no silence alarms fire,
  and only the most recent audio is retained. `voiceCommandAudio` returns the
  last 10 seconds; the internal buffer is trimmed on a rolling 5-minute
  window. `emitInitialAudio()` drains the RAM buffer, combines it with the
  voice-command tail and pushes the combined audio back onto `audioStream` —
  late subscribers (uploaders, transcribers) receive the pre-trigger audio,
  and the still-armed buffering subscription re-captures it.
- **File output** — `setOutputFile` writes raw headerless PCM by default,
  or a WAV container via `format: MicRecordingFileFormat.wav` (the 44-byte
  header is written up front and the RIFF/data sizes patched on close —
  directly loadable by `extractAmplitudes`). Encoded output via
  `setEncodedOutput` runs natively alongside; see
  [File output: WAV and encoded formats](#file-output-wav-and-encoded-formats).
- **Pause / resume** — `pause()` tears the capture stack down until `resume()`
  (or an interruption end) restarts it. Interruptions pause automatically and
  resume once the audio session is recovered. Paused spans are excluded from
  `onDurationChanged`, `elapsedDuration` and the `maxDuration` budget.

## File output: WAV and encoded formats

Three output paths can run from one capture: the raw stream (always on),
a Dart-written file and a native encoded file.

### WAV / raw PCM — `setOutputFile`

- `MicRecordingFileFormat.pcm16` (the default) writes raw headerless PCM —
  byte-for-byte the stream. When the file already exists and
  `deleteExistingFile` is `false` (default `true`), audio is appended.
- `MicRecordingFileFormat.wav` wraps the same PCM in a standards-compliant
  RIFF/WAVE container: the canonical 44-byte header is written up front and
  the true RIFF/data sizes are patched when the file is closed — even a hard
  process death leaves a playable (if mis-sized) file.
- Call again with a new path to roll to a new file; `clearOutputFile()`
  flushes and stops writing while capture keeps running (`outputFile` /
  `outputFileFormat` report the armed state).

### Encoded output — `setEncodedOutput`

Arms a **native** encoder that runs alongside the raw stream and the Dart
file writer, from the same capture:

| Encoder | Container | Default bit rate | Requires | Android | iOS |
|---|---|---|---|---|---|
| `MicAudioEncoder.aacLc` | `.m4a` | 128 kbit/s | — | yes | yes |
| `MicAudioEncoder.appleLossless` | `.m4a` | lossless | — | no | yes |
| `MicAudioEncoder.opus` | `.ogg` | 24 kbit/s | Android 10+ | yes | no |
| `MicAudioEncoder.flac` | `.flac` | lossless | — | yes | no |
| `MicAudioEncoder.amrNb` | `.amr` | 12.2 kbit/s | 8 kHz capture | yes | no |
| `MicAudioEncoder.amrWb` | `.amr` | 23.85 kbit/s | 16 kHz capture | yes | no |

- Call before `start`, or mid-recording (audio captured from now on —
  nothing is retroactively encoded). One encoded output at a time;
  `clearEncodedOutput()` disarms it and deletes the partial file while the
  recording keeps going. Pick the file extension from
  `MicAudioEncoder.fileExtension`; `bitRate` applies to the lossy encoders.
- **Pause/resume keeps one file** — presentation timestamps are derived from
  the frames fed, so the resumed audio continues the timeline and the paused
  gap spans naturally. `stop` finalizes; `cancel` and `clearEncodedOutput`
  discard.
- Errors: `StateError` when another encoded output is already armed, the
  encoder's sample-rate requirement is not met (arm `amrNb` only with
  `sampleRate: 8000`, `amrWb` with 16000), or the platform rejected the
  request; `UnsupportedError` when the encoder is unavailable on this
  platform.

### Stop results — `MicRecordingInfo`

`stop()` returns what the episode produced (null when the recorder was not
active):

| Field | Meaning |
|---|---|
| `startedAtUtc` | When the episode started (UTC). |
| `duration` | Active capture time — paused spans excluded. |
| `sizeBytes` | Bytes written to the output file (the encoded output when armed, else the Dart-written file); the bytes captured on the stream when no file was armed. |
| `path` | The file the episode wrote (the encoded output when armed, else the Dart-written file), null when recording to stream only. |
| `encoder` | The native encoder that produced `path`, null when Dart-written (see `fileFormat`). |
| `fileFormat` | The format of a Dart-written `path` (`pcm16` or `wav`), null for encoded output / no file. |
| `stopReason` | `MicRecordingStopReason.manual` or `.maxDurationReached`. |
| `sampleRate` / `bitDepth` / `channels` | The capture shape (always 16-bit mono). |

`lastRecordingInfo` keeps the most recently completed episode's result — an
app that armed `maxDuration` learns the auto-stop there or on
`onStateChange`. `cancel()` stops like `stop()` but deletes every output
file the episode produced and reports nothing.

## The Android foreground service rationale

> This section records a deliberate design decision: the foreground-service
> notification is configured through `MicForegroundServiceConfig` passed to
> `initialize` — there is **deliberately no separate
> `setForegroundNotification` method**.

**Why a foreground service at all?**

- Since Android 8 (API 26), an app that keeps working while backgrounded is
  aggressively restricted. Ongoing **background microphone capture is simply
  not reliable without a foreground service** — the process is frozen or the
  capture is cut when the OS decides the app is idle. A microphone-type
  foreground service keeps the process alive and the capture running while
  the user does something else.
- The plugin therefore runs the capture inside a microphone-type foreground
  service (`foregroundServiceType="microphone"`, started with
  `startForeground(..., FOREGROUND_SERVICE_TYPE_MICROPHONE)` on API 30+)
  whenever a recording session is active — a **user-visible notification is
  the price Android charges for it**, and honest recording UIs owe the user
  that indicator anyway.

**Android 14 (API 34) adds two hard requirements:**

- Starting a microphone foreground service requires the
  **`FOREGROUND_SERVICE_MICROPHONE`** permission (declared by the plugin's
  manifest) **and** a *while-in-use* start: the service must be started while
  the app is visible (or another exemption applies). `MicRecorder.start()`
  already refuses to begin while the app is backgrounded, so the plugin's FGS
  start rides the same foreground guarantee.
- If the app is backgrounded when the service would need to start, the
  system throws — which is why the recorder's start path is foreground-gated
  and mid-recording backgrounding never needs a *new* FGS start (the running
  service just keeps going).

**Android 13 (API 33) — notification visibility:**

- The notification only renders if the user granted
  **`POST_NOTIFICATIONS`** at runtime. That permission is the **host app's
  responsibility** (the plugin never asks). If it is not granted:
  **recording continues safely** — you only lose the visible indicator, not
  the microphone.

**Why configuration instead of a method?**

- The notification has per-recording-state titles (`titleWhenRecording`,
  `titleWhenPaused`, `titleWhenInterrupted`, `titleWhenListening`) plus
  channel name/description and an optional small icon. Bundling all of it
  into `MicForegroundServiceConfig` on `initialize` means the whole
  notification lifecycle is declared once, up front, and the plugin updates
  the title itself as the state changes — there is no per-call notification
  API to misuse, no ordering hazard, and no state in which a recording runs
  with a stale/wrong notification because a setter was missed.
- If you do not want the notification path at all, set
  `MicForegroundServiceConfig(enabled: false)` and the plugin never starts
  the service (background recording is then on you and the OS's mercy).

**Lifecycle:** the FGS spans the recording *session* — started on
`start()` (including the title for the active mode), updated on
pause/interruption/resume, and stopped on `stop()`. Pauses keep the service
alive (the recording is still "open"), so the user always sees the truth.

## Interruption handling

The plugin owns the audio session for the recording: it configures and
activates it (Android: audio focus request; iOS: `AVAudioSession`
`playAndRecord`/`default` with `.allowBluetoothHFP` + `.defaultToSpeaker`),
reacts to interruptions, and recovers.

### Android — audio focus mapping

The native layer requests voice-communication audio focus
(`gainTransientExclusive`) and reports raw focus changes; the Dart session
controller maps them to typed interruptions:

| Native focus event | `MicAudioInterruption` |
|---|---|
| `loss` | `begin: true`, `type: unknown` |
| `lossTransient` | `begin: true`, `type: pause` |
| `lossTransientCanDuck` (with `androidWillPauseWhenDucked: true`, the default) | `begin: true`, `type: pause` |
| `lossTransientCanDuck` (with `androidWillPauseWhenDucked: false`) | `begin: true`, `type: duck` |
| `gain` | `begin: false`, `type: pause` |

On Android, a `loss` triggers auto-abandon of the focus request; when the
system re-grants focus (`gain`), recovery reconciles immediately. While the
app is backgrounded, a safety watch keeps polling whether the interrupting
audio actually stopped and drives the same recovery.

### iOS — AVAudioSession interruptions

| Interruption notification | `MicAudioInterruption` |
|---|---|
| `began` (not suspended) | `begin: true`, `type: unknown` |
| `began` with `wasSuspended` | dropped |
| `ended`, `shouldResume: true` | `begin: false`, `type: pause` |
| `ended`, `shouldResume: false` | `begin: false`, `type: unknown` |

An *unknown* end (ended without `shouldResume`) re-activates the session; a
`pause` end follows with auto-resume. While backgrounded, iOS defers session
writes and pays the debt on foreground return — an unknown interruption that
begins while backgrounded also emits `onMicrophoneLost`, because only the
user returning to the app can fix it.

### Auto-pause / auto-resume semantics

- **Begin** → capture pauses immediately (`MicRecorderState.paused`, FGS
  title switches to `titleWhenInterrupted`). The pause is tagged
  *for-interruption*.
- **End** → only an *interruption-caused* pause auto-resumes, and only after
  the session is re-activated and the microphone is not held by a call
  (`resume()` returns `false` while `isAndroidMicHeldByCall()` is true). If
  the native resume fails, the retry stays armed: the next foreground
  transition or the arrival of live audio reconciles it.
- **Manual `resume()`** cancels any pending automatic resume; it is blocked
  while a call holds the microphone.
- Live audio arriving while Dart still thinks it is paused reconciles the
  state within ~100 ms — native recovery wins over bookkeeping.
- **Microphone lost** — an interruption that begins while the app is
  backgrounded (iOS semantics, where only the user can restore access) is
  reported on `onMicrophoneLost`. Surface your own notification: the plugin
  deliberately does not post local notifications.

## Input switching (priority ladder)

While recording, the plugin steers capture to the best available input:

| Priority | Kind | iOS port types | Android device types |
|---|---|---|---|
| 1 | USB / wired | `USBAudio`, `HeadsetMic`, `LineIn`, `CarAudio` | `usbAudio`, `wiredHeadset`, `lineAnalog`, `lineDigital`, `carAudio` |
| 2 | Bluetooth | `BluetoothHFP`, `BluetoothLE` | `bluetoothSco`, `bluetoothLe` (+ any listed Bluetooth device as a headset-connected signal) |
| 3 | Built-in | `BuiltInMic` | `builtInMic` |
| — | none selectable | `systemDefault` | `systemDefault` |

- **Applied before capture starts** (`prepare`) so the first buffer already
  comes from the priority input, then **re-evaluated on every device change**
  while recording (device list diffs on both platforms).
- Timed re-asserts cover slow device enumeration: a settle re-check 3 s after
  recording starts and a foreground re-assert 300 ms after the app resumes.
- On Android, Bluetooth selection means starting the SCO link and pinning the
  recorder to the SCO input; unselecting restores normal routing. On iOS,
  selection is `setPreferredInput` on the shared session.
- Effective-source changes are reported (deduped per recording episode) on
  `onAudioSourceSwitched` with the kind, the previous kind, a device name
  when available, and the reason.

**Disabling the ladder:** pass `routeSwitchingEnabled: false` to
`initialize`, or call `setRouteSwitchingEnabled(false)` at any time — routing
is then left entirely to the OS (device changes are still observed and
logged, and observed source changes are still reported), and Android's normal
Bluetooth behavior is restored. Persisting the user's choice is the app's job;
`isRouteSwitchingEnabled` reads the current value.

## Metering, duration and auto-stop

### Loudness — `onAmplitude` / `amplitude`

- `onAmplitude` emits live loudness in dBFS while audio flows, throttled to
  at most one event per `MicRecorderConfig.amplitudeInterval` (100 ms by
  default); the `amplitude` getter always holds the freshest per-chunk
  reading, unthrottled.
- `MicAmplitude` carries `currentDbfs` (the most recent chunk),
  `averageDbfs` (mean since the recording started) and `peakDbfs` (loudest
  since the recording started), clamped to `[-120.0, 0.0]` — digital silence
  reads `MicAmplitude.silenceDbfs` (`-120.0`; `isSilent` reports it).
- The values are computed from the same PCM chunks that feed the stream and
  the output files — no extra capture pass.

### The recording clock — `onDurationChanged` / `elapsedDuration`

- `onDurationChanged` emits `Duration.zero` on `start`, ticks the active
  capture duration while recording, and finishes with the episode's exact
  total on `stop`.
- **Paused spans never count** — the clock only advances while capture is
  live, and the pause transition banks the elapsed active span.
- Ticks arrive with the audio (throttled to ~200 ms): the recorder has no
  wall-clock timer, so a frozen capture pipeline stops the clock instead of
  lying about it.
- `elapsedDuration` reads the always-current value — null before the first
  `start`, frozen at the episode's final duration after `stop`, cleared by
  `cancel`. `recordingStartedAt` anchors the episode in UTC.

### Auto-stop — `maxDuration`

- `MicRecorderConfig.maxDuration` stops the recording automatically once
  that much **active** capture time has elapsed — a paused recording never
  burns its budget.
- The auto-stop runs with `MicRecordingStopReason.maxDurationReached`, so it
  surfaces in the returned `MicRecordingInfo.stopReason`, in
  `lastRecordingInfo`, and on `onStateChange` (the usual stopped
  transition).

## Limitations & scope

- **Mono by design.** Capture is 16-bit mono PCM: Bluetooth HFP capture is
  mono, and voice/speech — the plugin's domain — never needs more. Stereo
  and multi-channel recording are intentionally out of scope (the encoded
  outputs mirror the same single channel).
- **Android and iOS only** — no web/desktop support; the routing ladder and
  session handling are inherently platform-audio APIs.
- **Best-effort Android effects** — the echo canceler, noise suppressor and
  automatic gain control attach only when the device provides them; iOS
  governs these through the audio session mode instead.
- **Opus needs Android 10+**; AMR-NB requires 8 kHz capture and AMR-WB
  16 kHz (see the encoder table above).

## API reference

All types are exported by `package:mic_recorder/mic_recorder.dart`.

### `MicRecorder` — the recorder singleton

| Member | Description |
|---|---|
| `instance` | The shared recorder instance. |
| `initialize(MicRecorderConfig config)` | Configure before the first start; call again while stopped to reconfigure (throws `StateError` while recording). |
| `config` | The active `MicRecorderConfig`. |
| `sampleRate` | Capture sample rate in Hz. |
| `bitDepth` | Always 16. |
| `isInitialized` | Whether `initialize` ran with an explicit configuration. |
| `start({MicRecordingMode mode})` | Start a recording episode; returns `false` (state → `error`) when native capture could not start. |
| `pause()` | Pause: capture tears down until `resume()` or an interruption end. |
| `resume()` | Resume a paused recording; `false` when a call holds the mic or the native resume failed. |
| `stop({MicRecordingStopReason reason})` | Stop the episode: finalize the outputs, stop buffering, tear the session down, remove the FGS notification — and return its `MicRecordingInfo` (null when not active). `reason` flows into the info's `stopReason`. |
| `cancel()` | Stop like `stop()` but discard every output file the episode produced (encoded and Dart-written) — the recording is thrown away. |
| `audioStream` | Raw PCM stream (`Stream<List<int>>`, 16-bit little-endian mono). |
| `onStateChange` | `MicRecorderState` transitions (`stopped` initially). |
| `currentState` | Current `MicRecorderState`. |
| `onAudioInterruption` | Rich begin/end interruption events (`MicAudioInterruption`). |
| `onAudioSourceSwitched` | Effective mic source change events. |
| `onConversationSilence` | One `MicConversationSilenceEvent` per completed 5-minute quiet window (conversation mode only). |
| `onMicrophoneLost` | The mic went away while backgrounded and needs the user. |
| `onAmplitude` | Live loudness (`Stream<MicAmplitude>`, dBFS) while audio flows, throttled to `amplitudeInterval`. |
| `amplitude` | The most recent loudness reading (null before audio flows). |
| `onDurationChanged` | The live episode clock (`Stream<Duration>`): active capture duration, zero on start, exact total on stop. |
| `elapsedDuration` | How long capture has been live — paused spans excluded (null before the first start, frozen after stop, cleared by cancel). |
| `recordingStartedAt` | When the current (or most recently completed) episode started, UTC (null before the first start and after cancel). |
| `lastRecordingInfo` | The most recently completed episode's result (see `stop`); an armed `maxDuration` auto-stop lands here. |
| `mode` | `MicRecordingMode` of the current episode. |
| `isRouteSwitchingEnabled` | Whether the priority ladder steers capture. |
| `setRouteSwitchingEnabled(bool)` | Enable/disable the ladder at runtime (persisting is the app's job). |
| `startAudioBuffering()` | Buffer all captured audio in RAM (implicitly starts recording). Returns `true` when buffering is live. |
| `stopAudioBuffering()` | Stop buffering and return the buffered audio. |
| `drainBufferedAudio()` | Atomically read-and-clear the RAM buffer without stopping buffering. |
| `voiceCommandAudio` | The most recent voice-command audio tail (up to 10 s). |
| `emitInitialAudio()` | Re-emit the conversation-creation window (RAM buffer + voice tail) onto `audioStream` for late subscribers; clears the voice buffer. |
| `bufferingStartedAt` | UTC instant the current buffering episode began. |
| `setOutputFile(path, {deleteExistingFile = true, format = MicRecordingFileFormat.pcm16})` | Arm streaming file output — raw PCM or a WAV container; roll by calling again with a new path. |
| `outputFile` | The file audio is currently written to (null when none). |
| `outputFileFormat` | The format the last `setOutputFile` armed (null when none). |
| `clearOutputFile()` | Flush and stop file output; the stream keeps flowing. |
| `setEncodedOutput(path, {required encoder, bitRate})` | Arm native encoded file output (`MicAudioEncoder`); throws `StateError` / `UnsupportedError` as documented above. |
| `encodedOutputFile` | The armed encoded output file (null when none is armed). |
| `clearEncodedOutput()` | Disarm the encoded output and delete the partial file; the recording keeps going. |
| `checkMicrophonePermission()` | Whether the microphone permission is currently granted. |
| `requestMicrophonePermission()` | Request the microphone permission; resolves with the grant. |
| `extractAmplitudes({required filePath, barCount = 60})` | Decode a file into `barCount` normalized (0.1–1.0) RMS bars; `null` on failure. |
| `getRouteState()` | Native route diagnostics (Android only; null elsewhere/on failure). |
| `isOtherAudioPlaying()` | Another app's audio is playing (music, or a call holding the mic). |
| `isAndroidMicHeldByCall()` | A POTS/VoIP call currently holds the microphone (Android only). |
| `dispose()` | Tear the recorder down completely (engine detach / hot restart). Terminal — streams do not revive. |

### Configuration

| `MicRecorderConfig` | Description |
|---|---|
| `sampleRate` | Capture rate in Hz (default 16000). |
| `audioSession` | `MicAudioSessionConfig` for the shared audio session. |
| `androidForegroundService` | `MicForegroundServiceConfig` for the Android notification. |
| `routeSwitchingEnabled` | Whether the input priority ladder runs (default `true`). |
| `amplitudeInterval` | Minimum spacing between `onAmplitude` emissions (default 100 ms; per-chunk readings still update `amplitude`). |
| `androidEchoCancel` | Enable the platform echo canceler for Android capture (best effort; ignored on iOS). |
| `androidNoiseSuppress` | Enable the platform noise suppressor for Android capture (best effort; ignored on iOS). |
| `androidAutoGain` | Enable the platform automatic gain control for Android capture (best effort; ignored on iOS). |
| `maxDuration` | Auto-stop after this much active capture time (paused spans excluded); null (default) means unlimited. |
| `log` | Optional `MicLogSink` for verbose tracing (opt-in). |

| `MicAudioSessionConfig` | Description |
|---|---|
| `allowBluetooth` | Allow Bluetooth HFP input (iOS category option; default `true`). |
| `defaultToSpeaker` | Route output to the speaker by default (default `true`). |
| `notifyOthersOnDeactivation` | Notify other audio sessions on deactivation (default `true`). |
| `androidWillPauseWhenDucked` | Pause (rather than duck) when another app can-duck wins focus (default `true`). |

| `MicForegroundServiceConfig` | Description |
|---|---|
| `enabled` | Run the Android microphone foreground service at all. |
| `channelName` | Notification channel name (default `Recording`). |
| `channelDescription` | Notification channel description (default `Microphone recording status`). |
| `icon` | Optional small-icon resource name; falls back to the bundled mic icon. |
| `titleWhenRecording` | Notification title while recording (conversation mode). |
| `titleWhenPaused` | Title while paused. |
| `titleWhenInterrupted` | Title while an interruption is in effect. |
| `titleWhenListening` | Title while recording in voice-command mode. |

### States, modes & models

| Type | Description |
|---|---|
| `MicRecorderState` | `stopped`, `recording`, `paused`, `error`; flags `isActive` (recording or paused) and `isRecording`. |
| `MicRecordingMode` | `conversation` (silence detection armed) or `voiceCommand` (continuous listening, rolling 10 s tail). |
| `MicAudioInterruption` | An interruption event: `begin` (bool) and `type` (`MicAudioInterruptionType`). |
| `MicAudioInterruptionType` | `unknown`, `pause`, `duck`. |
| `MicAudioSourceSwitchedEvent` | `sourceKind`, `previousSourceKind`, `sourceName`, `reason`, `switchingEnabled`. |
| `MicAudioSourceKind` | `usbWired`, `bluetooth`, `defaultMicrophone`, `systemDefault` (+ `wireName`). |
| `MicConversationSilenceEvent` | `startedAtUtc`, `duration`, `lastRms`, `silenceThreshold`, `bytesCapturedSinceStart`, `buffersCapturedSinceStart`, `silenceRecoveryAttempts`, `routeState`. |
| `MicMicrophoneLostEvent` | `reason` — why the mic went away. |
| `MicAudioDevice` | A device: `id`, `name`, `type`, `isInput`, `isOutput`; static decoders `fromAndroidType` / `fromIosPortType`. |
| `MicAudioDeviceType` | Device classification: `usbAudio`, `wiredHeadset`, `lineAnalog`, `lineDigital`, `carAudio`, `bluetoothSco`, `bluetoothLe`, `bluetoothA2dp`, `builtInMic`, `builtInSpeaker`, `unknown`. |
| `MicAudioInput` | An iOS input port: `uid`, `portType`, `portName`. |
| `MicAudioRoute` | An iOS route snapshot: `inputs`, `outputs`. |
| `MicRecordingFileFormat` | `setOutputFile` containers: `pcm16` (headerless 16-bit LE mono PCM) or `wav` (RIFF/WAVE, canonical 44-byte header). |
| `MicAudioEncoder` | Encoded output formats for `setEncodedOutput`: `aacLc`, `appleLossless`, `opus`, `flac`, `amrNb`, `amrWb` (see the table above). |
| `MicRecordingInfo` | The result of a completed episode: `startedAtUtc`, `duration`, `sizeBytes`, `sampleRate`, `bitDepth`, `channels`, `stopReason`, `path`, `encoder`, `fileFormat`. |
| `MicRecordingStopReason` | Why an episode ended: `manual` or `maxDurationReached`. |
| `MicAmplitude` | A loudness reading in dBFS: `currentDbfs`, `averageDbfs`, `peakDbfs` (plus `isSilent` and the `silenceDbfs` floor, -120.0). |
| `MicLogSink` / `MicLogLevel` / `defaultMicLog` | Opt-in logging hook, levels (`trace`, `debug`, `warn`, `error`) and the default sink. |

### Advanced: the controllers behind the orchestrator

`MicRecorder` composes two controllers that are also exported for advanced
use:

| Type | Description |
|---|---|
| `MicAudioSessionController` | Audio-session lifecycle: configure/activate, focus & interruption mapping, recovery retries, device snapshots (`devicesStream`), `onMicrophoneLost`, `isOtherAudioPlaying()`, `isAndroidMicHeldByCall()`. |
| `MicRouteController` | The input priority ladder: `prepare`/`start`/`stop`, `setEnabled`, `onAudioSourceSwitched`, the priority type sets (`usbWiredInputTypes`, `bluetoothInputTypes`, …) and its documented timing constants. |

## Example app

The [`example/`](example/) app exercises every public API member, and its
v0.2 demo sections map one-to-one onto the new features:

- a **permissions gate** — check / request the microphone before the first
  start (with the grant state visible in the status card);
- an **encoded output card** — pick an encoder, arm / clear it (and see the
  armed file);
- a **WAV selector** — toggle Dart-side WAV recording per episode;
- a **dBFS meter** — live current / average / peak bars from `onAmplitude`;
- a **duration timer** — the running clock from `onDurationChanged`;
- **maxDuration chips** — arm an auto-stop before starting;
- a **stop-result card** — the last `MicRecordingInfo` (path, duration,
  size, encoder/format, stop reason).

The older sections (live PCM streaming with a per-chunk meter, RAM buffering
and voice-command flows, routing & diagnostics, the event log and the
configuration screen) remain — see the example's own README for the
per-API matrix and the permission snippets.

## Troubleshooting / FAQ

**`start()` returned `false` / state is `error`.**
Most commonly the microphone permission was never granted (Android
`RECORD_AUDIO`, or the iOS app lacks `NSMicrophoneUsageDescription`) — call
`requestMicrophonePermission()` first. On Android, another app holding the
microphone (or a call) produces the same result.

**The recording works but I see no notification on Android 13+.**
Grant `POST_NOTIFICATIONS` at runtime — the host app's job. Recording
continues safely either way.

**Android 14: the foreground service did not start.**
The microphone FGS must start while-in-use. `MicRecorder.start()` itself
refuses to start while backgrounded, so this appears only if you bypass it —
start the recording from the foreground.

**`resume()` returns `false`.**
A call is holding the microphone (`isAndroidMicHeldByCall()` is `true`) or
the native resume failed; the retry stays armed and reconciles on the next
foreground transition or live audio. Check `isOtherAudioPlaying()`.

**`extractAmplitudes` returns `null` for my file.**
The native decoders need a real container (WAV, M4A, …). Record with
`format: MicRecordingFileFormat.wav`, or arm an encoded output — raw `pcm16`
output stays headerless by design.

**`setEncodedOutput` threw a `StateError` / `UnsupportedError`.**
A `StateError` means another encoded output is still armed (clear it with
`clearEncodedOutput()`), the encoder's rate requirement is unmet (`amrNb`
needs `sampleRate: 8000`, `amrWb` 16000), or the platform rejected the arm.
An `UnsupportedError` means the encoder does not exist on this platform (see
the encoder table — e.g. `appleLossless` is iOS-only, `opus`/`flac`/`amr*`
are Android-only).

**Recording pauses by itself.**
That is an interruption (audio focus loss on Android, an AVAudioSession
interruption on iOS — e.g. a phone call or an assistant). Capture
auto-resumes when the interruption ends; see
[Interruption handling](#interruption-handling).

**My Bluetooth headset is not used.**
Check the ladder: a USB/wired mic outranks Bluetooth; `allowBluetooth: false`
disables HFP input; and the headset must support HFP (an A2DP-only headset
has no microphone). Toggle `routeSwitchingEnabled` if you want the OS to
decide.

**Recording stops when the app goes to background (iOS).**
Add `UIBackgroundModes` → `audio` to the app's `Info.plist`.

**I get silence alarms while the user is just quiet.**
The silence machinery only rebuilds the capture stack after 30 s of digital
silence and paces recovery attempts — human breathing typically sits above
the RMS threshold. Voice-command mode never fires silence alarms by design.

**How do I know the recording auto-stopped at `maxDuration`?**
The auto-stop is reported through the same channels as a manual one: the
episode's `MicRecordingInfo.stopReason` is
`MicRecordingStopReason.maxDurationReached`, `lastRecordingInfo` holds it,
and `onStateChange` emits the usual `stopped` transition.

**Where are the PCM headers?**
The stream is raw 16-bit LE mono PCM — bytes-per-second is `sampleRate * 2`.
For files, arm the WAV container (`setOutputFile(format:
MicRecordingFileFormat.wav)`) or an encoded output; only raw `pcm16` output
is headerless.

## License

[MIT](LICENSE) — Copyright © 2026 Bilal Uddin Ahmed.
