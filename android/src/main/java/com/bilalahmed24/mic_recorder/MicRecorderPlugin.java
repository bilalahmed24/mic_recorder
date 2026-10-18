package com.bilalahmed24.mic_recorder;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import android.Manifest;
import android.app.Activity;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;

import androidx.core.app.ActivityCompat;
import androidx.core.content.ContextCompat;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.PluginRegistry;

/**
 * The Android side of the mic_recorder plugin.
 *
 * <p>Registers one MethodChannel and two EventChannels on the engine's
 * binary messenger and dispatches every wire verb to a single
 * {@link MicAudioRecorder} (the raw PCM capture engine) and a single
 * {@link MicAudioSession} (the Android audio-session layer):
 *
 * <ul>
 *   <li>{@code com.bilalahmed24.mic_recorder/methods} — the command surface;
 *       unknown verbs reply {@code notImplemented}.</li>
 *   <li>{@code com.bilalahmed24.mic_recorder/audio_stream} — the raw 16-bit
 *       little-endian mono PCM byte chunks captured by the engine.</li>
 *   <li>{@code com.bilalahmed24.mic_recorder/session_events} — audio-focus
 *       and device-change maps emitted by the session layer.</li>
 * </ul>
 *
 * <p>Dispatch implements the full command surface with the
 * foreground-service pending-result protocol: {@code showForegroundNotification}
 * starts {@link MicForegroundService}, holds a pending
 * {@link MethodChannel.Result} keyed by a request id, and the service
 * broadcasts {@code com.bilalahmed24.mic_recorder.FGS_RESULT} (package-scoped)
 * once {@code startForeground()} succeeded or failed. A 5s timeout — and any
 * pre-empting request, and {@code removeForegroundNotification} — completes
 * a pending result with {@code success(false)}.
 *
 * <p>Verbs that exist on iOS only reply benign values (Dart gates them by
 * platform anyway): {@code getCurrentRoute} replies {@code null} — REQUIRED,
 * Dart's {@code getAudioDevices()} probes it first and falls back to the
 * {@code getAudioDevices} verb only on a null route.
 *
 * <p>{@link #onDetachedFromEngine} ports the original MainActivity.onDestroy:
 * cancel the FGS timeout, complete a pending result with {@code false},
 * unregister the FGS receiver, stop the service, null the channels, then
 * release the recorder and the session.
 */
public class MicRecorderPlugin implements FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware {

    private static final String TAG = "MicRecorder";

    /** MethodChannel name (frozen wire contract). */
    private static final String METHOD_CHANNEL_NAME = "com.bilalahmed24.mic_recorder/methods";

    /** EventChannel carrying the raw PCM audio stream (frozen wire contract). */
    private static final String AUDIO_STREAM_CHANNEL_NAME =
            "com.bilalahmed24.mic_recorder/audio_stream";

    /** EventChannel carrying session events (frozen wire contract). */
    private static final String SESSION_EVENTS_CHANNEL_NAME =
            "com.bilalahmed24.mic_recorder/session_events";

    /**
     * How long showForegroundNotification waits for the service's
     * result broadcast before completing the pending result with false
     * (5 seconds).
     */
    private static final long FGS_RESULT_TIMEOUT_MS = 5000L;

    /** Default bar count for extractAmplitudes when the caller omits barCount. */
    private static final int DEFAULT_BAR_COUNT = 60;

    /** requestPermissions code for the RECORD_AUDIO runtime request. */
    private static final int MIC_PERMISSION_REQUEST_CODE = 48371;

    /** The fallback bit rate when the wire carries none (Dart always sends one). */
    private static final int DEFAULT_ENCODED_BIT_RATE = 128000;

    /**
     * The sample rate used by resumeRecording. The frozen wire verb takes no
     * argument, and resume is defined as start-with-last-rate — so the
     * plugin tracks the last rate here.
     */
    private int defaultSampleRate = 16000;

    private Context applicationContext;

    private final Handler mainHandler = new Handler(Looper.getMainLooper());

    private MicAudioRecorder recorder;
    private MicAudioSession session;

    /** The armed encoded output (fed from the audio-stream tee). */
    private MicAudioEncoder encodedEncoder;

    /** The host activity while attached (permission requests need it). */
    private Activity activity;

    /** The in-flight permission request's reply (one at a time). */
    private MethodChannel.Result pendingPermissionResult;

    private MethodChannel methodChannel;
    private EventChannel audioStreamChannel;
    private EventChannel sessionEventsChannel;

