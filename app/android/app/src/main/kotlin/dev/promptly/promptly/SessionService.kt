package dev.promptly.promptly

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

// Keeps the app running while it is in the background and sessions are
// open, so they stay connected; otherwise Android soon stops a background
// app and its connections with it. Its notification says how many sessions
// are open and brings the app back when tapped. MainActivity starts and
// stops it as the app reports its open sessions.
class SessionService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val open = intent?.getIntExtra(EXTRA_OPEN, 1) ?: 1
        val shown = notification(this, open)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIFICATION_ID, shown, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIFICATION_ID, shown)
        }
        running = true
        // Not restarted if Android stops it: the sessions went with the app.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        running = false
        super.onDestroy()
    }

    companion object {
        const val EXTRA_OPEN = "open"
        private const val NOTIFICATION_ID = 1
        private const val CHANNEL_ID = "sessions"

        // Whether the service is up, so a new count only updates its notification.
        @Volatile
        var running = false

        fun update(context: Context, open: Int) {
            context.getSystemService(NotificationManager::class.java)
                .notify(NOTIFICATION_ID, notification(context, open))
        }

        private fun notification(context: Context, open: Int): Notification {
            val manager = context.getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Open sessions", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "Shown while sessions are open, so they keep running in the background."
                    setShowBadge(false)
                },
            )
            // Back to the app as it was, as its icon in the launcher does.
            val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
                ?: Intent(context, MainActivity::class.java)
            val tap = PendingIntent.getActivity(
                context,
                0,
                launch,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            val title = if (open == 1) "Promptly: 1 session open" else "Promptly: $open sessions open"
            return Notification.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.mipmap.ic_launcher_monochrome)
                .setContentTitle(title)
                .setContentText("Tap to go back to your sessions.")
                .setContentIntent(tap)
                .setOngoing(true)
                .setShowWhen(false)
                .setCategory(Notification.CATEGORY_SERVICE)
                .build()
        }
    }
}
