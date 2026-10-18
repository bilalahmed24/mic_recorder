package com.bilalahmed24.mic_recorder;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

import android.content.Context;
import android.media.AudioAttributes;
import android.media.AudioDeviceCallback;
import android.media.AudioDeviceInfo;
import android.media.AudioFocusRequest;
import android.media.AudioManager;
import android.os.Build;
import android.os.Handler;
import android.util.Log;

import androidx.annotation.RequiresApi;

import io.flutter.plugin.common.EventChannel;

/**
 * The Android audio-session layer, implemented directly against
 * {@link AudioManager}.
 *
 * <p>While the recorder runs, this layer holds an audio-focus request
 * that describes a voice-communication capture: usage
 * {@code USAGE_VOICE_COMMUNICATION}, content type speech, audibility
 * enforced. Activation ({@link #setAudioSessionActive}) is therefore a
 * focus request — on API 26+ through an {@link AudioFocusRequest}, on
 * API 24/25 through the legacy stream-based call — and only a granted
 * request counts as an active session; deactivation abandons it. When
 * the system permanently revokes focus the request is dropped before
 * anything else, because a dead request is never re-granted, while a
 * clean state lets the next activation request anew.
 *
 * <p>Two kinds of notifications are forwarded to the session_events
 * sink, both on the platform main thread:
 *
 * <ul>
 *   <li>Every focus transition, unchanged, as
 *       {@code {event: audioFocusChanged, focus: <int>}} — the raw
 *       {@link AudioManager} focus code; the platform-neutral
 *       interruption mapping is owned by the Dart layer.</li>
 *   <li>Every device the system adds or removes, as
 *       {@code {event: devicesChanged, added: [...], removed: [...]}}
 *       with the device maps {@code id}, {@code name}, {@code type}
 *       (the raw {@link AudioDeviceInfo} type int), {@code isSource}
 *       and {@code isSink}.</li>
 * </ul>
 *
 * <p>Of the {@link #configureAudioSession} flags only
 * {@code willPauseWhenDucked} changes what Android does — it selects
 * the gain hint of the focus request (transient-may-duck when this app
 * pauses on duck, transient-exclusive when it does not) and the
 * request's ducking behavior. The remaining three flags describe the
 * Darwin half of the shared configuration and are stored for parity.
 *
 * <p>No {@code ACTION_AUDIO_BECOMING_NOISY} or SCO-state receivers are
 * registered here: the capture engine ({@link MicAudioRecorder})
 * already tracks the SCO link itself, and a second registration would
 * only duplicate its broadcasts.
 */
public class MicAudioSession {

    private static final String TAG = "MicRecorder";

    private final Handler mainHandler;
    private final AudioManager audioManager;

    /** Application context; cleared by {@link #release()}. */
    private Context applicationContext;

    /** The session_events sink; attached and detached by the plugin. */
    private EventChannel.EventSink sessionEventSink;

    /**
     * The shared session configuration. Only
     * {@code willPauseWhenDucked} has an Android effect (focus-gain
     * selection); the others express the Darwin half of the
     * configuration and are stored for parity.
     */
    private volatile boolean allowBluetooth;
    private volatile boolean defaultToSpeaker;
    private volatile boolean notifyOthersOnDeactivation;
    private volatile boolean willPauseWhenDucked;

    /** The API 26+ focus request currently held; null while none is. */
    private AudioFocusRequest heldFocusRequest;

    /** True while focus is held (the API 26+ and legacy forms alike). */
    private volatile boolean focusHeld;

    private AudioDeviceCallback deviceListener;

    /**
     * The single focus listener shared by both request forms. A
     * permanent loss drops the held request first (a dead request is
     * never re-granted), then the raw focus code is forwarded to the
     * session-events sink.
     */
    private final AudioManager.OnAudioFocusChangeListener focusChangeListener =
            new AudioManager.OnAudioFocusChangeListener() {
                @Override
                public void onAudioFocusChange(int focusChange) {
                    if (focusChange == AudioManager.AUDIOFOCUS_LOSS) {
                        dropFocus();
                    }

                    emitEvent(focusChangeEvent(focusChange));
                }
            };

    /**
     * Creates the session layer. The device listener is registered on
     * the main handler here and unregistered by {@link #release()}.
     *
     * @param context     any context; the application context is kept
     * @param mainHandler the platform main-thread handler, used for
     *                    focus callbacks and event delivery
     */
    public MicAudioSession(Context context, Handler mainHandler) {
        this.applicationContext = context != null ? context.getApplicationContext() : null;
        this.mainHandler = mainHandler;
        this.audioManager = this.applicationContext != null
                ? (AudioManager) this.applicationContext.getSystemService(Context.AUDIO_SERVICE)
                : null;

        registerDeviceListener();
    }