    // ---------------------------------------------------------------------
    // Foreground-service pending-result protocol (MainActivity port).
    // ---------------------------------------------------------------------

    private Intent fgsServiceIntent;
    private MethodChannel.Result pendingFgsResult;
    private String pendingFgsRequestId;

    /** Completes a pending showForegroundNotification with false. */
    private final Runnable fgsTimeout = () -> {
        if (pendingFgsResult == null) {
            return;
        }

        MethodChannel.Result result = pendingFgsResult;

        pendingFgsResult = null;
        pendingFgsRequestId = null;

        completeQuietly(() -> result.success(false));
    };

    /** Receives the FGS start result broadcast (request-id matched). */
    private final BroadcastReceiver fgsResultReceiver = new BroadcastReceiver() {
        @Override
        public void onReceive(Context context, Intent intent) {
            if (!MicForegroundService.ACTION_FGS_RESULT.equals(intent.getAction())) {
                return;
            }

            String requestId = intent.getStringExtra(MicForegroundService.EXTRA_REQUEST_ID);
            boolean success = intent.getBooleanExtra(MicForegroundService.EXTRA_SUCCESS, false);

            if (pendingFgsRequestId == null || !pendingFgsRequestId.equals(requestId)) {
                return;
            }

            completePendingFgsResult(success);
        }
    };

    /* ********************************************************************
     * FlutterPlugin lifecycle.
     * ******************************************************************** */

    @Override
    public void onAttachedToEngine(FlutterPlugin.FlutterPluginBinding binding) {
        applicationContext = binding.getApplicationContext();

        recorder = new MicAudioRecorder(applicationContext, mainHandler);
        session = new MicAudioSession(applicationContext, mainHandler);

        methodChannel = new MethodChannel(binding.getBinaryMessenger(), METHOD_CHANNEL_NAME);
        methodChannel.setMethodCallHandler(this);

        // Raw PCM byte[] stream from the capture engine.
        audioStreamChannel = new EventChannel(binding.getBinaryMessenger(), AUDIO_STREAM_CHANNEL_NAME);
        audioStreamChannel.setStreamHandler(new EventChannel.StreamHandler() {
            @Override
            public void onListen(Object arguments, EventChannel.EventSink events) {
                // The tee feeds the armed encoded encoder from the same
                // chunks the Dart stream receives.
                recorder.setAudioEventSink(wrapAudioSink(events));
            }

            @Override
            public void onCancel(Object arguments) {
                recorder.setAudioEventSink(null);
            }
        });

        // Audio-focus / device-change maps from the session layer.
        sessionEventsChannel = new EventChannel(
                binding.getBinaryMessenger(), SESSION_EVENTS_CHANNEL_NAME);
        sessionEventsChannel.setStreamHandler(new EventChannel.StreamHandler() {
            @Override
            public void onListen(Object arguments, EventChannel.EventSink events) {
                session.setSessionEventSink(events);
            }

            @Override
            public void onCancel(Object arguments) {
                session.setSessionEventSink(null);
            }
        });

        fgsServiceIntent = new Intent(applicationContext, MicForegroundService.class);

        // App-internal broadcast: package-scoped by the sender and
        // RECEIVER_NOT_EXPORTED here (satisfies the Android 14
        // receiver-flag requirement).
        IntentFilter filter = new IntentFilter(MicForegroundService.ACTION_FGS_RESULT);

        ContextCompat.registerReceiver(
                applicationContext, fgsResultReceiver, filter, ContextCompat.RECEIVER_NOT_EXPORTED);
    }

    /**
     * MainActivity.onDestroy port: cancel the FGS timeout, complete a pending
     * result with false, unregister the FGS receiver, stop the service, null
     * the channels, then release the recorder and the session.
     */
    @Override
    public void onDetachedFromEngine(FlutterPlugin.FlutterPluginBinding binding) {
        mainHandler.removeCallbacks(fgsTimeout);

        if (pendingFgsResult != null) {
            MethodChannel.Result pending = pendingFgsResult;

            pendingFgsResult = null;
            pendingFgsRequestId = null;

            completeQuietly(() -> pending.success(false));
        }

        if (applicationContext != null) {
            try {
                applicationContext.unregisterReceiver(fgsResultReceiver);
            } catch (IllegalArgumentException ignored) {
                // Already unregistered.
            }
        }

        // Stop the foreground service.
        if (fgsServiceIntent != null && applicationContext != null) {
            try {
                applicationContext.stopService(fgsServiceIntent);
            } catch (Exception ignored) {
                // The service may already be gone.
            }
        }

        fgsServiceIntent = null;

        if (methodChannel != null) {
            methodChannel.setMethodCallHandler(null);
            methodChannel = null;
        }

        if (audioStreamChannel != null) {
            audioStreamChannel.setStreamHandler(null);
            audioStreamChannel = null;
        }

        if (sessionEventsChannel != null) {
            sessionEventsChannel.setStreamHandler(null);
            sessionEventsChannel = null;
        }

        if (recorder != null) {
            recorder.release();
            recorder = null;
        }

        if (encodedEncoder != null) {
            encodedEncoder.abort();
            encodedEncoder = null;
        }

        if (session != null) {
            session.release();
            session = null;
        }

        applicationContext = null;
    }

