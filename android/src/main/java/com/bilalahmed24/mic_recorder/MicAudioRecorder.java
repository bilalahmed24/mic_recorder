package com.bilalahmed24.mic_recorder;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.ShortBuffer;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;

import android.annotation.SuppressLint;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.util.Log;

import android.media.AudioDeviceCallback;
import android.media.AudioDeviceInfo;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioRecord;
import android.media.MediaCodec;
import android.media.MediaExtractor;
import android.media.MediaFormat;
import android.media.MediaRecorder;
import android.media.audiofx.AcousticEchoCanceler;
import android.media.audiofx.AutomaticGainControl;
import android.media.audiofx.NoiseSuppressor;
import android.bluetooth.BluetoothA2dp;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothManager;
import android.bluetooth.BluetoothProfile;

import androidx.core.content.ContextCompat;

import io.flutter.plugin.common.EventChannel;

/**
 * The raw PCM capture engine.
 *
 * An {@code AudioRecord} engine with the Bluetooth SCO lifecycle and the
 * silence / route / stall rebuild watchdogs. App-concerns that a plugin
 * must not own (vibration, geofence gating, local notifications) surface
 * as Dart-side events instead.
 *
 * The engine emits 16-bit little-endian mono PCM chunks on the plugin's
 * {@code audio_stream} event channel. Chunks are copied and posted to the
 * main thread before hitting the event sink (posting the shared read buffer
 * corrupted audio whenever the platform thread lagged).
 */
public class MicAudioRecorder {

    private static final String TAG = "MicRecorder";

    private Context context;
    private final Handler mainHandler;

    /** The audio_stream event sink; set/cleared by the plugin on listen/cancel. */
    private EventChannel.EventSink eventSink;

    private AudioRecord recorder = null;
    private AudioManager audioManager;
    private int bufferSize;
    private RecordingThread recordingThread;
    private Boolean isRecording = false;
    private Boolean isBluetoothAllowed = true;
    private boolean isReceiverRegistered = false;

    private int currentSampleRate = 16000;

    /// Consecutive digital silence required before the recorder is rebuilt.
    private static final double SILENCE_REBUILD_THRESHOLD_MS = 15000;

    private double silentMs = 0;
    private int silenceRebuilds = 0;
    private static final int MAX_SILENCE_REBUILDS = 4;

    /// After the quick-rebuild budget is spent, keep one rebuild per this
    /// interval while the silence continues. A permanently dead route must
    /// never end recovery(headset back in range, mic privacy re-enabled, SCO
    /// link re-negotiated), and the recorder must still be trying when it
    /// does.
    private static final long SILENCE_REBUILD_PACE_MS = 60000;
    private long lastSilenceRebuildAt = 0L;

    /// Set by the SCO receiver so the recording loop rebuilds the recorder on
    /// the capture thread (rebuilding from the receiver thread would deadlock
    /// on recordingThread.join()).
    private volatile boolean rebuildRequested = false;
    private volatile boolean rebuildGateRequired = true;
    private volatile String pendingRebuildReason = null;

    // The record's routed input was physically removed: its track is dead and
    // in-place healing cannot be trusted (getRoutedDevice() lies for a
    // framework-restored record; only a Java-level re-creation heals it).
    private volatile boolean routedInputVanished = false;

    // The external input the record was last resolved to (-1: none). A dying
    // track's getRoutedDevice() reports the post-removal default, not the
    // device the record was actually using when unpinned.
    private volatile int lastPreferredInputId = -1;

    // Set while the capture thread is inside recorder.read(); a read older
    // than this is the dead-track stall the framework takes ~10s to revive
    // internally while delivering silence.
    private volatile long captureReadSince = 0L;
    private static final long CAPTURE_READ_STALL_MS = 1000;

    // Bumped on every route-relevant change and stamped into recorderEpoch at
    // each open: inequality means the record opened against a different route
    // state - the route confirmation that works where getRoutedDevice() is null.
    private final AtomicInteger routeEpoch = new AtomicInteger(0);
    private volatile int recorderEpoch = 0;

    // At most one Bluetooth engagement runs at a time; it drives the route
    // to its target beside the running capture.
    private final AtomicBoolean btEngageInFlight = new AtomicBoolean(false);

    // Echo guard: route events scheduled while a rebuild was in flight
    // describe that rebuild's own reroute, not a new transition.
    private volatile long lastRouteRebuildCompletedAt = 0L;

    private volatile int scoState = AudioManager.SCO_AUDIO_STATE_DISCONNECTED;

    private volatile boolean commDeviceIsLeAudio = false;

    private final Handler routeWatchdogHandler = new Handler(Looper.getMainLooper());

    // A classic (BR/EDR) SCO headset negotiates its HFP socket AFTER
    // startBluetoothSco() returns; the policy reroute that follows is
    // what invalidates a record opened too early. Only the SCO-connected
    // broadcast proves the socket is up, so a classic headset waits for it.
    private static final long SCO_ROUTE_READY_TIMEOUT_MS = 2000;

    // LE Audio headsets never emit SCO broadcasts; for them a listing that
    // has been stable for this long (and is not mid-connection) is the best
    // available readiness signal.
    private static final long SCO_LISTED_GRACE_MS = 400;

    // The SCO-connected broadcast slightly PRECEDES the policy input
    // reroute; opening in that window is what got the track invalidated.
    private static final long SCO_POST_CONNECT_SETTLE_MS = 250;

    // Route verifications are scheduled this long after a route event so
    // the policy reroute has landed before we judge the routed device.
    private static final long ROUTE_VERIFY_DELAY_MS = 600;

    private int routeRebuilds = 0;
    private static final int MAX_ROUTE_REBUILDS = 8;

    private final AtomicInteger stallRebuilds = new AtomicInteger(0);
    private static final int MAX_STALL_REBUILDS = 4;

    // A communication-device clear can stick on some ROMs; bound the
    // retries instead of fighting forever.
    private int scoCleanupAttempts = 0;
    private static final int MAX_SCO_CLEANUP_ATTEMPTS = 3;
    private boolean scoCleanupStoodDown = false;