    /**
     * Attaches or detaches the session_events sink. The plugin drives
     * this from the EventChannel's stream handler.
     *
     * @param sink the sink to deliver events to, or null to detach
     */
    public synchronized void setSessionEventSink(EventChannel.EventSink sink) {
        sessionEventSink = sink;
    }

    /**
     * Stores the shared audio-session configuration (the
     * configureAudioSession verb). Android acts only on
     * {@code willPauseWhenDucked}, which selects the focus request's
     * gain hint and ducking behavior; the remaining flags are the
     * Darwin-side keys of the shared configuration.
     *
     * @param allowBluetooth             whether Bluetooth HFP input is
     *                                   desired (Darwin-side; the
     *                                   Android engine routes via
     *                                   setBluetoothStatus)
     * @param defaultToSpeaker           whether playback should default
     *                                   to the loudspeaker (Darwin-side)
     * @param notifyOthersOnDeactivation whether other audio should be
     *                                   notified on deactivation
     *                                   (Darwin-side)
     * @param willPauseWhenDucked        whether this app pauses
     *                                   (instead of ducking) when
     *                                   another app ducks it
     */
    public synchronized void configureAudioSession(
            boolean allowBluetooth,
            boolean defaultToSpeaker,
            boolean notifyOthersOnDeactivation,
            boolean willPauseWhenDucked) {
        this.allowBluetooth = allowBluetooth;
        this.defaultToSpeaker = defaultToSpeaker;
        this.notifyOthersOnDeactivation = notifyOthersOnDeactivation;
        this.willPauseWhenDucked = willPauseWhenDucked;
    }

    /**
     * Activates or deactivates the session: activation requests audio
     * focus, deactivation abandons it.
     *
     * <p>Requesting while a request is already held succeeds without
     * another round trip. A denied request holds nothing, so the next
     * activation can retry.
     *
     * @param active true to request focus, false to abandon it
     * @return whether the request (or the abandon) succeeded
     */
    public synchronized boolean setAudioSessionActive(boolean active) {
        if (audioManager == null) {
            return false;
        }

        if (!active) {
            return dropFocus() == AudioManager.AUDIOFOCUS_REQUEST_GRANTED;
        }

        if (focusHeld) {
            return true;
        }

        // A speech capture either opts into pausing when ducked — a
        // may-duck request lets other media keep playing underneath —
        // or claims an exclusive transient request instead.
        final int gainHint = willPauseWhenDucked
                ? AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK
                : AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE;

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            AudioFocusRequest request = buildFocusRequest(gainHint);

            final int status = audioManager.requestAudioFocus(request);

            final boolean granted = status == AudioManager.AUDIOFOCUS_REQUEST_GRANTED;

            heldFocusRequest = granted ? request : null;
            focusHeld = granted;

            return granted;
        }

        // API 24/25: the pre-O stream-based request; the voice-call
        // stream pairs with the voice-communication usage above.
        focusHeld = audioManager.requestAudioFocus(
                focusChangeListener, AudioManager.STREAM_VOICE_CALL, gainHint)
                == AudioManager.AUDIOFOCUS_REQUEST_GRANTED;