    /* ********************************************************************
     * ActivityAware: RECORD_AUDIO runtime requests.
     * ******************************************************************** */

    @Override
    public void onAttachedToActivity(ActivityPluginBinding binding) {
        activity = binding.getActivity();

        binding.addRequestPermissionsResultListener(permissionResultListener);
    }

    @Override
    public void onDetachedFromActivity() {
        activity = null;

        if (pendingPermissionResult != null) {
            MethodChannel.Result pending = pendingPermissionResult;

            pendingPermissionResult = null;

            completeQuietly(() -> pending.success(false));
        }
    }

    @Override
    public void onReattachedToActivityForConfigChanges(ActivityPluginBinding binding) {
        activity = binding.getActivity();

        binding.addRequestPermissionsResultListener(permissionResultListener);
    }

    @Override
    public void onDetachedFromActivityForConfigChanges() {
        activity = null;
    }

    private final PluginRegistry.RequestPermissionsResultListener permissionResultListener =
            (requestCode, permissions, grantResults) -> {
                if (requestCode != MIC_PERMISSION_REQUEST_CODE) return false;

                final MethodChannel.Result pending = pendingPermissionResult;

                pendingPermissionResult = null;

                if (pending != null) {
                    final boolean granted = grantResults.length > 0
                            && grantResults[0] == PackageManager.PERMISSION_GRANTED;

                    completeQuietly(() -> pending.success(granted));
                }

                return true;
            };

    private boolean isRecordAudioGranted() {
        return ContextCompat.checkSelfPermission(
                applicationContext, Manifest.permission.RECORD_AUDIO)
                == PackageManager.PERMISSION_GRANTED;
    }

    /* ********************************************************************
     * Encoded output tee.
     * ******************************************************************** */

    /**
     * Wraps the Dart-facing audio sink so every captured chunk also feeds
     * the armed {@link MicAudioEncoder} — encoded output runs alongside the
     * raw stream from the same capture pipeline.
     */
    private EventChannel.EventSink wrapAudioSink(EventChannel.EventSink delegate) {
        return new EventChannel.EventSink() {
            @Override
            public void success(Object event) {
                final MicAudioEncoder encoder = encodedEncoder;

                if (encoder != null && event instanceof byte[]) {
                    // write() aborts itself (and deletes the file) on codec
                    // failure; the stale reference no-ops afterwards.
                    encoder.write((byte[]) event);
                }

                delegate.success(event);
            }

            @Override
            public void error(String errorCode, String errorMessage, Object errorDetails) {
                delegate.error(errorCode, errorMessage, errorDetails);
            }

            @Override
            public void endOfStream() {
                delegate.endOfStream();
            }
        };
    }

    /* ********************************************************************
     * MethodChannel dispatch (frozen wire contract).
     * ******************************************************************** */

    @Override
    public void onMethodCall(MethodCall call, MethodChannel.Result result) {
        try {
            dispatchMethodCall(call, result);
        } catch (Exception e) {
            // Any unexpected handler failure must surface as a typed
            // PlatformException, never as a crash.
            Log.e(TAG, "Unexpected error handling '" + call.method + "'", e);

            completeQuietly(() -> result.error(
                    "mic_recorder_error",
                    e.getMessage() != null ? e.getMessage() : e.getClass().getSimpleName(),
                    null));
        }
    }