    private boolean scoRequestStoodDown = false;

    private AudioDeviceCallback audioDeviceCallback;

    MicAudioRecorder(Context context, Handler mainHandler) {
        this.context = context.getApplicationContext();
        this.mainHandler = mainHandler;

        initBluetooth();
    }

    /** Attaches / detaches the audio_stream event sink (engine detach clears it). */
    public synchronized void setAudioEventSink(EventChannel.EventSink sink) {
        eventSink = sink;
    }

    /**
     * Selects the best-effort platform capture effects for the NEXT (and
     * every rebuild of the) AudioRecord — applied per session id, so route
     * rebuilds re-arm them. Unavailable effects are skipped silently
     * (device-dependent; iOS applies its equivalents via the session mode).
     */
    public synchronized void setAudioEffects(
            boolean echoCancel, boolean noiseSuppress, boolean autoGain) {
        wantEchoCancel = echoCancel;
        wantNoiseSuppress = noiseSuppress;
        wantAutoGain = autoGain;
    }

    private boolean wantEchoCancel;
    private boolean wantNoiseSuppress;
    private boolean wantAutoGain;

    private AcousticEchoCanceler echoCanceler;
    private NoiseSuppressor noiseSuppressor;
    private AutomaticGainControl autoGainControl;

    /** Attaches the selected effects to [recorder]'s audio session. */
    private void applyAudioEffects(AudioRecord recorder) {
        releaseAudioEffects();

        if (recorder == null) return;

        final int sessionId = recorder.getAudioSessionId();

        try {
            if (wantEchoCancel && AcousticEchoCanceler.isAvailable()) {
                echoCanceler = AcousticEchoCanceler.create(sessionId);

                if (echoCanceler != null) echoCanceler.setEnabled(true);
            }

            if (wantNoiseSuppress && NoiseSuppressor.isAvailable()) {
                noiseSuppressor = NoiseSuppressor.create(sessionId);

                if (noiseSuppressor != null) noiseSuppressor.setEnabled(true);
            }

            if (wantAutoGain && AutomaticGainControl.isAvailable()) {
                autoGainControl = AutomaticGainControl.create(sessionId);

                if (autoGainControl != null) autoGainControl.setEnabled(true);
            }
        } catch (Exception e) {
            // Effects are strictly best-effort — capture must never fail
            // because a device's effect stack misbehaves.
            Log.w(TAG, "Audio effects could not be applied: " + e.getMessage());

            releaseAudioEffects();
        }
    }

    private void releaseAudioEffects() {
        try {
            if (echoCanceler != null) echoCanceler.release();
        } catch (Exception ignored) {
        } finally {
            echoCanceler = null;
        }

        try {
            if (noiseSuppressor != null) noiseSuppressor.release();
        } catch (Exception ignored) {
        } finally {
            noiseSuppressor = null;
        }

        try {
            if (autoGainControl != null) autoGainControl.release();
        } catch (Exception ignored) {
        } finally {
            autoGainControl = null;
        }
    }

    @SuppressLint("MissingPermission")
    private void initBluetooth() {
        audioManager = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);

        IntentFilter filter = new IntentFilter();
        filter.addAction(AudioManager.ACTION_SCO_AUDIO_STATE_UPDATED);
        filter.addAction(BluetoothA2dp.ACTION_CONNECTION_STATE_CHANGED);

        // Both actions are protected system broadcasts — only the system
        // can send them — so an exported receiver is safe here, and the
        // explicit flag satisfies the Android 14 requirement for
        // context-registered receivers.
        ContextCompat.registerReceiver(context, receiver, filter, ContextCompat.RECEIVER_EXPORTED);

        audioDeviceCallback = new AudioDeviceCallback() {
            @Override
            public void onAudioDevicesAdded(AudioDeviceInfo[] addedDevices) {
                if (isRecording && hasInputDevice(addedDevices)) {
                    routeEpoch.incrementAndGet();

                    Log.i(TAG, "Audio input devices added: types "
                            + describeInputDeviceTypes(addedDevices));

                    scheduleRouteTransition("audio input device added");
                }
            }

            @Override
            public void onAudioDevicesRemoved(AudioDeviceInfo[] removedDevices) {
                if (isRecording && hasInputDevice(removedDevices)) {
                    routeEpoch.incrementAndGet();

                    Log.i(TAG, "Audio input devices removed: types "
                            + describeInputDeviceTypes(removedDevices));

                    markRoutedInputVanished(removedDevices);

                    scheduleRouteTransition("audio input device removed");
                }
            }
        };

        if (audioManager != null) {
            audioManager.registerAudioDeviceCallback(audioDeviceCallback, routeWatchdogHandler);
        }