        return focusHeld;
    }

    /**
     * Whether any music/media stream is currently playing — on Android
     * the signal for competing audio.
     */
    public boolean isMusicActive() {
        AudioManager manager = audioManager;
        return manager != null && manager.isMusicActive();
    }

    /**
     * The current audio mode as the raw {@link AudioManager} int
     * ({@code NORMAL}, {@code RINGTONE}, {@code IN_CALL},
     * {@code IN_COMMUNICATION}, ...). Dart combines it with
     * {@link #isMusicActive()} to detect an ongoing call.
     *
     * @return the raw mode, or {@code MODE_NORMAL} when unavailable
     */
    public int getMode() {
        AudioManager manager = audioManager;
        return manager != null ? manager.getMode() : AudioManager.MODE_NORMAL;
    }

    /**
     * Whether other audio is playing. On Android the answer is
     * {@link #isMusicActive()}.
     */
    public boolean isOtherAudioPlaying() {
        return isMusicActive();
    }

    /**
     * Snapshot of the currently listed input devices (the
     * getAudioDevices verb). Each device map carries {@code id},
     * {@code name}, {@code type} (the raw {@link AudioDeviceInfo} type
     * int), {@code isSource} and {@code isSink}.
     *
     * @return the source (input) devices currently known to the system
     */
    public List<Map<String, Object>> getInputDevices() {
        List<Map<String, Object>> inputs = new ArrayList<>();

        AudioManager manager = audioManager;

        if (manager == null) {
            return inputs;
        }

        for (AudioDeviceInfo device : manager.getDevices(AudioManager.GET_DEVICES_INPUTS)) {
            if (device.isSource()) {
                inputs.add(encodeDevice(device));
            }
        }

        return inputs;
    }

    /**
     * Full teardown: abandons any held focus request, unregisters the
     * device listener and detaches the sink. Called when the Flutter
     * engine detaches from the plugin.
     */
    public synchronized void release() {
        dropFocus();

        if (deviceListener != null && audioManager != null) {
            try {
                audioManager.unregisterAudioDeviceCallback(deviceListener);
            } catch (Exception ignored) {
                // Teardown ordering can unregister ahead of us.
            }

            deviceListener = null;
        }

        sessionEventSink = null;
        applicationContext = null;
    }

    /* ------------------------------------------------------------------
     * Focus plumbing.
     * ------------------------------------------------------------------ */

    /**
     * Builds the API 26+ request: the voice-communication capture
     * profile (speech content, audibility enforced), the configured
     * gain hint and ducking behavior, and callbacks delivered on the
     * main handler.
     */
    @RequiresApi(Build.VERSION_CODES.O)
    private AudioFocusRequest buildFocusRequest(int gainHint) {
        AudioAttributes captureProfile = new AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                .setFlags(AudioAttributes.FLAG_AUDIBILITY_ENFORCED)
                .build();

        return new AudioFocusRequest.Builder(gainHint)
                .setAudioAttributes(captureProfile)
                .setWillPauseWhenDucked(willPauseWhenDucked)
                .setOnAudioFocusChangeListener(focusChangeListener, mainHandler)
                .build();
    }

    /**
     * Abandons the held focus request, if any. Abandoning when nothing
     * is held is a success; a real abandon forwards the system's
     * status code.
     *
     * @return the {@link AudioManager} abandon status code
     */
    private synchronized int dropFocus() {
        if (!focusHeld) {
            return AudioManager.AUDIOFOCUS_REQUEST_GRANTED;
        }

        focusHeld = false;

        AudioFocusRequest request = heldFocusRequest;
        heldFocusRequest = null;

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                return audioManager.abandonAudioFocusRequest(request);
            }

            return audioManager.abandonAudioFocus(focusChangeListener);
        } catch (Exception e) {
            Log.w(TAG, "Abandoning audio focus failed: " + e.getMessage());

            return AudioManager.AUDIOFOCUS_REQUEST_FAILED;
        }
    }

    /* ------------------------------------------------------------------
     * Device tracking and event emission.
     * ------------------------------------------------------------------ */

    /** Registers the device listener on the main handler. */
    private void registerDeviceListener() {
        if (audioManager == null) {
            return;
        }

        deviceListener = new AudioDeviceCallback() {
            @Override
            public void onAudioDevicesAdded(AudioDeviceInfo[] addedDevices) {
                emitEvent(devicesChangeEvent(addedDevices, new AudioDeviceInfo[0]));
            }

            @Override
            public void onAudioDevicesRemoved(AudioDeviceInfo[] removedDevices) {
                emitEvent(devicesChangeEvent(new AudioDeviceInfo[0], removedDevices));
            }
        };

        audioManager.registerAudioDeviceCallback(deviceListener, mainHandler);
    }

    /**
     * Builds the devicesChanged event. Sources and sinks are both
     * included: the isSource/isSink flags let the Dart layer filter
     * (a Bluetooth A2DP <em>sink</em> appearing is itself a routing
     * signal).
     */
    private static Map<String, Object> devicesChangeEvent(
            AudioDeviceInfo[] added,
            AudioDeviceInfo[] removed) {
        Map<String, Object> event = new HashMap<>();

        event.put("event", "devicesChanged");
        event.put("added", encodeDevices(added));
        event.put("removed", encodeDevices(removed));

        return event;
    }

    /** Builds the audioFocusChanged event for a raw focus code. */
    private static Map<String, Object> focusChangeEvent(int focusChange) {
        Map<String, Object> event = new HashMap<>();

        event.put("event", "audioFocusChanged");
        event.put("focus", focusChange);

        return event;
    }

    private static List<Map<String, Object>> encodeDevices(AudioDeviceInfo[] devices) {
        List<Map<String, Object>> encoded = new ArrayList<>(devices.length);

        for (AudioDeviceInfo device : devices) {
            encoded.add(encodeDevice(device));
        }

        return encoded;
    }

    /**
     * Encodes one device for the wire: the stable system-assigned
     * {@code id}, the product {@code name}, and the raw {@code type}
     * int (Dart owns the decoding table) with the source/sink flags.
     */
    private static Map<String, Object> encodeDevice(AudioDeviceInfo device) {
        Map<String, Object> map = new HashMap<>();

        map.put("id", device.getId());

        CharSequence productName = device.getProductName();
        map.put("name", productName == null ? "" : productName.toString());

        map.put("type", device.getType());
        map.put("isSource", device.isSource());
        map.put("isSink", device.isSink());

        return map;
    }

    /** Delivers a session event to the sink on the main thread. */
    private void emitEvent(Map<String, Object> event) {
        mainHandler.post(
                () -> {
                    EventChannel.EventSink sink = sessionEventSink;

                    if (sink != null) {
                        sink.success(event);
                    }
                });
    }
}
