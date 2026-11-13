package com.justspeaktoit.android.dictation

import android.Manifest
import android.annotation.SuppressLint
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationChannelCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import com.justspeaktoit.android.R

/**
 * The microphone foreground service that keeps a dictation running while another app is in front or
 * the screen is off. It owns no audio: the session keeps capturing in the app's process and this only
 * shows the ongoing notification, whose Stop action finishes the session like the Stop button.
 *
 * Android 14+ only lets a microphone service start while the app is visible, so the session starts it
 * when capture starts, never on leaving the app.
 */
class DictationForegroundService : Service() {
    private var foreground = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        val channel = NotificationChannelCompat.Builder(CHANNEL_ID, NotificationManagerCompat.IMPORTANCE_LOW)
            .setName(getString(R.string.notification_channel_dictation))
            .setDescription(getString(R.string.notification_channel_dictation_description))
            .setShowBadge(false)
            .build()
        NotificationManagerCompat.from(this).createNotificationChannel(channel)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            val listener = ForegroundDictation.listener
            if (listener == null) stopSelf() else listener.onStopRequested()
            return START_NOT_STICKY
        }
        val phase = ForegroundPhase.entries.firstOrNull { it.name == intent?.getStringExtra(EXTRA_PHASE) }
            ?: ForegroundPhase.Recording
        if (foreground) update(phase) else enterForeground(phase)
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }

    // The microphone type is 128 on every release; ServiceCompat drops it below Android 11.
    @SuppressLint("InlinedApi")
    private fun enterForeground(phase: ForegroundPhase) {
        try {
            ServiceCompat.startForeground(
                this,
                NOTIFICATION_ID,
                notification(phase),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
            )
            foreground = true
        } catch (e: IllegalStateException) {
            // ForegroundServiceStartNotAllowedException: the app was no longer visible.
            refuse()
        } catch (e: SecurityException) {
            // The microphone permission was missing or not usable from where the app was.
            refuse()
        }
    }

    private fun refuse() {
        ForegroundDictation.listener?.onForegroundRefused()
        stopSelf()
    }

    /** Updated in place: calling startForeground again from the background could be refused. */
    private fun update(phase: ForegroundPhase) {
        val allowed = Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        if (allowed) NotificationManagerCompat.from(this).notify(NOTIFICATION_ID, notification(phase))
    }

    private fun notification(phase: ForegroundPhase) = NotificationCompat.Builder(this, CHANNEL_ID)
        .setSmallIcon(R.drawable.ic_mic)
        .setContentTitle(getString(R.string.notification_dictation_title))
        .setContentText(
            getString(
                when (phase) {
                    ForegroundPhase.Recording -> R.string.notification_dictation_recording
                    ForegroundPhase.Paused -> R.string.notification_dictation_paused
                    ForegroundPhase.Finishing -> R.string.notification_dictation_finishing
                },
            ),
        )
        .setOngoing(true)
        .setSilent(true)
        .setCategory(NotificationCompat.CATEGORY_SERVICE)
        .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
        .setContentIntent(openApp())
        .apply {
            if (phase != ForegroundPhase.Finishing) {
                addAction(R.drawable.ic_stop, getString(R.string.notification_action_stop), stopIntent())
            }
        }
        .build()

    private fun openApp(): PendingIntent? {
        val launch = packageManager.getLaunchIntentForPackage(packageName) ?: return null
        return PendingIntent.getActivity(this, 0, launch, PendingIntent.FLAG_IMMUTABLE)
    }

    private fun stopIntent(): PendingIntent = PendingIntent.getService(
        this,
        1,
        Intent(this, DictationForegroundService::class.java).setAction(ACTION_STOP),
        PendingIntent.FLAG_IMMUTABLE,
    )

    internal companion object {
        const val ACTION_STOP = "com.justspeaktoit.android.action.STOP_DICTATION"
        const val EXTRA_PHASE = "phase"
        private const val CHANNEL_ID = "dictation"
        private const val NOTIFICATION_ID = 1
    }
}

/** Starts, updates and stops [DictationForegroundService]. Call from the main thread. */
internal class AndroidForegroundSession(private val context: Context) : ForegroundSession {
    private var running = false

    override fun show(phase: ForegroundPhase): Boolean {
        val intent = Intent(context, DictationForegroundService::class.java)
            .putExtra(DictationForegroundService.EXTRA_PHASE, phase.name)
        return try {
            // A running foreground service counts as foreground, so an update may use startService.
            if (running) context.startService(intent) else ContextCompat.startForegroundService(context, intent)
            running = true
            true
        } catch (e: IllegalStateException) {
            false
        } catch (e: SecurityException) {
            false
        }
    }

    override fun hide() {
        if (!running) return
        running = false
        context.stopService(Intent(context, DictationForegroundService::class.java))
    }
}