        isReceiverRegistered = true;
    }

    private void unsubscribeBluetoothEvents() {
        if (isReceiverRegistered) {
            try {
                context.unregisterReceiver(receiver);
            } catch (IllegalArgumentException ignored) {
                // Already unregistered (engine teardown ordering quirk).
            }

            if (audioDeviceCallback != null && audioManager != null) {
                audioManager.unregisterAudioDeviceCallback(audioDeviceCallback);
                audioDeviceCallback = null;
            }
        }

        isReceiverRegistered = false;
    }

    public void setBluetoothStatus(boolean isAllowed) {
        if (isBluetoothAllowed == isAllowed) return;

        Log.i(TAG, "Bluetooth routing intent: allowed=" + isAllowed
                + " (was " + isBluetoothAllowed + ")");

        isBluetoothAllowed = isAllowed;

        routeEpoch.incrementAndGet();

        scoCleanupAttempts = 0;
        scoCleanupStoodDown = false;
        scoRequestStoodDown = false;

        if (isAllowed) {
            // Engaging while recording reroutes the open record in place;
            // a release-and-reopen follows only if it did not follow.
            if (isRecording) requestBluetoothRoute("bluetooth-engaged");
        } else if (isRecording) {
            // Clearing under a live record would invalidate its track; the
            // rebuild clears with the record released.
            requestRebuild("bluetooth-disengaged");
        } else {
            stopScoIfActive();
        }
    }

    @SuppressLint("MissingPermission")
    private boolean isBluetoothMicrophoneConnected() {
        if (!isBluetoothAllowed) return false;

        Context currentContext = context;

        if (currentContext == null) return false;

        try {
            BluetoothManager bluetoothManager = (BluetoothManager) currentContext
                    .getSystemService(Context.BLUETOOTH_SERVICE);
            BluetoothAdapter bluetoothAdapter = bluetoothManager.getAdapter();

            // The Bluetooth headset profile includes both Bluetooth headphones and
            // microphones
            return bluetoothAdapter != null && bluetoothAdapter
                    .getProfileConnectionState(BluetoothProfile.HEADSET) == BluetoothAdapter.STATE_CONNECTED;
        } catch (Exception e) {
            return false;
        }
    }

    @SuppressLint("MissingPermission")
    public boolean startRecording(int sampleRate) {
        if (isRecording)
            return true;

        currentSampleRate = sampleRate;

        bufferSize = AudioRecord.getMinBufferSize(sampleRate, AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT) * 3;

        // Establish the Bluetooth route before opening the record so the first
        // open lands on the final device and needs no settle-rebuild.
        if (isBluetoothMicrophoneConnected() && requestScoOn()) {
            waitForScoRouteReady();
        }

        int openEpoch = routeEpoch.get();

        recorder = new AudioRecord(
                MediaRecorder.AudioSource.MIC,
                sampleRate,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                bufferSize);

        // Failed to initialize recorder. Microphone might be already in use.
        if (recorder.getState() == AudioRecord.STATE_UNINITIALIZED) {
            stopRecording();

            return false;
        }

        applyPreferredDevice();

        if (audioManager.isMicrophoneMute()) {
            Log.w(TAG, "Starting recording while system microphone is muted");
        }

        recorder.startRecording();

        // Failed to start recording. Microphone might be already in use.
        if (recorder.getRecordingState() != AudioRecord.RECORDSTATE_RECORDING) {
            stopRecording();

            return false;
        }

        applyAudioEffects(recorder);

        recorderEpoch = openEpoch;

        isRecording = true;

        silentMs = 0;
        silenceRebuilds = 0;
        lastSilenceRebuildAt = 0L;
        rebuildRequested = false;
        routedInputVanished = false;
        stallRebuilds.set(0);
        scoCleanupAttempts = 0;
        scoCleanupStoodDown = false;
        scoRequestStoodDown = false;

        recordingThread = new RecordingThread();
        recordingThread.start();

        return true;
    }

    public void stopRecording() {
        if (!isRecording)
            return;

        isRecording = false;

        try {
            recordingThread.interrupt();
            recordingThread.join();
        } catch (InterruptedException e) {
            // Restore the interrupted status.
            Thread.currentThread().interrupt();

        }

        requestScoOff();

        releaseAudioEffects();

        if (recorder != null) {
            try {
                recorder.stop();
            } catch (IllegalStateException ignored) {
            }

            recorder.release();
        }

        recorder = null;
        recordingThread = null;

        stopRouteWatchdog();

        scoState = AudioManager.SCO_AUDIO_STATE_DISCONNECTED;
        stallRebuilds.set(0);
        scoCleanupAttempts = 0;
        scoCleanupStoodDown = false;
        scoRequestStoodDown = false;
    }

    /**
     * Full teardown; called when the Flutter engine detaches (the original
     * app ran the equivalent on activity destroy).
     */
    public void release() {
        if (eventSink != null) {
            try {
                eventSink.endOfStream();
            } catch (Exception ignored) {
                // The channel may already be torn down during engine detach.
            }
        }

        stopRouteWatchdog();

        stopRecording();

        unsubscribeBluetoothEvents();

        context = null;
    }

    /* ********************************************************************
     * Silence watchdog helpers.
     * ******************************************************************** */

    /// Peak int16 magnitude at or below this counts as silence (~ -68 dBFS).
    /// A dead capture path is not always all-zero — a zombie SCO link can
    /// deliver low-level dither. A live microphone's noise floor (AGC gain included)
    //  sits well above this, so a genuinely quiet room does not false-trigger.
    private static final int SILENT_CHUNK_PEAK_THRESHOLD = 12;

    private static boolean isSilentChunk(byte[] chunk) {
        for (int i = 0; i + 1 < chunk.length; i += 2) {
            // 16-bit little-endian PCM; the cast sign-extends correctly.
            short sample = (short) (chunk[i] | (chunk[i + 1] << 8));

            if (Math.abs(sample) > SILENT_CHUNK_PEAK_THRESHOLD) return false;
        }

        return true;
    }

    private void requestRebuild(String reason) {
        pendingRebuildReason = reason;
        rebuildGateRequired = true;
        rebuildRequested = true;
    }

    private void requestForcedRebuild(String reason) {
        pendingRebuildReason = reason;
        rebuildGateRequired = false;
        rebuildRequested = true;
    }

    // A record whose routed input was removed is a corpse: the framework may
    // restore its IAudioRecord and report the new route, but the data path
    // stays dead until the record is re-created. Route checks cannot detect
    // this; only the removal event can.
    private void markRoutedInputVanished(AudioDeviceInfo[] removedDevices) {
        AudioRecord currentRecorder = recorder;

        if (currentRecorder == null) return;

        AudioDeviceInfo routed = null;
        AudioDeviceInfo pinned = null;

        try {
            routed = currentRecorder.getRoutedDevice();
        } catch (Exception ignored) {
        }

        try {
            pinned = currentRecorder.getPreferredDevice();
        } catch (Exception ignored) {
        }

        for (AudioDeviceInfo device : removedDevices) {
            if (!device.isSource()) continue;

            int type = device.getType();

            boolean routedMatch = routed != null && routed.getId() == device.getId();
            boolean pinnedMatch = pinned != null && pinned.getId() == device.getId();
            boolean intendedMatch = lastPreferredInputId == device.getId();
            boolean usbFallback = routed == null && pinned == null
                    && (type == AudioDeviceInfo.TYPE_USB_DEVICE
                        || type == AudioDeviceInfo.TYPE_USB_HEADSET
                        || type == AudioDeviceInfo.TYPE_USB_ACCESSORY
                        || type == AudioDeviceInfo.TYPE_WIRED_HEADSET
                        || type == AudioDeviceInfo.TYPE_LINE_ANALOG
                        || type == AudioDeviceInfo.TYPE_LINE_DIGITAL);

            if (routedMatch || pinnedMatch || intendedMatch || usbFallback) {
                routedInputVanished = true;

                Log.w(TAG, "Routed input device removed (type " + type
                        + "); open record track is dead");

                return;
            }
        }
    }

    // A record whose input died blocks the capture thread inside read() for
    // ~10s while the framework revives its track; stop() cancels that read
    // so a pending rebuild runs immediately.
    private void unblockCaptureForRebuild() {
        AudioRecord currentRecorder = recorder;

        if (currentRecorder == null) return;

        try {
            currentRecorder.stop();
        } catch (Exception ignored) {
        }
    }

    /// Rebuilds the AudioRecord in place. MUST be called from the recording
    /// thread only (stopRecording() joins that thread and would deadlock).
    @SuppressLint("MissingPermission")
    private void rebuildRecorderOnCaptureThread(String reason) {
        Log.w(TAG, "Rebuilding AudioRecord: " + reason);

        AudioRecord old = recorder;
        recorder = null;

        releaseAudioEffects();

        if (old != null) {
            try {
                old.stop();
            } catch (IllegalStateException ignored) {
            }

            old.release();
        }

        // With the old record released, the communication device can now
        // change without invalidating a live track.
        establishRouteForRebuild();

        lastRouteRebuildCompletedAt = SystemClock.elapsedRealtime();

        int openEpoch = routeEpoch.get();

        recorder = new AudioRecord(
                MediaRecorder.AudioSource.MIC,
                currentSampleRate,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                bufferSize);

        if (recorder.getState() == AudioRecord.STATE_UNINITIALIZED) {
            Log.e(TAG, "AudioRecord re-initialization failed after " + reason);

            recorder = null;

            SystemClock.sleep(250);

            if (stallRebuilds.incrementAndGet() <= MAX_STALL_REBUILDS) {
                requestForcedRebuild("reinit-failed");
            }

            return;
        }

        applyPreferredDevice();

        recorder.startRecording();

        if (recorder.getRecordingState() != AudioRecord.RECORDSTATE_RECORDING) {
            Log.e(TAG, "AudioRecord re-start failed after " + reason);
        }

        applyAudioEffects(recorder);

        recorderEpoch = openEpoch;
    }

    // Runs on the capture thread with the recorder already released, so the
    // communication-device writes here can never invalidate a live track.
    private void establishRouteForRebuild() {
        if (!isBluetoothAllowed) {
            stopScoIfActive();
            return;
        }

        // The HFP profile outlives the socket during teardown and lags it
        // during engagement; the socket state arbitrates.
        if (!isBluetoothMicrophoneConnected() && !commDeviceIsLeAudio
                && scoState == AudioManager.SCO_AUDIO_STATE_DISCONNECTED) {
            requestScoOff();
            return;
        }

        if (scoRequestedActive()) {
            // The request flag can outlive the socket; only a CONNECTED
            // broadcast proves the link. Cycle a zombie so the fresh record
            // does not open on dead telephony air.
            if (commDeviceIsLeAudio
                    || scoState == AudioManager.SCO_AUDIO_STATE_CONNECTED
                    || scoState == AudioManager.SCO_AUDIO_STATE_CONNECTING) return;

            requestScoOff();
        }

        if (!scoRequestStoodDown && isBluetoothMicrophoneConnected()) {
            requestScoOn();

            waitForScoRouteReady();
        }
    }

    private void applyPreferredDevice() {
        AudioDeviceInfo preferred = resolvePreferredDevice();

        lastPreferredInputId = preferred == null ? -1 : preferred.getId();

        if (preferred == null) return;

        // A pin onto the device the record already uses is a redundant
        // policy write — and policy writes are what invalidate open tracks.
        try {
            AudioDeviceInfo routed = recorder.getRoutedDevice();

            if (routed != null && routed.getId() == preferred.getId()) return;
        } catch (Exception ignored) {
        }

        if (!recorder.setPreferredDevice(preferred)) {
            Log.w(TAG, "Preferred input device rejected (type " + preferred.getType() + ")");
        }
    }

    private AudioDeviceInfo resolvePreferredDevice() {
        AudioDeviceInfo usbDevice = null;
        AudioDeviceInfo scoDevice = null;

        for (AudioDeviceInfo device : audioManager.getDevices(AudioManager.GET_DEVICES_INPUTS)) {
            if (!device.isSource()) continue;

            int type = device.getType();

            if (type == AudioDeviceInfo.TYPE_USB_DEVICE
                    || type == AudioDeviceInfo.TYPE_USB_HEADSET
                    || type == AudioDeviceInfo.TYPE_USB_ACCESSORY
                    || type == AudioDeviceInfo.TYPE_WIRED_HEADSET
                    || type == AudioDeviceInfo.TYPE_LINE_ANALOG
                    || type == AudioDeviceInfo.TYPE_LINE_DIGITAL) {
                usbDevice = device;
            } else if (type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO
                    || type == AudioDeviceInfo.TYPE_BLE_HEADSET) {
                scoDevice = device;
            }
        }

        if (usbDevice != null) return usbDevice;

        // The SCO listing outlives the socket during teardown, and the
        // HEADSET profile lags the socket during engagement (still CONNECTING
        // while the link is already up). The socket state is the live truth;
        // the profile check stays for the no-socket window.
        if (scoDevice != null && isBluetoothAllowed
                && (scoState == AudioManager.SCO_AUDIO_STATE_CONNECTED
                    || isBluetoothMicrophoneConnected()
                    || (commDeviceIsLeAudio && scoRequestedActive()))) {
            return scoDevice;
        }

        return null;
    }

    private boolean routeAlreadyPreferred() {
        AudioRecord currentRecorder = recorder;

        // A rebuild is in flight: its re-open adopts the live route state,
        // and anything changing after it stamps its own epoch re-triggers.
        if (currentRecorder == null) return true;

        // The record opened against the current route state - the only
        // confirmation available on ROMs where getRoutedDevice() is null.
        if (routeEpoch.get() == recorderEpoch) return true;

        try {
            AudioDeviceInfo routed = currentRecorder.getRoutedDevice();
            AudioDeviceInfo preferred = resolvePreferredDevice();

            if (preferred != null) {
                if (routed != null && routed.getId() == preferred.getId()) {
                    recorderEpoch = routeEpoch.get();

                    return true;
                }

                return false;
            }

            // No capturable external device listed: a rebuild could only
            // re-open the default route - unless Bluetooth must be left, or
            // is wanted and the rebuild itself must bring its link up.
            if (!isBluetoothAllowed
                    && (isBluetoothType(routed) || scoSwitchOn())) {
                return false;
            }

            boolean settled = !(isBluetoothAllowed && !scoRequestStoodDown
                    && !scoRequestedActive() && scoRouteListed()
                    && (isBluetoothMicrophoneConnected() || commDeviceIsLeAudio));

            if (settled) recorderEpoch = routeEpoch.get();

            return settled;
        } catch (Exception e) {
            return false;
        }
    }

    private static boolean isBluetoothType(AudioDeviceInfo device) {
        if (device == null) return false;

        int type = device.getType();

        return type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO
                || type == AudioDeviceInfo.TYPE_BLE_HEADSET;
    }

    private static boolean hasInputDevice(AudioDeviceInfo[] devices) {
        for (AudioDeviceInfo device : devices) {
            if (device.isSource()) return true;
        }

        return false;
    }

    private static String describeInputDeviceTypes(AudioDeviceInfo[] devices) {
        StringBuilder types = new StringBuilder();

        for (AudioDeviceInfo device : devices) {
            if (!device.isSource()) continue;

            if (types.length() > 0) types.append(", ");
            types.append(device.getType());
        }

        return types.length() == 0 ? "none" : types.toString();
    }

    private void stopRouteWatchdog() {
        routeWatchdogHandler.removeCallbacksAndMessages(null);

        pendingRouteTransition = null;
    }

    private Runnable pendingRouteTransition;

    /// Debounced post-settle route transition. Immediate rebuilds raced the
    /// policy reroute (round 40), and a null getRoutedDevice() on some ROMs
    /// makes verification a silent no-op there — so the transition event
    /// itself drives the rebuild decision once the settle window has passed.
    private void scheduleRouteTransition(String reason) {
        if (pendingRouteTransition != null) {
            routeWatchdogHandler.removeCallbacks(pendingRouteTransition);
        }

        pendingRouteTransition = () -> {
            pendingRouteTransition = null;

            if (!isRecording) return;

            // An engagement in flight is already driving the route to its
            // target; this event describes that engagement's own transition.
            if (btEngageInFlight.get()) return;

            // Events scheduled while a route rebuild was in flight echo
            // that rebuild's own reroute; they are not new transitions.
            if (SystemClock.elapsedRealtime() - lastRouteRebuildCompletedAt
                    < ROUTE_VERIFY_DELAY_MS) return;

            if (routedInputVanished) {
                routedInputVanished = false;

                if (routeRebuilds >= MAX_ROUTE_REBUILDS) {
                    Log.w(TAG, "Route rebuild budget exhausted after " + reason);

                    return;
                }

                routeRebuilds++;

                Log.i(TAG, "Route transition (" + reason + "); rebuilding capture");

                unblockCaptureForRebuild();

                requestForcedRebuild(reason);

                return;
            }

            if (routeAlreadyPreferred()) {
                routeRebuilds = 0;

                Log.i(TAG, "Route already preferred after " + reason + "; no rebuild");

                return;
            }

            if (routeRebuilds >= MAX_ROUTE_REBUILDS) {
                Log.w(TAG, "Route rebuild budget exhausted after " + reason);

                return;
            }

            routeRebuilds++;

            Log.i(TAG, "Route transition (" + reason + "); rebuilding capture");

            requestRebuild(reason);
        };

        routeWatchdogHandler.postDelayed(pendingRouteTransition, ROUTE_VERIFY_DELAY_MS);
    }


    private void stopScoIfActive() {
        if (scoCleanupStoodDown) return;

        if (!scoSwitchOn()) {
            scoCleanupAttempts = 0;

            return;
        }

        if (scoCleanupAttempts >= MAX_SCO_CLEANUP_ATTEMPTS) {
            scoCleanupStoodDown = true;

            Log.w(TAG, "Bluetooth SCO still on after "
                    + scoCleanupAttempts + " stop attempts; standing down");

            return;
        }

        scoCleanupAttempts++;

        Log.w(TAG, "Bluetooth disallowed; stopping Bluetooth SCO");

        audioManager.stopBluetoothSco();

        routeEpoch.incrementAndGet();
    }

    private boolean scoSwitchOn() {
        return audioManager.isBluetoothScoOn();
    }

    private boolean requestScoOn() {
        boolean status = scoSwitchOn();

        if (status) {
            Log.i(TAG, "Bluetooth SCO already requested");

            return true;
        }

        audioManager.startBluetoothSco();

        Log.i(TAG, "startBluetoothSco() requested");

        routeEpoch.incrementAndGet();

        return false;
    }

    // Mid-recording activation runs beside the capture: the policy write
    // reroutes the open record in place (the framework restores its track
    // on the next read), so no speech is lost waiting for the socket. A
    // release-and-reopen follows only when the healed record did not
    // follow the route.
    private void requestBluetoothRoute(String reason) {
        if (!isRecording) {
            requestScoOn();
            return;
        }

        if (btEngageInFlight.compareAndSet(false, true)) {
            new Thread(() -> {
                try {
                    engageBluetoothRoute(reason);
                } finally {
                    btEngageInFlight.set(false);
                }
            }, "MicRecorder-BtEngage").start();
        }
    }

    private void engageBluetoothRoute(String reason) {
        if (scoRequestStoodDown) return;

        if (!scoRequestedActive()) {
            Log.i(TAG, "Engaging Bluetooth route (" + reason
                    + "); the open record may self-restore once");

            requestScoOn();
        }

        waitForScoRouteReady();

        if (!isRecording) return;

        boolean pinned = pinBluetoothInput();

        SystemClock.sleep(SCO_POST_CONNECT_SETTLE_MS);

        if (routedInputVanished) {
            routedInputVanished = false;

            Log.i(TAG, "Bluetooth route engaged (" + reason
                    + "); routed input was removed, forcing rebuild");

            unblockCaptureForRebuild();

            requestForcedRebuild(reason);

            return;
        }

        long readSince = captureReadSince;

        if (readSince != 0L
                && SystemClock.elapsedRealtime() - readSince > CAPTURE_READ_STALL_MS) {
            Log.i(TAG, "Bluetooth route engaged (" + reason
                    + "); capture read stalled, forcing rebuild");

            unblockCaptureForRebuild();

            requestForcedRebuild(reason);

            return;
        }

        if (pinned && routeAlreadyPreferred()) {
            Log.i(TAG, "Bluetooth route engaged without rebuild (" + reason + ")");
            return;
        }

        requestRebuild(reason);
    }

    // Forces this record's capture onto the Bluetooth input. Unlike a
    // communication-device write, the pin follows the record through track
    // restores and re-opens (applyPreferredDevice re-applies it at open).
    private boolean pinBluetoothInput() {
        AudioRecord currentRecorder = recorder;

        if (currentRecorder == null) return false;

        AudioDeviceInfo preferred = resolvePreferredDevice();

        if (preferred == null) {
            Log.w(TAG, "Bluetooth input not pinnable: allowed=" + isBluetoothAllowed
                    + ", scoState=" + scoState
                    + ", headsetProfile=" + isBluetoothMicrophoneConnected()
                    + ", scoListed=" + scoRouteListed());

            return false;
        }

        try {
            AudioDeviceInfo pinned = currentRecorder.getPreferredDevice();

            if (pinned != null && pinned.getId() == preferred.getId()) return true;

            if (currentRecorder.setPreferredDevice(preferred)) {
                Log.i(TAG, "Pinned open record to input device type "
                        + preferred.getType());

                return true;
            }

            Log.w(TAG, "Preferred input device rejected (type "
                    + preferred.getType() + ")");

            return false;
        } catch (Exception e) {
            Log.w(TAG, "Preferred input device pin failed: " + e.getMessage());

            return false;
        }
    }

    private void requestScoOff() {
        commDeviceIsLeAudio = false;

        if (scoSwitchOn()) {
            audioManager.stopBluetoothSco();

            routeEpoch.incrementAndGet();
        }
    }

    private boolean scoRouteListed() {
        for (AudioDeviceInfo device : audioManager.getDevices(AudioManager.GET_DEVICES_INPUTS)) {
            int type = device.getType();

            if (type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO
                    || type == AudioDeviceInfo.TYPE_BLE_HEADSET) return true;
        }

        return false;
    }

    private void waitForScoRouteReady() {
        long startAt = SystemClock.elapsedRealtime();

        while (true) {
            // stopRecording() interrupts this thread before joining; abandon
            // the wait so the join is not blocked by the timeout.
            if (Thread.currentThread().isInterrupted()) return;

            long elapsed = SystemClock.elapsedRealtime() - startAt;

            // Classic SCO: only the connected broadcast proves the HFP
            // socket is up — but it slightly precedes the policy reroute,
            // so let the reroute land before opening.
            if (scoState == AudioManager.SCO_AUDIO_STATE_CONNECTED) {
                SystemClock.sleep(SCO_POST_CONNECT_SETTLE_MS);

                if (scoState == AudioManager.SCO_AUDIO_STATE_CONNECTED) {
                    Log.i(TAG, "Bluetooth route ready after "
                            + (elapsed + SCO_POST_CONNECT_SETTLE_MS)
                            + "ms (SCO connected + settle)");

                    return;
                }
            }

            // LE Audio: no SCO broadcast will ever arrive; accept a listing
            // that has been stable and is not mid-connection.
            if (commDeviceIsLeAudio && scoState != AudioManager.SCO_AUDIO_STATE_CONNECTING
                    && elapsed >= SCO_LISTED_GRACE_MS && scoRouteListed()) {
                Log.i(TAG, "LE Audio route listed; opening after " + elapsed + "ms");

                return;
            }

            if (elapsed >= SCO_ROUTE_READY_TIMEOUT_MS) {
                Log.w(TAG, "Bluetooth route not settled after " + elapsed
                        + "ms (scoState=" + scoState + ")");

                return;
            }

            SystemClock.sleep(50);
        }
    }

    private boolean scoRequestedActive() {
        return scoSwitchOn()
                || scoState == AudioManager.SCO_AUDIO_STATE_CONNECTED
                || scoState == AudioManager.SCO_AUDIO_STATE_CONNECTING;
    }

    /** Route diagnostics snapshot for the Dart-side route ladder. */
    public Map<String, Object> getRouteState() {
        Map<String, Object> state = new HashMap<>();

        state.put("scoConnected", scoState == AudioManager.SCO_AUDIO_STATE_CONNECTED
                || scoSwitchOn());
        state.put("scoState", scoState);
        state.put("bluetoothAllowed", isBluetoothAllowed);
        state.put("isRecording", isRecording);
        state.put("musicActive", audioManager.isMusicActive());
        state.put("bluetoothHeadsetConnected", isBluetoothMicrophoneConnected());
        state.put("scoRequestStoodDown", scoRequestStoodDown);
        state.put("silentMs", (long) silentMs);
        state.put("silenceRebuilds", silenceRebuilds);

        AudioRecord currentRecorder = recorder;

        if (currentRecorder != null) {
            try {
                AudioDeviceInfo routedDevice = currentRecorder.getRoutedDevice();

                state.put("routedDeviceType", routedDevice == null ? null : routedDevice.getType());
            } catch (Exception ignored) {
            }
        }

        return state;
    }

    /**
     * Decodes [filePath] into [barCount] normalized (0.1–1.0) RMS bars.
     * Heavy decoding — call off the platform main thread.
     */
    public List<Double> extractAmplitudes(String filePath, int barCount) throws Exception {
        MediaExtractor extractor = new MediaExtractor();
        extractor.setDataSource(filePath);

        // Find the first audio track
        int audioTrackIndex = -1;
        MediaFormat format = null;
        for (int i = 0; i < extractor.getTrackCount(); i++) {
            MediaFormat f = extractor.getTrackFormat(i);
            String mime = f.getString(MediaFormat.KEY_MIME);
            if (mime != null && mime.startsWith("audio/")) {
                audioTrackIndex = i;
                format = f;
                break;
            }
        }
        if (audioTrackIndex < 0) {
            extractor.release();
            return new ArrayList<>();
        }

        extractor.selectTrack(audioTrackIndex);
        String mime = format.getString(MediaFormat.KEY_MIME);
        assert mime != null;
        MediaCodec codec = MediaCodec.createDecoderByType(mime);
        codec.configure(format, null, null, 0);
        codec.start();

        int sampleRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE);
        int channelCount = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT);

        long durationUs = 0L;
        try {
            durationUs = format.getLong(MediaFormat.KEY_DURATION);
        } catch (Exception ignored) {}

        final int totalFrames = durationUs > 0
                ? (int) (durationUs * sampleRate / 1_000_000L)
                : 0;

        double[] bucketSums = new double[barCount];
        int[] bucketCounts = new int[barCount];

        MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
        boolean inputDone = false;
        boolean outputDone = false;
        long frameIndex = 0L;

        try {
            while (!outputDone) {
                if (!inputDone) {
                    int inputBufferIndex = codec.dequeueInputBuffer(10_000);
                    if (inputBufferIndex >= 0) {
                        ByteBuffer inputBuffer = codec.getInputBuffer(inputBufferIndex);
                        assert inputBuffer != null;
                        int sampleSize = extractor.readSampleData(inputBuffer, 0);
                        if (sampleSize < 0) {
                            codec.queueInputBuffer(
                                    inputBufferIndex, 0, 0, 0,
                                    MediaCodec.BUFFER_FLAG_END_OF_STREAM);
                            inputDone = true;
                        } else {
                            codec.queueInputBuffer(
                                    inputBufferIndex, 0, sampleSize,
                                    extractor.getSampleTime(), 0);
                            extractor.advance();
                        }
                    }
                }

                int outputBufferIndex = codec.dequeueOutputBuffer(info, 10_000);
                if (outputBufferIndex >= 0) {
                    ByteBuffer outputBuffer = codec.getOutputBuffer(outputBufferIndex);

                    if (info.size > 0 && outputBuffer != null) {
                        outputBuffer.position(info.offset);
                        outputBuffer.limit(info.offset + info.size);

                        int samplesInBuffer = info.size / 2;
                        int framesInBuffer = samplesInBuffer / channelCount;

                        ByteBuffer readBuffer = outputBuffer.duplicate();
                        ShortBuffer shortBuffer = readBuffer.order(ByteOrder.LITTLE_ENDIAN).asShortBuffer();

                        for (int i = 0; i < framesInBuffer; i++) {
                            short sample = shortBuffer.get(i * channelCount);

                            if (totalFrames > 0) {
                                int bucketIndex = (int) (frameIndex * barCount / totalFrames);
                                if (bucketIndex < 0) bucketIndex = 0;
                                if (bucketIndex >= barCount) bucketIndex = barCount - 1;
                                bucketSums[bucketIndex] += (double) sample * (double) sample;
                                bucketCounts[bucketIndex]++;
                            }
                            frameIndex++;
                        }
                    }

                    codec.releaseOutputBuffer(outputBufferIndex, false);

                    if ((info.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                        outputDone = true;
                    }
                }
            }
        } finally {
            try { codec.stop(); } catch (Exception ignored) {}
            codec.release();
            extractor.release();
        }

        if (totalFrames == 0) return new ArrayList<>();

        double[] rmsValues = new double[barCount];
        double maxRms = 1.0;
        for (int i = 0; i < barCount; i++) {
            if (bucketCounts[i] > 0) {
                rmsValues[i] = Math.sqrt(bucketSums[i] / bucketCounts[i]);
                if (rmsValues[i] > maxRms) maxRms = rmsValues[i];
            }
        }

        List<Double> resultList = new ArrayList<>(barCount);
        for (int i = 0; i < barCount; i++) {
            double normalized = rmsValues[i] / maxRms;
            if (normalized < 0.1) normalized = 0.1;
            if (normalized > 1.0) normalized = 1.0;
            resultList.add(normalized);
        }
        return resultList;
    }

    private final BroadcastReceiver receiver = new BroadcastReceiver() {
        @Override
        public void onReceive(Context context, Intent intent) {
            final String action = intent.getAction();

            if (action == null)
                return;

            if (action.equals(BluetoothA2dp.ACTION_CONNECTION_STATE_CHANGED)) {
                final int state = intent.getIntExtra(BluetoothA2dp.EXTRA_STATE, BluetoothA2dp.STATE_DISCONNECTED);

                if (state == BluetoothA2dp.STATE_CONNECTED
                        || state == BluetoothA2dp.STATE_DISCONNECTED) {
                    routeEpoch.incrementAndGet();

                    Log.i(TAG, "Bluetooth headset "
                            + (state == BluetoothA2dp.STATE_CONNECTED ? "connected" : "disconnected")
                            + " (A2DP)");
                }

                if (state == BluetoothA2dp.STATE_CONNECTED && isBluetoothAllowed) {
                    scoRequestStoodDown = false;

                    // The HFP profile and the SCO listing land after A2DP; an
                    // immediate rebuild would re-open mid-negotiation. The
                    // debounced transition re-evaluates once they settle.
                    if (isRecording) {
                        scheduleRouteTransition("bluetooth-headset-connected");
                    }
                }

                else if (state == BluetoothA2dp.STATE_DISCONNECTED) {
                    scoCleanupAttempts = 0;
                    scoCleanupStoodDown = false;

                    // A2DP drops before the HFP profile and the SCO listing
                    // clear; rebuilding in that window pins the fresh record
                    // to a device that is about to be removed. Deferred, the
                    // framework's own re-route has landed and the gate sees
                    // the settled truth.
                    if (isRecording) {
                        scheduleRouteTransition("bluetooth-headset-disconnected");
                    } else {
                        requestScoOff();
                    }
                }
            }

            if (action.equals(AudioManager.ACTION_SCO_AUDIO_STATE_UPDATED)) {
                final int state = intent.getIntExtra(AudioManager.EXTRA_SCO_AUDIO_STATE, AudioManager.ERROR);

                if (state == AudioManager.SCO_AUDIO_STATE_CONNECTED
                        || state == AudioManager.SCO_AUDIO_STATE_CONNECTING
                        || state == AudioManager.SCO_AUDIO_STATE_DISCONNECTED) {
                    if (scoState != state) {
                        scoState = state;

                        routeEpoch.incrementAndGet();
                    }
                }

                /*
                 * When microphone interruption is over, disconnected state is resolved after
                 * the recording has started.
                 * We are redirecting the audio in startRecording as the previous state haven't
                 * been resolved to disconnected and
                 * a new request to redirect audio to Bluetooth is given, the new request is
                 * ignored. Therefore, upon disconnected state,
                 * requesting to redirect audio to Bluetooth again, if recording is true.
                 */
                if (state == AudioManager.SCO_AUDIO_STATE_DISCONNECTED) {
                    scoCleanupAttempts = 0;
                    scoCleanupStoodDown = false;

                    if (isRecording && isBluetoothAllowed && !scoRequestedActive()) {
                        requestBluetoothRoute("sco-reconnect");
                    }
                }

                // FIX: an active AudioRecord frequently does not follow SCO route
                // changes and keeps delivering zero-filled buffers until it is
                // re-created. The rebuild decision is DEFERRED to a post-settle
                // verification: an immediate rebuild raced the policy reroute
                // and invalidated the fresh record too (the churn cycle).
                if (isRecording
                        && (state == AudioManager.SCO_AUDIO_STATE_CONNECTED
                        || state == AudioManager.SCO_AUDIO_STATE_DISCONNECTED)) {
                    scheduleRouteTransition(state == AudioManager.SCO_AUDIO_STATE_CONNECTED
                            ? "sco-connected" : "sco-disconnected");
                }
            }
        }
    };

    private final class RecordingThread extends Thread {

        RecordingThread() {
            super("MicRecorder-Capture");
        }

        @Override
        public void run() {
            var buffer = new byte[bufferSize];

            final double msPerByte = 1000.0 / (currentSampleRate * 2.0); // 16-bit mono

            int buffered = 0;

            while (!interrupted() && isRecording) {
                if (rebuildRequested) {
                    rebuildRequested = false;

                    String reason = pendingRebuildReason == null ? "unspecified" : pendingRebuildReason;
                    pendingRebuildReason = null;

                    boolean gateRequired = rebuildGateRequired;

                    if (gateRequired && routeAlreadyPreferred()) {
                        Log.i(TAG, "Skipping rebuild (" + reason
                                + "); routed device already preferred");
                    } else {
                        if (buffered > 0) {
                            boolean rebuilt = processChunk(buffer, buffered, msPerByte);

                            buffered = 0;

                            if (rebuilt) continue;
                        }

                        rebuildRecorderOnCaptureThread(reason);

                        continue;
                    }
                }

                // A failed re-initialization leaves no recorder to read from;
                // park until a forced rebuild re-opens one or recording ends.
                if (recorder == null) {
                    if (wasInterrupted(50)) return;

                    continue;
                }

                captureReadSince = SystemClock.elapsedRealtime();

                int bytesRead = recorder.read(buffer, buffered, buffer.length - buffered,
                        AudioRecord.READ_NON_BLOCKING);

                captureReadSince = 0L;

                if (bytesRead > 0) {
                    stallRebuilds.set(0);

                    buffered += bytesRead;

                    if (buffered < buffer.length) continue;

                    processChunk(buffer, buffered, msPerByte);

                    buffered = 0;
                } else if (bytesRead < 0) {
                    // FIX: read error - previously this busy-looped at full CPU.
                    Log.e(TAG, "AudioRecord read error: " + bytesRead);

                    if (wasInterrupted(50)) return;
                } else if (wasInterrupted(15)) {
                    return;
                }
            }
        }
    }

    private boolean wasInterrupted(long millis) {
        try {
            Thread.sleep(millis);

            return false;
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();

            return true;
        }
    }

    // Returns true when the chunk triggered a silence rebuild (chunk not forwarded).
    private boolean processChunk(byte[] data, int length, double msPerByte) {
        // FIX: copy the chunk before posting. The previous code posted the
        // shared buffer object, which this thread kept overwriting while the
        // UI thread had not serialized it yet -> corrupted/duplicated audio
        // whenever the UI thread lagged.
        final byte[] chunk = Arrays.copyOf(data, length);

        if (isSilentChunk(chunk)) {
            silentMs += chunk.length * msPerByte;

            if (silentMs >= SILENCE_REBUILD_THRESHOLD_MS) {
                long now = SystemClock.elapsedRealtime();

                // Quick rebuilds first (15s cadence, bounded churn); once
                // that budget is spent, keep one paced attempt per minute
                // for as long as the capture path stays dead.
                if (silenceRebuilds < MAX_SILENCE_REBUILDS
                        || now - lastSilenceRebuildAt >= SILENCE_REBUILD_PACE_MS) {

                    silenceRebuilds++;
                    lastSilenceRebuildAt = now;
                    silentMs = 0;

                    rebuildRecorderOnCaptureThread("digital-silence");

                    return true;
                }
            }
        } else {
            silentMs = 0;
            silenceRebuilds = 0;
        }

        // Send the audioData to Flutter
        mainHandler.post(() -> {
            if (eventSink != null) {
                eventSink.success(chunk);
            }
        });

        return false;
    }
}

