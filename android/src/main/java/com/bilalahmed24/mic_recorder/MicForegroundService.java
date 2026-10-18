package com.bilalahmed24.mic_recorder;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.os.Build;
import android.os.IBinder;
import android.util.Log;

import androidx.annotation.Nullable;
import androidx.core.app.NotificationCompat;

/**
 * The microphone foreground service keeping the capture alive while the app
 * records (Android 14+ requires an FGS of the matching type for background
 * microphone access).
 *
 * <p>The service is plugin-owned throughout: the host app never manages
 * it directly (beyond granting the permissions it documents):
 *
 * <ul>
 *   <li>The notification channel is created (and re-synced) from the extras
 *       of every start call — the plugin cannot run the app's
 *       setup-on-launch code.</li>
 *   <li>The tap intent opens the host app's launcher activity instead of the
 *       app's own hard-coded MainActivity.</li>
 *   <li>The small icon resolves from the configured name against the merged
 *       package, falling back to the bundled icon and then a system
 *       drawable — a bad icon name never crashes the service.</li>
 *   <li>Every start attempt reports success/failure to the plugin through a
 *       request-id-matched, package-scoped broadcast
 *       ({@link #ACTION_FGS_RESULT}); the plugin holds the pending
 *       MethodChannel result until it arrives (5s timeout).</li>
 * </ul>
 */
public class MicForegroundService extends Service {

    private static final String TAG = "MicRecorderFGS";

    /**
     * Broadcast action carrying the FGS start result back to the plugin.
     * The intent is package-scoped ({@code setPackage}) so it never leaves
     * the app; the plugin registers for it with RECEIVER_NOT_EXPORTED.
     */
    public static final String ACTION_FGS_RESULT = "com.bilalahmed24.mic_recorder.FGS_RESULT";

    /** Start action for the service intent. */
    public static final String ACTION_START_SERVICE = "ACTION_START_SERVICE";

    /** Request id extra; matches the plugin's pending result. */
    public static final String EXTRA_REQUEST_ID = "REQUEST_ID";

    /** Success boolean extra of the result broadcast. */
    public static final String EXTRA_SUCCESS = "SUCCESS";

    /** Optional error message extra of the result broadcast. */
    public static final String EXTRA_ERROR = "ERROR";

    /** Notification title extra (the per-state title from the Dart config). */
    public static final String EXTRA_NOTIFICATION_TITLE = "NOTIFICATION_TITLE";

    /** Optional notification-channel name extra (host app's label for it). */
    public static final String EXTRA_NOTIFICATION_CHANNEL_NAME = "NOTIFICATION_CHANNEL_NAME";

    /** Optional notification-channel description extra. */
    public static final String EXTRA_NOTIFICATION_CHANNEL_DESCRIPTION =
            "NOTIFICATION_CHANNEL_DESCRIPTION";

    /** Optional small-icon drawable name extra resolved against the merged package. */
    public static final String EXTRA_NOTIFICATION_ICON = "NOTIFICATION_ICON";

    /** Plugin-internal channel id. */
    private static final String NOTIFICATION_CHANNEL_ID = "mic_recorder_status";

    /** Notification id (an arbitrary stable value). */
    private static final int NOTIFICATION_ID = 450279;

    private static final String DEFAULT_CHANNEL_NAME = "Recording";

    private static final String DEFAULT_CHANNEL_DESCRIPTION = "Microphone recording status";

    private static final String DEFAULT_TITLE = "Waiting for instruction...";

    /** System drawable of last resort — exists on every Android version. */
    private static final int FALLBACK_SMALL_ICON = android.R.drawable.ic_btn_speak_now;

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        String title = DEFAULT_TITLE;
        String requestId = null;
        String channelName = null;
        String channelDescription = null;
        String iconName = null;

        if (intent != null) {
            requestId = intent.getStringExtra(EXTRA_REQUEST_ID);

            if (ACTION_START_SERVICE.equals(intent.getAction())) {
                String requestedTitle = intent.getStringExtra(EXTRA_NOTIFICATION_TITLE);

                if (requestedTitle != null) title = requestedTitle;

                channelName = intent.getStringExtra(EXTRA_NOTIFICATION_CHANNEL_NAME);
                channelDescription = intent.getStringExtra(EXTRA_NOTIFICATION_CHANNEL_DESCRIPTION);
                iconName = intent.getStringExtra(EXTRA_NOTIFICATION_ICON);
            }
        }

        // Must exist before startForeground on API 26+, or the notification
        // is silently dropped by the system.
        ensureNotificationChannel(channelName, channelDescription);