    private void dispatchMethodCall(MethodCall call, MethodChannel.Result result) {
        if (recorder == null || session == null || applicationContext == null) {
            result.error("mic_recorder_error", "mic_recorder is not attached to the engine", null);
            return;
        }

        switch (call.method) {
            case "startRecording": {
                int sampleRate = intArgument(call, "sampleRate", defaultSampleRate);

                defaultSampleRate = sampleRate;

                // Best-effort platform capture effects (Dart defaults all
                // false — the historic behavior unless opted in).
                recorder.setAudioEffects(
                        boolArgument(call, "echoCancel", false),
                        boolArgument(call, "noiseSuppress", false),
                        boolArgument(call, "autoGain", false));

                // An encoder armed against a different rate cannot be
                // salvaged mid-flight — drop it loudly rather than ship
                // pitch-shifted audio.
                final MicAudioEncoder armedEncoder = encodedEncoder;

                if (armedEncoder != null && armedEncoder.sampleRate() != sampleRate) {
                    Log.w(TAG, "Dropping armed encoded output: sample-rate mismatch "
                            + armedEncoder.sampleRate() + " != " + sampleRate);

                    armedEncoder.abort();
                    encodedEncoder = null;
                }

                boolean isStarted = recorder.startRecording(sampleRate);

                result.success(isStarted);
                break;
            }

            case "pauseRecording": {
                // Android pause == full teardown: the engine has no paused
                // state, and the pause verb stops the recorder outright.
                // isPausedForInterruption is an iOS-only
                // distinction — accepted and ignored.
                recorder.stopRecording();

                result.success(true);
                break;
            }

            case "resumeRecording": {
                // The wire verb carries no argument; resume is a fresh start
                // at the tracked last rate.
                boolean isResumed = recorder.startRecording(defaultSampleRate);

                result.success(isResumed);
                break;
            }

            case "stopRecording": {
                recorder.stopRecording();

                // Only the stop verb finalizes the encoded file — the
                // pause verbs deliberately keep the encoder alive.
                final MicAudioEncoder encoder = encodedEncoder;

                encodedEncoder = null;

                if (encoder != null) encoder.finish();

                result.success(true);
                break;
            }

            case "setEncodedOutput": {
                final String path = stringArgument(call, "path");
                final String encoderName = stringArgument(call, "encoder");

                if (path == null || path.isEmpty()
                        || encoderName == null || encoderName.isEmpty()) {
                    result.success(false);
                    break;
                }

                final Integer bitRate = intArgumentOrNull(call, "bitRate");

                // The Dart layer always sends the configured capture rate;
                // the last-started rate is only a fallback for foreign
                // callers, so arming BEFORE the first start works.
                final int encoderSampleRate =
                        intArgument(call, "sampleRate", defaultSampleRate);

                if (encodedEncoder != null) {
                    encodedEncoder.abort();
                    encodedEncoder = null;
                }

                try {
                    encodedEncoder = MicAudioEncoder.create(
                            path,
                            encoderName,
                            encoderSampleRate,
                            bitRate != null ? bitRate : DEFAULT_ENCODED_BIT_RATE);

                    result.success(true);
                } catch (Exception e) {
                    Log.e(TAG, "setEncodedOutput failed: " + e.getMessage());

                    encodedEncoder = null;

                    result.success(false);
                }
                break;
            }

            case "clearEncodedOutput": {
                final MicAudioEncoder encoder = encodedEncoder;

                encodedEncoder = null;

                if (encoder != null) encoder.abort();

                result.success(true);
                break;
            }

            case "checkMicPermission": {
                result.success(isRecordAudioGranted());
                break;
            }

            case "requestMicPermission": {
                if (isRecordAudioGranted()) {
                    result.success(true);
                    break;
                }

                final Activity currentActivity = activity;

                if (currentActivity == null) {
                    // Headless engine (no activity to host the system
                    // dialog): report the current state.
                    result.success(false);
                    break;
                }

                if (pendingPermissionResult != null) {
                    final MethodChannel.Result stale = pendingPermissionResult;

                    pendingPermissionResult = null;

                    completeQuietly(() -> stale.success(false));
                }

                pendingPermissionResult = result;

                ActivityCompat.requestPermissions(
                        currentActivity,
                        new String[]{Manifest.permission.RECORD_AUDIO},
                        MIC_PERMISSION_REQUEST_CODE);
                break;
            }

            case "microphoneInterrupted": {
                // iOS-only verb; benign Android reply.
                result.success(false);
                break;
            }

            case "setBluetoothStatus": {
                // A missing arg normalizes to true.
                boolean isAllowed = boolArgument(call, "isAllowed", true);

                recorder.setBluetoothStatus(isAllowed);

                result.success(true);
                break;
            }

            case "getRouteState": {
                result.success(recorder.getRouteState());
                break;
            }

            case "extractAmplitudes": {
                handleExtractAmplitudes(call, result);
                break;
            }

            case "configureAudioSession": {
                Map<?, ?> config = mapArgument(call, "config");

                session.configureAudioSession(
                        boolFromMap(config, "allowBluetooth", false),
                        boolFromMap(config, "defaultToSpeaker", false),
                        boolFromMap(config, "notifyOthersOnDeactivation", false),
                        boolFromMap(config, "willPauseWhenDucked", false));

                result.success(true);
                break;
            }

            case "setAudioSessionActive": {
                boolean isActive = boolArgument(call, "active", true);

                result.success(session.setAudioSessionActive(isActive));
                break;
            }

            case "isOtherAudioPlaying": {
                result.success(session.isOtherAudioPlaying());
                break;
            }

            case "isMusicActive": {
                result.success(session.isMusicActive());
                break;
            }

            case "getAudioMode": {
                result.success(session.getMode());
                break;
            }

            case "setAllowHapticsAndSystemSoundsDuringRecording": {
                // iOS-only verb; benign Android reply.
                result.success(null);
                break;
            }

            case "getAudioDevices": {
                result.success(session.getInputDevices());
                break;
            }

            case "getAvailableInputs": {
                // iOS-only verb; benign Android reply.
                result.success(new ArrayList<>());
                break;
            }

            case "getCurrentRoute": {
                // iOS-only verb. The null reply is REQUIRED: Dart's
                // getAudioDevices() probes getCurrentRoute first and falls
                // back to the getAudioDevices verb only on null.
                result.success(null);
                break;
            }

            case "setPreferredInput": {
                // iOS-only verb; benign Android reply.
                result.success(false);
                break;
            }

            case "showForegroundNotification": {
                handleShowForegroundNotification(call, result);
                break;
            }

            case "removeForegroundNotification": {
                handleRemoveForegroundNotification(result);
                break;
            }

            default:
                result.notImplemented();
        }
    }

