# mic_recorder — architecture

Engineering reference for how the plugin is put together, and why. Start-up
usage is covered by the [README](../README.md); this document is for
maintainers and reviewers.

## Table of contents

1. [Layer map](#1-layer-map)
2. [Design decisions](#2-design-decisions)
   - [2.1 Why the audio-session layer is implemented natively](#21-why-the-audio-session-layer-is-implemented-natively)
   - [2.2 Why Pigeon was dropped](#22-why-pigeon-was-dropped)
   - [2.3 Why rxdart was dropped](#23-why-rxdart-was-dropped)
3. [Wire protocol](#3-wire-protocol)
4. [Threading models](#4-threading-models)
5. [Recorder state machine](#5-recorder-state-machine)
6. [Route priority ladder and watchdogs](#6-route-priority-ladder-and-watchdogs)
7. [Android foreground-service lifecycle](#7-android-foreground-service-lifecycle)
8. [File output and encoded output](#8-file-output-and-encoded-output)
9. [Duration, amplitude and the episode clock](#9-duration-amplitude-and-the-episode-clock)
10. [Testing strategy](#10-testing-strategy)
11. [Limitations](#11-limitations)

## 1. Layer map

```
                          Host application
                                 │  package:mic_recorder
                                 ▼
┌────────────────────────────────────────────────────────────────────┐
│  Dart — lib/src/mic_recorder.dart                                 │
│                                                                    │
│  MicRecorder (singleton orchestrator)                              │
│    • recording episodes: start/pause/resume/stop/cancel           │
│    • state machine + interruption auto-pause/auto-resume           │
│    • audioStream fan-out: listeners, RAM buffer, PCM/WAV writer  │
│    • episode clock + dBFS metering + max-duration auto-stop      │
│    • silence / conversation-silence / audio-health monitoring      │
│    • voice-command rolling buffer (10 s tail, 5 min trim)          │
│                                                                    │
│  composes (built by initialize(), owned per config):              │
│  ┌──────────────────────────────────────────────────────────────┐ │
│  │ MicAudioSessionController   (session/mic_audio_session_…dart)│ │
│  │   configure/activate, focus+interruption mapping, retries,   │ │
│  │   devicesStream snapshots, onMicrophoneLost, diagnostics      │ │
│  ├──────────────────────────────────────────────────────────────┤ │
│  │ MicRouteController          (route/mic_route_controller.dart) │ │
│  │   input priority ladder, device-change re-evaluation,        │ │
│  │   settle/foreground re-asserts, source-switch events          │ │
│  └──────────────────────────────────────────────────────────────┘ │
│  internal: AppLifecycleTracker (WidgetsBindingObserver),          │
│            MicLogSink logging, SeededStream/takeUntil streams     │
│                                                                    │
│  MicRecorderPlatform (platform/mic_recorder_platform.dart)         │
│    ▲ PlatformInterface.verify(token)                               │
│  MethodChannelMicRecorder (platform/method_channel_mic_recorder)   │
└───────────────────────────────┬────────────────────────────────────┘
                                │
          MethodChannel  com.bilalahmed24.mic_recorder/methods
          EventChannel   com.bilalahmed24.mic_recorder/audio_stream
          EventChannel   com.bilalahmed24.mic_recorder/session_events
                                │
              ┌─────────────────┴──────────────────┐
              ▼                                    ▼
┌──────────────────────────────┐   ┌──────────────────────────────────┐
│ Android (Java)              │   │ iOS (Swift)                      │
│ android/src/main/java/…     │   │ ios/mic_recorder/Sources/…       │
│                              │   │                                   │
│ MicRecorderPlugin.java       │   │ MicRecorderPlugin.swift           │
│  channel dispatch, FGS       │   │  channel dispatch, sinks          │
│  pending-result protocol     │   │                                   │
│ ├ MicAudioRecorder.java       │   │ ├ MicAudioService.swift           │
│ │  AudioRecord engine, SCO,   │   │ │  AVAudioEngine tap, converter,  │
│ │  rebuild watchdogs, effects │   │ │  handoffs, route watchdogs      │
│ ├ MicAudioEncoder.java        │   │ ├ MicAudioFileWriter.swift        │
│ │  MediaCodec/MediaMuxer or   │   │ │  AVAudioFile AAC/Apple Lossless  │
│ │  raw-stream encoders        │   │ │  encoded-output writer           │
│ ├ MicAudioSession.java        │   │ ├ MicAudioSessionCore.swift       │
│ │  focus + device callbacks   │   │ │  AVAudioSession category/active,│
│ │  (AudioManager focus)       │   │ │  interruption/route observers   │
│ └ MicForegroundService.java   │   │ └ (SwiftPM Package.swift + podspec│
│    microphone-type FGS        │   │    + PrivacyInfo.xcprivacy)       │
└──────────────────────────────┘   └──────────────────────────────────┘
```

The Dart layer is platform-agnostic: every platform-specific verb is gated
behind `Platform.isAndroid` / `Platform.isIOS` (`micIsAndroid` /
`micIsIOS`), so the native sides never see a verb they cannot answer (the
iOS side still replies `FlutterMethodNotImplemented` for the Android-only
verbs as a backstop, and Android replies benign values for the iOS-only
ones).

## 2. Design decisions

### 2.1 Why the audio-session layer is implemented natively

> Design decision: **the audio-session layer is implemented natively
> inside the plugin, directly against the platform audio APIs — no
> audio-session dependency.**

A recorder needs a small, well-understood slice of audio-session
behavior: hold audio focus while capturing, learn about competing audio,
follow interruptions, and list and choose inputs. A general-purpose
session abstraction would drag that dependency into every consumer's
tree for the sake of that slice — and the plugin's
zero-Dart-dependency goal (`flutter` + `plugin_platform_interface`
only) rules it out. The layer is therefore written directly against the
platform APIs:

**Android — `MicAudioSession.java` (on `AudioManager`):**

- Audio-focus request/abandon with `usage = voiceCommunication`,
  `contentType = speech`, `audibilityEnforced`, and
  `gainTransientExclusive` (API 26+ `AudioFocusRequest.Builder`; legacy
  `STREAM_VOICE_CALL` request on API 24/25), with
  `androidWillPauseWhenDucked` from the config;
- focus loss auto-abandons the request and forwards the raw code to Dart as
  `{event: audioFocusChanged, focus: <int>}`;
- `AudioDeviceCallback` → `{event: devicesChanged, added: [...],
  removed: [...]}`;
- `isMusicActive()`, `getMode()`, `isOtherAudioPlaying()` (Android mapping:
  `isMusicActive`), input device listing (`GET_DEVICES_INPUTS`);
- deliberately omitted: the noisy-audio and SCO-state receivers — the
  capture engine already tracks the SCO link itself, so a second
  registration would only duplicate broadcasts.

**iOS — `MicAudioSessionCore.swift` (on `AVAudioSession`):**

- `configureAudioSession`: `setCategory(.playAndRecord, .default,
  [HFP-option, .defaultToSpeaker])` per config keys
  (`willPauseWhenDucked` is Android-only and ignored). The HFP option is
  spelled `.allowBluetoothHFP` on the Xcode 26 SDK and the (deprecated,
  bit-identical) `.allowBluetooth` on older SDKs — a compile-time
  `#if compiler(>=6.2)` split so the plugin builds on every supported
  Xcode;
- `setAudioSessionActive(active)` — applies the stored
  `notifyOthersOnDeactivation` option;
- `isOtherAudioPlaying`, `setAllowHapticsAndSystemSoundsDuringRecording`
  (merged into the live `categoryOptions`, preserving category/mode);
- `getAvailableInputs` / `getCurrentRoute` / `setPreferredInput` as
  `{uid, portType, portName}` maps;
- interruption observer → `{event: interruption, type: 0|1, shouldResume,
  wasSuspended?}` and route-change observer →
  `{event: routeChange, reason: <int rawValue>}`, installed at init on the
  main queue and kept across sink clears.

**Dart-side semantics** (`MicAudioSessionController`) implement
recording-specific recovery on top of that native layer: the
Android focus → interruption mapping table (below), activation-failure →
teardown + 5 s retry, unknown-interruption handling with the hard-reset
path, iOS background write deferral, and the microphone-lost event.

### 2.2 Why Pigeon was dropped

A Phase-0 note considered Pigeon (29.0.10) for a typed command surface. It
was dropped deliberately:

- **Pigeon has no EventChannel support** — the raw PCM stream would have
  stayed on a hand-rolled `EventChannel` anyway, splitting the protocol
  across two mechanisms.
- **The wire protocol is the contract.** The verb semantics (names,
  argument keys, reply shapes) are frozen and pinned by tests — a
  hand-rolled `MethodChannel` maps directly onto that contract with zero
  translation layer.
- **Zero codegen.** No pigeon dependency, no generated files, no
  generation step in the dev loop; Java stays a first-class citizen
  (Pigeon's generated Java would fight the Java-only Android decision).

The wire contract is therefore frozen and tested: the method-channel test
suite pins every verb, argument map and reply shape (see
[§3](#3-wire-protocol)).

### 2.3 Why rxdart was dropped

Seeded state (current value replayed to late subscribers) and episode-
scoped stream termination (`takeUntil`) compose trivially on plain
`StreamController`s:

- `SeededStream<T>` — a broadcast controller that seeds the current value
  to new listeners (state, interruption, device snapshots);
- a small `takeUntil` helper — episode-scoped termination
  (`stream.takeUntil(episode)`) on standard streams;
- explicit broadcast controllers for event fan-out.

Result: no `rxdart` dependency, identical observable semantics, and fewer
moving parts under `fake_async` in tests (see [§10](#10-testing-strategy)).

## 3. Wire protocol

Three channels, all namespaced `com.bilalahmed24.mic_recorder`:

| Channel | Kind | Payload |
|---|---|---|
| `…/methods` | `MethodChannel` | verbs below |
| `…/audio_stream` | `EventChannel` | raw PCM `Uint8List`/`byte[]` chunks (16-bit LE mono) |
| `…/session_events` | `EventChannel` | session/route/interruption maps (below) |

### 3.1 Method verbs

Arguments are single-level maps; `?` marks optional keys (omitted when
null). Replies are the stated scalar/list/map, or `FlutterError` on failure
(verb-specific codes; unmapped verbs reply `FlutterMethodNotImplemented`).

| Verb | Arguments | Reply | Platform |
|---|---|---|---|
| `startRecording` | `{sampleRate: int, echoCancel: bool, noiseSuppress: bool, autoGain: bool}` | `bool` | both |
| `pauseRecording` | `{isPausedForInterruption: bool}` | `bool` | both |
| `resumeRecording` | — | `bool` | both |
| `stopRecording` | — | `bool` | both |
| `setEncodedOutput` | `{path: String, encoder: String, bitRate?: int, sampleRate?: int}` | `bool` | both |
| `clearEncodedOutput` | — | `bool` | both |
| `checkMicPermission` | — | `bool` | both |
| `requestMicPermission` | — | `bool` | both |
| `microphoneInterrupted` | — | `bool` | iOS (Android: benign `false`) |
| `setBluetoothStatus` | `{isAllowed: bool}` | `void` | Android |
| `getRouteState` | — | map (below) / `null` | Android |
| `extractAmplitudes` | `{filePath: String, barCount: int}` | `List<num>` (0.1–1.0) / `null` | both |
| `configureAudioSession` | `{config: {allowBluetooth, defaultToSpeaker, notifyOthersOnDeactivation, willPauseWhenDucked: bool}}` | `bool` | both |
| `setAudioSessionActive` | `{active: bool}` | `bool` | both |
| `isOtherAudioPlaying` | — | `bool` | both |
| `isMusicActive` | — | `bool` | Android |
| `getAudioMode` | — | `int` | Android |
| `setAllowHapticsAndSystemSoundsDuringRecording` | `{enabled: bool}` | `void` | iOS |
| `getAudioDevices` | — | `List<{id, name, type, isSource, isSink}>` | Android |
| `getAvailableInputs` | — | `List<{uid, portType, portName}>` | iOS |
| `getCurrentRoute` | — | `{inputs: [{uid, portType, portName}], outputs: […]}` | iOS |
| `setPreferredInput` | `{uid: String}` | `bool` | iOS |
| `showForegroundNotification` | `{notificationTitle: String, channelName?, channelDescription?, icon?}` | `bool` | Android |
| `removeForegroundNotification` | — | `bool` | Android |

Notes:

- `startRecording`'s four keys are always sent by Dart (the effect toggles
  default `false`); iOS accepts and ignores the Android-only toggles.
- `setEncodedOutput`'s `encoder` is the Dart enum's wire name (`aacLc`,
  `appleLossless`, `opus`, `flac`, `amrNb`, `amrWb`); `bitRate` only applies
  to the lossy encoders. Dart always sends the configured capture rate as
  `sampleRate` — the natives fall back to their tracked last-started rate
  only for foreign callers, so arming before the first start works at
  non-default rates. An unavailable encoder (wrong platform, missing
  container support, AMR rate mismatch) replies `false`; Dart raises a
  `StateError`. Android's `requestMicPermission` short-circuits `true` when
  already granted and `false` on a headless engine (no activity to host the
  dialog), and completes any stale pending result with `false` before
  posting a new one.
- `pauseRecording == stopRecording` natively on Android (full teardown;
  resume = fresh start with the last sample rate); the distinction is
  Android-side bookkeeping only. On iOS `pause(true)` (interruption) is a
  flag while `pause(false)`/`stopRecording` is a teardown. The pause verbs
  deliberately never finalize the armed encoded output — only `stopRecording`
  does (see [§8](#8-file-output-and-encoded-output)).
- `getRouteState()` reply map (Android diagnostics):
  `scoConnected`, `scoState`, `bluetoothAllowed`, `isRecording`,
  `musicActive`, `bluetoothHeadsetConnected`, `scoRequestStoodDown`,
  `silentMs`, `silenceRebuilds`, plus `routedDeviceType` (null when the ROM
  reports no routed device).
- Dart's `getAudioDevices()` composes the iOS snapshot from
  `getCurrentRoute` + `getAvailableInputs` (route outputs with an
  input-listed uid upgrade to a headset device) and only falls back to the
  Android `getAudioDevices` verb when the route reply is null.
- The FGS verbs use a pending-result + request-id broadcast + 5 s timeout
  protocol on the Android side (see [§7](#7-android-foreground-service-lifecycle)).

### 3.2 Event payload shapes

`audio_stream` — raw bytes, nothing else. Chunk boundaries are engine
buffers, not frame guarantees.

`session_events` — a single map per event, discriminated by `event`:

```jsonc
// Android — raw AudioManager focus code (e.g. -1 loss, -2 lossTransient,
// -3 lossTransientCanDuck, +1 gain)
{"event": "audioFocusChanged", "focus": -1}

// Android — device list diff
{"event": "devicesChanged",
 "added":   [{"id": 11, "name": "USB mic", "type": 11, "isSource": true, "isSink": false}],
 "removed": [...]}

// iOS — type 0 = began, 1 = ended; wasSuspended omitted when unreported
{"event": "interruption", "type": 0, "shouldResume": false, "wasSuspended": false}
{"event": "interruption", "type": 1, "shouldResume": true}

// iOS — raw AVAudioSession.RouteChangeReason rawValue
{"event": "routeChange", "reason": 2}
```

Dart decodes these defensively (missing keys → zero/empty) into the sealed
`MicSessionEvent` family: `MicAndroidAudioFocusChanged`,
`MicAndroidDevicesChanged`, `MicIosInterruptionNotification`,
`MicIosRouteChange`. Unknown event names decode to a zero-reason
`MicIosRouteChange` rather than throwing.

## 4. Threading models

### Android

- **Main thread** — all channel dispatch, the focus/session verbs, the FGS
  lifecycle, the route-transition watchdog (`routeWatchdogHandler` on the
  main `Looper`), and the SCO/A2DP broadcasts. Audio chunks are *copied*
  per chunk and posted to the main thread before hitting the event sink
  (posting the shared read buffer corrupted audio whenever the platform
  thread lagged).
- **Capture thread** — one `RecordingThread` (`MicRecorder-Capture`) runs a
  non-blocking `AudioRecord.read` loop with partial-buffer accumulation.
  All `AudioRecord` re-creations happen **on the capture thread**: the
  rebuild is requested by setting `rebuildRequested`, and the loop performs
  it between reads (rebuilding from a receiver thread would deadlock on
  `recordingThread.join()` inside `stopRecording`). `stopRecording()`
  interrupts + joins the thread.
- **Engagement threads** — the in-place Bluetooth engagement
  (`MicRecorder-BtEngage`) drives the route to its target beside the
  running capture; amplitude extraction decodes on `MicRecorder-Amplitudes`
  and replies on main.
- **Cross-thread state** — `routeEpoch`/`recorderEpoch` echo guards,
  `btEngageInFlight`, `routedInputVanished`, `captureReadSince` are
  `volatile`/`Atomic*` fields written by the receivers/watchdogs and read
  by the capture loop.

### iOS

- **Main thread** — channel dispatch, the session-core verbs, observers
  (installed at init, `queue: .main`), and all replies.
- **Render path** — the `AVAudioEngine` input tap feeds an
  `AVAudioConverter` (16-bit mono at the requested rate) under a converter
  lock and a tap-liveness lock; converted buffers are forwarded to the
  event sink. Engine rebuilds/handoffs use a generation counter and
  retire-before-rebuild so a dying tap never outlives its engine.
- **Queued work** — `extractAmplitudes` decodes on a global queue and
  replies on main.

## 5. Recorder state machine

`MicRecorderState` is a four-state enum with two convenience flags
(`isActive` = recording or paused; `isRecording` = recording):

```
                 initialize()                    start() → true
   stopped ────────────────────────► stopped ───────────────► recording
                                            ▲   ▲                  │ ▲
                    start() → false          │   │        pause()   │ │ resume() → true
                            └────────────► error │   interruption  │ │ interruption end
                                                 │     begin      │ │ (recovered)
                                                 │   ┌────────────┘ │
                                                 │   │  resume() → false keeps paused
                                                 ▼   ▼                │
                                              paused ◄────── (retry stays armed)
                            stop()              │
   stopped ◄───────────────────────── recording/paused
```

On top of the enum sit the flags that make interruption recovery work:

| Flag | Meaning |
|---|---|
| `_isPausedForInterruption` | The current pause was caused by an interruption — only such pauses auto-resume. Cleared by a manual resume or stop; re-armed when an auto-resume attempt fails so the next foreground/live-audio event retries. |
| `_isInitiated` | The lifecycle priming has happened once (first start waits for `AppLifecycleState.resumed`). |
| `session.isInterruptionActive` / `isRecoveringFromInterruption` | Rich interruption state shared with the route ladder's write gates. |
| `_isRecoveringFromSilence` | A foreground capture-stack recovery is in flight (paced, one attempt per 60 s while silence continues). |

The pause/resume *semantics* are platform-shaped: Android pause is a full
native teardown (resume = fresh start), iOS interruption-pause keeps the
engine flagged and paused-for-interruption. The Dart API presents a uniform
pause/resume; the orchestrator reconciles state via the live-audio
reconcile timer (100 ms) when native recovery outruns Dart's bookkeeping.

The `maxDuration` auto-stop (see [§9](#9-duration-amplitude-and-the-episode-clock))
enters through the same `stop()` path, and `_finishEpisode`'s re-entry
guard makes a concurrent manual/dispose stop benign — the first stop owns
the episode.

## 6. Route priority ladder and watchdogs

### Ladder (Dart, `MicRouteController`)

Priority **USB/wired → Bluetooth → built-in**; applied at `prepare()`
(before the native recorder opens, so the first buffer already comes from
the priority input), re-applied at `start()`, and re-evaluated on every
device-list change (serialized; only the latest pending snapshot is
evaluated). Timed re-asserts: 3 s settle re-assert after start, 300 ms
foreground re-assert after resume. iOS input writes are gated while the
route is torn down or an interruption window is active (5 s cooldown after
the last interruption; deferred decisions retry on a 2 s repay timer).

- iOS rung membership: `USBAudio`/`HeadsetMic`/`LineIn`/`CarAudio` →
  `BluetoothHFP`/`BluetoothLE` → `BuiltInMic`; selection =
  `setPreferredInput(uid)`.
- Android rung membership: `usbAudio`/`wiredHeadset`/`lineAnalog`/
  `lineDigital`/`carAudio` → `bluetoothSco`/`bluetoothLe` → `builtInMic`;
  selection = the `setBluetoothStatus` SCO gate (any listed Bluetooth
  device, including A2DP, counts as a headset-connected signal because it
  appears before the SCO input does).
- With the ladder disabled, device changes are still observed/logged and
  observed source changes are still emitted (`onAudioSourceSwitched`,
  deduped per recording episode); disabling restores Android's normal
  Bluetooth behavior.

### Native watchdogs

Android (`MicAudioRecorder.java`) — all budgets reset on a successful
(re)start:

| Watchdog | Threshold | Budget |
|---|---|---|
| Digital silence (peak ≤ 12 int16) | 15 s cumulative | 4 quick rebuilds, then one per 60 s for as long as silence continues |
| Route transitions (device change / SCO / A2DP, debounced 600 ms) | — | 8 rebuilds per episode |
| Capture read stall (a read older than 1 s) | unblocks via `stop()` | 4 forced rebuilds |
| Routed-input vanished (removal of the routed/pinned input) | immediate corpse detection | shares the route budget |
| SCO cleanup (communication-device clear sticks) | — | 3 attempts, then stands down |
| SCO readiness | classic SCO socket wait 2 s; LE-listed grace 400 ms; post-connect settle 250 ms | — |

iOS (`MicAudioService.swift`):

| Mechanism | Timing |
|---|---|
| Route watchdog (engine route sanity) | 2 s cadence |
| Route-settle debounce | 0.4 s, capped at 2 s |
| Live engine handoff | retire-before-rebuild with a generation counter; `noteHandoffFailure` restore path |
| Engine recreation retry | 0.7 s |
| Foreground recreation | 0.4 s after resume |
| Silent-buffer zombie detection | peak ≤ 12 for 20 s |
| Background rebuild refusal | OS error codes `560557684` (`!int`) and `2003329396` (`what`) are treated as "try again later", not failures |

Dart-side silence machinery complements the native one: RMS-based silence
classification (threshold 0.004), a 30 s alarm, 60 s-paced foreground
capture-stack recovery (`pause → resetService → init → resume` through the
existing verbs), a 2-minute health heartbeat, and one conversation-silence
event per completed 5-minute quiet window (conversation mode only;
voice-command silence is expected and never alarms).

## 7. Android foreground-service lifecycle

`MicForegroundService` is a microphone-type foreground service
(`foregroundServiceType="microphone"`, `START_NOT_STICKY`,
`startForeground(..., FOREGROUND_SERVICE_TYPE_MICROPHONE)` on API 30+,
2-arg overload below; guarded `startForegroundService` below API 26). Its
lifecycle is **recording-session-scoped** (the recorder stops the FGS when
the episode ends):

```
MicRecorder.start()
  └─ showForegroundNotification(titleWhen[Recording|Listening])
       └─ pending result kept until the FGS broadcast reports completion
          (request-id broadcast, 5 s timeout — timeout/pre-emption → false,
          logged, recording continues)
pause()/interruption begin
  └─ title → titleWhenPaused / titleWhenInterrupted   (service keeps running)
resume()/interruption end
  └─ title → titleWhen[Recording|Listening]
MicRecorder.stop()
  └─ removeForegroundNotification() → service stopped
```

- Channel (id `mic_recorder_status`, notification id `450279`) is created
  on the first show of an episode and re-synced from each call's
  `channelName`/`channelDescription` (defaults `Recording` /
  `Microphone recording status`).
- The small icon resolves configured-name → bundled `ic_stat_mic` →
  system fallback; a bad icon name never crashes.
- The notification tap opens the host app's launch intent.
- Rationale (user decision #2 — also in the README): Android 8+ background
  execution limits require ongoing background capture to run as a
  microphone-type FGS with a user-visible notification; Android 14
  requires the `FOREGROUND_SERVICE_MICROPHONE` permission (plugin
  manifest) and a while-in-use start (the recorder's foreground-gated
  `start()` provides it); Android 13+ needs the host app's
  `POST_NOTIFICATIONS` runtime grant for visibility only — recording
  continues safely without it. There is deliberately **no separate
  `setForegroundNotification` method**: the whole notification is declared
  through `MicForegroundServiceConfig` on `initialize`/`start`.

## 8. File output and encoded output

Three output paths can run from one capture: the raw stream (always on),
a Dart-written file and a native encoded file.

### 8.1 Dart file output (`MicOutputFileWriter`)

`setOutputFile` arms a file sink that receives the same chunks the stream
fans out — the tee lives in the `takeUntil(...)` listen in `start()`, so
listeners, RAM buffer and file writer all get every chunk:

- `MicRawPcmFileWriter` — headerless PCM, byte-for-byte the stream.
- `MicWavFileWriter` — a RIFF/WAVE container: the canonical 44-byte
  header (PCM format tag, channel count, sample rate, byte rate, block
  align, bit depth) is written **up front with zero sizes**, and the true
  RIFF size (offset 4) and data size (offset 40) are patched on `close()`
  — so even a hard process death leaves a playable (if mis-sized) file.
  `discard()` closes and deletes — a cancelled recording leaves nothing.

`clearOutputFile()` closes the writer (flush + WAV size patch) while
capture keeps running; arming again rolls to a new file. `stop()` closes
the writer; `cancel()` discards it. The episode's `MicRecordingInfo`
reports the result (the encoded output wins over the Dart-written file,
which wins over stream-only bytes).

### 8.2 Encoded output — Android (`MicAudioEncoder.java`)

One class, two output plumblings, selected by the wire name:

- **Muxer path** (`aacLc`, `opus`): `MediaCodec`
  (`audio/mp4a-latm` / `audio/opus`) into a `MediaMuxer` — MPEG-4 for
  AAC, Ogg for Opus (Android 10+ only; older API levels fail the arm).
  The muxer track is added when the codec's `INFO_OUTPUT_FORMAT_CHANGED`
  surfaces the config data; codec-config buffers are consumed by the
  muxer, never written directly.
- **Raw-stream path** (`flac`, `amrNb`, `amrWb`): a plain
  `FileOutputStream` plus the format's magic bytes. AMR files start with
  `#!AMR\n` / `#!AMR-WB\n` immediately; FLAC's `fLaC` magic is written
  when the codec's `csd-0` (the STREAMINFO metadata block) arrives, so it
  sits adjacent to the stream header as the format requires (AMR's csd
  is a mode list, not file content — nothing to write). AMR-NB rejects
  anything but 8 kHz capture, AMR-WB anything but 16 kHz; FLAC runs
  compression level 5 where the key exists (API 31+).

Feeding and timing:

- `write(byte[])` is called on the main thread from the audio-stream
  sink, under a lock; PCM is queued in input-buffer-sized slices.
- **Presentation timestamps are frame-derived** —
  `framesFed * 1_000_000 / sampleRate`, the instant of the buffer's first
  sample — never wall time. A pause simply stops the chunks, so resumed
  audio continues the timeline exactly where it left off; the pause gap
  spans naturally.
- `finish()` queues end-of-stream, drains to EOS (bounded iterations),
  stops the muxer **only if a sample was ever written** (stopping a
  sample-less muxer throws; release is the safe path), and deletes the
  file when nothing was produced — an empty container is not a playable
  file.
- `abort()` releases without finalizing and deletes the partial file.

### 8.3 Encoded output — iOS (`MicAudioFileWriter.swift`)

`AVAudioFile(forWriting:)` with `AVFormatIDKey` = `kAudioFormatMPEG4AAC`
(bit rate from the wire) or `kAudioFormatAppleLossless` (16-bit PCM
depth key); a pre-existing file is removed first. The writer is fed from
the stream tee on the main queue: each chunk is converted Int16 →
Float32 (`sample / 32768.0`) into the file's `processingFormat` buffer,
because an `AVAudioFile` writes float deinterleaved audio. A failed
write drops that chunk only — capture and the raw stream keep flowing.
`finish()` drops the reference (closing finalizes the M4A); `abort()`
also deletes the file. As on Android, the pause verbs never touch the
writer — only `stopRecording` finishes it.

### 8.4 Arming lifecycle and stop/cancel semantics

- **Armed before or during a recording** — `setEncodedOutput` can be
  called while stopped (the encoder/writer is created immediately) or
  mid-episode (audio from now on; nothing retroactive). One encoded
  output at a time: Dart raises `StateError` on a second arm; the
  natives replace-and-abort a foreign caller's arm.
- **Pause keeps the encoder alive** — both platforms deliberately
  finalize only on the stop verb, so a pause/resume cycle continues the
  same file.
- **Only `stop` finalizes.** Dart's stop path lets the native
  `stopRecording` drain and finalize the encoder. `cancel()` instead
  calls `clearEncodedOutput` *before* the native stop — the engine's
  finish call then finds nothing to finalize — and the Dart-written file
  is discarded as well.
- `clearEncodedOutput()` aborts and deletes the partial file while the
  recording keeps going; an armed-but-idle encoder is also cleared on
  `dispose()` (it would otherwise leak its native codec).

## 9. Duration, amplitude and the episode clock

All Dart-side, all riding the audio chunks — none of it runs a timer of
its own.

### The episode clock

- Entering `recording` stamps `_activeSince`; leaving it
  (pause/stop/error) banks `now - _activeSince` into
  `_accumulatedActiveDuration`. Paused spans therefore never count — not
  in the emitted duration, not in `elapsedDuration`, not against
  `maxDuration`.
- The clock advances **only when chunks arrive**: each chunk stamps
  `DateTime.now()`, and `_updateDuration` emits
  `_accumulatedActiveDuration + now - _activeSince`, throttled to one
  emission per 200 ms. There is no wall-clock timer — a frozen capture
  pipeline stops the clock instead of lying about it. `start()` emits
  `Duration.zero` (a UI timer starts ticking immediately); the stop
  transition banks the final span and emits the exact total as the last
  event.
- `elapsedDuration` computes the same value on demand (null before the
  first start, frozen after stop, cleared by cancel);
  `recordingStartedAt` anchors the episode in UTC.

### maxDuration enforcement

`_checkMaxDuration` runs on the chunk path, right after the duration
update. When the elapsed ACTIVE time reaches
`MicRecorderConfig.maxDuration`, a one-shot guard
(`_maxDurationStopScheduled`, reset per episode) ensures the stop is
scheduled exactly once, the event is logged at debug level
(`maxDurationReached`), and the stop is issued **unawaited** with
`MicRecordingStopReason.maxDurationReached`. Because only active time
counts, a paused recording never burns its budget — no chunk arrives
while paused, so the check never even runs.

### Episode finishing: the re-entry guard

The automatic max-duration stop, a manual `stop()` and a dispose-triggered
stop can race. `_finishEpisode` guards with `_isFinishingEpisode`: the
first caller owns the episode, later callers return `null` immediately, and
the guard is released in `finally` once the episode is fully torn down.

### dBFS metering

Per chunk, RMS is computed over the 16-bit samples (`_computeRms`,
normalized to [-1, 1]) and converted to dBFS (`20 * log10(rms)`,
floored at `MicAmplitude.silenceDbfs` = -120.0 for digital silence).
Current/average/peak statistics are maintained per episode (reset on
start); `onAmplitude` emissions are throttled to
`MicRecorderConfig.amplitudeInterval` (100 ms by default) while the
`amplitude` getter always holds the freshest per-chunk reading.

## 10. Testing strategy

**Unit tests over a fake platform.** `FakeMicRecorderPlatform` implements
`MicRecorderPlatform`, records every call, and scripts replies and events
(focus changes, interruptions, device diffs, route changes, audio chunks).
The method-channel layer is pinned against a mocked binary messenger
(verb-by-verb argument/reply assertions). Controllers are constructed
directly with injected fakes; the orchestrator is exercised through the
plumbed platform. Native sides are reviewed against the read-only source
and compiled (Android) / built on CI (iOS).

The suite is 250 tests across six files (plus the shared fake),
with 92.3 % Dart-side line coverage (the uncovered remainder is
real-time-gated code — the 30 s/60 s/120 s silence alarms, the five-minute
conversation-silence windows, the undeletable-file path — plus two
defensive error branches):

- `method_channel_mic_recorder_test.dart` — 47 tests, the wire contract:
  every verb's argument map and reply shape, including the
  `startRecording` sample-rate + effect-toggle payload and the
  encoded-output/permission payload pinning (`setEncodedOutput` sends
  `{path, encoder, bitRate?, sampleRate?}`, omits null optionals, and maps
  `false`/`null` replies; `clearEncodedOutput` / `checkMicPermission` /
  `requestMicPermission` argument shapes).
- `mic_audio_session_controller_test.dart` — 36 tests (focus and
  interruption mappings, recovery, devices, diagnostics); the four
  `testWidgets` in it now run to completion — they were rewritten around
  the fake-async laws below after a runner crash ("Cannot close sink while
  adding stream").
- `mic_recorder_test.dart` — 58 orchestrator tests: the duration-clock
  lifecycle (zero on start, paused-span exclusion, exact final event),
  `maxDuration` auto-stop (fires on active time only, never while
  paused), manual-stop info fields, amplitude metering (dBFS values +
  throttle), **on-disk WAV verification** (the canonical 44-byte
  RIFF/fmt/data layout, patched RIFF/data sizes, byte-exact PCM payload),
  raw `pcm16` passthrough, encoded-output arming (payload carries the
  sample rate, double-arm `StateError`, cross-platform `UnsupportedError`,
  AMR rate validation, episode-info priority encoded > Dart-written file,
  `cancel` discards both outputs, platform rejection → `StateError`),
  the permissions passthrough, and the restored integration paths:
  start/state transitions and double-start rejection, the voice-command
  RAM tail and its five-minute trim, failed-start error state, pause and
  resume semantics (pausing while idle is a `StateError`), the call-held
  resume block, RAM buffering with the `emitInitialAudio` drain, the PCM
  file lifecycle, Android foreground-service titles with failure
  containment, diagnostics passthrough, route toggling, and fake-clock
  interruption retry ladders (the duration clock counting
  post-auto-resume audio included).
- `mic_route_controller_test.dart` — 34 tests: the iOS input ladder
  (USB > wired > Bluetooth > built-in, no-input deferral, already-routed
  dedupe, background write-gate deferral), the Android ladder (USB
  disengage, Bluetooth engage, A2DP headset upgrade, default mic,
  repeated-decision dedupe), toggling (prepare-while-disabled stand-down,
  observe-only, mid-flight enable), device-change serialization
  (mid-evaluation changes are held, then applied against the latest
  snapshot), stop/episode reset, switch/eval/observation failure
  resilience, and unsupported platforms.
- `mic_route_controller_timers_test.dart` — 9 `testWidgets` on the fake
  clock: the settle re-assert (3 s, exact edge), the foreground re-assert
  (300 ms), the route repay (2 s, with the 5 s interruption-cooldown
  re-deferral) and the Android SCO verification (live, dropped,
  stood-down).
- `mic_models_test.dart` — 54 tests: every model's decode/encode/equality
  contract — the dBFS clamp boundaries, the Android/iOS device-type
  tables, the encoder reachability and rate requirements, the stop
  reasons, and every event family's field mapping.
- `mic_config_test.dart` — 12 tests: the production-profile defaults,
  full-field round-trips, and the two sub-config wire maps.

CI runs the same suite with coverage (see `.github/workflows/ci.yml`).

**Fake-async laws learned the hard way** (Flutter 3.47 / Dart 3.13 — the
teardown code and the testWidgets suites are shaped around them):

1. Awaiting a broadcast `StreamSubscription.cancel()` or
   `StreamController.close()` future never completes under `fake_async`
   (the done-future resolves on an event-loop turn the fake clock never
   runs) — and even un-awaited, cancel/close machinery can poison the zone
   for later pumps when a subscription was cancelled first. *Consequence:*
   all broadcast cancels/closes in teardown paths are `unawaited()`;
   `SeededStream.close()` is fire-and-forget `void`; `Stream.multi`
   `onCancel` wrappers never return broadcast cancel futures.
2. A `setUp`-created controller's stream machinery does not advance on
   `tester.pump` inside `testWidgets` (zone mismatch). *Consequence:*
   fake-async tests build their instances locally inside the test body.
3. A trailing `await` — a `subscription.cancel()`, a controller
   `dispose()` — after the last pump never drains, and the suite ends with
   a sink still adding, which is the "Cannot close sink while adding
   stream" crash. *Consequence:* the rewritten tests release trailing
   cleanup fire-and-forget and end with a drain pump before asserting.

Coverage notes: the suite covers all deterministic logic; the uncovered
remainder is real-time-gated code (30/60/120-second silence and health
timers, 5-minute conversation windows, the 5-minute voice trim) that
would need real sleeps.

## 11. Limitations

- **iOS compilation is verified on CI/macOS only.** The plugin was
  developed in a Linux sandbox without Xcode; the Swift sources were
  verified by careful re-reading and diffing against the original, and
  `.github/workflows/ci.yml` builds `example/` with
  `flutter build ios --no-codesign` on `macos-14` — that job (or a local
  macOS build) is the compile gate.
- **No web or desktop support** — Android and iOS only. The routing ladder
  and session handling are inherently platform-audio APIs.
- **Mono by design.** Capture is 16-bit little-endian mono PCM at the
  configured rate: Bluetooth HFP capture is mono, and voice/speech — the
  plugin's domain — never needs more. Stereo/multi-channel recording is
  intentionally out of scope; the encoded outputs mirror the same single
  channel.
- **Permissions flow only through the API.** The plugin provides
  `checkMicrophonePermission` / `requestMicrophonePermission` and capture
  never requests implicitly, but the host app still owns the
  `RECORD_AUDIO` / `POST_NOTIFICATIONS` (Android) and
  `NSMicrophoneUsageDescription` / `UIBackgroundModes` (iOS) declarations.
- Raw `pcm16` output stays headerless; arm
  `MicRecordingFileFormat.wav` (or an encoded output) when
  `extractAmplitudes`' native decoders need a real container.