        try {
            Notification notification = createNotification(title, resolveSmallIcon(iconName)).build();

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                // The typed overload is required for the microphone FGS type
                // on Android 11+ (the type constant is API 30).
                startForeground(
                        NOTIFICATION_ID,
                        notification,
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE);
            } else {
                startForeground(NOTIFICATION_ID, notification);
            }

            sendForegroundResult(requestId, true, null);
        } catch (Exception e) {
            Log.e(TAG, "startForeground() failed. requestId=" + requestId, e);

            sendForegroundResult(requestId, false, e.getMessage());
        }

        return START_NOT_STICKY;
    }

    @Override
    public void onDestroy() {
        super.onDestroy();

        // Kept from the source service (harmless: it is already being
        // destroyed; a stopSelf() here also clears any pending self-stop).
        stopSelf();
    }

    @Nullable
    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    /* ********************************************************************
     * Notification building.
     * ******************************************************************** */

    /**
     * Creates the channel when it does not exist yet, and re-syncs the
     * user-visible name/description from the latest call's extras (creating
     * an existing channel updates those two fields — importance changes are
     * user-controlled and ignored).
     *
     * <p>No-op below API 26 (no channels exist there).
     *
     * @param channelName        the configured channel name, or null for
     *                           the default ("Recording")
     * @param channelDescription the configured channel description, or null
     *                           for the default
     */
    private void ensureNotificationChannel(String channelName, String channelDescription) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return;

        NotificationManager manager =
                (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);

        if (manager == null) return;

        NotificationChannel channel = new NotificationChannel(
                NOTIFICATION_CHANNEL_ID,
                channelName != null ? channelName : DEFAULT_CHANNEL_NAME,
                NotificationManager.IMPORTANCE_DEFAULT);

        channel.setDescription(
                channelDescription != null ? channelDescription : DEFAULT_CHANNEL_DESCRIPTION);

        manager.createNotificationChannel(channel);
    }

    /**
     * Builds the ongoing recording status notification.
     *
     * @param title     the notification title (per-state, from Dart config)
     * @param smallIcon the resolved small-icon resource id
     * @return the notification builder
     */
    private NotificationCompat.Builder createNotification(String title, int smallIcon) {
        NotificationCompat.Builder builder = new NotificationCompat.Builder(
                        this, NOTIFICATION_CHANNEL_ID)
                .setSmallIcon(smallIcon)
                .setContentTitle(title)
                .setOngoing(true);

        // Opens the host app when tapped — the plugin cannot reference the
        // host's own activity class, so the launch intent is resolved by
        // package instead.
        Intent launchIntent = getPackageManager().getLaunchIntentForPackage(getPackageName());

        if (launchIntent != null) {
            PendingIntent pendingIntent = PendingIntent.getActivity(
                    this, 0, launchIntent, PendingIntent.FLAG_IMMUTABLE);

            builder.setContentIntent(pendingIntent);
        }

        return builder;
    }

    /**
     * Resolves the notification small icon:
     * <ol>
     *   <li>an icon name configured by the host app, resolved as a drawable
     *       against the merged package ({@code getIdentifier} returns 0 —
     *       never throws — for a name that does not exist);</li>
     *   <li>the icon bundled with this plugin ({@code ic_stat_mic});</li>
     *   <li>a system drawable that is present on every Android version.</li>
     * </ol>
     *
     * @param configuredIconName the icon name from the Dart config, or null
     * @return the small-icon resource id (never 0)
     */
    private int resolveSmallIcon(String configuredIconName) {
        if (configuredIconName != null && !configuredIconName.isEmpty()) {
            int configured =
                    getResources().getIdentifier(configuredIconName, "drawable", getPackageName());

            if (configured != 0) {
                return configured;
            }

            Log.w(TAG, "Notification icon '" + configuredIconName
                    + "' not found; using the bundled icon");
        }

        return R.drawable.ic_stat_mic != 0 ? R.drawable.ic_stat_mic : FALLBACK_SMALL_ICON;
    }

    /* ********************************************************************
     * Result reporting.
     * ******************************************************************** */

    /**
     * Broadcasts the start result to the plugin. The intent is
     * package-scoped so it stays app-internal; the plugin matches the
     * request id against its pending MethodChannel result.
     *
     * @param requestId the request id from the start intent (may be null —
     *                  then the plugin ignores the broadcast)
     * @param success   whether startForeground succeeded
     * @param error     optional failure message
     */
    private void sendForegroundResult(String requestId, boolean success, String error) {
        Intent intent = new Intent(ACTION_FGS_RESULT);

        intent.setPackage(getPackageName());
        intent.putExtra(EXTRA_REQUEST_ID, requestId);
        intent.putExtra(EXTRA_SUCCESS, success);

        if (error != null) {
            intent.putExtra(EXTRA_ERROR, error);
        }

        sendBroadcast(intent);
    }
}