    /* ********************************************************************
     * Verb implementations (non-trivial ones).
     * ******************************************************************** */

    /**
     * extractAmplitudes{filePath, barCount} -> List&lt;Double&gt;. Decoding
     * is heavy, so it runs on a worker thread; the result is delivered on
     * the main thread.
     */
    private void handleExtractAmplitudes(MethodCall call, MethodChannel.Result result) {
        final String filePath = stringArgument(call, "filePath");
        final Integer barCount = intArgumentOrNull(call, "barCount");

        if (filePath == null || filePath.isEmpty()) {
            result.error("invalid_path", "File path is null or empty", null);
            return;
        }

        final int bars = barCount != null ? barCount : DEFAULT_BAR_COUNT;
        final MicAudioRecorder currentRecorder = recorder;

        if (currentRecorder == null) {
            result.error("mic_recorder_error", "mic_recorder is not attached to the engine", null);
            return;
        }

        Thread worker = new Thread(() -> {
            try {
                final List<Double> amplitudes = currentRecorder.extractAmplitudes(filePath, bars);

                // The result must be called on the main thread.
                mainHandler.post(() -> completeQuietly(() -> result.success(amplitudes)));
            } catch (Exception e) {
                final String message = e.getMessage();

                mainHandler.post(() -> completeQuietly(
                        () -> result.error("extraction_failed", message, null)));
            }
        }, "MicRecorder-Amplitudes");

        worker.start();
    }

    /**
     * showForegroundNotification{notificationTitle, channelName?,
     * channelDescription?, icon?} -> bool, via the FGS pending-result
     * protocol ported from the original MainActivity.
     */
    private void handleShowForegroundNotification(MethodCall call, MethodChannel.Result result) {
        String notificationTitle = stringArgument(call, "notificationTitle");
        String channelName = stringArgument(call, "channelName");
        String channelDescription = stringArgument(call, "channelDescription");
        String icon = stringArgument(call, "icon");

        // A previous request still pending: it can never succeed now.
        // Complete it with false before replacing it with this request.
        if (pendingFgsResult != null) {
            MethodChannel.Result preempted = pendingFgsResult;

            pendingFgsResult = null;
            pendingFgsRequestId = null;

            mainHandler.removeCallbacks(fgsTimeout);

            completeQuietly(() -> preempted.success(false));
        }

        String requestId = UUID.randomUUID().toString();
        pendingFgsResult = result;
        pendingFgsRequestId = requestId;

        Intent serviceIntent = fgsServiceIntent;

        if (serviceIntent == null) {
            serviceIntent = new Intent(applicationContext, MicForegroundService.class);
            fgsServiceIntent = serviceIntent;
        }

        serviceIntent.setAction(MicForegroundService.ACTION_START_SERVICE);
        serviceIntent.putExtra(MicForegroundService.EXTRA_NOTIFICATION_TITLE, notificationTitle);
        serviceIntent.putExtra(MicForegroundService.EXTRA_NOTIFICATION_CHANNEL_NAME, channelName);
        serviceIntent.putExtra(
                MicForegroundService.EXTRA_NOTIFICATION_CHANNEL_DESCRIPTION, channelDescription);
        serviceIntent.putExtra(MicForegroundService.EXTRA_NOTIFICATION_ICON, icon);
        serviceIntent.putExtra(MicForegroundService.EXTRA_REQUEST_ID, requestId);

        try {
            startForegroundServiceSafely(serviceIntent);

            mainHandler.postDelayed(fgsTimeout, FGS_RESULT_TIMEOUT_MS);
        } catch (Exception e) {
            Log.e(TAG, "Could not start foreground service: " + e.getMessage());

            if (requestId.equals(pendingFgsRequestId)) {
                pendingFgsResult = null;
                pendingFgsRequestId = null;

                mainHandler.removeCallbacks(fgsTimeout);

                result.success(false);
            }
        }
    }

    /** removeForegroundNotification -> bool: stops the service, pre-completes any pending show with false. */
    private void handleRemoveForegroundNotification(MethodChannel.Result result) {
        // Stop the foreground service.
        try {
            applicationContext.stopService(fgsServiceIntent);
        } catch (Exception ignored) {
            // The service may already be gone.
        }

        if (pendingFgsResult != null) {
            mainHandler.removeCallbacks(fgsTimeout);

            MethodChannel.Result pendingResult = pendingFgsResult;

            pendingFgsResult = null;
            pendingFgsRequestId = null;

            completeQuietly(() -> pendingResult.success(false));
        }

        result.success(true);
    }

    /**
     * startForegroundService exists from API 26; below that the plain
     * startService has the same effect for a started service.
     */
    private void startForegroundServiceSafely(Intent serviceIntent) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            applicationContext.startForegroundService(serviceIntent);
        } else {
            applicationContext.startService(serviceIntent);
        }
    }

    /**
     * Completes the pending showForegroundNotification result with the
     * service's broadcast success.
     */
    private void completePendingFgsResult(boolean success) {
        if (pendingFgsResult == null) {
            return;
        }

        mainHandler.removeCallbacks(fgsTimeout);

        MethodChannel.Result result = pendingFgsResult;

        pendingFgsResult = null;
        pendingFgsRequestId = null;

        completeQuietly(() -> result.success(success));
    }

    /* ********************************************************************
     * Argument normalization (defensive decoding of the wire payloads).
     * ******************************************************************** */

    /** Runs a result-completing action, swallowing the dead-channel case. */
    private static void completeQuietly(Runnable completion) {
        try {
            completion.run();
        } catch (Exception ignored) {
            // The engine may already have detached (e.g. a decode finished
            // while the engine tore down). Never crash on a dead channel.
        }
    }

    private static String stringArgument(MethodCall call, String key) {
        Object value = call.argument(key);
        return value instanceof String ? (String) value : null;
    }

    private static boolean boolArgument(MethodCall call, String key, boolean fallback) {
        Object value = call.argument(key);
        return value instanceof Boolean ? (Boolean) value : fallback;
    }

    /**
     * Accepts the wire int in any of its decodable shapes: a Number (the
     * StandardMessageCodec's int/double) or a legacy stringified int.
     */
    private static int intArgument(MethodCall call, String key, int fallback) {
        Integer value = intArgumentOrNull(call, key);
        return value != null ? value : fallback;
    }

    private static Integer intArgumentOrNull(MethodCall call, String key) {
        Object value = call.argument(key);

        if (value instanceof Number) {
            return ((Number) value).intValue();
        }

        if (value instanceof String) {
            try {
                return Integer.parseInt((String) value);
            } catch (NumberFormatException ignored) {
                // Falls through to the caller's fallback.
            }
        }

        return null;
    }

    private static Map<?, ?> mapArgument(MethodCall call, String key) {
        Object value = call.argument(key);
        return value instanceof Map ? (Map<?, ?>) value : null;
    }

    private static boolean boolFromMap(Map<?, ?> map, String key, boolean fallback) {
        if (map == null) return fallback;

        Object value = map.get(key);
        return value instanceof Boolean ? (Boolean) value : fallback;
    }
}
